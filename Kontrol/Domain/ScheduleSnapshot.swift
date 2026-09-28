import Foundation

enum ScheduleValidationError: Error, Equatable {
    case emptyTitle
    case invalidStart
    case invalidEnd
    case endNotAfterStart
}

/// Unsaved editor values; validating returns a normalized copy, never mutating the draft.
struct ScheduleInput: Equatable {
    let title: String
    let startAt: Date
    let endAt: Date
    let note: String?
    let lessonID: String?

    init(title: String, startAt: Date, endAt: Date, note: String? = nil,
         lessonID: String? = nil) {
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.note = note
        self.lessonID = lessonID
    }

    func validated() throws -> ScheduleInput {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw ScheduleValidationError.emptyTitle }
        guard startAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ScheduleValidationError.invalidStart
        }
        guard endAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ScheduleValidationError.invalidEnd
        }
        guard endAt > startAt else { throw ScheduleValidationError.endNotAfterStart }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScheduleInput(title: trimmedTitle, startAt: startAt, endAt: endAt,
                             note: trimmedNote.flatMap { $0.isEmpty ? nil : $0 },
                             lessonID: lessonID)
    }
}

/// A value copy of every persisted block field; never holds a SwiftData model/context.
struct ScheduleSnapshot: Equatable, Identifiable {
    let id: UUID
    let title: String
    let startAt: Date
    let endAt: Date
    let note: String?
    let lessonID: String?
    let linkedTitleSnapshot: String?

    init(id: UUID, title: String, startAt: Date, endAt: Date, note: String? = nil,
         lessonID: String? = nil, linkedTitleSnapshot: String? = nil) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.note = note
        self.lessonID = lessonID
        self.linkedTitleSnapshot = linkedTitleSnapshot
    }

    init(_ block: ScheduleBlock) {
        self.init(id: block.id, title: block.title, startAt: block.startAt,
                  endAt: block.endAt, note: block.note, lessonID: block.lessonID,
                  linkedTitleSnapshot: block.linkedTitleSnapshot)
    }
}
