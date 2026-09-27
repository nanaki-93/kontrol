import Foundation
import SwiftData

@MainActor
protocol CatalogRepository {
    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult
}

enum CatalogImportResult: Equatable {
    case imported
    case unchanged
}

enum CatalogImportError: Error, Equatable {
    case downgrade(installed: Int, requested: Int)
}

// Each import owns a fresh context. In particular, neither a failed save nor a
// pre-save error can roll back unsaved work in a view's main context.
@MainActor
final class SwiftDataCatalogRepository: CatalogRepository {
    private let container: ModelContainer
    private let beforeSave: () throws -> Void
    private let save: (ModelContext) throws -> Void

    // Hooks are scoped to the operation's commit boundary, not the shared container.
    // A throwing save hook must fail *instead of* saving, never after a commit.
    init(container: ModelContainer,
         beforeSave: @escaping () throws -> Void = {},
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.beforeSave = beforeSave
        self.save = save
    }

    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let value = catalog.value
        let states = try context.fetch(FetchDescriptor<CatalogImportState>())
        let state = states.first { $0.catalogID == value.catalogID }
        if let installed = state?.lastImportedVersion {
            if value.version < installed {
                throw CatalogImportError.downgrade(installed: installed, requested: value.version)
            }
            if value.version == installed { return .unchanged }
        }

        // Load all definition identities before changing anything. The input has
        // already passed whole-catalog validation; absence in a later version is
        // not a deletion instruction.
        let topics = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Topic>()).map { ($0.id, $0) })
        let subtopics = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Subtopic>()).map { ($0.id, $0) })
        let concepts = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Concept>()).map { ($0.id, $0) })
        let lessons = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<LessonDefinition>()).map { ($0.id, $0) })

        for item in value.topics {
            if let existing = topics[item.id] {
                existing.name = item.name
            } else {
                context.insert(Topic(id: item.id, name: item.name))
            }
        }
        for item in value.subtopics {
            if let existing = subtopics[item.id] {
                existing.topicID = item.topicID
                existing.name = item.name
            } else {
                context.insert(Subtopic(id: item.id, topicID: item.topicID, name: item.name))
            }
        }
        for item in value.concepts {
            if let existing = concepts[item.id] {
                existing.subtopicID = item.subtopicID
                existing.name = item.name
                existing.prerequisiteConceptIDs = item.prerequisiteConceptIDs
            } else {
                context.insert(Concept(id: item.id, subtopicID: item.subtopicID,
                                       name: item.name, prerequisiteConceptIDs: item.prerequisiteConceptIDs))
            }
        }
        for item in value.lessons {
            let definition: LessonDefinition
            if let existing = lessons[item.id] {
                definition = existing
            } else {
                definition = LessonDefinition(
                    id: item.id, objectiveKey: item.objectiveKey, title: item.title,
                    topicID: item.topicID, subtopicID: item.subtopicID,
                    conceptIDs: item.conceptIDs, difficulty: item.difficulty,
                    format: item.format, estimatedMinutes: item.estimatedMinutes,
                    prerequisiteConceptIDs: item.prerequisiteConceptIDs,
                    explanation: item.explanation, workedExample: item.workedExample,
                    exercise: item.exercise, referenceAnswer: item.referenceAnswer,
                    selfCheckCriteria: item.selfCheckCriteria, contentVersion: item.contentVersion,
                    normalizedContentHash: item.normalizedContentHash, source: item.source,
                    provenance: item.provenance)
                context.insert(definition)
            }
            definition.objectiveKey = item.objectiveKey
            definition.title = item.title
            definition.topicID = item.topicID
            definition.subtopicID = item.subtopicID
            definition.conceptIDs = item.conceptIDs
            definition.difficulty = item.difficulty
            definition.format = item.format
            definition.estimatedMinutes = item.estimatedMinutes
            definition.prerequisiteConceptIDs = item.prerequisiteConceptIDs
            definition.explanation = item.explanation
            definition.workedExample = item.workedExample
            definition.exercise = item.exercise
            definition.referenceAnswer = item.referenceAnswer
            definition.selfCheckCriteria = item.selfCheckCriteria
            definition.contentVersion = item.contentVersion
            definition.normalizedContentHash = item.normalizedContentHash
            definition.source = item.source
            definition.provenance = item.provenance
        }
        if let state {
            state.lastImportedVersion = value.version
        } else {
            context.insert(CatalogImportState(catalogID: value.catalogID,
                                              lastImportedVersion: value.version))
        }
        // One SQLite commit for all definitions and the version marker. On any
        // error the unsaved private context is discarded; no main-context rollback.
        try beforeSave()
        try save(context)
        return .imported
    }
}
