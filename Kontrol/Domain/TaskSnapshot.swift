import Foundation

/// Editor input. A nil plan means unplanned (unlike legacy quick capture's nil = Today).
struct TaskInput: Equatable {
    var title: String
    var notes: String?
    var dueAt: Date?
    var plannedFor: PlannedDay?

    init(title: String, notes: String? = nil, dueAt: Date? = nil,
         plannedFor: PlannedDay? = nil) {
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.plannedFor = plannedFor
    }

    func validated() throws -> TaskInput {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw KontrolSchemaV1.TaskValidationError.emptyTitle }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskInput(title: trimmedTitle,
                         notes: trimmedNotes.flatMap { $0.isEmpty ? nil : $0 },
                         dueAt: dueAt, // An absolute instant; never convert to a planned day.
                         plannedFor: try plannedFor?.validated())
    }
}

/// Copies every persisted field; no SwiftData object or ModelContext is retained.
struct TaskSnapshot: Equatable, Identifiable {
    let id: UUID
    let title: String
    let notes: String?
    let dueAt: Date?
    let plannedDay: KontrolSchemaV1.PlannedDayComponents?
    let plannedTimeZoneID: String?
    let createdAt: Date
    let completedAt: Date?

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        notes = task.notes
        dueAt = task.dueAt
        plannedDay = task.plannedDay
        plannedTimeZoneID = task.plannedTimeZoneID
        createdAt = task.createdAt
        completedAt = task.completedAt
    }

    var isCompleted: Bool { completedAt != nil }
}
