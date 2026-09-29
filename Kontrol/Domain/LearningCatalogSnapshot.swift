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

// V6 evidence is detached from SwiftData and from mutable installed definitions.
// Nil fields are known gaps in legacy evidence, not permission to fill from today's catalog.
enum TerminalMetadataProvenance: String, Codable, Equatable {
    case studiedPin, dismissalPin, dismissalReference, legacyCompletedPartial, legacyRecoveredReference
}

struct LessonTerminalMetadata: Codable, Equatable {
    let lessonID: String
    let provenance: TerminalMetadataProvenance
    let title: String?
    let topicID: String?
    let subtopicID: String?
    let contentVersion: Int?
    let objectiveKey: String?
    let conceptIDs: [String]?
    let normalizedContentHash: String?
    let format: String?
    // Only a pre-study dismissal may retain a definition as reference material.
    // A studied pin remains owned by LessonAttempt.pinnedContentData.
    let dismissalTimeDefinition: LessonDefinitionSnapshot?

    func validate() throws {
        // Unknown legacy fields are nil. A present matching field must still be
        // usable evidence; in particular an empty set or malformed digest cannot
        // masquerade as full archival metadata.
        func canonicalID(_ id: String) -> Bool {
            !id.isEmpty && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
        }
        func validHash(_ hash: String) -> Bool {
            let bytes = Array(hash.utf8)
            return bytes.count == 71 && bytes.starts(with: Array("sha256:".utf8)) &&
                bytes.dropFirst(7).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard canonicalID(lessonID), contentVersion.map({ $0 > 0 }) ?? true,
              objectiveKey.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
              conceptIDs.map({ !$0.isEmpty && $0.allSatisfy(canonicalID) &&
                  $0 == Array(Set($0)).sorted() }) ?? true,
              normalizedContentHash.map(validHash) ?? true,
              dismissalTimeDefinition.map({ $0.id == lessonID }) ?? true,
              (provenance == .dismissalReference || provenance == .legacyRecoveredReference ||
               dismissalTimeDefinition == nil),
              // Full evidence must be complete; legacy partial fields may be unknown.
              ([TerminalMetadataProvenance.legacyCompletedPartial, .legacyRecoveredReference]
                  .contains(provenance) ||
               (title != nil && topicID != nil && subtopicID != nil &&
                contentVersion != nil && objectiveKey != nil && conceptIDs != nil &&
                normalizedContentHash != nil && format != nil)) else {
            throw LearningEvidenceError.invalidPayload
        }
    }
}

struct CurrentCatalogMembership: Codable, Equatable {
    let catalogID: String
    let catalogVersion: Int
    let topicIDs: [String]
    let subtopicIDs: [String]
    let conceptIDs: [String]
    let seededLessonIDs: [String]

    func validate() throws {
        guard !catalogID.isEmpty, catalogVersion > 0,
              [topicIDs, subtopicIDs, conceptIDs, seededLessonIDs].allSatisfy({
                  !$0.contains("") && $0 == Array(Set($0)).sorted()
              }) else { throw LearningEvidenceError.invalidPayload }
    }
}

enum CatalogMembershipAvailability: Equatable {
    case available(CurrentCatalogMembership)
    case unavailable // no matching validated catalog established current membership
}

// Only terminal completion records are eligible for practice. The date belongs
// to progress/attempt evidence, not to an installed lesson definition.
struct CoverageCompletionEvidence: Equatable {
    let lessonID: String
    let status: LessonProgressStatus
    let completedAt: Date?
    let metadata: LessonTerminalMetadata?
}

enum LearningEvidenceError: Error, Equatable {
    case unsupportedVersion(Int)
    case corruptPayload
    case invalidPayload
    case identityMismatch
    case duplicateIdentity
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
    // Historical pin/snapshot wins over the installed catalog. A missing
    // definition has an honest stable-ID label and no invented topic.
    let title: String
    let topicID: String?
    let contentVersion: Int?
    let provenance: TerminalMetadataProvenance?
    let metadata: LessonTerminalMetadata?
    let content: LessonStudiedContent
    let attempt: LessonAttemptSnapshot?

    init(lessonID: String, status: LessonProgressStatus, date: Date, title: String,
         topicID: String?, contentVersion: Int? = nil,
         provenance: TerminalMetadataProvenance? = nil, metadata: LessonTerminalMetadata? = nil,
         content: LessonStudiedContent, attempt: LessonAttemptSnapshot?) {
        self.lessonID = lessonID
        self.status = status
        self.date = date
        self.title = title
        self.topicID = topicID
        self.contentVersion = contentVersion
        self.provenance = provenance
        self.metadata = metadata
        self.content = content
        self.attempt = attempt
    }
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
    let coverage: LearningCoverageSnapshot
    let replacedSlot: LessonSlotSnapshot?
}

struct LearningCatalogSnapshot: Equatable {
    let topics: [LearningTopicSnapshot]
    let subtopics: [LearningSubtopicSnapshot]
    let concepts: [LearningConceptSnapshot]
    let definitions: [LessonDefinitionSnapshot]
    let progress: [LessonProgressSnapshot]
    let slots: [LessonSlotSnapshot]
    // Detached opened versions for active work; definitions can change or be omitted
    // without changing what a learner is studying. Empty for legacy work without a pin.
    var startedPins: [LessonDefinitionSnapshot] = []
}
