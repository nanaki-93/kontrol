import Foundation
import SwiftData

/// The IO boundary returns immutable committed values, never context-owned models.
@MainActor
protocol FocusRepository {
    func fetchAll() throws -> [FocusSessionSnapshot]
    func create(input: FocusStartInput) throws -> FocusSessionSnapshot
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
