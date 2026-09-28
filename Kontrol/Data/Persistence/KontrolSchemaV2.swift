import Foundation
import SwiftData

// V1 types are reused verbatim so released entities retain their persisted identities.
enum KontrolSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        KontrolSchemaV1.models + [ScheduleBlock.self]
    }

    @Model
    final class ScheduleBlock {
        @Attribute(.unique) var id: UUID
        var title: String
        var startAt: Date
        var endAt: Date
        var note: String?
        // Stable metadata, not a relationship: missing lessons must not remove blocks.
        var lessonID: String?
        var linkedTitleSnapshot: String?

        init(id: UUID, title: String, startAt: Date, endAt: Date,
             note: String? = nil, lessonID: String? = nil,
             linkedTitleSnapshot: String? = nil) {
            self.id = id
            self.title = title
            self.startAt = startAt
            self.endAt = endAt
            self.note = note
            self.lessonID = lessonID
            self.linkedTitleSnapshot = linkedTitleSnapshot
        }
    }
}

typealias ScheduleBlock = KontrolSchemaV2.ScheduleBlock
