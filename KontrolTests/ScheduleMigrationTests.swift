import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class ScheduleMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()
    private let historicalID = UUID(uuidString: "D07A6D98-65ED-4B59-92B2-DA3CED39F3E5")!
    private let blockID = UUID(uuidString: "7B64320A-734A-4FFB-B42E-5E2527DD834B")!
    private let v2TaskID = UUID(uuidString: "6E9D469D-49F7-4D66-9084-2E1AA79E5FF2")!
    private let v2BlockID = UUID(uuidString: "9BA7AB1F-6349-4CDD-AF43-08FE8BA9DB13")!

    private func files(at directory: URL) throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return try Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil as (String, Data)?
            }
            return (url.lastPathComponent, try Data(contentsOf: url))
        })
    }

    private func uniqueDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolMigration-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func copyClosedStore(from source: URL, to destination: URL) throws -> [String: Data] {
        let originals = try files(at: source)
        XCTAssertTrue(originals.keys.contains("Kontrol.store"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in originals.keys {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                             to: destination.appendingPathComponent(name))
        }
        XCTAssertEqual(try files(at: destination), originals)
        return originals
    }

    private func assertUnchanged(_ original: [String: Data], at source: URL) throws {
        // Dictionary equality checks both the complete filename set and every byte,
        // including the WAL and SHM, not merely the SQLite main file.
        XCTAssertEqual(try files(at: source), original)
    }

    private func records<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    private func assertBlock(_ container: ModelContainer) throws {
        let blocks = try records(ScheduleBlock.self, in: container)
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.id, blockID)
        XCTAssertEqual(block.title, "V2 manual block")
        XCTAssertEqual(block.startAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(block.endAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(block.note, "After migration")
        XCTAssertNil(block.lessonID)
        XCTAssertNil(block.linkedTitleSnapshot)
    }

    private func insertBlock(_ container: ModelContainer) throws {
        XCTAssertTrue(try records(ScheduleBlock.self, in: container).isEmpty)
        let context = ModelContext(container)
        context.insert(ScheduleBlock(id: blockID, title: "V2 manual block",
                                     startAt: Date(timeIntervalSince1970: 1_800_000_000),
                                     endAt: Date(timeIntervalSince1970: 1_800_003_600),
                                     note: "After migration"))
        try context.save()
    }

    private func assertHistoricalTask(_ container: ModelContainer) throws {
        let tasks = try records(TaskItem.self, in: container)
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.id, historicalID)
        XCTAssertEqual(task.title, "V1 reopen fixture")
        XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(task.notes)
        XCTAssertNil(task.dueAt)
        XCTAssertNil(task.plannedDay)
        XCTAssertNil(task.plannedTimeZoneID)
        XCTAssertNil(task.completedAt)
    }

    func testFrozenV2CopyReopensTwiceWithoutChangingEitherFixtureVersion() throws {
        let bundle = Bundle(for: Self.self)
        let v1 = try XCTUnwrap(bundle.url(forResource: "V1", withExtension: nil))
        let v2 = try XCTUnwrap(bundle.url(forResource: "V2", withExtension: nil))
        let v1Original = try files(at: v1)
        XCTAssertEqual(Set(v1Original.keys), ["Kontrol.store", "Kontrol.store-shm", "Kontrol.store-wal"])
        let copy = uniqueDirectory("v2-frozen")
        let v2Original = try copyClosedStore(from: v2, to: copy)
        XCTAssertEqual(Set(v2Original.keys), ["Kontrol.store", "Kontrol.store-shm", "Kontrol.store-wal"])
        let url = copy.appendingPathComponent("Kontrol.store")
        func assertV2Values(_ container: ModelContainer) throws {
            let tasks = try records(TaskItem.self, in: container)
            XCTAssertEqual(tasks.count, 1)
            let task = try XCTUnwrap(tasks.first)
            XCTAssertEqual(task.id, v2TaskID)
            XCTAssertEqual(task.title, "V2 fixture task")
            XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 1_710_000_000))
            XCTAssertEqual(task.notes, "Keep for upgrade")
            XCTAssertEqual(task.dueAt, Date(timeIntervalSince1970: 1_710_086_400))
            XCTAssertNil(task.plannedDay)
            XCTAssertNil(task.plannedTimeZoneID)
            XCTAssertNil(task.completedAt)
            let blocks = try records(ScheduleBlock.self, in: container)
            XCTAssertEqual(blocks.count, 1)
            let block = try XCTUnwrap(blocks.first)
            XCTAssertEqual(block.id, v2BlockID)
            XCTAssertEqual(block.title, "V2 fixture block")
            XCTAssertEqual(block.startAt, Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(block.endAt, Date(timeIntervalSince1970: 1_800_005_400))
            XCTAssertEqual(block.note, "Manual plan")
            XCTAssertNil(block.lessonID)
            XCTAssertNil(block.linkedTitleSnapshot)
        }
        try autoreleasepool {
            try assertV2Values(factory.makeContainer(mode: .persistent(url)))
        }
        try autoreleasepool {
            try assertV2Values(factory.makeContainer(mode: .persistent(url)))
        }
        try assertUnchanged(v2Original, at: v2)
        try assertUnchanged(v1Original, at: v1)
        // Keep the opened UUID-isolated copy until the host exits; SwiftData can
        // retain internal SQLite descriptors after these explicit owners release.
    }

    func testFrozenV1CopyMigratesAddsBlockAndReopensWithoutChangingBundle() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V1", withExtension: nil))
        let copy = uniqueDirectory("frozen")
        let original = try copyClosedStore(from: fixture, to: copy)
        XCTAssertEqual(Set(original.keys), ["Kontrol.store", "Kontrol.store-shm", "Kontrol.store-wal"])
        let url = copy.appendingPathComponent("Kontrol.store")
        // Explicit scopes release app-owned contexts and containers between disk opens.
        try autoreleasepool {
            let container = try factory.makeContainer(mode: .persistent(url))
            try assertHistoricalTask(container)
            try insertBlock(container)
            try assertHistoricalTask(container)
            try assertBlock(container)
        }
        try autoreleasepool {
            let reopened = try factory.makeContainer(mode: .persistent(url))
            try assertHistoricalTask(reopened)
            try assertBlock(reopened)
        }
        try assertUnchanged(original, at: fixture)
        // SwiftData may retain SQLite descriptors in the test host; never unlink an
        // opened copy while the host is alive. The UUID-isolated temp copy is disposable.
    }

    func testRichV1StoreMigratesEveryEntityAndReopensAfterV2Write() throws {
        let writer = uniqueDirectory("v1-writer")
        let source = uniqueDirectory("v1-closed-source")
        let copy = uniqueDirectory("v1-copy")
        let sourceURL = writer.appendingPathComponent("Kontrol.store")
        let stamp = Date(timeIntervalSince1970: 1_704_000_000)
        let later = Date(timeIntervalSince1970: 1_704_003_600)
        let taskID = UUID(uuidString: "0E67C839-A6F6-4D30-9C97-68105604D6A0")!
        let attemptID = UUID(uuidString: "A214608B-97BC-4218-9CD4-3B81045D8DBA")!
        let day = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian",
                                                         year: 2024, month: 2, day: 15)
        let content = KontrolSchemaV1.LessonContentSnapshot(
            title: "Archived lesson", objectiveKey: "objective-1", conceptIDs: ["concept-1"],
            difficulty: "beginner", format: "reading", explanation: "Explanation",
            workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
            selfCheckCriteria: ["Check one", "Check two"])
        // Construct the released V1 schema directly; the production factory is V2
        // and must never be used to seed this fixture.
        try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV1.self)
            let config = ModelConfiguration(schema: schema, url: sourceURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.insert(Topic(id: "topic-1", name: "Original topic"))
            context.insert(Subtopic(id: "subtopic-1", topicID: "topic-1", name: "Original subtopic"))
            context.insert(Concept(id: "concept-1", subtopicID: "subtopic-1", name: "Original concept",
                                   prerequisiteConceptIDs: ["concept-0"]))
            context.insert(LessonDefinition(
                id: "lesson-1", objectiveKey: "objective-1", title: "Archived lesson",
                topicID: "topic-1", subtopicID: "subtopic-1", conceptIDs: ["concept-1"],
                difficulty: "beginner", format: "reading", estimatedMinutes: 37,
                prerequisiteConceptIDs: ["concept-0"], explanation: "Explanation",
                workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
                selfCheckCriteria: ["Check one", "Check two"], contentVersion: 7,
                normalizedContentHash: "sha256:historical", source: "bundle", provenance: "V1 test"))
            context.insert(CatalogImportState(catalogID: "catalog-1", lastImportedVersion: 12))
            context.insert(LessonProgress(lessonID: "lesson-1", status: .completed,
                                          firstShownAt: stamp, startedAt: later,
                                          completedAt: later, dismissedAt: nil, lastOpenedAt: later))
            context.insert(KontrolSchemaV1.LessonAttempt(id: attemptID, lessonID: "lesson-1", contentVersion: 7,
                                         answerDraft: "My answer", solutionRevealedAt: stamp,
                                         selfCheckAcknowledgedAt: later, completedAt: later,
                                         completedContentSnapshot: content))
            context.insert(try TaskItem(id: taskID, title: "Original task", createdAt: stamp,
                                        notes: "Personal notes", dueAt: later, plannedDay: day,
                                        plannedTimeZoneID: "America/New_York", completedAt: later))
            try context.save()
        }
        // Releasing the explicit owners does not close SwiftData's internal WAL
        // descriptors. Snapshot transactionally before the byte-copy/immutability
        // boundary, using the same lock-tested helper as Focus migration.
        try FocusMigrationTests.snapshotSeed(at: writer, to: source)
        let original = try copyClosedStore(from: source, to: copy)
        let url = copy.appendingPathComponent("Kontrol.store")
        func assertV1Values(_ container: ModelContainer) throws {
            let topics = try records(Topic.self, in: container)
            XCTAssertEqual(topics.count, 1)
            XCTAssertEqual(topics.first?.id, "topic-1")
            XCTAssertEqual(topics.first?.name, "Original topic")
            let subtopics = try records(Subtopic.self, in: container)
            XCTAssertEqual(subtopics.count, 1)
            XCTAssertEqual(subtopics.first?.id, "subtopic-1")
            XCTAssertEqual(subtopics.first?.topicID, "topic-1")
            XCTAssertEqual(subtopics.first?.name, "Original subtopic")
            let concepts = try records(Concept.self, in: container)
            XCTAssertEqual(concepts.count, 1)
            XCTAssertEqual(concepts.first?.id, "concept-1")
            XCTAssertEqual(concepts.first?.subtopicID, "subtopic-1")
            XCTAssertEqual(concepts.first?.name, "Original concept")
            XCTAssertEqual(concepts.first?.prerequisiteConceptIDs, ["concept-0"])
            let lessons = try records(LessonDefinition.self, in: container)
            XCTAssertEqual(lessons.count, 1)
            let lesson = try XCTUnwrap(lessons.first)
            XCTAssertEqual(lesson.id, "lesson-1")
            XCTAssertEqual(lesson.objectiveKey, "objective-1")
            XCTAssertEqual(lesson.title, content.title)
            XCTAssertEqual(lesson.topicID, "topic-1")
            XCTAssertEqual(lesson.subtopicID, "subtopic-1")
            XCTAssertEqual(lesson.conceptIDs, content.conceptIDs)
            XCTAssertEqual(lesson.difficulty, content.difficulty)
            XCTAssertEqual(lesson.format, content.format)
            XCTAssertEqual(lesson.estimatedMinutes, 37)
            XCTAssertEqual(lesson.prerequisiteConceptIDs, ["concept-0"])
            XCTAssertEqual(lesson.explanation, content.explanation)
            XCTAssertEqual(lesson.workedExample, content.workedExample)
            XCTAssertEqual(lesson.exercise, content.exercise)
            XCTAssertEqual(lesson.referenceAnswer, content.referenceAnswer)
            XCTAssertEqual(lesson.selfCheckCriteria, content.selfCheckCriteria)
            XCTAssertEqual(lesson.contentVersion, 7)
            XCTAssertEqual(lesson.normalizedContentHash, "sha256:historical")
            XCTAssertEqual(lesson.source, "bundle")
            XCTAssertEqual(lesson.provenance, "V1 test")
            let imports = try records(CatalogImportState.self, in: container)
            XCTAssertEqual(imports.count, 1)
            XCTAssertEqual(imports.first?.catalogID, "catalog-1")
            XCTAssertEqual(imports.first?.lastImportedVersion, 12)
            let progress = try records(LessonProgress.self, in: container)
            XCTAssertEqual(progress.count, 1)
            XCTAssertEqual(progress.first?.lessonID, "lesson-1")
            XCTAssertEqual(progress.first?.status, .completed)
            XCTAssertEqual(progress.first?.firstShownAt, stamp)
            XCTAssertEqual(progress.first?.startedAt, later)
            XCTAssertEqual(progress.first?.completedAt, later)
            XCTAssertNil(progress.first?.dismissedAt)
            XCTAssertEqual(progress.first?.lastOpenedAt, later)
            let attempts = try records(LessonAttempt.self, in: container)
            XCTAssertEqual(attempts.count, 1)
            let attempt = try XCTUnwrap(attempts.first)
            XCTAssertEqual(attempt.id, attemptID)
            XCTAssertEqual(attempt.lessonID, "lesson-1")
            XCTAssertEqual(attempt.contentVersion, 7)
            XCTAssertEqual(attempt.answerDraft, "My answer")
            XCTAssertEqual(attempt.solutionRevealedAt, stamp)
            XCTAssertEqual(attempt.selfCheckAcknowledgedAt, later)
            XCTAssertEqual(attempt.completedAt, later)
            XCTAssertEqual(attempt.completedContentSnapshot, content)
            let tasks = try records(TaskItem.self, in: container)
            XCTAssertEqual(tasks.count, 1)
            let task = try XCTUnwrap(tasks.first)
            XCTAssertEqual(task.id, taskID)
            XCTAssertEqual(task.title, "Original task")
            XCTAssertEqual(task.notes, "Personal notes")
            XCTAssertEqual(task.dueAt, later)
            XCTAssertEqual(task.plannedDay, day)
            XCTAssertEqual(task.plannedTimeZoneID, "America/New_York")
            XCTAssertEqual(task.createdAt, stamp)
            XCTAssertEqual(task.completedAt, later)
        }
        try autoreleasepool {
            let container = try factory.makeContainer(mode: .persistent(url))
            try assertV1Values(container)
            try insertBlock(container)
        }
        try autoreleasepool {
            let container = try factory.makeContainer(mode: .persistent(url))
            try assertV1Values(container)
            try assertBlock(container)
        }
        try assertUnchanged(original, at: source)
    }

    func testFailedOpenOfV1CopyUsesNonDestructiveLaunchRecovery() async throws {
        enum Injected: Error { case open }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V1", withExtension: nil))
        let copy = uniqueDirectory("recovery")
        let sourceBytes = try copyClosedStore(from: fixture, to: copy)
        let before = try files(at: copy)
        let url = copy.appendingPathComponent("Kontrol.store")
        var attempts = 0
        let coordinator = LaunchCoordinator(open: {
            attempts += 1
            if attempts == 1 { throw Injected.open }
            return try self.factory.makeContainer(mode: .persistent(url))
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.store))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try files(at: copy), before, "Failure cannot reset any V1 file or sidecar")
        await coordinator.start()
        XCTAssertEqual(attempts, 1, "Recovery requires an explicit retry")
        XCTAssertEqual(try files(at: copy), before)
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(attempts, 2)
        let container = try XCTUnwrap(coordinator.dependencies?.container)
        try assertHistoricalTask(container)
        try assertUnchanged(sourceBytes, at: fixture)
    }
}
