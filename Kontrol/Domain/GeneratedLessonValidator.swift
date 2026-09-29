import CoreFoundation
import Foundation

// Only this validator can produce a persistable definition. Callers must repeat
// validation against fresh evidence in the eventual insertion transaction.
struct ValidatedGeneratedLesson {
    let definition: LessonDefinitionSnapshot
    let operationID: UUID
    let catalogID: String
    let catalogVersion: Int
    let objectiveRegistryVersion: Int
    let request: LessonGenerationRequest
    let candidate: CandidateLesson
    let registry: GenerationObjectives
    let requestedModel: String
    let returnedModel: String?
    let validatedAt: Date

    fileprivate init(definition: LessonDefinitionSnapshot, request: LessonGenerationRequest,
                     candidate: CandidateLesson, registry: GenerationObjectives,
                     requestedModel: String, returnedModel: String?, now: Date) {
        self.request = request
        self.candidate = candidate
        self.registry = registry
        self.requestedModel = requestedModel
        self.returnedModel = returnedModel
        validatedAt = now
        self.definition = definition
        operationID = request.operationID
        catalogID = request.catalogID
        catalogVersion = request.catalogVersion
        objectiveRegistryVersion = request.objectiveRegistryVersion
    }
}

enum GeneratedLessonValidator {
    static let maximumResponseBytes = 256 * 1024
    private static let fields: Set<String> = [
        "title", "objectiveKey", "objective", "topicID", "subtopicID", "conceptIDs",
        "difficulty", "format", "estimatedMinutes", "prerequisiteConceptIDs",
        "explanation", "workedExample", "exercise", "referenceAnswer", "selfCheckCriteria"
    ]

    // Decode a complete candidate object, never an arbitrary provider envelope.
    // The adapter must independently reject refusals/incomplete envelopes and cap
    // bytes *while receiving*; this limit also protects callers of this API.
    static func decode(_ data: Data) throws -> CandidateLesson {
        guard !data.isEmpty, data.count <= maximumResponseBytes else {
            throw LessonGenerationError.malformedResponse
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == fields,
              let duration = object["estimatedMinutes"] as? NSNumber,
              CFGetTypeID(duration) != CFBooleanGetTypeID(),
              !["d", "f"].contains(String(cString: duration.objCType)),
              let candidate = try? JSONDecoder().decode(CandidateLesson.self, from: data) else {
            throw LessonGenerationError.malformedResponse
        }
        return candidate
    }

    static func validate(_ candidate: CandidateLesson, request: LessonGenerationRequest,
                         context: LessonGenerationContext, registry: GenerationObjectives,
                         requestedModel: String, returnedModel: String? = nil,
                         now: Date) throws -> ValidatedGeneratedLesson {
        guard request.requestSchemaVersion == LessonGenerationRequest.schemaVersion,
              request.objectiveRegistryVersion == registry.version,
              request.catalogID == context.catalog.value.catalogID,
              request.catalogVersion == context.catalog.value.version else {
            throw LessonGenerationError.staleContext
        }
        // A recomputed scope uses current membership and prerequisites, rather
        // than trusting even a detached request if the catalog changed.
        let canonical: LessonGenerationRequest
        do {
            canonical = try LessonGenerationRequestBuilder.make(
                selection: LessonGenerationSelection(topicID: request.topicID,
                    objectiveKey: request.objectiveKey, format: request.format,
                    difficulty: request.difficulty), operationID: request.operationID,
                context: context, registry: registry)
        } catch LessonGenerationError.exhaustedObjectives {
            throw LessonGenerationError.duplicateObjective
        }
        guard request.topicID == canonical.topicID,
              request.subtopicID == canonical.subtopicID,
              request.conceptIDs == canonical.conceptIDs,
              request.prerequisiteConceptIDs == canonical.prerequisiteConceptIDs,
              request.objective == canonical.objective else {
            throw LessonGenerationError.invalidScope
        }
        guard candidate.objectiveKey == canonical.objectiveKey,
              candidate.topicID == canonical.topicID,
              candidate.subtopicID == canonical.subtopicID,
              candidate.conceptIDs.count <= 20,
              candidate.prerequisiteConceptIDs.count <= 20,
              Set(candidate.conceptIDs).count == candidate.conceptIDs.count,
              Set(candidate.prerequisiteConceptIDs).count == candidate.prerequisiteConceptIDs.count,
              Set(candidate.conceptIDs) == Set(canonical.conceptIDs),
              Set(candidate.prerequisiteConceptIDs) == Set(canonical.prerequisiteConceptIDs),
              candidate.difficulty == canonical.difficulty,
              candidate.format == canonical.format else {
            throw LessonGenerationError.invalidCandidate
        }
        func valid(_ value: String, maximum: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                value.unicodeScalars.count <= maximum
        }
        guard valid(candidate.title, maximum: 200),
              valid(candidate.objective, maximum: 1_000),
              valid(candidate.explanation, maximum: 12_000),
              valid(candidate.workedExample, maximum: 12_000),
              valid(candidate.exercise, maximum: 12_000),
              valid(candidate.referenceAnswer, maximum: 12_000),
              (1...10).contains(candidate.selfCheckCriteria.count),
              candidate.selfCheckCriteria.allSatisfy({ valid($0, maximum: 1_000) }),
              (1...120).contains(candidate.estimatedMinutes) else {
            throw LessonGenerationError.invalidCandidate
        }

        let id = "generated.\(request.operationID.uuidString.lowercased())"
        let hash = CatalogValidator.fingerprint(explanation: candidate.explanation,
            workedExample: candidate.workedExample, exercise: candidate.exercise,
            referenceAnswer: candidate.referenceAnswer, selfCheckCriteria: candidate.selfCheckCriteria)
        // The requested model is local configuration. A returned model, if any,
        // is only bounded nonsecret metadata; never accept an arbitrary payload.
        func safeModel(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || [45, 46, 58, 95].contains($0)
            }
        }
        guard safeModel(requestedModel), returnedModel.map(safeModel) ?? true else {
            throw LessonGenerationError.invalidCandidate
        }
        struct Provenance: Encodable {
            let version: Int
            let provider: String
            let requestedModel: String
            let returnedModel: String?
            let generatedAt: String
            let operationID: UUID
            let requestSchemaVersion: Int
            let objectiveRegistryVersion: Int
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let provenance = Provenance(version: 1, provider: "openai", requestedModel: requestedModel,
            returnedModel: returnedModel, generatedAt: formatter.string(from: now),
            operationID: request.operationID, requestSchemaVersion: request.requestSchemaVersion,
            objectiveRegistryVersion: request.objectiveRegistryVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let provenanceData = try? encoder.encode(provenance),
              let provenanceText = String(data: provenanceData, encoding: .utf8) else {
            throw LessonGenerationError.invalidCandidate
        }
        let definition = LessonDefinitionSnapshot(id: id, objectiveKey: canonical.objectiveKey,
            objective: canonical.objective, title: candidate.title, topicID: canonical.topicID,
            subtopicID: canonical.subtopicID, conceptIDs: canonical.conceptIDs,
            difficulty: canonical.difficulty, format: canonical.format,
            estimatedMinutes: candidate.estimatedMinutes,
            prerequisiteConceptIDs: canonical.prerequisiteConceptIDs,
            explanation: candidate.explanation, workedExample: candidate.workedExample,
            exercise: candidate.exercise, referenceAnswer: candidate.referenceAnswer,
            selfCheckCriteria: candidate.selfCheckCriteria, contentVersion: 1,
            normalizedContentHash: hash, source: "generated", provenance: provenanceText)
        let metadata = LessonMatchMetadata(definition)
        let installed = context.catalog.value.lessons.map(LessonMatchMetadata.init) +
            context.definitions.map(LessonMatchMetadata.init) +
            context.startedPins.map(LessonMatchMetadata.init)
        guard !installed.contains(where: { $0.id == id }) &&
                !context.terminal.contains(where: { $0.metadata.id == id }) else {
            throw LessonGenerationError.duplicateIdentity
        }
        switch LessonDeduplication.decide(candidate: metadata, terminal: context.terminal,
                                          active: installed) {
        case .eligible: break
        case .rejected(.objectiveConceptOverlap): throw LessonGenerationError.duplicateObjective
        case .rejected(.exactContent): throw LessonGenerationError.duplicateContent
        case .rejected(.completedID), .rejected(.dismissedID), .rejected(.activeID):
            throw LessonGenerationError.duplicateIdentity
        case .rejected(.invalidMetadata): throw LessonGenerationError.invalidCandidate
        }
        return ValidatedGeneratedLesson(definition: definition, request: request, candidate: candidate,
            registry: registry, requestedModel: requestedModel, returnedModel: returnedModel, now: now)
    }
}
