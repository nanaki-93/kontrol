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

/// A currently assigned choice or explicitly restored, unslotted started lesson.
/// Browsing this value never allocates a slot or opens an attempt.
struct ConceptLessonChoice: Equatable, Identifiable {
    let lessonID: String
    let title: String
    let started: Bool
    let slot: LessonSlotSnapshot?
    var id: String { lessonID }
}

// Pure projection of explicitly installed taxonomy and detached historical
// evidence. No attempt state, installed lesson content, or prerequisite closure
// participates in the numerator.
enum LearningCoverage {
    /// Only actual offered work, not every retained definition, may be opened.
    /// Require authoritative History as well as the committed choices so that a
    /// stale terminal exclusion cannot become an apparent concept suggestion.
    static func lessons(for conceptID: String, in snapshot: LearningCatalogSnapshot,
                        history: [LessonHistorySnapshot]) -> [ConceptLessonChoice] {
        let terminal = history.map { entry in
            TerminalLessonMatch(status: entry.status,
                metadata: LessonMatchMetadata(id: entry.lessonID,
                    objectiveKey: entry.metadata?.objectiveKey,
                    conceptIDs: entry.metadata?.conceptIDs,
                    contentHash: entry.metadata?.normalizedContentHash))
        }
        let definitions = Dictionary(snapshot.definitions.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let statuses = Dictionary(snapshot.progress.map { ($0.lessonID, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let pins = Dictionary(snapshot.startedPins.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let slotted = snapshot.slots.map { ($0.lessonID, Optional($0)) }
        let restored = snapshot.progress.filter { row in
            row.status == .started && row.dismissedAt != nil &&
            !snapshot.slots.contains(where: { $0.lessonID == row.lessonID })
        }.map { ($0.lessonID, Optional<LessonSlotSnapshot>.none) }
        return (slotted + restored).compactMap { id, slot -> ConceptLessonChoice? in
            let started = statuses[id]?.status == .started
            // A started choice is the opened version, even when the installed
            // definition was edited or removed. Never substitute newer content
            // when its studied pin is unavailable.
            guard let lesson = started ? pins[id] : definitions[id],
                  let ids = LessonDeduplication.canonicalConcepts(lesson.conceptIDs),
                  ids.contains(conceptID),
                  statuses[id]?.status != .completed, statuses[id]?.status != .dismissed,
                  LessonDeduplication.decide(candidate: LessonMatchMetadata(lesson),
                                             terminal: terminal) == .eligible else { return nil }
            return ConceptLessonChoice(lessonID: id, title: lesson.title,
                                       started: statuses[id]?.status == .started, slot: slot)
        }.sorted { $0.lessonID < $1.lessonID }
    }

    /// A reference is a completed *archived* lesson that recorded direct practice
    /// of this concept, not a current definition or a dismissed reference.
    static func completedReferences(for conceptID: String,
                                    in history: [LessonHistorySnapshot]) -> [LessonHistorySnapshot] {
        history.filter { $0.status == .completed && $0.metadata?.conceptIDs?.contains(conceptID) == true }
            .sorted { lhs, rhs in
                lhs.date == rhs.date ? lhs.lessonID < rhs.lessonID : lhs.date > rhs.date
            }
    }

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
