import Foundation
import SwiftData

/// The IO boundary returns immutable committed values, never context-owned models.
@MainActor
protocol FocusRepository {
    func fetchAll() throws -> [FocusSessionSnapshot]
    func create(input: FocusStartInput) throws -> FocusSessionSnapshot
    func transition(id: UUID, command: FocusTransition, effectiveEndedAt: Date?) throws -> FocusSessionSnapshot
}

/// All decisions and the insert use one fresh, non-autosaving context on the main
/// actor. A failed save drops this context; it cannot publish an uncommitted row.
@MainActor
final class SwiftDataFocusRepository: FocusRepository {
    private let container: ModelContainer
    private let makeID: () -> UUID
    private let fetchSessions: (ModelContext) throws -> [FocusSession]
    private let fetchTasks: (ModelContext, UUID) throws -> [TaskItem]
    // A hook must fail before committing, never after a successful save.
    private let save: (ModelContext) throws -> Void

    init(container: ModelContainer, makeID: @escaping () -> UUID = UUID.init,
         fetchSessions: @escaping (ModelContext) throws -> [FocusSession] = {
             try $0.fetch(FetchDescriptor<FocusSession>())
         }, fetchTasks: @escaping (ModelContext, UUID) throws -> [TaskItem] = { context, id in
             try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
         }, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.makeID = makeID
        self.fetchSessions = fetchSessions
        self.fetchTasks = fetchTasks
        self.save = save
    }

    func fetchAll() throws -> [FocusSessionSnapshot] {
        let context = privateContext()
        let rows = try persistedSessions(in: context)
        return try rows.map(FocusSessionSnapshot.init).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func create(input: FocusStartInput) throws -> FocusSessionSnapshot {
        // Reject invalid input before allocating an ID, reading, or attempting a write.
        let clean = try input.validated()
        let context = privateContext()
        // Validate *all* rows, not just those that happen to have a recognized active
        // state. An unknown/corrupt row must not authorize another Start.
        let existing = try persistedSessions(in: context).map(FocusSessionSnapshot.init)
        guard !existing.contains(where: { $0.state.isActive }) else {
            throw FocusError.activeSessionConflict
        }
        let title: String?
        if let taskID = clean.linkedTaskID {
            let matches: [TaskItem]
            do { matches = try fetchTasks(context, taskID) }
            catch { throw FocusError.persistenceFailure }
            guard matches.count == 1, !matches[0].isCompleted else {
                throw FocusError.unavailableTask
            }
            title = matches[0].title
        } else {
            title = nil
        }
        let id = makeID()
        guard !existing.contains(where: { $0.id == id }) else {
            throw FocusError.activeSessionConflict
        }
        // Construct and validate the complete receipt before insertion. In particular,
        // a date too large to represent its deadline must never reach the store.
        let receipt = try FocusSessionSnapshot(
            id: id, state: .running, plannedSeconds: clean.plannedSeconds,
            accumulatedActiveSeconds: 0, activeSegmentStartedAt: clean.startedAt,
            deadline: clean.startedAt.addingTimeInterval(Double(clean.plannedSeconds)),
            startedAt: clean.startedAt, checkpointAt: clean.startedAt,
            linkedTaskID: clean.linkedTaskID, linkedLessonID: clean.linkedLessonID,
            linkedTitleSnapshot: title)
        context.insert(FocusSession(
            id: receipt.id, state: receipt.state.rawValue,
            plannedSeconds: receipt.plannedSeconds, accumulatedActiveSeconds: 0,
            activeSegmentStartedAt: receipt.activeSegmentStartedAt, deadline: receipt.deadline,
            startedAt: receipt.startedAt, checkpointAt: receipt.checkpointAt,
            linkedTaskID: receipt.linkedTaskID, linkedLessonID: receipt.linkedLessonID,
            linkedTitleSnapshot: receipt.linkedTitleSnapshot))
        do { try save(context) }
        catch { throw FocusError.persistenceFailure }
        return receipt // No read after commit can misreport a successful Start as failed.
    }

    /// `effectiveEndedAt` is the monotonic calculation's effective finish instant;
    /// `sampledAt` is the sampled checkpoint time (which can be a later wake).
    /// The stored checkpoint may advance past it to distinguish rollback writes.
    /// The caller passes the former for completion rather than dating history at wake.
    func transition(id: UUID, command: FocusTransition,
                    effectiveEndedAt: Date? = nil) throws -> FocusSessionSnapshot {
        let context = privateContext()
        let rows = try persistedSessions(in: context)
        let matches = rows.filter { $0.id == id }
        guard !matches.isEmpty else { throw FocusError.missingSession }
        guard matches.count == 1 else { throw FocusError.activeSessionConflict }
        let row = matches[0]
        let current = try FocusSessionSnapshot(row)
        // Idempotency precedes payload validation: even a delayed duplicate terminal
        // callback must not change a committed finish time or attempt another save.
        if !current.state.isActive {
            switch command {
            case .end, .complete: return current
            default: throw FocusError.invalidTransition
            }
        }
        let payload: FocusTransitionPayload
        switch command {
        case .pause(let value), .resume(let value), .checkpoint(let value),
             .end(let value), .complete(let value): payload = value
        case .reconcile, .recover: throw FocusError.invalidTransition // Step 2.3
        }
        _ = try payload.validated(plannedSeconds: current.plannedSeconds)
        guard payload.expectedCheckpointAt == current.checkpointAt else {
            throw FocusError.staleBaseline
        }
        guard payload.sampledAt >= current.checkpointAt,
              payload.accumulatedActiveSeconds >= current.accumulatedActiveSeconds else {
            throw FocusError.invalidTransition
        }
        // A rollback may leave the wall timestamp unchanged across pause/resume.
        // Advance this durable logical watermark on every write so old baselines
        // cannot be reused. A millisecond survives store serialization; nextUp
        // also works for Dates with coarser floating-point spacing.
        let previous = current.checkpointAt.timeIntervalSinceReferenceDate
        let next = max(previous.nextUp, previous + 0.001)
        let stamp = Date(timeIntervalSinceReferenceDate:
            max(payload.sampledAt.timeIntervalSinceReferenceDate, next))
        guard stamp.timeIntervalSinceReferenceDate.isFinite, stamp > current.checkpointAt else {
            throw FocusError.invalidTransition
        }
        let elapsed = payload.accumulatedActiveSeconds
        let plan = Double(current.plannedSeconds)
        let newState: FocusSessionState
        var anchor: Date?
        var deadline: Date?
        var pausedAt: Date?
        var endedAt: Date?
        switch command {
        case .pause:
            guard current.state == .running, elapsed < plan else {
                throw FocusError.invalidTransition
            }
            newState = .paused
            pausedAt = stamp
        case .resume:
            guard current.state == .paused, !current.recoveryRequired,
                  elapsed == current.accumulatedActiveSeconds, elapsed < plan else {
                throw FocusError.invalidTransition
            }
            newState = .running
            anchor = stamp
            deadline = stamp.addingTimeInterval(plan - elapsed)
        case .checkpoint:
            guard current.state == .running, elapsed < plan else {
                throw FocusError.invalidTransition
            }
            newState = .running
            anchor = stamp
            deadline = stamp.addingTimeInterval(plan - elapsed)
        case .end:
            guard !current.recoveryRequired, elapsed < plan,
                  current.state == .running ||
                  (current.state == .paused && elapsed == current.accumulatedActiveSeconds),
                  effectiveEndedAt == nil else { throw FocusError.invalidTransition }
            newState = .ended
            endedAt = stamp
        case .complete:
            guard current.state == .running, elapsed == plan else {
                throw FocusError.invalidTransition
            }
            newState = .completed
            // Completion may arrive long after zero (sleep / late callback).
            // Never silently substitute the callback time for the effective finish.
            guard let effectiveEndedAt else { throw FocusError.invalidTransition }
            endedAt = effectiveEndedAt
            guard let endedAt, endedAt.timeIntervalSinceReferenceDate.isFinite,
                  endedAt >= current.startedAt, endedAt <= payload.sampledAt else {
                throw FocusError.invalidTransition
            }
        case .reconcile, .recover:
            throw FocusError.invalidTransition
        }
        // Construct before mutation: rejects unrepresentable deadlines and any
        // inconsistent anchors. Link fields come exclusively from the latest row,
        // never from an older service snapshot or timing calculation.
        let receipt: FocusSessionSnapshot
        do {
            receipt = try FocusSessionSnapshot(
                id: current.id, state: newState, plannedSeconds: current.plannedSeconds,
                accumulatedActiveSeconds: elapsed, activeSegmentStartedAt: anchor,
                deadline: deadline, pausedAt: pausedAt, startedAt: current.startedAt,
                endedAt: endedAt, checkpointAt: stamp,
                linkedTaskID: current.linkedTaskID, linkedLessonID: current.linkedLessonID,
                linkedTitleSnapshot: current.linkedTitleSnapshot)
        } catch { throw FocusError.invalidTransition }
        row.state = receipt.state.rawValue
        row.accumulatedActiveSeconds = receipt.accumulatedActiveSeconds
        row.activeSegmentStartedAt = receipt.activeSegmentStartedAt
        row.deadline = receipt.deadline
        row.pausedAt = receipt.pausedAt
        row.endedAt = receipt.endedAt
        row.checkpointAt = receipt.checkpointAt
        row.recoveryRequired = receipt.recoveryRequired
        do { try save(context) }
        catch { throw FocusError.persistenceFailure }
        return receipt
    }

    private func privateContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func persistedSessions(in context: ModelContext) throws -> [FocusSession] {
        do { return try fetchSessions(context) }
        catch { throw FocusError.persistenceFailure }
    }
}
