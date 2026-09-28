import CryptoKit
import Foundation

// Construction is restricted to successful whole-catalog validation. DTOs remain
// copyable values; neither parsing nor checking touches a persistent context.
struct ValidatedCatalog {
    let value: CatalogDTO

    private init(_ value: CatalogDTO) { self.value = value }

    static func validating(_ value: CatalogDTO) throws -> Self {
        try CatalogValidator.check(value)
        return Self(value)
    }
}

enum CatalogValidationError: Error, Equatable {
    // Finite codes only: never embed resource text, IDs, paths, or decoder errors.
    enum Issue: String {
        case malformedJSON, oversizedCatalog, invalidCatalogIdentity, invalidVersion
        case emptyCollection, duplicateID, invalidIdentity, invalidParent
        case invalidConceptReference, duplicateReference, cyclicPrerequisites
        case emptyConceptSet, unsupportedDifficulty, unsupportedFormat, unsupportedSource
        case invalidEstimate, invalidContentVersion, missingMetadata
        case missingExplanation, missingExample, missingExercise, missingAnswer, missingSelfCheck
        case invalidFingerprint
    }
    case invalid(Issue)
}

enum CatalogValidator {
    // Bound untrusted input before decoding and before walking its graph.
    static let maximumBytes = 4 * 1024 * 1024
    private static let maximumEntries = 10_000
    private static let difficulties: Set<String> = ["basic", "intermediate", "advanced"]
    private static let formats: Set<String> = ["learn", "code", "question", "design"]
    private static let sources: Set<String> = ["seed", "generated"]

    static func decodeAndValidate(_ data: Data) throws -> ValidatedCatalog {
        guard data.count <= maximumBytes else {
            throw CatalogValidationError.invalid(.oversizedCatalog)
        }
        let dto: CatalogDTO
        do {
            dto = try JSONDecoder().decode(CatalogDTO.self, from: data)
        } catch {
            throw CatalogValidationError.invalid(.malformedJSON)
        }
        return try ValidatedCatalog.validating(dto)
    }

    static func validate(_ value: CatalogDTO) throws -> ValidatedCatalog {
        try ValidatedCatalog.validating(value)
    }

    // The teaching-content fingerprint excludes metadata (including the objective).
    // Trim, normalize to NFC, and separate sections with U+001F in authored order.
    static func fingerprint(for lesson: LessonDTO) -> String {
        let sections = [lesson.explanation, lesson.workedExample, lesson.exercise,
                        lesson.referenceAnswer] + lesson.selfCheckCriteria
        let normalized = sections.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        }.joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func check(_ catalog: CatalogDTO) throws {
        try require(nonblank(catalog.catalogID), .invalidCatalogIdentity)
        try require(catalog.version > 0, .invalidVersion)
        let groups = [catalog.topics.count, catalog.subtopics.count,
                      catalog.concepts.count, catalog.lessons.count]
        try require(groups.allSatisfy { $0 > 0 }, .emptyCollection)
        try require(groups.reduce(0, +) <= maximumEntries, .oversizedCatalog)

        try unique(catalog.topics.map(\.id))
        try unique(catalog.subtopics.map(\.id))
        try unique(catalog.concepts.map(\.id))
        try unique(catalog.lessons.map(\.id))
        try require(Set(catalog.topics.map(\.id) + catalog.subtopics.map(\.id) +
                        catalog.concepts.map(\.id) + catalog.lessons.map(\.id)).count ==
                    groups.reduce(0, +), .duplicateID)
        let topics = Set(catalog.topics.map(\.id))
        let subtopics = Dictionary(uniqueKeysWithValues: catalog.subtopics.map { ($0.id, $0.topicID) })
        let concepts = Dictionary(uniqueKeysWithValues: catalog.concepts.map { ($0.id, $0.subtopicID) })

        for topic in catalog.topics {
            try require(nonblank(topic.name), .missingMetadata)
        }
        for subtopic in catalog.subtopics {
            try require(nonblank(subtopic.name), .missingMetadata)
            try require(topics.contains(subtopic.topicID), .invalidParent)
        }
        var edges: [String: [String]] = [:]
        for concept in catalog.concepts {
            try require(nonblank(concept.name), .missingMetadata)
            guard let topicID = subtopics[concept.subtopicID] else {
                throw CatalogValidationError.invalid(.invalidParent)
            }
            try references(concept.prerequisiteConceptIDs, concepts: concepts,
                           subtopics: subtopics, topicID: topicID)
            edges[concept.id] = concept.prerequisiteConceptIDs
        }
        try require(acyclic(edges), .cyclicPrerequisites)

        for lesson in catalog.lessons {
            try require(nonblank(lesson.objectiveKey) && nonblank(lesson.objective) &&
                        nonblank(lesson.title) &&
                        nonblank(lesson.normalizedContentHash) && nonblank(lesson.provenance), .missingMetadata)
            try require(topics.contains(lesson.topicID) &&
                        subtopics[lesson.subtopicID] == lesson.topicID, .invalidParent)
            try require(!lesson.conceptIDs.isEmpty, .emptyConceptSet)
            try references(lesson.conceptIDs, concepts: concepts,
                           subtopics: subtopics, topicID: lesson.topicID)
            try references(lesson.prerequisiteConceptIDs, concepts: concepts,
                           subtopics: subtopics, topicID: lesson.topicID)
            try require(difficulties.contains(lesson.difficulty), .unsupportedDifficulty)
            try require(formats.contains(lesson.format), .unsupportedFormat)
            try require(sources.contains(lesson.source), .unsupportedSource)
            try require(lesson.estimatedMinutes > 0, .invalidEstimate)
            try require(lesson.contentVersion > 0, .invalidContentVersion)
            try require(nonblank(lesson.explanation), .missingExplanation)
            try require(nonblank(lesson.workedExample), .missingExample)
            try require(nonblank(lesson.exercise), .missingExercise)
            try require(nonblank(lesson.referenceAnswer), .missingAnswer)
            try require(!lesson.selfCheckCriteria.isEmpty &&
                        lesson.selfCheckCriteria.allSatisfy(nonblank), .missingSelfCheck)
            try require(lesson.normalizedContentHash == fingerprint(for: lesson), .invalidFingerprint)
        }
    }

    private static func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func require(_ condition: Bool, _ issue: CatalogValidationError.Issue) throws {
        guard condition else { throw CatalogValidationError.invalid(issue) }
    }

    private static func unique(_ ids: [String]) throws {
        try require(ids.allSatisfy(nonblank), .invalidIdentity)
        try require(Set(ids).count == ids.count, .duplicateID)
    }

    private static func references(_ ids: [String], concepts: [String: String],
                                   subtopics: [String: String], topicID: String) throws {
        try require(Set(ids).count == ids.count, .duplicateReference)
        try require(ids.allSatisfy { id in
            guard let subtopicID = concepts[id] else { return false }
            return subtopics[subtopicID] == topicID
        }, .invalidConceptReference)
    }

    // Kahn's algorithm avoids recursion depth problems in large malformed graphs.
    private static func acyclic(_ edges: [String: [String]]) -> Bool {
        var incoming = edges.mapValues(\.count)
        var dependents: [String: [String]] = [:]
        for (id, prerequisites) in edges {
            for prerequisite in prerequisites { dependents[prerequisite, default: []].append(id) }
        }
        var queue = incoming.compactMap { $0.value == 0 ? $0.key : nil }
        var next = 0
        while next < queue.count {
            let id = queue[next]
            next += 1
            for dependent in dependents[id, default: []] {
                incoming[dependent, default: 0] -= 1
                if incoming[dependent] == 0 { queue.append(dependent) }
            }
        }
        return next == edges.count
    }
}
