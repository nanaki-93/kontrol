import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class AIMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolAIMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testFreshSettingsStayDisabledUntilExplicitlyConfiguredAndReopen() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kontrol.store")
        let reference = UUID().uuidString
        var firstRevision: UUID?
        try autoreleasepool {
            let container = try factory.makeContainer(mode: .persistent(url))
            let repository = SwiftDataAISettingsRepository(container: container)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<AISettingsRecord>()).isEmpty)
            XCTAssertEqual(try repository.load(), .disabled)
            let configured = try repository.save(AISettingsSnapshot(
                enabled: false, providerID: "openai", modelID: "gpt-4o-2024-08-06",
                credentialReference: reference, revision: nil), expectedRevision: nil)
            firstRevision = configured.revision
            XCTAssertNotNil(firstRevision)
            XCTAssertFalse(configured.enabled)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<AISettingsRecord>()).count, 1)
        }
        let reopened = try factory.makeContainer(mode: .persistent(url))
        let repository = SwiftDataAISettingsRepository(container: reopened)
        let saved = try repository.load()
        XCTAssertEqual(saved.revision, firstRevision)
        XCTAssertEqual(saved.credentialReference, reference)
        XCTAssertFalse(saved.enabled)
        let enabled = try repository.save(AISettingsSnapshot(
            enabled: true, providerID: saved.providerID, modelID: saved.modelID,
            credentialReference: saved.credentialReference, revision: saved.revision),
            expectedRevision: saved.revision)
        XCTAssertTrue(enabled.enabled)
        XCTAssertNotEqual(enabled.revision, firstRevision)
        XCTAssertThrowsError(try repository.save(saved, expectedRevision: firstRevision)) {
            XCTAssertEqual($0 as? AISettingsPersistenceError, .staleRevision)
        }
        XCTAssertThrowsError(try repository.save(.disabled, expectedRevision: nil)) {
            XCTAssertEqual($0 as? AISettingsPersistenceError, .staleRevision)
        }
        XCTAssertEqual(try repository.load(), enabled)
        XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<AISettingsRecord>()).count, 1)
    }

    func testUnknownAndCorruptSettingsFailClosedWithoutDamagingLearning() throws {
        let container = try factory.makeContainer(mode: .inMemory)
        let context = ModelContext(container)
        context.insert(try TaskItem(id: UUID(), title: "Keep learning", createdAt: Date()))
        let row = AISettingsRecord()
        context.insert(row)
        try context.save()
        let repository = SwiftDataAISettingsRepository(container: container)
        XCTAssertFalse(try repository.load().enabled)
        row.payloadVersion = 99
        try context.save()
        XCTAssertThrowsError(try repository.load()) {
            XCTAssertEqual($0 as? AISettingsPersistenceError, .invalidSettings)
        }
        XCTAssertThrowsError(try repository.save(.disabled, expectedRevision: nil)) {
            XCTAssertEqual($0 as? AISettingsPersistenceError, .invalidSettings)
        }
        row.payloadVersion = 1
        row.providerID = "unknown"
        try context.save()
        XCTAssertThrowsError(try repository.load()) {
            XCTAssertEqual($0 as? AISettingsPersistenceError, .invalidSettings)
        }
        row.providerID = "openai"
        row.enabled = true // without a model/key: never authorize generation
        try context.save()
        XCTAssertThrowsError(try repository.load()) {
            XCTAssertEqual($0 as? AISettingsPersistenceError, .invalidSettings)
        }
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.title,
                       "Keep learning")
    }

    func testInvalidWriteDoesNotChangeRevisionOrRetainSecretAsReference() throws {
        let container = try factory.makeContainer(mode: .inMemory)
        let repository = SwiftDataAISettingsRepository(container: container)
        for reference in ["sk-not-a-reference", "  ", ""] {
            XCTAssertThrowsError(try repository.save(AISettingsSnapshot(
                enabled: false, providerID: "openai", modelID: "gpt-4o",
                credentialReference: reference, revision: nil), expectedRevision: nil)) {
                XCTAssertEqual($0 as? AISettingsPersistenceError, .invalidSettings)
            }
        }
        XCTAssertThrowsError(try repository.save(AISettingsSnapshot(
            enabled: true, providerID: "openai", modelID: nil,
            credentialReference: nil, revision: nil), expectedRevision: nil))
        XCTAssertEqual(try repository.load(), .disabled)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<AISettingsRecord>()).isEmpty)
    }

    func testV6MigrationPreservesPersonalRecordsAndSettingsRemainAbsent() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kontrol.store")
        let id = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV6.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(try TaskItem(id: id, title: "Original task", createdAt: Date(timeIntervalSince1970: 10)))
            context.insert(LessonProgress(lessonID: "old", status: .started,
                                          startedAt: Date(timeIntervalSince1970: 20)))
            context.insert(LessonAttempt(id: UUID(), lessonID: "old", contentVersion: 1, answerDraft: "Keep draft"))
            context.insert(try CatalogMembership(membership: CurrentCatalogMembership(
                catalogID: "starter", catalogVersion: 1, topicIDs: ["go"],
                subtopicIDs: [], conceptIDs: [], seededLessonIDs: [])))
            try context.save()
        }
        for _ in 0..<2 {
            let container = try factory.makeContainer(mode: .persistent(url))
            XCTAssertEqual(try SwiftDataAISettingsRepository(container: container).load(), .disabled)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<AISettingsRecord>()).isEmpty)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.id, id)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).first?.status, .started)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).first?.answerDraft,
                           "Keep draft")
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CatalogMembership>()).first?
                .membership().topicIDs, ["go"])
        }
    }

    func testOlderFrozenFixtureMigratesToV7WithoutTouchingSource() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V3", withExtension: nil))
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        let originals = try Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
        for file in files {
            try FileManager.default.copyItem(at: file,
                to: directory.appendingPathComponent(file.lastPathComponent))
        }
        for _ in 0..<2 {
            let container = try factory.makeContainer(mode: .persistent(
                directory.appendingPathComponent("Kontrol.store")))
            XCTAssertEqual(try SwiftDataAISettingsRepository(container: container).load(), .disabled)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.title,
                           "V3 fixture task")
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FocusSession>()).count, 1)
        }
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file), originals[file.lastPathComponent])
        }
    }
}
