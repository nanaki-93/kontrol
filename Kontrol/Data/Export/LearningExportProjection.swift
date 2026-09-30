import Foundation

/// Maps supplied stored content only. Fetching a committed snapshot belongs to
/// the caller; no catalog load/import, reconciliation, generation, or save occurs.
@MainActor
enum LearningExportProjection {
    static func project(topics: [Topic], subtopics: [Subtopic], concepts: [Concept],
                        definitions: [LessonDefinition], into envelope: LocalDataExport) throws -> LocalDataExport {
        // Swift String equality treats canonically equivalent Unicode as equal.
        // Check bytes so storage identities are validated, never normalized.
        try topics.forEach { try identity($0.id) }
        try subtopics.forEach { try identity($0.id); try identity($0.topicID) }
        try concepts.forEach {
            try identity($0.id); try identity($0.subtopicID)
            try $0.prerequisiteConceptIDs.forEach(identity)
        }
        var value = envelope
        value.learning.topics = topics.map { .init(id: $0.id, name: $0.name) }
        value.learning.subtopics = subtopics.map { .init(id: $0.id, topicID: $0.topicID, name: $0.name) }
        value.learning.concepts = concepts.map {
            .init(id: $0.id, subtopicID: $0.subtopicID, name: $0.name,
                  prerequisiteConceptIDs: $0.prerequisiteConceptIDs)
        }
        value.learning.definitions = try definitions.map(definition)
        // Validate scalars and identity collections through the shared contract.
        // Historical links need not belong to today's installed membership.
        try value.validate()
        return value.canonicalized()
    }

    private static func identity(_ text: String) throws {
        let canonical = text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !canonical.isEmpty, text.utf8.elementsEqual(canonical.utf8) else {
            throw LocalDataExportError.invalidValue
        }
    }

    private static func definition(_ row: LessonDefinition) throws -> LocalDataExport.Definition {
        try [row.id, row.topicID, row.subtopicID].forEach(identity)
        try row.conceptIDs.forEach(identity)
        try row.prerequisiteConceptIDs.forEach(identity)
        // Check the recorded fingerprint against the recorded ordered sections,
        // never replace it with a newly computed value or today's catalog content.
        guard row.normalizedContentHash == CatalogValidator.fingerprint(
            explanation: row.explanation, workedExample: row.workedExample,
            exercise: row.exercise, referenceAnswer: row.referenceAnswer,
            selfCheckCriteria: row.selfCheckCriteria),
              row.objective.isEmpty || !row.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalDataExportError.invalidValue
        }
        let provenance: LocalDataExport.Provenance?
        switch row.source {
        case "seed":
            // Seed provenance is authored attribution text, not a provider blob.
            // Empty legacy attribution is unavailable, not reconstructed.
            provenance = row.provenance.isEmpty ? nil : .init(attribution: row.provenance, generation: nil)
        case "generated":
            let generation = try generatedProvenance(row.provenance)
            guard row.id == "generated.\(generation.operationID.uuidString.lowercased())" else {
                throw LocalDataExportError.identityMismatch
            }
            // These are the local acceptance validator's content bounds, without
            // revalidating against mutable current objectives or prerequisites.
            func bounded(_ text: String, _ maximum: Int) -> Bool { text.unicodeScalars.count <= maximum }
            guard bounded(row.title, 200), bounded(row.objective, 1_000), !row.objective.isEmpty,
                  [row.explanation, row.workedExample, row.exercise, row.referenceAnswer]
                    .allSatisfy({ bounded($0, 12_000) }),
                  (1...10).contains(row.selfCheckCriteria.count),
                  row.selfCheckCriteria.allSatisfy({ bounded($0, 1_000) }),
                  row.conceptIDs.count <= 20, row.prerequisiteConceptIDs.count <= 20,
                  (1...120).contains(row.estimatedMinutes) else {
                throw LocalDataExportError.invalidValue
            }
            provenance = .init(attribution: nil, generation: generation)
        default: throw LocalDataExportError.invalidValue
        }
        return .init(id: row.id, objectiveKey: row.objectiveKey, objective: row.objective,
            title: row.title, topicID: row.topicID, subtopicID: row.subtopicID, conceptIDs: row.conceptIDs,
            difficulty: row.difficulty, format: row.format, estimatedMinutes: row.estimatedMinutes,
            prerequisiteConceptIDs: row.prerequisiteConceptIDs, explanation: row.explanation,
            workedExample: row.workedExample, exercise: row.exercise, referenceAnswer: row.referenceAnswer,
            selfCheckCriteria: row.selfCheckCriteria, contentVersion: row.contentVersion,
            normalizedContentHash: row.normalizedContentHash, source: row.source, provenance: provenance)
    }

    /// Exactly the version-1 metadata written by GeneratedLessonValidator. Missing
    /// returnedModel is the released encoder's nil representation. Other missing,
    /// unknown, corrupt, or unsupported fields fail; none are dumped into JSON.
    private static func generatedProvenance(_ text: String) throws -> LocalDataExport.Generation {
        struct Stored: Decodable {
            let version: Int
            let provider: String
            let requestedModel: String
            let returnedModel: String?
            let generatedAt: String
            let operationID: UUID
            let requestSchemaVersion: Int
            let objectiveRegistryVersion: Int
        }
        let data = Data(text.utf8)
        let required: Set<String> = ["version", "provider", "requestedModel", "generatedAt", "operationID",
                                     "requestSchemaVersion", "objectiveRegistryVersion"]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(["returnedModel"])),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw LocalDataExportError.invalidValue
        }
        guard stored.version == 1, stored.requestSchemaVersion == LessonGenerationRequest.schemaVersion else {
            throw LocalDataExportError.unsupportedVersion
        }
        guard stored.provider == "openai", GeneratedLessonValidator.safeModel(stored.requestedModel),
              stored.returnedModel.map(GeneratedLessonValidator.safeModel) ?? true,
              stored.objectiveRegistryVersion > 0 else {
            throw LocalDataExportError.invalidValue
        }
        return try .init(provider: stored.provider, requestedModel: stored.requestedModel,
            returnedModel: stored.returnedModel, generatedAt: ExportTimestamp(value: stored.generatedAt),
            operationID: stored.operationID, requestSchemaVersion: stored.requestSchemaVersion,
            objectiveRegistryVersion: stored.objectiveRegistryVersion)
    }
}
