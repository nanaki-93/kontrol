import Foundation

// An optional, read-only registry. Loading it never imports a catalog or opens a store.
struct GenerationObjective: Decodable, Equatable {
    let key: String
    let text: String
    let topicID: String
    let subtopicID: String
    let conceptIDs: [String]
    let prerequisiteConceptIDs: [String]
    let formats: [String]
    let difficulties: [String]
}

struct GenerationObjectives: Decodable {
    let version: Int
    let objectives: [GenerationObjective]

    func unseen(topicID: String, excluding keys: Set<String>) throws -> [GenerationObjective] {
        let available = objectives.filter { $0.topicID == topicID && !keys.contains($0.key) }
        guard !available.isEmpty else { throw GenerationObjectivesError.exhausted }
        return available
    }
}

enum GenerationObjectivesError: Error, Equatable {
    case missing, corrupt, exhausted

    var message: String {
        switch self {
        case .missing: return "Generation objectives are unavailable"
        case .corrupt: return "Generation objectives are invalid"
        case .exhausted: return "No unseen generation objectives available"
        }
    }
}

enum GenerationObjectivesLoader {
    static let maximumBytes = 64 * 1024
    private static let formats: Set<String> = ["learn", "code", "question", "design"]
    private static let difficulties: Set<String> = ["basic", "intermediate", "advanced"]

    // The caller supplies authoritative *current* membership, not retained historical rows.
    // No cache: a failed optional resource must not turn catalog launch into a failure.
    static func load(from bundle: Bundle = .main, catalog: ValidatedCatalog,
                     membership: CurrentCatalogMembership) throws -> GenerationObjectives {
        guard let url = bundle.url(forResource: "generation-objectives", withExtension: "json") else {
            throw GenerationObjectivesError.missing
        }
        guard let data = try? Data(contentsOf: url) else { throw GenerationObjectivesError.missing }
        return try decodeAndValidate(data, catalog: catalog, membership: membership)
    }

    static func decodeAndValidate(_ data: Data, catalog: ValidatedCatalog,
                                  membership: CurrentCatalogMembership) throws -> GenerationObjectives {
        guard !data.isEmpty, data.count <= maximumBytes,
              let registry = try? JSONDecoder().decode(GenerationObjectives.self, from: data),
              registry.version == 1, !registry.objectives.isEmpty, registry.objectives.count <= 1000,
              (try? membership.validate()) != nil,
              membership.catalogID == catalog.value.catalogID,
              membership.catalogVersion == catalog.value.version else {
            throw GenerationObjectivesError.corrupt
        }
        let topics = Set(catalog.value.topics.map(\.id)).intersection(membership.topicIDs)
        let subtopics = Dictionary(uniqueKeysWithValues: catalog.value.subtopics.map { ($0.id, $0.topicID) })
        let concepts = Dictionary(uniqueKeysWithValues: catalog.value.concepts.map { ($0.id, $0.subtopicID) })
        let currentSubtopics = Set(membership.subtopicIDs)
        let currentConcepts = Set(membership.conceptIDs)
        let seedKeys = Set(catalog.value.lessons.map(\.objectiveKey))
        let seedTexts = Set(catalog.value.lessons.map { $0.objective.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping })
        let keys = registry.objectives.map(\.key)
        let texts = registry.objectives.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
        func uniqueNonempty(_ values: [String]) -> Bool {
            !values.isEmpty && values.count == Set(values).count &&
                values.allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
        }
        guard Set(keys).count == keys.count, Set(texts).count == texts.count,
              Set(topics) == Set(membership.topicIDs),
              Set(membership.subtopicIDs).isSubset(of: Set(subtopics.keys)),
              Set(membership.conceptIDs).isSubset(of: Set(concepts.keys)),
              registry.objectives.allSatisfy({ item in
                  let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
                  return !item.key.isEmpty && item.key == item.key.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping &&
                      !seedKeys.contains(item.key) && !text.isEmpty && text.unicodeScalars.count <= 1000 &&
                      !seedTexts.contains(text) && topics.contains(item.topicID) &&
                      currentSubtopics.contains(item.subtopicID) && subtopics[item.subtopicID] == item.topicID &&
                      uniqueNonempty(item.conceptIDs) && item.conceptIDs.count <= 20 &&
                      item.conceptIDs.allSatisfy { currentConcepts.contains($0) && concepts[$0] == item.subtopicID } &&
                      item.prerequisiteConceptIDs.count <= 20 && Set(item.prerequisiteConceptIDs).count == item.prerequisiteConceptIDs.count &&
                      item.prerequisiteConceptIDs.allSatisfy { id in
                          guard let subtopic = concepts[id] else { return false }
                          return currentConcepts.contains(id) && subtopics[subtopic] == item.topicID
                      } && uniqueNonempty(item.formats) && Set(item.formats).isSubset(of: formats) &&
                      uniqueNonempty(item.difficulties) && Set(item.difficulties).isSubset(of: difficulties)
              }), Set(registry.objectives.map(\.topicID)) == topics else {
            throw GenerationObjectivesError.corrupt
        }
        return registry
    }
}
