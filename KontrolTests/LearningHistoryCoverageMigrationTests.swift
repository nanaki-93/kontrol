import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LearningHistoryCoverageMigrationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private enum Injected: Error { case save }

    private func upgraded(_ original: ValidatedCatalog, id: String) throws -> ValidatedCatalog {
        var value = original.value
        value.version += 1
        let index = try XCTUnwrap(value.lessons.firstIndex { $0.id == id })
        value.lessons[index].title = "New installed title"
        value.lessons[index].contentVersion += 1
        value.lessons[index].explanation = "New installed teaching"
        value.lessons[index].normalizedContentHash = CatalogValidator.fingerprint(for: value.lessons[index])
        return try CatalogValidator.validate(value)
    }

    private func seed(_ container: ModelContainer, catalog: ValidatedCatalog) throws -> (String, String, String, Data) {
        let rows = catalog.value.lessons.prefix(3)
        let ids = Array(rows.map(\.id))
        let context = ModelContext(container)
        let definition = try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first { $0.id == ids[0] })
        let pin = try PinnedLessonContent(definition: LessonDefinitionSnapshot(
            id: definition.id, objectiveKey: definition.objectiveKey, objective: definition.objective,
            title: definition.title, topicID: definition.topicID, subtopicID: definition.subtopicID,
            conceptIDs: definition.conceptIDs, difficulty: definition.difficulty, format: definition.format,
            estimatedMinutes: definition.estimatedMinutes, prerequisiteConceptIDs: definition.prerequisiteConceptIDs,
            explanation: definition.explanation, workedExample: definition.workedExample,
            exercise: definition.exercise, referenceAnswer: definition.referenceAnswer,
            selfCheckCriteria: definition.selfCheckCriteria, contentVersion: definition.contentVersion,
            normalizedContentHash: definition.normalizedContentHash, source: definition.source,
            provenance: definition.provenance)).encoded()
        context.insert(LessonProgress(lessonID: ids[0], status: .completed, completedAt: date))
        context.insert(LessonAttempt(id: UUID(), lessonID: ids[0], contentVersion: definition.contentVersion,
            answerDraft: "  exact answer 🧪\n", completedAt: date, pinnedContentData: pin))
        let legacy = KontrolSchemaV1.LessonContentSnapshot(title: "Legacy completed title",
            objectiveKey: "legacy-objective", conceptIDs: ["legacy-concept"], difficulty: "basic",
            format: "code", explanation: "Old prose", workedExample: "Old example",
            exercise: "Old exercise", referenceAnswer: "Old answer", selfCheckCriteria: ["Old criterion"])
        context.insert(LessonProgress(lessonID: ids[1], status: .completed, completedAt: date))
        context.insert(LessonAttempt(id: UUID(), lessonID: ids[1], contentVersion: 1,
            answerDraft: "untouched legacy answer", completedAt: date,
            completedContentSnapshot: legacy, pinnedContentData: Data()))
        context.insert(LessonProgress(lessonID: ids[2], status: .dismissed, dismissedAt: date))
        try context.save()
        return (ids[0], ids[1], ids[2], pin)
    }

    func testMatchingVersionBackfillsMissingMembershipButMismatchedCatalogCannot() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = try BundledCatalogLoader.load()
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(catalog)
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<CatalogMembership>()) { context.delete(row) }
        try context.save()
        XCTAssertEqual(try repository.loadMembership(catalogID: catalog.value.catalogID), .unavailable)
        let marker = try XCTUnwrap(context.fetch(FetchDescriptor<CatalogImportState>()).first)
        marker.lastImportedVersion = catalog.value.version + 1
        try context.save()
        XCTAssertThrowsError(try repository.importIfNeeded(catalog)) {
            XCTAssertEqual($0 as? CatalogImportError, .downgrade(
                installed: catalog.value.version + 1, requested: catalog.value.version))
        }
        XCTAssertEqual(try repository.loadMembership(catalogID: catalog.value.catalogID), .unavailable)
        marker.lastImportedVersion = catalog.value.version
        try context.save()
        let failing = SwiftDataCatalogRepository(container: container, beforeSave: { throw Injected.save })
        XCTAssertThrowsError(try failing.importIfNeeded(catalog)) { XCTAssertTrue($0 is Injected) }
        XCTAssertEqual(try repository.loadMembership(catalogID: catalog.value.catalogID), .unavailable)
        XCTAssertEqual(try repository.importIfNeeded(catalog), .unchanged)
        let expected = CurrentCatalogMembership(catalogID: catalog.value.catalogID,
            catalogVersion: catalog.value.version, topicIDs: catalog.value.topics.map(\.id).sorted(),
            subtopicIDs: catalog.value.subtopics.map(\.id).sorted(),
            conceptIDs: catalog.value.concepts.map(\.id).sorted(),
            seededLessonIDs: catalog.value.lessons.filter { $0.source == "seed" }.map(\.id).sorted())
        XCTAssertEqual(try repository.loadMembership(catalogID: catalog.value.catalogID), .available(expected))
        XCTAssertEqual(try SwiftDataCatalogRepository(container: container,
            beforeSave: { throw Injected.save }).importIfNeeded(catalog), .unchanged)
    }

    func testSameVersionBackfillIsIdempotentAndKeepsOriginalAttempts() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = try BundledCatalogLoader.load()
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(catalog)
        let (pinned, partial, dismissed, pin) = try seed(container, catalog: catalog)
        XCTAssertEqual(try repository.importIfNeeded(catalog), .unchanged)
        let first = try repository.loadHistory()
        let records = try ModelContext(container).fetch(FetchDescriptor<LessonTerminalRecord>())
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(first.first { $0.lessonID == pinned }?.provenance, .studiedPin)
        XCTAssertEqual(first.first { $0.lessonID == pinned }?.metadata?.topicID,
                       catalog.value.lessons.first { $0.id == pinned }?.topicID)
        let legacy = try XCTUnwrap(first.first { $0.lessonID == partial })
        XCTAssertEqual(legacy.provenance, .legacyCompletedPartial)
        XCTAssertEqual(legacy.title, "Legacy completed title")
        XCTAssertNil(legacy.topicID)
        XCTAssertNil(legacy.metadata?.subtopicID)
        XCTAssertEqual(legacy.metadata?.conceptIDs, ["legacy-concept"])
        XCTAssertEqual(legacy.metadata?.contentVersion, 1)
        guard case .legacyCompleted(let studied) = legacy.content else {
            return XCTFail("Reduced historical snapshot should be readable")
        }
        XCTAssertEqual(studied.exercise, "Old exercise")
        let reference = try XCTUnwrap(first.first { $0.lessonID == dismissed })
        XCTAssertEqual(reference.provenance, .legacyRecoveredReference)
        XCTAssertNil(reference.attempt)
        XCTAssertEqual(reference.metadata?.dismissalTimeDefinition?.id, dismissed)
        let bytes = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<LessonAttempt>())
            .first { $0.lessonID == pinned }?.pinnedContentData)
        XCTAssertEqual(bytes, pin)
        let payloads = Dictionary(uniqueKeysWithValues: records.map { ($0.lessonID, $0.payload) })
        // No save on an unchanged retry, including when a save hook would throw.
        let noSave = SwiftDataCatalogRepository(container: container, beforeSave: { throw Injected.save })
        XCTAssertEqual(try noSave.importIfNeeded(catalog), .unchanged)
        XCTAssertEqual(try repository.loadHistory(), first)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonTerminalRecord>())
            .map { ($0.lessonID, $0.payload) }.reduce(into: [String: Data]()) { $0[$1.0] = $1.1 }, payloads)
    }

    func testUpgradeAndDiskReopenKeepArchivesAndAttemptBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolEvidence-\(UUID())/Kontrol.store")
        let catalog = try BundledCatalogLoader.load()
        var saved: [LessonHistorySnapshot] = []
        var originalPin = Data()
        var originalLegacy: KontrolSchemaV1.LessonContentSnapshot?
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let repository = SwiftDataCatalogRepository(container: container)
            _ = try repository.importIfNeeded(catalog)
            let (pinned, partial, dismissed, pin) = try seed(container, catalog: catalog)
            originalPin = pin
            let context = ModelContext(container)
            originalLegacy = try XCTUnwrap(context.fetch(FetchDescriptor<LessonAttempt>())
                .first { $0.lessonID == partial }?.completedContentSnapshot)
            let oldTitle = try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>())
                .first { $0.id == dismissed }?.title)
            _ = try repository.importIfNeeded(upgraded(catalog, id: dismissed))
            saved = try repository.loadHistory()
            XCTAssertEqual(saved.first { $0.lessonID == dismissed }?.title, oldTitle)
            XCTAssertEqual(saved.first { $0.lessonID == pinned }?.metadata?.normalizedContentHash,
                           catalog.value.lessons.first { $0.id == pinned }?.normalizedContentHash)
        }
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let repository = SwiftDataCatalogRepository(container: container)
            XCTAssertEqual(try repository.loadHistory(), saved)
            let attempts = try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>())
            XCTAssertEqual(attempts.count, 2)
            XCTAssertEqual(attempts.first { $0.pinnedContentData?.isEmpty == false }?.pinnedContentData, originalPin)
            XCTAssertEqual(attempts.first { $0.completedContentSnapshot != nil }?.completedContentSnapshot,
                           originalLegacy)
            XCTAssertEqual(attempts.first { $0.pinnedContentData?.isEmpty == false }?.answerDraft, "  exact answer 🧪\n")
        }
    }

    func testFailedSameVersionBackfillDoesNotPersistAcrossDiskReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolFailedBackfill-\(UUID())/Kontrol.store")
        let catalog = try BundledCatalogLoader.load()
        var originalPin = Data()
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let writer = SwiftDataCatalogRepository(container: container)
            _ = try writer.importIfNeeded(catalog)
            let (_, _, _, pin) = try seed(container, catalog: catalog)
            originalPin = pin
            // Simulate V5→V6: installed marker and definitions, but no membership.
            let migration = ModelContext(container)
            for row in try migration.fetch(FetchDescriptor<CatalogMembership>()) { migration.delete(row) }
            try migration.save()
            XCTAssertEqual(try writer.loadMembership(catalogID: catalog.value.catalogID), .unavailable)
            let failed = SwiftDataCatalogRepository(container: container,
                beforeSave: { throw Injected.save })
            XCTAssertThrowsError(try failed.importIfNeeded(catalog)) {
                XCTAssertTrue($0 is Injected)
            }
        }
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let context = ModelContext(container)
            XCTAssertTrue(try context.fetch(FetchDescriptor<LessonTerminalRecord>()).isEmpty)
            XCTAssertEqual(try context.fetch(FetchDescriptor<CatalogImportState>()).first?.lastImportedVersion,
                           catalog.value.version)
            XCTAssertEqual(try SwiftDataCatalogRepository(container: container).loadMembership(
                catalogID: catalog.value.catalogID), .unavailable)
            XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>())
                .first { $0.pinnedContentData?.isEmpty == false }?.pinnedContentData, originalPin)
            XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>()).count, 2)
            let repository = SwiftDataCatalogRepository(container: container)
            _ = try repository.importIfNeeded(catalog)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonTerminalRecord>()).count, 3)
            if case .available(let membership) = try repository.loadMembership(catalogID: catalog.value.catalogID) {
                XCTAssertEqual(membership.catalogVersion, catalog.value.version)
            } else { XCTFail("Matching-version retry must recover membership") }
        }
    }

    func testCorruptPinCannotFallBackAndFailedImportCommitsNothing() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = try BundledCatalogLoader.load()
        let writer = SwiftDataCatalogRepository(container: container)
        _ = try writer.importIfNeeded(catalog)
        let (pinned, _, _, _) = try seed(container, catalog: catalog)
        let upgrade = try upgraded(catalog, id: pinned)
        for failsAtSave in [false, true] {
            let failed = SwiftDataCatalogRepository(container: container,
                beforeSave: { if !failsAtSave { throw Injected.save } },
                save: { _ in if failsAtSave { throw Injected.save } })
            XCTAssertThrowsError(try failed.importIfNeeded(upgrade)) { XCTAssertTrue($0 is Injected) }
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonTerminalRecord>()).isEmpty)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CatalogImportState>())
                .first?.lastImportedVersion, catalog.value.version)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonDefinition>())
                .first { $0.id == pinned }?.title, catalog.value.lessons.first { $0.id == pinned }?.title)
        }
        let edit = ModelContext(container)
        try XCTUnwrap(edit.fetch(FetchDescriptor<LessonAttempt>()).first { $0.lessonID == pinned })
            .pinnedContentData = Data("corrupt".utf8)
        try edit.save()
        XCTAssertThrowsError(try writer.importIfNeeded(upgrade)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonTerminalRecord>()).isEmpty)
    }
}
