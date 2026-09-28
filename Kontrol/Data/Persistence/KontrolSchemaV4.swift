import Foundation
import SwiftData

// Only the definition changes; every other released model is reused verbatim.
// Keeping the entity name LessonDefinition allows SwiftData to migrate its rows
// rather than creating a second, unrelated definition table.
enum KontrolSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        KontrolSchemaV3.models.filter { $0 != KontrolSchemaV1.LessonDefinition.self }
            + [LessonDefinition.self, LessonSlot.self]
    }

    @Model
    final class LessonDefinition {
        @Attribute(.unique) var id: String
        var objectiveKey: String
        var title: String
        var topicID: String
        var subtopicID: String
        var conceptIDs: [String]
        var difficulty: String
        var format: String
        var estimatedMinutes: Int
        var prerequisiteConceptIDs: [String]
        var explanation: String
        var workedExample: String
        var exercise: String
        var referenceAnswer: String
        var selfCheckCriteria: [String]
        var contentVersion: Int
        var normalizedContentHash: String
        var source: String
        var provenance: String
        // Existing V1–V3 rows have no objective. Import can later supply one;
        // retained historical rows use objectiveKey for read-only display.
        var objective: String = ""

        init(id: String, objectiveKey: String, title: String, topicID: String,
             subtopicID: String, conceptIDs: [String], difficulty: String,
             format: String, estimatedMinutes: Int, prerequisiteConceptIDs: [String] = [],
             explanation: String, workedExample: String, exercise: String,
             referenceAnswer: String, selfCheckCriteria: [String], contentVersion: Int,
             normalizedContentHash: String, source: String, provenance: String,
             objective: String = "") {
            self.id = id
            self.objectiveKey = objectiveKey
            self.title = title
            self.topicID = topicID
            self.subtopicID = subtopicID
            self.conceptIDs = conceptIDs
            self.difficulty = difficulty
            self.format = format
            self.estimatedMinutes = estimatedMinutes
            self.prerequisiteConceptIDs = prerequisiteConceptIDs
            self.explanation = explanation
            self.workedExample = workedExample
            self.exercise = exercise
            self.referenceAnswer = referenceAnswer
            self.selfCheckCriteria = selfCheckCriteria
            self.contentVersion = contentVersion
            self.normalizedContentHash = normalizedContentHash
            self.source = source
            self.provenance = provenance
            self.objective = objective
        }
    }

    @Model
    final class LessonSlot {
        // UTF-8 byte length prefixes the topic, so even topics containing colons
        // cannot collide with a different topic/index pair.
        @Attribute(.unique) var key: String
        var topicID: String
        var slotIndex: Int
        @Attribute(.unique) var lessonID: String
        var assignedAt: Date

        static func canonicalKey(topicID: String, slotIndex: Int) -> String {
            "\(topicID.utf8.count):\(topicID):\(slotIndex)"
        }

        init(topicID: String, slotIndex: Int, lessonID: String, assignedAt: Date) {
            self.key = Self.canonicalKey(topicID: topicID, slotIndex: slotIndex)
            self.topicID = topicID
            self.slotIndex = slotIndex
            self.lessonID = lessonID
            self.assignedAt = assignedAt
        }
    }
}

typealias LessonDefinition = KontrolSchemaV4.LessonDefinition
typealias LessonSlot = KontrolSchemaV4.LessonSlot
