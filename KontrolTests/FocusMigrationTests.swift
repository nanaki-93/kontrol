import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()
    private let stamp = Date(timeIntervalSince1970: 1_704_000_000)
    private let later = Date(timeIntervalSince1970: 1_704_003_600)
    private let taskID = UUID(uuidString: "E726846B-F67A-4E64-95FA-CC60A2F56707")!
    private let blockID = UUID(uuidString: "C566F065-CA2B-46B9-B82F-5A694EC3CBB8")!
    private let attemptID = UUID(uuidString: "586058F3-B739-493D-9240-B6AE09F25210")!

    private func directory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolFocusMigration-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func bytes(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return try Dictionary(uniqueKeysWithValues: files.compactMap { file in
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil as (String, Data)?
            }
            return (file.lastPathComponent, try Data(contentsOf: file))
        })
    }

    @discardableResult
    private func copyClosed(_ source: URL, to destination: URL) throws -> [String: Data] {
        let original = try bytes(source)
        XCTAssertEqual(Set(original.keys), ["Kontrol.store", "Kontrol.store-shm", "Kontrol.store-wal"])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in original.keys {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                             to: destination.appendingPathComponent(name))
        }
        XCTAssertEqual(try bytes(destination), original)
        return original
    }

    private func bundled(_ version: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: version, withExtension: nil))
    }

    private func rows<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    private func assertFrozen(_ version: String, _ container: ModelContainer) throws {
        let tasks = try rows(TaskItem.self, in: container)
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        if version == "V1" {
            XCTAssertEqual(task.id, UUID(uuidString: "D07A6D98-65ED-4B59-92B2-DA3CED39F3E5"))
            XCTAssertEqual(task.title, "V1 reopen fixture")
            XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertNil(task.notes)
            XCTAssertNil(task.dueAt)
            XCTAssertTrue(try rows(ScheduleBlock.self, in: container).isEmpty)
        } else {
            XCTAssertEqual(task.id, UUID(uuidString: "6E9D469D-49F7-4D66-9084-2E1AA79E5FF2"))
            XCTAssertEqual(task.title, "V2 fixture task")
            XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 1_710_000_000))
            XCTAssertEqual(task.notes, "Keep for upgrade")
            XCTAssertEqual(task.dueAt, Date(timeIntervalSince1970: 1_710_086_400))
            let blocks = try rows(ScheduleBlock.self, in: container)
            XCTAssertEqual(blocks.count, 1)
            let block = try XCTUnwrap(blocks.first)
            XCTAssertEqual(block.id, UUID(uuidString: "9BA7AB1F-6349-4CDD-AF43-08FE8BA9DB13"))
            XCTAssertEqual(block.title, "V2 fixture block")
            XCTAssertEqual(block.startAt, Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(block.endAt, Date(timeIntervalSince1970: 1_800_005_400))
            XCTAssertEqual(block.note, "Manual plan")
            XCTAssertNil(block.lessonID)
            XCTAssertNil(block.linkedTitleSnapshot)
        }
        XCTAssertNil(task.plannedDay)
        XCTAssertNil(task.plannedTimeZoneID)
        XCTAssertNil(task.completedAt)
        XCTAssertTrue(try rows(FocusSession.self, in: container).isEmpty)
    }

    func testBothFrozenHistoricalVersionsUpgradeAcrossDistinctDiskOpens() throws {
        let sources = try ["V1": bundled("V1"), "V2": bundled("V2")]
        let originals = try sources.mapValues(bytes)
        for version in ["V1", "V2"] {
            let source = try XCTUnwrap(sources[version])
            let copy = directory("frozen-\(version)")
            try copyClosed(source, to: copy)
            let url = copy.appendingPathComponent("Kontrol.store")
            try autoreleasepool { try assertFrozen(version, factory.makeContainer(mode: .persistent(url))) }
            try autoreleasepool { try assertFrozen(version, factory.makeContainer(mode: .persistent(url))) }
            // Opened copies are not unlinked: SwiftData may keep internal SQLite descriptors.
        }
        for (version, source) in sources {
            XCTAssertEqual(try bytes(source), originals[version], "\(version) originals and sidecars must remain frozen")
        }
    }

    func testFrozenV1AndV2AreReadableWithoutMigrationAsTheirOwnVersions() throws {
        for version in ["V1", "V2"] {
            let source = try bundled(version)
            let original = try bytes(source)
            let copy = directory("direct-\(version)")
            try copyClosed(source, to: copy)
            let schema = version == "V1" ? Schema(versionedSchema: KontrolSchemaV1.self)
                                         : Schema(versionedSchema: KontrolSchemaV2.self)
            let config = ModelConfiguration(schema: schema,
                                            url: copy.appendingPathComponent("Kontrol.store"),
                                            cloudKitDatabase: .none)
            try autoreleasepool {
                let container = try ModelContainer(for: schema, configurations: [config])
                let task = try XCTUnwrap(rows(TaskItem.self, in: container).only)
                if version == "V1" {
                    XCTAssertEqual(task.id, UUID(uuidString: "D07A6D98-65ED-4B59-92B2-DA3CED39F3E5"))
                } else {
                    XCTAssertEqual(task.id, UUID(uuidString: "6E9D469D-49F7-4D66-9084-2E1AA79E5FF2"))
                    XCTAssertEqual(try rows(ScheduleBlock.self, in: container).count, 1)
                }
            }
            XCTAssertEqual(try bytes(source), original)
        }
    }

    private func content() -> KontrolSchemaV1.LessonContentSnapshot {
        .init(title: "Archived lesson", objectiveKey: "objective-1", conceptIDs: ["concept-1"],
              difficulty: "beginner", format: "reading", explanation: "Explanation",
              workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
              selfCheckCriteria: ["Check one", "Check two"])
    }

    // Write a historical store using ONLY its released versioned schema; never seed
    // through the production factory. The source is closed before copying/migration.
    private func seed(_ version: String, at url: URL) throws {
        try autoreleasepool {
            let schema = version == "V1" ? Schema(versionedSchema: KontrolSchemaV1.self)
                                         : Schema(versionedSchema: KontrolSchemaV2.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let day = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian",
                                                            year: 2024, month: 2, day: 15)
            context.insert(try TaskItem(id: taskID, title: "Original task", createdAt: stamp,
                                        notes: "Personal notes", dueAt: later, plannedDay: day,
                                        plannedTimeZoneID: "America/New_York", completedAt: later))
            context.insert(Topic(id: "topic-1", name: "Original topic"))
            context.insert(Subtopic(id: "subtopic-1", topicID: "topic-1", name: "Original subtopic"))
            context.insert(Concept(id: "concept-1", subtopicID: "subtopic-1", name: "Original concept",
                                   prerequisiteConceptIDs: ["concept-0"]))
            let snapshot = content()
            context.insert(LessonDefinition(
                id: "lesson-1", objectiveKey: "objective-1", title: snapshot.title,
                topicID: "topic-1", subtopicID: "subtopic-1", conceptIDs: snapshot.conceptIDs,
                difficulty: snapshot.difficulty, format: snapshot.format, estimatedMinutes: 37,
                prerequisiteConceptIDs: ["concept-0"], explanation: snapshot.explanation,
                workedExample: snapshot.workedExample, exercise: snapshot.exercise,
                referenceAnswer: snapshot.referenceAnswer, selfCheckCriteria: snapshot.selfCheckCriteria,
                contentVersion: 7, normalizedContentHash: "sha256:historical",
                source: "bundle", provenance: "V1/V2 test"))
            context.insert(CatalogImportState(catalogID: "catalog-1", lastImportedVersion: 12))
            context.insert(LessonProgress(lessonID: "lesson-1", status: .completed,
                                          firstShownAt: stamp, startedAt: later,
                                          completedAt: later, lastOpenedAt: later))
            context.insert(LessonAttempt(id: attemptID, lessonID: "lesson-1", contentVersion: 7,
                                         answerDraft: "My answer", solutionRevealedAt: stamp,
                                         selfCheckAcknowledgedAt: later, completedAt: later,
                                         completedContentSnapshot: snapshot))
            if version == "V2" {
                context.insert(ScheduleBlock(id: blockID, title: "Historical block",
                                             startAt: stamp, endAt: later, note: "Manual plan",
                                             lessonID: "lesson-1", linkedTitleSnapshot: snapshot.title))
            }
            try context.save()
        }
    }

    private func assertRich(_ container: ModelContainer) throws {
        let task = try XCTUnwrap(rows(TaskItem.self, in: container).only)
        XCTAssertEqual(task.id, taskID)
        XCTAssertEqual(task.title, "Original task")
        XCTAssertEqual(task.notes, "Personal notes")
        XCTAssertEqual(task.createdAt, stamp)
        XCTAssertEqual(task.dueAt, later)
        XCTAssertEqual(task.plannedDay, .init(calendarIdentifier: "gregorian", year: 2024, month: 2, day: 15))
        XCTAssertEqual(task.plannedTimeZoneID, "America/New_York")
        XCTAssertEqual(task.completedAt, later)
        let block = try XCTUnwrap(rows(ScheduleBlock.self, in: container).only)
        XCTAssertEqual(block.id, blockID)
        XCTAssertEqual(block.title, "Historical block")
        XCTAssertEqual(block.startAt, stamp)
        XCTAssertEqual(block.endAt, later)
        XCTAssertEqual(block.note, "Manual plan")
        XCTAssertEqual(block.lessonID, "lesson-1")
        XCTAssertEqual(block.linkedTitleSnapshot, "Archived lesson")
        let topic = try XCTUnwrap(rows(Topic.self, in: container).only)
        XCTAssertEqual(topic.id, "topic-1")
        XCTAssertEqual(topic.name, "Original topic")
        let subtopic = try XCTUnwrap(rows(Subtopic.self, in: container).only)
        XCTAssertEqual(subtopic.id, "subtopic-1")
        XCTAssertEqual(subtopic.topicID, topic.id)
        XCTAssertEqual(subtopic.name, "Original subtopic")
        let concept = try XCTUnwrap(rows(Concept.self, in: container).only)
        XCTAssertEqual(concept.id, "concept-1")
        XCTAssertEqual(concept.subtopicID, subtopic.id)
        XCTAssertEqual(concept.name, "Original concept")
        XCTAssertEqual(concept.prerequisiteConceptIDs, ["concept-0"])
        let lesson = try XCTUnwrap(rows(LessonDefinition.self, in: container).only)
        XCTAssertEqual(lesson.id, "lesson-1")
        XCTAssertEqual(lesson.objectiveKey, "objective-1")
        XCTAssertEqual(lesson.title, content().title)
        XCTAssertEqual(lesson.topicID, topic.id)
        XCTAssertEqual(lesson.subtopicID, subtopic.id)
        XCTAssertEqual(lesson.conceptIDs, content().conceptIDs)
        XCTAssertEqual(lesson.difficulty, content().difficulty)
        XCTAssertEqual(lesson.format, content().format)
        XCTAssertEqual(lesson.estimatedMinutes, 37)
        XCTAssertEqual(lesson.prerequisiteConceptIDs, ["concept-0"])
        XCTAssertEqual(lesson.explanation, content().explanation)
        XCTAssertEqual(lesson.workedExample, content().workedExample)
        XCTAssertEqual(lesson.exercise, content().exercise)
        XCTAssertEqual(lesson.referenceAnswer, content().referenceAnswer)
        XCTAssertEqual(lesson.selfCheckCriteria, content().selfCheckCriteria)
        XCTAssertEqual(lesson.contentVersion, 7)
        XCTAssertEqual(lesson.normalizedContentHash, "sha256:historical")
        XCTAssertEqual(lesson.source, "bundle")
        XCTAssertEqual(lesson.provenance, "V1/V2 test")
        let marker = try XCTUnwrap(rows(CatalogImportState.self, in: container).only)
        XCTAssertEqual(marker.catalogID, "catalog-1")
        XCTAssertEqual(marker.lastImportedVersion, 12)
        let progress = try XCTUnwrap(rows(LessonProgress.self, in: container).only)
        XCTAssertEqual(progress.lessonID, lesson.id)
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.firstShownAt, stamp)
        XCTAssertEqual(progress.startedAt, later)
        XCTAssertEqual(progress.completedAt, later)
        XCTAssertNil(progress.dismissedAt)
        XCTAssertEqual(progress.lastOpenedAt, later)
        let attempt = try XCTUnwrap(rows(LessonAttempt.self, in: container).only)
        XCTAssertEqual(attempt.id, attemptID)
        XCTAssertEqual(attempt.lessonID, lesson.id)
        XCTAssertEqual(attempt.contentVersion, 7)
        XCTAssertEqual(attempt.answerDraft, "My answer")
        XCTAssertEqual(attempt.solutionRevealedAt, stamp)
        XCTAssertEqual(attempt.selfCheckAcknowledgedAt, later)
        XCTAssertEqual(attempt.completedAt, later)
        XCTAssertEqual(attempt.completedContentSnapshot, content())
        XCTAssertTrue(try rows(FocusSession.self, in: container).isEmpty)
    }

    func testRichV1AndV2StoresPreserveEveryEntityOnUpgradeAndReopen() throws {
        for version in ["V1", "V2"] {
            let writer = directory("rich-\(version)-writer")
            let source = directory("rich-\(version)-closed-source")
            let copy = directory("rich-\(version)-copy")
            try seed(version, at: writer.appendingPathComponent("Kontrol.store"))
            // SwiftData may retain the writer's SQLite descriptors after its Swift
            // owners release. Preserve an independent closed snapshot as the
            // historical source, then copy that complete file set for migration.
            try copyClosed(writer, to: source)
            let original = try copyClosed(source, to: copy)
            let url = copy.appendingPathComponent("Kontrol.store")
            try autoreleasepool {
                let container = try factory.makeContainer(mode: .persistent(url))
                if version == "V1" {
                    XCTAssertTrue(try rows(ScheduleBlock.self, in: container).isEmpty)
                    let context = ModelContext(container)
                    context.insert(ScheduleBlock(id: blockID, title: "Historical block",
                                                 startAt: stamp, endAt: later, note: "Manual plan",
                                                 lessonID: "lesson-1", linkedTitleSnapshot: "Archived lesson"))
                    try context.save()
                }
                try assertRich(container)
            }
            try autoreleasepool { try assertRich(factory.makeContainer(mode: .persistent(url))) }
            XCTAssertEqual(try bytes(source), original, "\(version) original including sidecars remains unchanged")
        }
    }

    func testV3FixtureIsDirectlyReadableAsV3AndReopensUnchanged() throws {
        let source = try bundled("V3")
        let original = try bytes(source)
        let copy = directory("frozen-V3")
        try copyClosed(source, to: copy)
        let url = copy.appendingPathComponent("Kontrol.store")
        // No migration plan: independently identify this artifact as a V3 store.
        try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV3.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            try assertV3(ModelContainer(for: schema, configurations: [config]))
        }
        try autoreleasepool { try assertV3(factory.makeContainer(mode: .persistent(url))) }
        XCTAssertEqual(try bytes(source), original)
    }

    private func assertV3(_ container: ModelContainer) throws {
        let task = try XCTUnwrap(rows(TaskItem.self, in: container).only)
        XCTAssertEqual(task.id, UUID(uuidString: "0C8C76A6-085B-47D7-A820-43EA0BDAB311"))
        XCTAssertEqual(task.title, "V3 fixture task")
        XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 1_720_000_000))
        XCTAssertEqual(task.notes, "Retained task")
        XCTAssertEqual(task.dueAt, Date(timeIntervalSince1970: 1_720_086_400))
        XCTAssertNil(task.plannedDay)
        XCTAssertNil(task.plannedTimeZoneID)
        XCTAssertNil(task.completedAt)
        let block = try XCTUnwrap(rows(ScheduleBlock.self, in: container).only)
        XCTAssertEqual(block.id, UUID(uuidString: "88E80A72-F92B-4E9E-A38A-338F54818D9B"))
        XCTAssertEqual(block.title, "V3 fixture block")
        XCTAssertEqual(block.startAt, Date(timeIntervalSince1970: 1_820_000_000))
        XCTAssertEqual(block.endAt, Date(timeIntervalSince1970: 1_820_001_800))
        XCTAssertEqual(block.note, "Manual")
        XCTAssertNil(block.lessonID)
        XCTAssertNil(block.linkedTitleSnapshot)
        let focus = try XCTUnwrap(rows(FocusSession.self, in: container).only)
        XCTAssertEqual(focus.id, UUID(uuidString: "83B6B103-03BA-4CD5-8D54-90E3398F6E00"))
        XCTAssertEqual(focus.state, "ended")
        XCTAssertEqual(focus.plannedSeconds, 1500)
        XCTAssertEqual(focus.accumulatedActiveSeconds, 72.5)
        XCTAssertEqual(focus.startedAt, Date(timeIntervalSince1970: 1_720_000_000))
        XCTAssertEqual(focus.endedAt, Date(timeIntervalSince1970: 1_720_000_073))
        XCTAssertEqual(focus.checkpointAt, focus.endedAt)
        XCTAssertNil(focus.activeSegmentStartedAt)
        XCTAssertNil(focus.deadline)
        XCTAssertNil(focus.pausedAt)
        XCTAssertFalse(focus.recoveryRequired)
        XCTAssertEqual(focus.linkedTaskID, task.id)
        XCTAssertNil(focus.linkedLessonID)
        XCTAssertEqual(focus.linkedTitleSnapshot, task.title)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
