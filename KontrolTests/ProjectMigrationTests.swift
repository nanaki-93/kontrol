import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class ProjectMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolProjectMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testFreshV8ReferenceReopensWithOnlyLocalAuthorizationFields() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Kontrol.store")
        let id = UUID()
        let revision = UUID()
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)
        let bookmark = Data([0, 1, 255, 42])
        try autoreleasepool {
            let container = try factory.makeContainer(mode: .persistent(url))
            let context = ModelContext(container)
            XCTAssertTrue(try context.fetch(FetchDescriptor<ProjectReference>()).isEmpty)
            context.insert(ProjectReference(id: id, manifestID: "project.identity", bookmarkData: bookmark,
                                            displayOrder: 3, displayNameHint: "Last known name",
                                            lastSuccessfulReadAt: readAt, revision: revision))
            try context.save()
        }
        let container = try factory.makeContainer(mode: .persistent(url))
        let row = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<ProjectReference>()).first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.manifestID, "project.identity")
        XCTAssertEqual(row.bookmarkData, bookmark)
        XCTAssertEqual(row.displayOrder, 3)
        XCTAssertEqual(row.displayNameHint, "Last known name")
        XCTAssertEqual(row.lastSuccessfulReadAt, readAt)
        XCTAssertEqual(row.revision, revision)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ProjectReference>()).count, 1)
    }

    func testV7DiskUpgradesToV8WithoutChangingPersonalRecords() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Kontrol.store")
        let taskID = UUID()
        let settingsRevision = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV7.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.insert(try TaskItem(id: taskID, title: "Existing task", createdAt: Date(timeIntervalSince1970: 1)))
            context.insert(LessonProgress(lessonID: "existing", status: .completed,
                                          completedAt: Date(timeIntervalSince1970: 2)))
            context.insert(LessonAttempt(id: UUID(), lessonID: "existing", contentVersion: 1,
                                         answerDraft: "Keep my answer"))
            context.insert(AISettingsRecord(revision: settingsRevision))
            try context.save()
        }
        for _ in 0..<2 {
            try autoreleasepool {
                let container = try factory.makeContainer(mode: .persistent(url))
                let context = ModelContext(container)
                XCTAssertTrue(try context.fetch(FetchDescriptor<ProjectReference>()).isEmpty)
                XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).first?.id, taskID)
                XCTAssertEqual(try context.fetch(FetchDescriptor<LessonProgress>()).first?.status, .completed)
                XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>()).first?.answerDraft,
                               "Keep my answer")
                XCTAssertEqual(try context.fetch(FetchDescriptor<AISettingsRecord>()).first?.revision,
                               settingsRevision)
            }
        }
    }

    func testFrozenV1CopyUpgradesThroughAllStagesWithoutTouchingFixture() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V1", withExtension: nil))
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        let originals = try Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
        for file in files {
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        for _ in 0..<2 {
            try autoreleasepool {
                let container = try factory.makeContainer(mode: .persistent(
                    folder.appendingPathComponent("Kontrol.store")))
                let context = ModelContext(container)
                XCTAssertTrue(try context.fetch(FetchDescriptor<ProjectReference>()).isEmpty)
                XCTAssertFalse(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
            }
        }
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file), originals[file.lastPathComponent])
        }
    }
}
