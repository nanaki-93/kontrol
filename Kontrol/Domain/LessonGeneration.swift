import Foundation

// The only value the provider may encode. In particular the context below is NOT
// Encodable: it retains full local evidence and must never cross the IO boundary.
struct LessonGenerationRequest: Encodable, Equatable {
    static let schemaVersion = 1
    static let maximumBytes = 32 * 1024 // Complete serialized provider POST body
    static let providerEnvelopeAllowance = 8 * 1024
    static let maximumDomainBytes = maximumBytes - providerEnvelopeAllowance
    static let maximumExclusions = 50

    struct ObjectiveExclusion: Encodable, Equatable {
        let key: String
        let conceptIDs: [String]
    }

    let operationID: UUID
    let requestSchemaVersion: Int
    let catalogID: String
    let catalogVersion: Int
    let objectiveRegistryVersion: Int
    let topicID: String
    let subtopicID: String
    let conceptIDs: [String]
    let objectiveKey: String
    let objective: String
    let difficulty: String
    let format: String
    let prerequisiteConceptIDs: [String]
    let completedConceptIDs: [String]
    let excludedObjectives: [ObjectiveExclusion]

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumDomainBytes else { throw LessonGenerationError.oversizedRequest }
        return data
    }

    // The provider adapter must call this on its FINAL Encodable POST body before
    // creating the URLRequest. The domain allowance is not a substitute for this
    // check: instructions, schema and other provider fields also consume bytes.
    static func encodedProviderBody<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)
        guard data.count <= maximumBytes else { throw LessonGenerationError.oversizedRequest }
        return data
    }
}

// Full, detached, authoritative read. Later local validation/acceptance can use
// all terminal evidence, definitions and pinned active content, not the truncated
// hints in LessonGenerationRequest. No model, context, answer or attempt is encoded.
struct LessonGenerationContext {
    // The catalog contains only currently installed taxonomy and seeded lessons.
    // Definitions and terminal evidence also include retained historical records
    // for full local duplicate validation; slots carry exact assignment identity.
    let catalog: ValidatedCatalog
    let membership: CurrentCatalogMembership
    let completedConceptIDs: Set<String>
    let terminal: [TerminalLessonMatch]
    let definitions: [LessonDefinitionSnapshot]
    let startedPins: [LessonDefinitionSnapshot]
    var slots: [LessonSlotSnapshot] = []
}

// Scope availability is not an ordinary Learning catalog read failure. Never
// manufacture a catalog from retained rows when membership is absent or stale.
enum GenerationContextError: Error, Equatable {
    case invalidScope, unavailable, invalidEvidence, readFailure
}

struct LessonGenerationSelection {
    let topicID: String
    let objectiveKey: String? // nil selects the first unseen, eligible canonical objective
    let format: String
    let difficulty: String
}

// Untrusted output only; no provider-supplied ID, source, hash or provenance.
// Decode only via GeneratedLessonValidator.decode: Codable alone ignores unknown keys.
struct CandidateLesson: Codable, Equatable {
    let title: String
    let objectiveKey: String
    let objective: String
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
}

protocol LessonGenerator {
    func generate(_ request: LessonGenerationRequest) async throws -> CandidateLesson
}

// Finite, payload-free failure codes. No raw provider errors or personal data.
enum LessonGenerationError: Error, Equatable {
    case disabled, unconfigured, missingCredential, inaccessibleCredential
    case unsupportedModel, unavailableObjectives, corruptObjectives, exhaustedObjectives
    case invalidScope, unmetPrerequisites, oversizedRequest, staleContext
    case offline, timeout, cancelled, authentication, authorization
    case rateLimited(retryAfter: Date?)
    case providerFailure, oversizedResponse, refusal, incompleteResponse, malformedResponse
    case invalidCandidate, duplicateIdentity, duplicateContent, duplicateObjective, persistenceFailure
}

enum LessonGenerationRequestBuilder {
    static func make(selection: LessonGenerationSelection, operationID: UUID,
                     context: LessonGenerationContext, registry: GenerationObjectives) throws -> LessonGenerationRequest {
        let catalog = context.catalog.value
        let membership = context.membership
        guard (try? membership.validate()) != nil,
              membership.catalogID == catalog.catalogID,
              membership.catalogVersion == catalog.version else { throw LessonGenerationError.staleContext }
        do {
            try GenerationObjectivesLoader.validate(registry, catalog: context.catalog, membership: membership)
        } catch { throw LessonGenerationError.corruptObjectives }
        guard membership.topicIDs.contains(selection.topicID),
              catalog.topics.contains(where: { $0.id == selection.topicID }) else {
            throw LessonGenerationError.invalidScope
        }
        let subtopics = Dictionary(uniqueKeysWithValues: catalog.subtopics.map { ($0.id, $0.topicID) })
        let concepts = Dictionary(uniqueKeysWithValues: catalog.concepts.map { ($0.id, $0) })
        let currentConcepts = Set(membership.conceptIDs)
        let completed = context.completedConceptIDs.intersection(currentConcepts)
        var satisfied = completed
        var pending = Array(completed)
        while let id = pending.popLast() {
            for parent in concepts[id]?.prerequisiteConceptIDs ?? [] where currentConcepts.contains(parent) {
                if satisfied.insert(parent).inserted { pending.append(parent) }
            }
        }
        let excludedKeys = Set(context.terminal.filter { $0.status == .completed || $0.status == .dismissed }
            .compactMap { $0.metadata.objectiveKey.map(LessonDeduplication.normalizedObjective) })
        let available = registry.objectives.filter {
            $0.topicID == selection.topicID &&
                !excludedKeys.contains(LessonDeduplication.normalizedObjective($0.key))
        }.sorted { $0.key < $1.key }
        guard !available.isEmpty else { throw LessonGenerationError.exhaustedObjectives }
        let objective: GenerationObjective
        if let key = selection.objectiveKey {
            guard let found = available.first(where: { $0.key == key }) else {
                throw LessonGenerationError.invalidScope
            }
            objective = found
        } else {
            // Do not pick an ineligible first item and fail if another is usable.
            guard let found = available.first(where: { item in
                item.formats.contains(selection.format) && item.difficulties.contains(selection.difficulty) &&
                    item.prerequisiteConceptIDs.allSatisfy(satisfied.contains)
            }) else { throw LessonGenerationError.invalidScope }
            objective = found
        }
        guard objective.formats.contains(selection.format),
              objective.difficulties.contains(selection.difficulty),
              membership.subtopicIDs.contains(objective.subtopicID),
              subtopics[objective.subtopicID] == selection.topicID,
              objective.conceptIDs.allSatisfy({ id in
                  currentConcepts.contains(id) && concepts[id]?.subtopicID == objective.subtopicID
              }), objective.prerequisiteConceptIDs.allSatisfy({ id in
                  guard let subtopic = concepts[id]?.subtopicID else { return false }
                  return currentConcepts.contains(id) && subtopics[subtopic] == selection.topicID
              }) else { throw LessonGenerationError.invalidScope }
        guard objective.prerequisiteConceptIDs.allSatisfy(satisfied.contains) else {
            throw LessonGenerationError.unmetPrerequisites
        }

        // Remote hints are narrower than the local duplicate evidence. A sibling
        // subtopic in the same topic is not relevant unless its concept is an
        // explicit prerequisite of this objective. A known objective in the
        // selected subtopic can still be relevant with missing legacy concepts.
        let relevantIDs = Set(objective.conceptIDs + objective.prerequisiteConceptIDs)
        let selectedSubtopicKeys = Set(catalog.lessons.filter {
            $0.subtopicID == objective.subtopicID && membership.seededLessonIDs.contains($0.id)
        }.map { LessonDeduplication.normalizedObjective($0.objectiveKey) })
            .union(registry.objectives.filter { $0.subtopicID == objective.subtopicID }
                .map { LessonDeduplication.normalizedObjective($0.key) })
        var evidence: [String: Set<String>] = [:]
        for record in context.terminal where record.status == .completed || record.status == .dismissed {
            guard record.topicID == selection.topicID, let key = record.metadata.objectiveKey else { continue }
            let normalizedKey = LessonDeduplication.normalizedObjective(key)
            guard !normalizedKey.isEmpty else { continue }
            let ids = Set(record.metadata.conceptIDs ?? []).intersection(relevantIDs)
            guard !ids.isEmpty || selectedSubtopicKeys.contains(normalizedKey) else { continue }
            evidence[normalizedKey, default: []].formUnion(ids)
        }
        var exclusions = evidence.keys.sorted().map {
            LessonGenerationRequest.ObjectiveExclusion(key: $0, conceptIDs: evidence[$0, default: []].sorted())
        }
        let relevantCompleted = completed.intersection(relevantIDs).sorted()
        var completedHints = relevantCompleted
        // Total remote exclusion count, not a per-array allowance. Always keep
        // complete evidence in `context` for acceptance after the response.
        if exclusions.count > LessonGenerationRequest.maximumExclusions {
            exclusions = Array(exclusions.prefix(LessonGenerationRequest.maximumExclusions))
        }
        completedHints = Array(completedHints.prefix(LessonGenerationRequest.maximumExclusions - exclusions.count))
        func request() -> LessonGenerationRequest {
            LessonGenerationRequest(operationID: operationID,
                requestSchemaVersion: LessonGenerationRequest.schemaVersion,
                catalogID: catalog.catalogID, catalogVersion: catalog.version,
                objectiveRegistryVersion: registry.version, topicID: objective.topicID,
                subtopicID: objective.subtopicID, conceptIDs: objective.conceptIDs,
                objectiveKey: objective.key, objective: objective.text,
                difficulty: selection.difficulty, format: selection.format,
                prerequisiteConceptIDs: objective.prerequisiteConceptIDs,
                completedConceptIDs: completedHints, excludedObjectives: exclusions)
        }
        // Reserve envelope bytes before deterministically dropping suffix hints.
        // The adapter must also check the complete encoded body at the IO boundary.
        while true {
            let value = request()
            if (try? value.encodedData()) != nil { return value }
            if !completedHints.isEmpty { completedHints.removeLast() }
            else if !exclusions.isEmpty { exclusions.removeLast() }
            else { throw LessonGenerationError.oversizedRequest }
        }
    }
}
