import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class NewsMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolNewsMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func assertNewsAbsent(_ context: ModelContext) throws {
        XCTAssertTrue(try context.fetch(FetchDescriptor<NewsPreferencesRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NewsFeedRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NewsArticleRecord>()).isEmpty)
    }

    func testV8DiskUpgradesPreservingEveryFeatureAndRepeatReopen() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Kontrol.store")
        let taskID = UUID(), blockID = UUID(), focusID = UUID(), attemptID = UUID()
        let projectID = UUID(), settingsRevision = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let bookmark = Data([0, 255, 42])
        try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV8.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.insert(try TaskItem(id: taskID, title: "Existing task", createdAt: when,
                                        notes: "Keep notes", completedAt: when))
            context.insert(ScheduleBlock(id: blockID, title: "Plan", startAt: when,
                                         endAt: when.addingTimeInterval(3600), note: "Keep plan"))
            context.insert(FocusSession(id: focusID, state: "paused", plannedSeconds: 900,
                                        accumulatedActiveSeconds: 23, pausedAt: when,
                                        startedAt: when, checkpointAt: when, linkedTaskID: taskID))
            context.insert(Topic(id: "go", name: "Learning Go"))
            context.insert(LessonDefinition(id: "lesson", objectiveKey: "objective", title: "Lesson",
                topicID: "go", subtopicID: "go.base", conceptIDs: ["concept"], difficulty: "basic",
                format: "learn", estimatedMinutes: 10, explanation: "Existing explanation",
                workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
                selfCheckCriteria: ["Check"], contentVersion: 1, normalizedContentHash: "digest",
                source: "seed", provenance: "catalog"))
            context.insert(LessonProgress(lessonID: "lesson", status: .started, startedAt: when))
            context.insert(LessonAttempt(id: attemptID, lessonID: "lesson", contentVersion: 1,
                                         answerDraft: "Keep draft"))
            context.insert(AISettingsRecord(revision: settingsRevision))
            context.insert(ProjectReference(id: projectID, manifestID: "project", bookmarkData: bookmark,
                                            displayOrder: 2, displayNameHint: "Project", revision: UUID()))
            try context.save()
        }
        for _ in 0..<2 {
            try autoreleasepool {
                let context = ModelContext(try factory.makeContainer(mode: .persistent(url)))
                XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).first?.id, taskID)
                XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).first?.notes, "Keep notes")
                XCTAssertEqual(try context.fetch(FetchDescriptor<ScheduleBlock>()).first?.id, blockID)
                XCTAssertEqual(try context.fetch(FetchDescriptor<ScheduleBlock>()).first?.note, "Keep plan")
                XCTAssertEqual(try context.fetch(FetchDescriptor<FocusSession>()).first?.id, focusID)
                XCTAssertEqual(try context.fetch(FetchDescriptor<FocusSession>()).first?.linkedTaskID, taskID)
                XCTAssertEqual(try context.fetch(FetchDescriptor<Topic>()).first?.name, "Learning Go")
                XCTAssertEqual(try context.fetch(FetchDescriptor<LessonDefinition>()).first?.explanation,
                               "Existing explanation")
                XCTAssertEqual(try context.fetch(FetchDescriptor<LessonProgress>()).first?.startedAt, when)
                XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>()).first?.id, attemptID)
                XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>()).first?.answerDraft, "Keep draft")
                XCTAssertEqual(try context.fetch(FetchDescriptor<AISettingsRecord>()).first?.revision,
                               settingsRevision)
                XCTAssertEqual(try context.fetch(FetchDescriptor<ProjectReference>()).first?.id, projectID)
                XCTAssertEqual(try context.fetch(FetchDescriptor<ProjectReference>()).first?.bookmarkData,
                               bookmark)
                try assertNewsAbsent(context)
            }
        }
    }

    func testCopiedFrozenV1FixtureUpgradesThroughV9WithoutChangingOriginal() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V1", withExtension: nil))
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        let original = try Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
        XCTAssertNotNil(original["Kontrol.store"])
        for file in files {
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        for _ in 0..<2 {
            try autoreleasepool {
                let context = ModelContext(try factory.makeContainer(mode: .persistent(
                    folder.appendingPathComponent("Kontrol.store"))))
                XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).first?.title,
                               "V1 reopen fixture")
                try assertNewsAbsent(context)
            }
        }
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file), original[file.lastPathComponent])
        }
    }

    func testFailedOpenPreservesExistingStoreBytesAndDoesNotCreateEmptyNews() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Kontrol.store")
        let bytes = Data("corrupt SQLite; do not reset user data".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try factory.makeContainer(mode: .persistent(url)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertThrowsError(try factory.makeContainer(mode: .persistent(url)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
