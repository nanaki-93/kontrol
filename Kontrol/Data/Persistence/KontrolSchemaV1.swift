import Foundation
import SwiftData

// Released V1 definitions are immutable. Add a new VersionedSchema for future model changes.
enum KontrolSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TaskItem.self, Topic.self, Subtopic.self, Concept.self,
         LessonDefinition.self, LessonProgress.self, LessonAttempt.self,
         CatalogImportState.self]
    }

    enum TaskValidationError: Error {
        case emptyTitle
        case incompletePlannedDay
    }

    // Foundation DateComponents includes a Calendar object which SwiftData cannot
    // persist as a struct. Persist only the selected local calendar-date components.
    struct PlannedDayComponents: Codable, Equatable {
        var calendarIdentifier: String
        var year: Int
        var month: Int
        var day: Int
    }

    @Model
    final class TaskItem {
        @Attribute(.unique) var id: UUID
        var title: String
        var notes: String?
        var dueAt: Date?
        // Only year/month/day are set; the original zone is kept separately so a
        // later device time-zone change does not move the user's chosen day.
        var plannedDay: PlannedDayComponents?
        var plannedTimeZoneID: String?
        var createdAt: Date
        var completedAt: Date?

        var isCompleted: Bool { completedAt != nil }

        init(id: UUID, title: String, createdAt: Date, notes: String? = nil,
             dueAt: Date? = nil, plannedDay: PlannedDayComponents? = nil,
             plannedTimeZoneID: String? = nil, completedAt: Date? = nil) throws {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { throw TaskValidationError.emptyTitle }
            guard (plannedDay == nil) == (plannedTimeZoneID == nil),
                  plannedTimeZoneID.map({ !$0.isEmpty }) ?? true else {
                throw TaskValidationError.incompletePlannedDay
            }
            self.id = id
            self.title = trimmedTitle
            self.createdAt = createdAt
            self.notes = notes
            self.dueAt = dueAt
            self.plannedDay = plannedDay
            self.plannedTimeZoneID = plannedTimeZoneID
            self.completedAt = completedAt
        }
    }

    @Model
    final class Topic {
        @Attribute(.unique) var id: String
        var name: String

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    @Model
    final class Subtopic {
        @Attribute(.unique) var id: String
        var topicID: String
        var name: String

        init(id: String, topicID: String, name: String) {
            self.id = id
            self.topicID = topicID
            self.name = name
        }
    }

    @Model
    final class Concept {
        @Attribute(.unique) var id: String
        var subtopicID: String
        var name: String
        var prerequisiteConceptIDs: [String]

        init(id: String, subtopicID: String, name: String, prerequisiteConceptIDs: [String] = []) {
            self.id = id
            self.subtopicID = subtopicID
            self.name = name
            self.prerequisiteConceptIDs = prerequisiteConceptIDs
        }
    }

    // Use stable string codes at the storage boundary; the catalog validator checks
    // supported difficulty, format and source values before any models are written.
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

        init(id: String, objectiveKey: String, title: String, topicID: String,
             subtopicID: String, conceptIDs: [String], difficulty: String,
             format: String, estimatedMinutes: Int, prerequisiteConceptIDs: [String] = [],
             explanation: String, workedExample: String, exercise: String,
             referenceAnswer: String, selfCheckCriteria: [String], contentVersion: Int,
             normalizedContentHash: String, source: String, provenance: String) {
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
        }
    }

    enum ProgressStatus: String, Codable {
        case available, started, completed, dismissed
    }

    @Model
    final class LessonProgress {
        @Attribute(.unique) var lessonID: String
        var status: ProgressStatus
        var firstShownAt: Date?
        var startedAt: Date?
        var completedAt: Date?
        var dismissedAt: Date?
        var lastOpenedAt: Date?

        init(lessonID: String, status: ProgressStatus = .available,
             firstShownAt: Date? = nil, startedAt: Date? = nil,
             completedAt: Date? = nil, dismissedAt: Date? = nil,
             lastOpenedAt: Date? = nil) {
            self.lessonID = lessonID
            self.status = status
            self.firstShownAt = firstShownAt
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.dismissedAt = dismissedAt
            self.lastOpenedAt = lastOpenedAt
        }
    }

    // A completed attempt retains the exact accepted content, not a reference to
    // the current definition (which may be corrected in a later catalog release).
    struct LessonContentSnapshot: Codable, Equatable {
        var title: String
        var objectiveKey: String
        var conceptIDs: [String]
        var difficulty: String
        var format: String
        var explanation: String
        var workedExample: String
        var exercise: String
        var referenceAnswer: String
        var selfCheckCriteria: [String]
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
        var completedContentSnapshot: LessonContentSnapshot?

        init(id: UUID, lessonID: String, contentVersion: Int, answerDraft: String = "",
             solutionRevealedAt: Date? = nil, selfCheckAcknowledgedAt: Date? = nil,
             completedAt: Date? = nil, completedContentSnapshot: LessonContentSnapshot? = nil) {
            self.id = id
            self.lessonID = lessonID
            self.contentVersion = contentVersion
            self.answerDraft = answerDraft
            self.solutionRevealedAt = solutionRevealedAt
            self.selfCheckAcknowledgedAt = selfCheckAcknowledgedAt
            self.completedAt = completedAt
            self.completedContentSnapshot = completedContentSnapshot
        }
    }

    @Model
    final class CatalogImportState {
        @Attribute(.unique) var catalogID: String
        var lastImportedVersion: Int

        init(catalogID: String, lastImportedVersion: Int) {
            self.catalogID = catalogID
            self.lastImportedVersion = lastImportedVersion
        }
    }
}

// Stable names at call sites without introducing another persistent model type.
typealias TaskItem = KontrolSchemaV1.TaskItem
typealias Topic = KontrolSchemaV1.Topic
typealias Subtopic = KontrolSchemaV1.Subtopic
typealias Concept = KontrolSchemaV1.Concept
typealias LessonProgress = KontrolSchemaV1.LessonProgress
typealias CatalogImportState = KontrolSchemaV1.CatalogImportState
