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
    private let fetchLessons: (ModelContext) throws -> [LessonDefinition]
    private let fetchProgress: (ModelContext) throws -> [LessonProgress]
    // A hook must fail before committing, never after a successful save.
    private let save: (ModelContext) throws -> Void

    init(container: ModelContainer, makeID: @escaping () -> UUID = UUID.init,
         fetchSessions: @escaping (ModelContext) throws -> [FocusSession] = {
             try $0.fetch(FetchDescriptor<FocusSession>())
         }, fetchTasks: @escaping (ModelContext, UUID) throws -> [TaskItem] = { context, id in
             try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
         }, fetchLessons: @escaping (ModelContext) throws -> [LessonDefinition] = {
             try $0.fetch(FetchDescriptor<LessonDefinition>())
         }, fetchProgress: @escaping (ModelContext) throws -> [LessonProgress] = {
             try $0.fetch(FetchDescriptor<LessonProgress>())
         }, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.makeID = makeID
        self.fetchSessions = fetchSessions
        self.fetchTasks = fetchTasks
        self.fetchLessons = fetchLessons
        self.fetchProgress = fetchProgress
        self.save = save
    }

    func fetchAll() throws -> [FocusSessionSnapshot] {
        let context = privateContext()
        let rows = try persistedSessions(in: context)
        return try checkedSnapshots(rows).sorted {
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
        let existing = try checkedSnapshots(persistedSessions(in: context))
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
        } else if let lessonID = clean.linkedLessonID {
            title = try resolveLessonTitle(lessonID, in: context)
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
        // Inspect the entire store before changing even a valid target. Another active
        // row or a corrupt history row makes the active status untrustworthy.
        let snapshots = try checkedSnapshots(rows)
        let matches = rows.filter { $0.id == id }
        guard let row = matches.first else { throw FocusError.missingSession }
        // Duplicate IDs are rejected by checkedSnapshots.
        guard let current = snapshots.first(where: { $0.id == id }) else {
            throw FocusError.missingSession
        }
        // Idempotency precedes payload validation: delayed duplicate terminal callbacks
        // and recovery decisions must not replace the original finish timestamp.
        if !current.state.isActive {
            switch command {
            case .end, .complete, .reconcile: return current
            case .recover(.end, _) where current.state == .ended: return current
            default: throw FocusError.invalidTransition
            }
        }
        let payload: FocusTransitionPayload
        switch command {
        case .pause(let value), .resume(let value), .checkpoint(let value),
             .end(let value), .complete(let value), .reconcile(let value),
             .recover(_, let value): payload = value
        }
        if case .reconcile = command, current.state == .paused { return current }
        _ = try payload.validated(plannedSeconds: current.plannedSeconds)
        // A second Resume decision may arrive after the first one committed. It
        // returns the stored row, without replaying the old segment or saving again.
        if case .recover(.resume, _) = command, current.state == .running,
           payload.expectedCheckpointAt < current.checkpointAt,
           payload.sampledAt <= current.checkpointAt,
           payload.accumulatedActiveSeconds <= current.accumulatedActiveSeconds {
            return current
        }
        guard payload.expectedCheckpointAt == current.checkpointAt else {
            throw FocusError.staleBaseline
        }
        // Reconciliation carries the *actual* relaunch wall sample. It can be
        // behind the durable checkpoint after a clock rollback; only the
        // resulting write timestamp is clamped to the logical watermark.
        // Other transitions must still submit an ordered sampled timestamp.
        if case .reconcile = command {
            guard payload.accumulatedActiveSeconds >= current.accumulatedActiveSeconds else {
                throw FocusError.invalidTransition
            }
        } else {
            guard payload.sampledAt >= current.checkpointAt,
                  payload.accumulatedActiveSeconds >= current.accumulatedActiveSeconds else {
                throw FocusError.invalidTransition
            }
        }
        if payload.wallAnchorAt != nil {
            guard case .checkpoint = command else { throw FocusError.invalidTransition }
        }
        // The repository verifies the calculation against the latest stored anchors;
        // a caller cannot manufacture a completion or count the closed interval twice.
        if case .reconcile = command {
            guard effectiveEndedAt == nil, current.state == .running,
                  case .changed(let calculated) = try FocusTiming.reconcileOnRelaunch(
                    current, at: payload.sampledAt),
                  calculated.transition == command else { throw FocusError.invalidTransition }
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
        var recoveryRequired = false
        switch command {
        case .pause:
            guard payload.wallAnchorAt == nil, current.state == .running, elapsed < plan else {
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
            // `stamp` is a strictly increasing concurrency watermark. During a
            // rollback the sampled wall anchor is earlier; never use the old
            // watermark as the relaunch clock or restore a stale timing baseline.
            anchor = payload.wallAnchorAt ?? stamp
            deadline = anchor?.addingTimeInterval(plan - elapsed)
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
        case .reconcile:
            // The pure calculation above is already checked against the submitted
            // payload. Recompute only its outcome; do not use stale link metadata.
            let result = try FocusTiming.reconcileOnRelaunch(current, at: payload.sampledAt)
            guard case .changed(let change) = result else { throw FocusError.invalidTransition }
            newState = change.snapshot.state
            pausedAt = newState == .paused ? stamp : nil
            endedAt = change.snapshot.endedAt
            recoveryRequired = newState == .paused
        case .recover(let choice, _):
            guard current.state == .paused, current.recoveryRequired,
                  elapsed == current.accumulatedActiveSeconds,
                  effectiveEndedAt == nil else { throw FocusError.invalidTransition }
            switch choice {
            case .resume:
                newState = .running
                anchor = stamp
                deadline = stamp.addingTimeInterval(plan - elapsed)
            case .end:
                newState = .ended
                endedAt = stamp
            }
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
                endedAt: endedAt, checkpointAt: stamp, recoveryRequired: recoveryRequired,
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

    /// Re-read both sides of the selection in the same non-autosaving creation context.
    /// A failed read is not absence, and contradictory rows are not eligibility.
    private func resolveLessonTitle(_ lessonID: String, in context: ModelContext) throws -> String {
        let definitions: [LessonDefinition]
        let progress: [LessonProgress]
        do {
            definitions = try fetchLessons(context).filter { $0.id == lessonID }
            progress = try fetchProgress(context).filter { $0.lessonID == lessonID }
        } catch { throw FocusError.persistenceFailure }
        guard definitions.count <= 1, progress.count <= 1 else {
            throw FocusError.invalidStoredData
        }
        guard let definition = definitions.first else { throw FocusError.unavailableLesson }
        guard let row = progress.first else { return try validatedLessonTitle(definition) }
        switch row.status {
        case .available, .started:
            guard row.completedAt == nil else { throw FocusError.invalidStoredData }
            return try validatedLessonTitle(definition)
        case .completed, .dismissed: throw FocusError.unavailableLesson
        }
    }

    private func validatedLessonTitle(_ definition: LessonDefinition) throws -> String {
        func nonblank(_ text: String) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let concepts = definition.conceptIDs
        let prerequisites = definition.prerequisiteConceptIDs
        // A link must point to a usable lesson, not merely a row with an ID/title.
        // Check the same required fields and teaching-content fingerprint as catalog import;
        // do not let a damaged installed definition authorize a new session.
        guard nonblank(definition.id), nonblank(definition.objectiveKey),
              nonblank(definition.objective), nonblank(definition.title),
              nonblank(definition.topicID), nonblank(definition.subtopicID),
              !concepts.isEmpty, concepts.allSatisfy(nonblank),
              Set(concepts).count == concepts.count,
              prerequisites.allSatisfy(nonblank),
              Set(prerequisites).count == prerequisites.count,
              ["basic", "intermediate", "advanced"].contains(definition.difficulty),
              ["learn", "code", "question", "design"].contains(definition.format),
              definition.estimatedMinutes > 0,
              nonblank(definition.explanation), nonblank(definition.workedExample),
              nonblank(definition.exercise), nonblank(definition.referenceAnswer),
              !definition.selfCheckCriteria.isEmpty,
              definition.selfCheckCriteria.allSatisfy(nonblank),
              definition.contentVersion > 0, nonblank(definition.normalizedContentHash),
              ["seed", "generated"].contains(definition.source),
              nonblank(definition.provenance) else {
            throw FocusError.invalidStoredData
        }
        let content = LessonDTO(
            id: definition.id, objectiveKey: definition.objectiveKey,
            objective: definition.objective, title: definition.title,
            topicID: definition.topicID, subtopicID: definition.subtopicID,
            conceptIDs: concepts, difficulty: definition.difficulty,
            format: definition.format, estimatedMinutes: definition.estimatedMinutes,
            prerequisiteConceptIDs: prerequisites, explanation: definition.explanation,
            workedExample: definition.workedExample, exercise: definition.exercise,
            referenceAnswer: definition.referenceAnswer,
            selfCheckCriteria: definition.selfCheckCriteria,
            contentVersion: definition.contentVersion,
            normalizedContentHash: definition.normalizedContentHash,
            source: definition.source, provenance: definition.provenance)
        guard definition.normalizedContentHash == CatalogValidator.fingerprint(for: content) else {
            throw FocusError.invalidStoredData
        }
        return definition.title
    }

    private func checkedSnapshots(_ rows: [FocusSession]) throws -> [FocusSessionSnapshot] {
        let values = try rows.map(FocusSessionSnapshot.init)
        guard values.filter({ $0.state.isActive }).count <= 1,
              Set(values.map(\.id)).count == values.count else {
            throw FocusError.activeSessionConflict
        }
        return values
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
