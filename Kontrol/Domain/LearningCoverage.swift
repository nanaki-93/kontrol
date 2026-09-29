import Foundation

struct ConceptCoverageSnapshot: Equatable, Identifiable {
    let id: String
    let name: String
    let latestCompletion: Date? // nil means no *known* direct practice
}

struct SubtopicCoverageSnapshot: Equatable, Identifiable {
    let id: String
    let topicID: String
    let topicName: String
    let name: String
    let concepts: [ConceptCoverageSnapshot]

    var currentConceptCount: Int { concepts.count }
    var practicedConceptCount: Int { concepts.filter { $0.latestCompletion != nil }.count }
    var latestCompletion: Date? { concepts.compactMap(\.latestCompletion).max() }
}

enum CoverageEvidenceState: Equatable {
    case complete
    // These completions have no trustworthy concept IDs or completion timestamp.
    // Known counts remain lower bounds, NOT an assertion of zero practice.
    case incomplete(completedLessonIDs: [String])
}

enum LearningCoverageSnapshot: Equatable {
    case membershipUnavailable
    case available(catalogID: String, catalogVersion: Int,
                   subtopics: [SubtopicCoverageSnapshot], evidence: CoverageEvidenceState)
}

// Pure projection of explicitly installed taxonomy and detached historical
// evidence. No attempt state, installed lesson content, or prerequisite closure
// participates in the numerator.
enum LearningCoverage {
    static func aggregate(membership: CatalogMembershipAvailability,
                          topics: [LearningTopicSnapshot],
                          subtopics: [LearningSubtopicSnapshot],
                          concepts: [LearningConceptSnapshot],
                          completions: [CoverageCompletionEvidence]) throws -> LearningCoverageSnapshot {
        guard case let .available(current) = membership else { return .membershipUnavailable }
        try current.validate()

        let topicIDs = Set(current.topicIDs)
        let topicNames = Dictionary(topics.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let subtopicIDs = Set(current.subtopicIDs)
        let conceptIDs = Set(current.conceptIDs)
        // A membership list cannot silently produce 0 of 0 if a current row
        // is missing or points outside the current taxonomy.
        let currentSubtopics = subtopics.filter { subtopicIDs.contains($0.id) }
        let currentConcepts = concepts.filter { conceptIDs.contains($0.id) }
        guard topicIDs.isSubset(of: Set(topicNames.keys)),
              topics.filter({ topicIDs.contains($0.id) }).count == topicIDs.count,
              currentSubtopics.count == subtopicIDs.count,
              currentConcepts.count == conceptIDs.count,
              Set(currentSubtopics.map(\.id)).count == subtopicIDs.count,
              Set(currentConcepts.map(\.id)).count == conceptIDs.count,
              currentSubtopics.allSatisfy({ topicIDs.contains($0.topicID) }),
              currentConcepts.allSatisfy({ subtopicIDs.contains($0.subtopicID) }) else {
            throw LearningEvidenceError.invalidPayload
        }

        var latest: [String: Date] = [:]
        var unknown = Set<String>()
        for completion in completions where completion.status == .completed {
            guard let date = completion.completedAt,
                  let metadata = completion.metadata,
                  metadata.lessonID == completion.lessonID,
                  metadata.provenance == .studiedPin || metadata.provenance == .legacyCompletedPartial,
                  let practiced = metadata.conceptIDs else {
                unknown.insert(completion.lessonID)
                continue
            }
            try metadata.validate()
            for id in Set(practiced) where conceptIDs.contains(id) {
                if let previous = latest[id] { latest[id] = max(previous, date) }
                else { latest[id] = date }
            }
        }

        let rows = currentSubtopics.sorted { $0.id < $1.id }.map { subtopic in
            SubtopicCoverageSnapshot(id: subtopic.id, topicID: subtopic.topicID,
                topicName: topicNames[subtopic.topicID]!, name: subtopic.name,
                concepts: currentConcepts.filter { $0.subtopicID == subtopic.id }
                    .sorted { $0.id < $1.id }
                    .map { ConceptCoverageSnapshot(id: $0.id, name: $0.name,
                                                  latestCompletion: latest[$0.id]) })
        }
        let evidence: CoverageEvidenceState = unknown.isEmpty ? .complete :
            .incomplete(completedLessonIDs: unknown.sorted())
        return .available(catalogID: current.catalogID, catalogVersion: current.catalogVersion,
                          subtopics: rows, evidence: evidence)
    }
}
