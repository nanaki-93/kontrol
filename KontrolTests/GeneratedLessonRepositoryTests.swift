import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class GeneratedLessonRepositoryTests: XCTestCase {
    private func setup() throws -> (ModelContainer, SwiftDataCatalogRepository, ValidatedCatalog) {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let catalog = try BundledCatalogLoader.load(from: Bundle.main)
        _ = try repository.importIfNeeded(catalog)
        return (container, repository, catalog)
    }

    private func count<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<T>()).count
    }

    private func ready(_ repository: SwiftDataCatalogRepository, container: ModelContainer,
                       operationID: UUID = UUID()) throws -> ValidatedGeneratedLesson {
        // A completed concept is authoritative only with its terminal archive.
        let catalog = try repository.generationContext(topicID: "go")
        if !catalog.completedConceptIDs.contains("go.concurrency.cancel-work") {
            let source = try XCTUnwrap(catalog.definitions.first {
                $0.conceptIDs.contains("go.concurrency.cancel-work") && $0.objectiveKey !=
                    "expansion.go.concurrency.cancellation-race"
            })
            let date = Date(timeIntervalSince1970: 20)
            let writer = ModelContext(container)
            writer.insert(LessonProgress(lessonID: source.id, status: .completed, completedAt: date))
            writer.insert(LessonAttempt(id: UUID(), lessonID: source.id, contentVersion: source.contentVersion,
                completedAt: date, pinnedContentData: try PinnedLessonContent(definition: source).encoded()))
            writer.insert(try LessonTerminalRecord(metadata: LessonTerminalMetadata(lessonID: source.id,
                provenance: .studiedPin, title: source.title, topicID: source.topicID,
                subtopicID: source.subtopicID, contentVersion: source.contentVersion,
                objectiveKey: source.objectiveKey, conceptIDs: source.conceptIDs.sorted(),
                normalizedContentHash: source.normalizedContentHash, format: source.format,
                dismissalTimeDefinition: nil)))
            try writer.save()
        }
        let context = try repository.generationContext(topicID: "go")
        let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
        let request = try LessonGenerationRequestBuilder.make(selection: LessonGenerationSelection(topicID: "go",
            objectiveKey: "expansion.go.concurrency.cancellation-race", format: "code",
            difficulty: "intermediate"), operationID: operationID, context: context, registry: registry)
        let candidate = CandidateLesson(title: "Cancellation race", objectiveKey: request.objectiveKey,
            objective: "Untrusted rewrite", topicID: request.topicID, subtopicID: request.subtopicID,
            conceptIDs: request.conceptIDs, difficulty: request.difficulty, format: request.format,
            estimatedMinutes: 20, prerequisiteConceptIDs: request.prerequisiteConceptIDs,
            explanation: "Distinct cancellation explanation", workedExample: "Distinct worked example",
            exercise: "Distinct exercise", referenceAnswer: "Distinct reference",
            selfCheckCriteria: ["Check distinct behavior"])
        return try GeneratedLessonValidator.validate(candidate, request: request, context: context,
            registry: registry, requestedModel: "gpt-4o-2024-08-06", now: Date(timeIntervalSince1970: 30))
    }

    func testVacancyCommitsOnlyNewAssignmentAndProjections() throws {
        let (container, repository, _) = try setup()
        let lesson = try ready(repository, container: container)
        let writer = ModelContext(container)
        let vacant = try XCTUnwrap(writer.fetch(FetchDescriptor<LessonSlot>())
            .filter { $0.topicID == "go" }.sorted { $0.slotIndex < $1.slotIndex }.first)
        let index = vacant.slotIndex
        writer.delete(vacant)
        try writer.save()
        let prior = try repository.loadSnapshot()
        let completedIDs = Set(prior.progress.filter { $0.status == .completed }.map(\.lessonID))
        let pinnedChoice = try XCTUnwrap(prior.slots.first {
            $0.topicID == "go" && !completedIDs.contains($0.lessonID)
        })
        _ = try repository.openLesson(lessonID: pinnedChoice.lessonID, now: Date(timeIntervalSince1970: 35))
        let before = try repository.loadSnapshot()
        let history = try repository.loadHistory()
        let coverage = try repository.loadCoverage()
        let attempts = try count(LessonAttempt.self, in: container)
        let result = try repository.acceptGeneratedLesson(lesson, now: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(result.lessonID, lesson.definition.id)
        XCTAssertEqual(result.assignedSlot?.slotIndex, index)
        XCTAssertEqual(result.assignedSlot?.assignedAt, Date(timeIntervalSince1970: 40))
        XCTAssertEqual(result.catalog.slots.filter { $0.lessonID != result.lessonID }, before.slots)
        XCTAssertEqual(result.catalog.progress, before.progress)
        XCTAssertEqual(result.catalog.startedPins, before.startedPins)
        XCTAssertEqual(result.history, history)
        XCTAssertEqual(result.coverage, coverage)
        XCTAssertEqual(try repository.loadSnapshot(), result.catalog)
        XCTAssertEqual(try count(LessonAttempt.self, in: container), attempts)
        XCTAssertEqual(try count(LessonProgress.self, in: container), before.progress.count)
        XCTAssertEqual(result.catalog.definitions.first { $0.id == result.lessonID }, lesson.definition)
        XCTAssertThrowsError(try repository.acceptGeneratedLesson(lesson, now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateIdentity)
        }
        XCTAssertEqual(try count(LessonDefinition.self, in: container), before.definitions.count + 1)
    }

    func testFullSlotsSaveWithoutChangingChoicesOrMembership() throws {
        let (container, repository, _) = try setup()
        let lesson = try ready(repository, container: container)
        let before = try repository.loadSnapshot()
        XCTAssertEqual(before.slots.filter { $0.topicID == "go" }.count, 4)
        let membership = try repository.generationContext(topicID: "go").membership
        let result = try repository.acceptGeneratedLesson(lesson, now: Date(timeIntervalSince1970: 40))
        XCTAssertNil(result.assignedSlot)
        XCTAssertEqual(result.catalog.slots, before.slots)
        XCTAssertEqual(result.catalog.progress, before.progress)
        XCTAssertEqual(result.catalog.startedPins, before.startedPins)
        XCTAssertEqual(try repository.generationContext(topicID: "go").membership, membership)
        XCTAssertTrue(result.catalog.definitions.contains(lesson.definition))
    }

    func testSaveFailureAndLateTerminalOverlapLeaveNoInsertion() throws {
        let (container, repository, _) = try setup()
        let lesson = try ready(repository, container: container)
        let failing = SwiftDataCatalogRepository(container: container, beforeSave: { throw LessonGenerationError.persistenceFailure })
        let before = try repository.loadSnapshot()
        XCTAssertThrowsError(try failing.acceptGeneratedLesson(lesson, now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .persistenceFailure)
        }
        XCTAssertEqual(try repository.loadSnapshot(), before)
        let writer = ModelContext(container)
        let date = Date(timeIntervalSince1970: 50)
        let other = "historical.duplicate"
        writer.insert(LessonProgress(lessonID: other, status: .dismissed, dismissedAt: date))
        writer.insert(try LessonTerminalRecord(metadata: LessonTerminalMetadata(lessonID: other,
            provenance: .legacyRecoveredReference, title: "Other", topicID: "go",
            subtopicID: lesson.definition.subtopicID, contentVersion: 1,
            objectiveKey: "other.objective", conceptIDs: lesson.definition.conceptIDs.sorted(),
            normalizedContentHash: lesson.definition.normalizedContentHash, format: "code",
            dismissalTimeDefinition: nil)))
        try writer.save()
        let changed = try repository.loadSnapshot()
        XCTAssertThrowsError(try repository.acceptGeneratedLesson(lesson, now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateContent)
        }
        XCTAssertEqual(try repository.loadSnapshot(), changed)
    }

    func testLatePrerequisiteLossAndCatalogUpgradeRejectBeforeWrite() throws {
        let (container, repository, catalog) = try setup()
        let lesson = try ready(repository, container: container)
        let writer = ModelContext(container)
        let completed = try XCTUnwrap(writer.fetch(FetchDescriptor<LessonProgress>()).first {
            $0.status == .completed && $0.lessonID != lesson.definition.id
        })
        let id = completed.lessonID
        writer.delete(completed)
        for row in try writer.fetch(FetchDescriptor<LessonTerminalRecord>()) where row.lessonID == id {
            writer.delete(row)
        }
        for row in try writer.fetch(FetchDescriptor<LessonAttempt>()) where row.lessonID == id {
            writer.delete(row)
        }
        try writer.save()
        let before = try repository.loadSnapshot()
        XCTAssertThrowsError(try repository.acceptGeneratedLesson(lesson, now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .unmetPrerequisites)
        }
        XCTAssertEqual(try repository.loadSnapshot(), before)
        var upgrade = catalog.value
        upgrade.version += 1
        _ = try repository.importIfNeeded(CatalogValidator.validate(upgrade))
        let upgraded = try repository.loadSnapshot()
        XCTAssertThrowsError(try repository.acceptGeneratedLesson(lesson, now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .staleContext)
        }
        XCTAssertEqual(try repository.loadSnapshot(), upgraded)
    }

    func testLateTerminalObjectiveOverlapRejectsBeforeWrite() throws {
        let (container, repository, _) = try setup()
        let lesson = try ready(repository, container: container)
        let writer = ModelContext(container)
        let date = Date(timeIntervalSince1970: 50)
        let other = "historical.overlap"
        writer.insert(LessonProgress(lessonID: other, status: .completed, completedAt: date))
        writer.insert(try LessonTerminalRecord(metadata: LessonTerminalMetadata(lessonID: other,
            provenance: .legacyRecoveredReference, title: "Older version", topicID: "go",
            subtopicID: lesson.definition.subtopicID, contentVersion: 1,
            objectiveKey: lesson.definition.objectiveKey, conceptIDs: lesson.definition.conceptIDs.sorted(),
            normalizedContentHash: CatalogValidator.fingerprint(explanation: "other", workedExample: "other",
                exercise: "other", referenceAnswer: "other", selfCheckCriteria: ["other"]),
            format: "code", dismissalTimeDefinition: nil)))
        try writer.save()
        let before = try repository.loadSnapshot()
        XCTAssertThrowsError(try repository.acceptGeneratedLesson(lesson, now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateObjective)
        }
        XCTAssertEqual(try repository.loadSnapshot(), before)
    }

    func testReopenAndSeedUpgradeRetainGeneratedDefinition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.store")
        let factory = ModelContainerFactory()
        let container = try factory.makeContainer(mode: .persistent(url))
        let repository = SwiftDataCatalogRepository(container: container)
        let catalog = try BundledCatalogLoader.load(from: Bundle.main)
        _ = try repository.importIfNeeded(catalog)
        let lesson = try ready(repository, container: container)
        _ = try repository.acceptGeneratedLesson(lesson, now: Date(timeIntervalSince1970: 40))
        let membership = try repository.generationContext(topicID: "go").membership
        let reopened = SwiftDataCatalogRepository(container: try factory.makeContainer(mode: .persistent(url)))
        XCTAssertTrue(try reopened.loadSnapshot().definitions.contains(lesson.definition))
        var upgraded = catalog.value
        upgraded.version += 1
        _ = try reopened.importIfNeeded(CatalogValidator.validate(upgraded))
        XCTAssertTrue(try reopened.loadSnapshot().definitions.contains(lesson.definition))
        let latest = try reopened.generationContext(topicID: "go").membership
        XCTAssertEqual(latest.seededLessonIDs, membership.seededLessonIDs)
        XCTAssertFalse(latest.seededLessonIDs.contains(lesson.definition.id))
    }

    func testContextUsesCurrentMembershipAndRetainsHistoricalDefinitions() throws {
        let (container, repository, catalog) = try setup()
        let removed = try XCTUnwrap(catalog.value.lessons.first { $0.topicID == "go" })
        var upgrade = catalog.value
        upgrade.version += 1
        upgrade.lessons.removeAll { $0.id == removed.id }
        _ = try repository.importIfNeeded(CatalogValidator.validate(upgrade))

        let result = try repository.generationContext(topicID: "go")
        XCTAssertEqual(result.catalog.value.version, upgrade.version)
        XCTAssertFalse(result.membership.seededLessonIDs.contains(removed.id))
        XCTAssertFalse(result.catalog.value.lessons.contains { $0.id == removed.id })
        XCTAssertTrue(result.definitions.contains { $0.id == removed.id })
        XCTAssertEqual(Set(result.catalog.value.lessons.map(\.id)), Set(result.membership.seededLessonIDs))
        XCTAssertEqual(Set(result.catalog.value.concepts.map(\.id)), Set(result.membership.conceptIDs))
        XCTAssertEqual(result.slots, try repository.loadSnapshot().slots)
        XCTAssertEqual(try count(LessonProgress.self, in: container), 0)
        XCTAssertEqual(try count(LessonAttempt.self, in: container), 0)
    }

    func testRetiredTaxonomyCannotBeSelectedFromRetainedRows() throws {
        let (_, repository, catalog) = try setup()
        var upgrade = catalog.value
        upgrade.version += 1
        let retiredSubtopics = Set(upgrade.subtopics.filter { $0.topicID == "go" }.map(\.id))
        upgrade.topics.removeAll { $0.id == "go" }
        upgrade.subtopics.removeAll { retiredSubtopics.contains($0.id) }
        upgrade.concepts.removeAll { retiredSubtopics.contains($0.subtopicID) }
        upgrade.lessons.removeAll { $0.topicID == "go" }
        _ = try repository.importIfNeeded(CatalogValidator.validate(upgrade))

        XCTAssertThrowsError(try repository.generationContext(topicID: "go")) {
            XCTAssertEqual($0 as? GenerationContextError, .invalidScope)
        }
        let current = try repository.generationContext(topicID: "java")
        XCTAssertEqual(Set(current.catalog.value.topics.map(\.id)), Set(upgrade.topics.map(\.id)))
        XCTAssertEqual(Set(current.catalog.value.subtopics.map(\.id)), Set(upgrade.subtopics.map(\.id)))
        XCTAssertEqual(Set(current.catalog.value.concepts.map(\.id)), Set(upgrade.concepts.map(\.id)))
        XCTAssertTrue(current.definitions.contains { $0.topicID == "go" }) // retained for duplicates
        XCTAssertFalse(current.catalog.value.lessons.contains { $0.topicID == "go" })
    }

    func testContextCarriesTerminalPrerequisitesPinsAndExactSlotsWithoutWriting() throws {
        let (container, repository, catalog) = try setup()
        let first = try XCTUnwrap(repository.loadSnapshot().slots.first { $0.topicID == "go" })
        let started = try repository.openLesson(lessonID: first.lessonID, now: Date(timeIntervalSince1970: 100))
        let completed = try XCTUnwrap(catalog.value.lessons.first { $0.id != first.lessonID && $0.topicID == "go" })
        let completedDefinition = try XCTUnwrap(repository.loadSnapshot().definitions.first { $0.id == completed.id })
        let date = Date(timeIntervalSince1970: 200)
        let metadata = LessonTerminalMetadata(lessonID: completed.id, provenance: .studiedPin,
            title: completed.title, topicID: completed.topicID, subtopicID: completed.subtopicID,
            contentVersion: completed.contentVersion, objectiveKey: completed.objectiveKey,
            conceptIDs: completed.conceptIDs.sorted(), normalizedContentHash: completed.normalizedContentHash,
            format: completed.format, dismissalTimeDefinition: nil)
        let writer = ModelContext(container)
        writer.insert(LessonProgress(lessonID: completed.id, status: .completed, completedAt: date))
        writer.insert(LessonAttempt(id: UUID(), lessonID: completed.id,
            contentVersion: completed.contentVersion,
            completedAt: date,
            pinnedContentData: try PinnedLessonContent(definition: completedDefinition).encoded()))
        writer.insert(try LessonTerminalRecord(metadata: metadata))
        try writer.save()

        let before = try repository.loadSnapshot()
        let history = try repository.loadHistory()
        let coverage = try repository.loadCoverage()
        let context = try repository.generationContext(topicID: "go")
        XCTAssertEqual(context.slots, before.slots) // no reconciliation of the terminal slot
        XCTAssertEqual(context.startedPins, before.startedPins)
        XCTAssertEqual(context.startedPins.first?.id, first.lessonID)
        if case .pinned(let pin) = started.detail.content {
            XCTAssertEqual(context.startedPins.first, pin)
        } else {
            XCTFail("Opened lesson must retain its studied pin")
        }
        XCTAssertEqual(context.terminal.first { $0.metadata.id == completed.id }?.metadata.contentHash,
                       completed.normalizedContentHash)
        XCTAssertTrue(Set(completed.conceptIDs).isSubset(of: context.completedConceptIDs))
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertEqual(try repository.loadHistory(), history)
        XCTAssertEqual(try repository.loadCoverage(), coverage)
        XCTAssertEqual(try count(LessonProgress.self, in: container), 2)
        XCTAssertEqual(try count(LessonAttempt.self, in: container), 2)
        XCTAssertEqual(try count(LessonTerminalRecord.self, in: container), 1)
    }

    func testUnavailableScopeAndCorruptSlotFailWithoutRepairOrWrites() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let empty = SwiftDataCatalogRepository(container: container)
        XCTAssertThrowsError(try empty.generationContext(topicID: "go")) {
            XCTAssertEqual($0 as? GenerationContextError, .unavailable)
        }
        XCTAssertEqual(try count(CatalogMembership.self, in: container), 0)
        XCTAssertEqual(try count(LessonSlot.self, in: container), 0)

        let catalog = try BundledCatalogLoader.load(from: Bundle.main)
        _ = try empty.importIfNeeded(catalog)
        XCTAssertThrowsError(try empty.generationContext(topicID: "retired")) {
            XCTAssertEqual($0 as? GenerationContextError, .invalidScope)
        }
        let writer = ModelContext(container)
        let slot = try XCTUnwrap(writer.fetch(FetchDescriptor<LessonSlot>()).first)
        slot.key = "invalid-slot"
        try writer.save()
        let stored = try writer.fetch(FetchDescriptor<LessonSlot>()).map(\.key)
        XCTAssertThrowsError(try empty.generationContext(topicID: "go")) {
            XCTAssertEqual($0 as? GenerationContextError, .invalidEvidence)
        }
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonSlot>()).map(\.key), stored)
        XCTAssertEqual(try count(LessonProgress.self, in: container), 0)
        XCTAssertEqual(try count(LessonAttempt.self, in: container), 0)
        XCTAssertEqual(try count(LessonTerminalRecord.self, in: container), 0)
    }

    func testMissingCurrentMembershipDoesNotFallBackToRetainedCatalog() throws {
        let (container, repository, _) = try setup()
        let writer = ModelContext(container)
        for row in try writer.fetch(FetchDescriptor<CatalogMembership>()) { writer.delete(row) }
        try writer.save()
        let before = try repository.loadSnapshot()
        XCTAssertThrowsError(try repository.generationContext(topicID: "go")) {
            XCTAssertEqual($0 as? GenerationContextError, .unavailable)
        }
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertEqual(try count(CatalogMembership.self, in: container), 0)
        XCTAssertEqual(try count(LessonProgress.self, in: container), 0)
        XCTAssertEqual(try count(LessonAttempt.self, in: container), 0)
    }
}
