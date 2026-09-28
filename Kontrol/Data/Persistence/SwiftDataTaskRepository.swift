import Foundation
import SwiftData

enum TaskRepositoryError: Error, Equatable {
    case notFound(UUID)
}

@MainActor
protocol TaskRepository {
    /// A nil plan captures today's local calendar day in this foundation slice.
    func create(title: String, plannedFor: PlannedDay?) throws -> UUID
    /// Unlike legacy capture, a nil plan here means unplanned.
    func create(input: TaskInput) throws -> TaskSnapshot
    func update(id: UUID, input: TaskInput) throws -> TaskSnapshot
    func fetchAll() throws -> [TaskItem]
}

/// Each write uses its own non-autosaving context. A failed commit drops only
/// that operation's changes, never a draft in another owner (including views).
@MainActor
final class SwiftDataTaskRepository: TaskRepository {
    private let container: ModelContainer
    private let now: () -> Date
    private let makeID: () -> UUID
    private let calendar: () -> Calendar
    private let timeZone: () -> TimeZone
    // The hook must fail *instead of* committing, never after a successful save.
    private let save: (ModelContext) throws -> Void

    init(container: ModelContainer, now: @escaping () -> Date = Date.init,
         makeID: @escaping () -> UUID = UUID.init,
         calendar: @escaping () -> Calendar = { .current },
         timeZone: @escaping () -> TimeZone = { .current },
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.now = now
        self.makeID = makeID
        self.calendar = calendar
        self.timeZone = timeZone
        self.save = save
    }

    func create(title: String, plannedFor: PlannedDay? = nil) throws -> UUID {
        try createValidated(TaskInput(title: title, plannedFor: plannedFor),
                            defaultToToday: true).id
    }

    func create(input: TaskInput) throws -> TaskSnapshot {
        try createValidated(input, defaultToToday: false)
    }

    private func createValidated(_ input: TaskInput, defaultToToday: Bool) throws -> TaskSnapshot {
        // Reject invalid input before consuming an ID or opening a write context.
        let clean = try input.validated()
        let createdAt = now()
        let day = try (defaultToToday && clean.plannedFor == nil
            ? PlannedDay.today(at: createdAt, calendar: calendar(), timeZone: timeZone()).validated()
            : clean.plannedFor)
        let id = makeID()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let task = try TaskItem(id: id, title: clean.title, createdAt: createdAt,
                                notes: clean.notes, dueAt: clean.dueAt,
                                plannedDay: day?.components, plannedTimeZoneID: day?.timeZoneID)
        context.insert(task)
        // On error the unsaved private context is discarded. Never roll back the
        // shared main context, or save a partially failed operation later.
        try save(context)
        // No post-commit fetch: a read failure must not report a committed insert as failed.
        return TaskSnapshot(task)
    }

    func update(id: UUID, input: TaskInput) throws -> TaskSnapshot {
        // Validate before touching the stored object. Only editable fields are
        // copied from the draft; completion is always read from the current row.
        let clean = try input.validated()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let task = try context.fetch(descriptor).first else {
            throw TaskRepositoryError.notFound(id)
        }
        task.title = clean.title
        task.notes = clean.notes
        task.dueAt = clean.dueAt
        task.plannedDay = clean.plannedFor?.components
        task.plannedTimeZoneID = clean.plannedFor?.timeZoneID
        // A failed save discards this context; no other owner's changes are rolled back.
        try save(context)
        return TaskSnapshot(task)
    }

    func fetchAll() throws -> [TaskItem] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try context.fetch(FetchDescriptor<TaskItem>()).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
