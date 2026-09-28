import Foundation
import SwiftData

// V5 changes only attempts. All other entities and the completed snapshot's
// released Codable shape retain their original persistent declarations.
enum KontrolSchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        KontrolSchemaV4.models.filter { $0 != KontrolSchemaV1.LessonAttempt.self }
            + [LessonAttempt.self]
    }

    @Model
    final class LessonAttempt {
        @Attribute(.unique) var id: UUID
        var lessonID: String
        var contentVersion: Int
        var answerDraft: String
        var solutionRevealedAt: Date?
        var selfCheckAcknowledgedAt: Date?
        var completedAt: Date?
        var completedContentSnapshot: KontrolSchemaV1.LessonContentSnapshot?
        // Nil on legacy attempts until the studied definition can be recovered.
        var pinnedContentData: Data?
        var revision: Int = 0

        init(id: UUID, lessonID: String, contentVersion: Int, answerDraft: String = "",
             solutionRevealedAt: Date? = nil, selfCheckAcknowledgedAt: Date? = nil,
             completedAt: Date? = nil,
             completedContentSnapshot: KontrolSchemaV1.LessonContentSnapshot? = nil,
             pinnedContentData: Data? = nil, revision: Int = 0) {
            self.id = id
            self.lessonID = lessonID
            self.contentVersion = contentVersion
            self.answerDraft = answerDraft
            self.solutionRevealedAt = solutionRevealedAt
            self.selfCheckAcknowledgedAt = selfCheckAcknowledgedAt
            self.completedAt = completedAt
            self.completedContentSnapshot = completedContentSnapshot
            self.pinnedContentData = pinnedContentData
            self.revision = revision
        }
    }
}

typealias LessonAttempt = KontrolSchemaV5.LessonAttempt
