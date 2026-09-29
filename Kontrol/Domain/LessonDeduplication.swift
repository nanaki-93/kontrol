import Foundation

/// Detached metadata only. A terminal record may be partial (legacy recovery);
/// a candidate must have a canonical ID, objective, concepts and content hash.
struct LessonMatchMetadata {
    let id: String
    let objectiveKey: String?
    let conceptIDs: [String]?
    let contentHash: String?

    init(id: String, objectiveKey: String?, conceptIDs: [String]?, contentHash: String?) {
        self.id = id
        self.objectiveKey = objectiveKey
        self.conceptIDs = conceptIDs
        self.contentHash = contentHash
    }

    init(_ lesson: LessonDTO) {
        self.init(id: lesson.id, objectiveKey: lesson.objectiveKey,
                  conceptIDs: lesson.conceptIDs,
                  contentHash: CatalogValidator.fingerprint(for: lesson))
    }

    init(_ lesson: LessonDefinitionSnapshot) {
        self.init(id: lesson.id, objectiveKey: lesson.objectiveKey,
                  conceptIDs: lesson.conceptIDs,
                  contentHash: CatalogValidator.fingerprint(
                    explanation: lesson.explanation, workedExample: lesson.workedExample,
                    exercise: lesson.exercise, referenceAnswer: lesson.referenceAnswer,
                    selfCheckCriteria: lesson.selfCheckCriteria))
    }
}

enum LessonDuplicateReason: String, Equatable {
    case completedID, dismissedID, activeID, exactContent, objectiveConceptOverlap, invalidMetadata
}

enum LessonDuplicateDecision: Equatable {
    case eligible
    case rejected(LessonDuplicateReason)
}

struct TerminalLessonMatch {
    let status: LessonProgressStatus
    let metadata: LessonMatchMetadata
}

/// No content, answer, title, objective or identifiers are included in a decision.
/// Only terminal history participates in near-duplicate suppression; active
/// assignments suppress stable IDs and exact teaching content only.
enum LessonDeduplication {
    static func decide(candidate: LessonMatchMetadata,
                       terminal: [TerminalLessonMatch],
                       active: [LessonMatchMetadata] = []) -> LessonDuplicateDecision {
        // Stable-ID status takes precedence even when candidate metadata is incomplete.
        // Input order cannot change this; restored (nonterminal) records do not exclude.
        if terminal.contains(where: { $0.status == .completed && $0.metadata.id == candidate.id }) {
            return .rejected(.completedID)
        }
        if terminal.contains(where: { $0.status == .dismissed && $0.metadata.id == candidate.id }) {
            return .rejected(.dismissedID)
        }
        // Exact teaching content is usable evidence even if other candidate fields
        // are missing. Do not treat a malformed or absent hash as a match.
        if let hash = candidate.contentHash, validHash(hash),
           terminal.contains(where: { isTerminal($0.status) && $0.metadata.contentHash == hash }) ||
            active.contains(where: { $0.contentHash == hash }) {
            return .rejected(.exactContent)
        }
        guard canonicalID(candidate.id),
              let objective = candidate.objectiveKey.map(normalizedObjective), !objective.isEmpty,
              let concepts = canonicalConcepts(candidate.conceptIDs), !concepts.isEmpty,
              let hash = candidate.contentHash, validHash(hash) else {
            return .rejected(.invalidMetadata)
        }
        for record in terminal where isTerminal(record.status) {
            let metadata = record.metadata
            guard let otherObjective = metadata.objectiveKey.map(normalizedObjective),
                  !otherObjective.isEmpty, otherObjective == objective,
                  let otherConcepts = canonicalConcepts(metadata.conceptIDs),
                  !otherConcepts.isEmpty else { continue }
            let intersection = concepts.intersection(otherConcepts).count
            let union = concepts.union(otherConcepts).count
            // Integer comparison avoids rounding at the inclusive 0.8 boundary.
            if intersection * 5 >= union * 4 {
                return .rejected(.objectiveConceptOverlap)
            }
        }
        if active.contains(where: { $0.id == candidate.id }) {
            return .rejected(.activeID)
        }
        return .eligible
    }

    static func normalizedObjective(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
            .precomposedStringWithCanonicalMapping
    }

    /// Concept IDs are identities, not fuzzy text: retain case and reject
    /// noncanonical/blank IDs rather than silently repairing a candidate.
    static func canonicalConcepts(_ ids: [String]?) -> Set<String>? {
        guard let ids, ids.allSatisfy(canonicalID) else { return nil }
        return Set(ids)
    }

    static func sortedConceptIDs(_ ids: [String]?) -> [String]? {
        canonicalConcepts(ids)?.sorted()
    }

    private static func isTerminal(_ status: LessonProgressStatus) -> Bool {
        status == .completed || status == .dismissed
    }

    private static func canonicalID(_ id: String) -> Bool {
        !id.isEmpty && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    private static func validHash(_ hash: String) -> Bool {
        guard hash.hasPrefix("sha256:"), hash.utf8.count == 71 else { return false }
        return hash.utf8.dropFirst(7).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
