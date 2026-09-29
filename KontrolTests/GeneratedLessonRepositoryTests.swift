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
