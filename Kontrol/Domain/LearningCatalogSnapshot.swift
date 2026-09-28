import Foundation

// Copies of catalog and personal rows. None of these values owns a SwiftData context.
struct LearningTopicSnapshot: Equatable, Identifiable {
    let id: String
    let name: String
}

struct LearningSubtopicSnapshot: Equatable, Identifiable {
    let id: String
    let topicID: String
    let name: String
}

struct LearningConceptSnapshot: Equatable, Identifiable {
    let id: String
    let subtopicID: String
    let name: String
    let prerequisiteConceptIDs: [String]
}

struct LessonDefinitionSnapshot: Codable, Equatable, Identifiable {
    let id: String
    let objectiveKey: String
    let objective: String
    let title: String
    let topicID: String
    let subtopicID: String
    let conceptIDs: [String]
    let difficulty: String
    let format: String
    let estimatedMinutes: Int
    let prerequisiteConceptIDs: [String]
    let explanation: String
    let workedExample: String
    let exercise: String
    let referenceAnswer: String
    let selfCheckCriteria: [String]
    let contentVersion: Int
    let normalizedContentHash: String
    let source: String
    let provenance: String

    // Migrated definitions retained after an upgrade may have no authored objective.
    var displayObjective: String { objective.isEmpty ? objectiveKey : objective }

    init(id: String, objectiveKey: String, objective: String, title: String,
         topicID: String, subtopicID: String, conceptIDs: [String], difficulty: String,
         format: String, estimatedMinutes: Int, prerequisiteConceptIDs: [String],
         explanation: String, workedExample: String, exercise: String,
         referenceAnswer: String, selfCheckCriteria: [String], contentVersion: Int,
         normalizedContentHash: String, source: String, provenance: String) {
        self.id = id
        self.objectiveKey = objectiveKey
        self.objective = objective
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

enum LessonProgressStatus: String, Equatable {
    case available, started, completed, dismissed
}

struct LessonProgressSnapshot: Equatable, Identifiable {
    var id: String { lessonID }
    let lessonID: String
    let status: LessonProgressStatus
    let firstShownAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let dismissedAt: Date?
    let lastOpenedAt: Date?

    init(lessonID: String, status: LessonProgressStatus, firstShownAt: Date? = nil,
         startedAt: Date? = nil, completedAt: Date? = nil, dismissedAt: Date? = nil,
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

struct LessonSlotSnapshot: Equatable, Identifiable {
    var id: String { key }
    let key: String
    let topicID: String
    let slotIndex: Int
    let lessonID: String
    let assignedAt: Date

    static func canonicalKey(topicID: String, slotIndex: Int) -> String {
        "\(topicID.utf8.count):\(topicID):\(slotIndex)"
    }

    init(topicID: String, slotIndex: Int, lessonID: String, assignedAt: Date) {
        self.init(key: Self.canonicalKey(topicID: topicID, slotIndex: slotIndex),
                  topicID: topicID, slotIndex: slotIndex, lessonID: lessonID, assignedAt: assignedAt)
    }

    // Preserve the stored key on read so reconciliation can detect a corrupted key.
    init(key: String, topicID: String, slotIndex: Int, lessonID: String, assignedAt: Date) {
        self.key = key
        self.topicID = topicID
        self.slotIndex = slotIndex
        self.lessonID = lessonID
        self.assignedAt = assignedAt
    }
}

// These projections are detached values. In particular, a historical detail must
// never silently fall back to the current catalog definition.
enum LessonStudiedContent: Equatable {
    case current(LessonDefinitionSnapshot) // unstarted preview; not a persisted pin
    case pinned(LessonDefinitionSnapshot)
    case legacyCompleted(KontrolSchemaV1.LessonContentSnapshot)
    case unavailable
}

struct LessonAttemptSnapshot: Equatable, Identifiable {
    let id: UUID
    let lessonID: String
    let contentVersion: Int
    let answerDraft: String
    let solutionRevealedAt: Date?
    let selfCheckAcknowledgedAt: Date?
    let completedAt: Date?
    let completedContentSnapshot: KontrolSchemaV1.LessonContentSnapshot?
    let pinnedContentData: Data?
    let revision: Int

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

struct LessonDetailSnapshot: Equatable, Identifiable {
    let id: String // stable lesson ID, not a choice index
    let progress: LessonProgressSnapshot?
    let attempt: LessonAttemptSnapshot?
    let content: LessonStudiedContent
}

struct LessonHistorySnapshot: Equatable, Identifiable {
    var id: String { lessonID }
    let lessonID: String
    let status: LessonProgressStatus // completed or dismissed
    let date: Date
    let content: LessonStudiedContent
    let attempt: LessonAttemptSnapshot?
}

enum LessonMutationOutcome: Equatable {
    case changed
    case unchanged
}

struct LessonMutationResult: Equatable {
    let outcome: LessonMutationOutcome
    let catalog: LearningCatalogSnapshot
    let detail: LessonDetailSnapshot
    let history: [LessonHistorySnapshot]
    let replacedSlot: LessonSlotSnapshot?
}

struct LearningCatalogSnapshot: Equatable {
    let topics: [LearningTopicSnapshot]
    let subtopics: [LearningSubtopicSnapshot]
    let concepts: [LearningConceptSnapshot]
    let definitions: [LessonDefinitionSnapshot]
    let progress: [LessonProgressSnapshot]
    let slots: [LessonSlotSnapshot]
}
