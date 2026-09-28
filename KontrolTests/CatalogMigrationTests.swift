import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class CatalogMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()
    private let start = Date(timeIntervalSince1970: 1_725_000_000)
    private let later = Date(timeIntervalSince1970: 1_725_003_600)
    private let taskID = UUID(uuidString: "746704AB-985C-42C1-9EB0-013319E391B4")!
    private let blockID = UUID(uuidString: "6D257154-1BD9-488B-BCB7-EB719A07D58E")!
    private let focusID = UUID(uuidString: "9C5098B6-1543-460E-A66F-077883E0EF14")!
    private let draftID = UUID(uuidString: "2DE88D2D-0B0D-4A17-8327-B155FCE78D6D")!
    private let completedID = UUID(uuidString: "B274344F-D863-486D-861E-2642642DB204")!

    private func directory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolCatalogMigration-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func bytes(at directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isRegularFileKey])
        return try Dictionary(uniqueKeysWithValues: files.compactMap { file in
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil as (String, Data)?
            }
            return (file.lastPathComponent, try Data(contentsOf: file))
        })
    }

    @discardableResult
    private func copyClosed(_ source: URL, to destination: URL) throws -> [String: Data] {
        let original = try bytes(at: source)
        XCTAssertTrue(original.keys.contains("Kontrol.store"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in original.keys {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                             to: destination.appendingPathComponent(name))
        }
        XCTAssertEqual(try bytes(at: destination), original)
        return original
    }

    private func rows<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    private func assertFrozen(_ version: String, in container: ModelContainer) throws {
        let tasks = try rows(TaskItem.self, in: container)
        XCTAssertEqual(tasks.count, version == "V4" ? 0 : 1)
        if let task = tasks.first {
            let ids = ["V1": "D07A6D98-65ED-4B59-92B2-DA3CED39F3E5",
                       "V2": "6E9D469D-49F7-4D66-9084-2E1AA79E5FF2",
                       "V3": "0C8C76A6-085B-47D7-A820-43EA0BDAB311"]
            XCTAssertEqual(task.id, UUID(uuidString: try XCTUnwrap(ids[version])))
            XCTAssertEqual(task.title, "\(version) \(version == "V1" ? "reopen fixture" : "fixture task")")
            XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970:
                version == "V1" ? 1_700_000_000 : version == "V2" ? 1_710_000_000 : 1_720_000_000))
            XCTAssertEqual(task.notes, version == "V1" ? nil : version == "V2" ? "Keep for upgrade" : "Retained task")
            XCTAssertEqual(task.dueAt, version == "V1" ? nil : Date(timeIntervalSince1970:
                version == "V2" ? 1_710_086_400 : 1_720_086_400))
            XCTAssertNil(task.plannedDay)
            XCTAssertNil(task.plannedTimeZoneID)
            XCTAssertNil(task.completedAt)
        }
        let blocks = try rows(ScheduleBlock.self, in: container)
        XCTAssertEqual(blocks.count, version == "V2" || version == "V3" ? 1 : 0)
        if let block = blocks.first {
            XCTAssertEqual(block.id, UUID(uuidString: version == "V2"
                ? "9BA7AB1F-6349-4CDD-AF43-08FE8BA9DB13" : "88E80A72-F92B-4E9E-A38A-338F54818D9B"))
            XCTAssertEqual(block.title, version == "V2" ? "V2 fixture block" : "V3 fixture block")
            XCTAssertEqual(block.startAt, Date(timeIntervalSince1970: version == "V2" ? 1_800_000_000 : 1_820_000_000))
            XCTAssertEqual(block.endAt, Date(timeIntervalSince1970: version == "V2" ? 1_800_005_400 : 1_820_001_800))
            XCTAssertEqual(block.note, version == "V2" ? "Manual plan" : "Manual")
            XCTAssertNil(block.lessonID)
            XCTAssertNil(block.linkedTitleSnapshot)
        }
        let focuses = try rows(FocusSession.self, in: container)
        XCTAssertEqual(focuses.count, version == "V3" ? 1 : 0)
        if let focus = focuses.first {
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
            XCTAssertEqual(focus.linkedTaskID, tasks.first?.id)
            XCTAssertNil(focus.linkedLessonID)
            XCTAssertEqual(focus.linkedTitleSnapshot, "V3 fixture task")
        }
        XCTAssertTrue(try rows(LessonProgress.self, in: container).isEmpty,
                      "A schema migration alone must not create personal progress")
        XCTAssertTrue(try rows(LessonAttempt.self, in: container).isEmpty)
        let definitions = try rows(LessonDefinition.self, in: container)
        let markers = try rows(CatalogImportState.self, in: container)
        let slots = try rows(LessonSlot.self, in: container)
        if version == "V4" {
            XCTAssertEqual(definitions.count, 1)
            let definition = try XCTUnwrap(definitions.first)
            XCTAssertEqual(definition.id, "v4-lesson")
            XCTAssertEqual(definition.objectiveKey, "v4-objective")
            XCTAssertEqual(definition.objective, "Explain frozen V4 persistence")
            XCTAssertEqual(definition.title, "Frozen V4 lesson")
            XCTAssertEqual(definition.topicID, "v4-topic")
            XCTAssertEqual(definition.subtopicID, "v4-subtopic")
            XCTAssertEqual(definition.conceptIDs, ["v4-concept"])
            XCTAssertEqual(definition.contentVersion, 2)
            XCTAssertEqual(definition.normalizedContentHash, "sha256:frozen-v4")
            XCTAssertEqual(try rows(Topic.self, in: container).map(\.name), ["Frozen V4 topic"])
            XCTAssertEqual(try rows(Subtopic.self, in: container).map(\.name), ["Frozen V4 subtopic"])
            XCTAssertEqual(try rows(Concept.self, in: container).map(\.name), ["Frozen V4 concept"])
            XCTAssertEqual(markers.map(\.catalogID), ["v4-catalog"])
            XCTAssertEqual(markers.map(\.lastImportedVersion), [23])
            XCTAssertEqual(slots.count, 1)
            XCTAssertEqual(slots.first?.topicID, "v4-topic")
            XCTAssertEqual(slots.first?.slotIndex, 2)
            XCTAssertEqual(slots.first?.key, LessonSlot.canonicalKey(topicID: "v4-topic", slotIndex: 2))
            XCTAssertEqual(slots.first?.lessonID, "v4-lesson")
            XCTAssertEqual(slots.first?.assignedAt, Date(timeIntervalSince1970: 1_730_000_000))
        } else {
            XCTAssertTrue(definitions.isEmpty)
            XCTAssertTrue(markers.isEmpty, "Schema migration must not import a catalog")
            XCTAssertTrue(slots.isEmpty)
        }
    }

    func testFrozenV1ThroughV4CopiesMigrateAndReopenWithoutChangingAnyOriginal() throws {
        let sources = try Dictionary(uniqueKeysWithValues: ["V1", "V2", "V3", "V4"].map {
            ($0, try XCTUnwrap(Bundle(for: Self.self).url(forResource: $0, withExtension: nil)))
        })
        let originals = try sources.mapValues { try bytes(at: $0) }
        for version in ["V1", "V2", "V3", "V4"] {
            let source = try XCTUnwrap(sources[version])
            XCTAssertEqual(Set(try XCTUnwrap(originals[version]).keys),
                           ["Kontrol.store", "Kontrol.store-shm", "Kontrol.store-wal"])
            let copy = directory("frozen-\(version)")
            try copyClosed(source, to: copy)
            let url = copy.appendingPathComponent("Kontrol.store")
            try autoreleasepool { try assertFrozen(version, in: factory.makeContainer(mode: .persistent(url))) }
            try autoreleasepool { try assertFrozen(version, in: factory.makeContainer(mode: .persistent(url))) }
            // Do not unlink opened copies: SwiftData can retain SQLite handles after owner release.
        }
        for (version, source) in sources {
            XCTAssertEqual(try bytes(at: source), originals[version], "Frozen \(version) bytes changed")
        }
    }

    func testFrozenV4IsDirectlyIdentifiableAsV4WithoutMigration() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V4", withExtension: nil))
        let copy = directory("direct-v4")
        let original = try copyClosed(source, to: copy)
        let schema = Schema(versionedSchema: KontrolSchemaV4.self)
        let config = ModelConfiguration(schema: schema,
            url: copy.appendingPathComponent("Kontrol.store"), cloudKitDatabase: .none)
        try autoreleasepool {
            try assertFrozen("V4", in: ModelContainer(for: schema, configurations: [config]))
        }
        XCTAssertEqual(try bytes(at: source), original)
    }

    private func snapshot() -> KontrolSchemaV1.LessonContentSnapshot {
        .init(title: "Original completed lesson", objectiveKey: "completed-objective",
              conceptIDs: ["concept"], difficulty: "basic", format: "code",
              explanation: "Original explanation", workedExample: "Original example",
              exercise: "Original exercise", referenceAnswer: "Original answer",
              selfCheckCriteria: ["Original rubric", "Second criterion"])
    }

    // Seed ONLY the released V3 schema, with no migration plan or V4 type.
    private func seedV3(at url: URL) throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV3.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.insert(Topic(id: "topic", name: "Historical topic"))
            context.insert(Subtopic(id: "subtopic", topicID: "topic", name: "Historical subtopic"))
            context.insert(Concept(id: "concept", subtopicID: "subtopic", name: "Historical concept",
                                   prerequisiteConceptIDs: ["earlier-concept"]))
            for status in ["available", "started", "completed", "dismissed"] {
                context.insert(KontrolSchemaV1.LessonDefinition(
                    id: status, objectiveKey: "\(status)-objective", title: "\(status) title",
                    topicID: "topic", subtopicID: "subtopic", conceptIDs: ["concept"],
                    difficulty: "basic", format: "code", estimatedMinutes: 27,
                    prerequisiteConceptIDs: ["earlier-concept"], explanation: "Old explanation",
                    workedExample: "Old example", exercise: "Old exercise",
                    referenceAnswer: "Old answer", selfCheckCriteria: ["Old rubric"],
                    contentVersion: 7, normalizedContentHash: "sha256:historical-\(status)",
                    source: "seed", provenance: "V3-only source"))
            }
            context.insert(CatalogImportState(catalogID: "historical", lastImportedVersion: 17))
            context.insert(LessonProgress(lessonID: "available", status: .available,
                                          firstShownAt: start, lastOpenedAt: later))
            context.insert(LessonProgress(lessonID: "started", status: .started,
                                          firstShownAt: start, startedAt: later, lastOpenedAt: later))
            context.insert(LessonProgress(lessonID: "completed", status: .completed,
                                          firstShownAt: start, startedAt: start,
                                          completedAt: later, lastOpenedAt: later))
            context.insert(LessonProgress(lessonID: "dismissed", status: .dismissed,
                                          firstShownAt: start, dismissedAt: later, lastOpenedAt: later))
            context.insert(KontrolSchemaV1.LessonAttempt(id: draftID, lessonID: "started", contentVersion: 7,
                                         answerDraft: "Unsent personal draft"))
            context.insert(KontrolSchemaV1.LessonAttempt(id: completedID, lessonID: "completed", contentVersion: 6,
                                         answerDraft: "Archived personal answer", solutionRevealedAt: start,
                                         selfCheckAcknowledgedAt: later, completedAt: later,
                                         completedContentSnapshot: snapshot()))
            let day = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian",
                                                            year: 2024, month: 8, day: 30)
            context.insert(try TaskItem(id: taskID, title: "Personal V3 task", createdAt: start,
                                        notes: "Do not discard", dueAt: later, plannedDay: day,
                                        plannedTimeZoneID: "Pacific/Auckland", completedAt: later))
            context.insert(ScheduleBlock(id: blockID, title: "Personal schedule", startAt: start,
                                         endAt: later, note: "Keep schedule note", lessonID: "started",
                                         linkedTitleSnapshot: "started title"))
            context.insert(FocusSession(id: focusID, state: "ended", plannedSeconds: 1500,
                                        accumulatedActiveSeconds: 74.5, startedAt: start,
                                        endedAt: later, checkpointAt: later, linkedTaskID: taskID,
                                        linkedLessonID: "started", linkedTitleSnapshot: "started title"))
            try context.save()
        }
    }

    // SQLite backup gives a closed transactionally consistent source even when SwiftData
    // retains the writer's WAL handle beyond the lifetime of the Swift container.
    private func snapshotClosedWriter(_ writer: URL, to source: URL) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        var input: OpaquePointer?
        var output: OpaquePointer?
        guard sqlite3_open_v2(writer.appendingPathComponent("Kontrol.store").path,
                              &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let input { sqlite3_close(input) }
            throw NSError(domain: "CatalogMigrationFixture", code: 1)
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(source.appendingPathComponent("Kontrol.store").path,
                              &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let output { sqlite3_close(output) }
            throw NSError(domain: "CatalogMigrationFixture", code: 2)
        }
        defer { sqlite3_close(output) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw NSError(domain: "CatalogMigrationFixture", code: 3)
        }
        // A released SwiftData container may still be checkpointing its WAL.
        // Retry transient SQLite writer locks rather than treating a busy backup as corrupt.
        var result: Int32 = SQLITE_BUSY
        for _ in 0..<100 {
            result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_BUSY || result == SQLITE_LOCKED || result == SQLITE_OK else { break }
            sqlite3_sleep(10)
        }
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw NSError(domain: "CatalogMigrationFixture", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "SQLite backup did not finish (\(result), \(finish))"])
        }
    }

    private func assertRichV3(_ container: ModelContainer) throws {
        XCTAssertEqual(try rows(Topic.self, in: container).map(\.name), ["Historical topic"])
        XCTAssertEqual(try rows(Subtopic.self, in: container).first?.topicID, "topic")
        XCTAssertEqual(try rows(Concept.self, in: container).first?.prerequisiteConceptIDs,
                       ["earlier-concept"])
        let definitions = try rows(LessonDefinition.self, in: container)
        XCTAssertEqual(definitions.count, 4)
        for status in ["available", "started", "completed", "dismissed"] {
            let definition = try XCTUnwrap(definitions.first { $0.id == status })
            XCTAssertEqual(definition.objective, "", "Migrated V3 objectives must use the V4 fallback")
            XCTAssertEqual(definition.objectiveKey, "\(status)-objective")
            XCTAssertEqual(definition.title, "\(status) title")
            XCTAssertEqual(definition.topicID, "topic")
            XCTAssertEqual(definition.subtopicID, "subtopic")
            XCTAssertEqual(definition.conceptIDs, ["concept"])
            XCTAssertEqual(definition.difficulty, "basic")
            XCTAssertEqual(definition.format, "code")
            XCTAssertEqual(definition.estimatedMinutes, 27)
            XCTAssertEqual(definition.prerequisiteConceptIDs, ["earlier-concept"])
            XCTAssertEqual(definition.explanation, "Old explanation")
            XCTAssertEqual(definition.workedExample, "Old example")
            XCTAssertEqual(definition.exercise, "Old exercise")
            XCTAssertEqual(definition.referenceAnswer, "Old answer")
            XCTAssertEqual(definition.selfCheckCriteria, ["Old rubric"])
            XCTAssertEqual(definition.contentVersion, 7)
            XCTAssertEqual(definition.normalizedContentHash, "sha256:historical-\(status)")
            XCTAssertEqual(definition.source, "seed")
            XCTAssertEqual(definition.provenance, "V3-only source")
        }
        let marker = try XCTUnwrap(rows(CatalogImportState.self, in: container).first)
        XCTAssertEqual(try rows(CatalogImportState.self, in: container).count, 1)
        XCTAssertEqual(marker.catalogID, "historical")
        XCTAssertEqual(marker.lastImportedVersion, 17)
        let progress = try rows(LessonProgress.self, in: container)
        XCTAssertEqual(progress.count, 4)
        for status in ["available", "started", "completed", "dismissed"] {
            let row = try XCTUnwrap(progress.first { $0.lessonID == status })
            XCTAssertEqual(row.status.rawValue, status)
            XCTAssertEqual(row.firstShownAt, start)
            XCTAssertEqual(row.startedAt, status == "started" ? later :
                           status == "completed" ? start : nil)
            XCTAssertEqual(row.completedAt, status == "completed" ? later : nil)
            XCTAssertEqual(row.dismissedAt, status == "dismissed" ? later : nil)
            XCTAssertEqual(row.lastOpenedAt, later)
        }
        let attempts = try rows(LessonAttempt.self, in: container)
        XCTAssertEqual(attempts.count, 2)
        let draft = try XCTUnwrap(attempts.first { $0.id == draftID })
        XCTAssertEqual(draft.lessonID, "started")
        XCTAssertEqual(draft.contentVersion, 7)
        XCTAssertEqual(draft.answerDraft, "Unsent personal draft")
        XCTAssertNil(draft.solutionRevealedAt)
        XCTAssertNil(draft.selfCheckAcknowledgedAt)
        XCTAssertNil(draft.completedAt)
        XCTAssertNil(draft.completedContentSnapshot)
        let completed = try XCTUnwrap(attempts.first { $0.id == completedID })
        XCTAssertEqual(completed.lessonID, "completed")
        XCTAssertEqual(completed.contentVersion, 6)
        XCTAssertEqual(completed.answerDraft, "Archived personal answer")
        XCTAssertEqual(completed.solutionRevealedAt, start)
        XCTAssertEqual(completed.selfCheckAcknowledgedAt, later)
        XCTAssertEqual(completed.completedAt, later)
        XCTAssertEqual(completed.completedContentSnapshot, snapshot())
        let task = try XCTUnwrap(rows(TaskItem.self, in: container).first)
        XCTAssertEqual(try rows(TaskItem.self, in: container).count, 1)
        XCTAssertEqual(task.id, taskID)
        XCTAssertEqual(task.title, "Personal V3 task")
        XCTAssertEqual(task.notes, "Do not discard")
        XCTAssertEqual(task.createdAt, start)
        XCTAssertEqual(task.dueAt, later)
        XCTAssertEqual(task.plannedDay, .init(calendarIdentifier: "gregorian", year: 2024, month: 8, day: 30))
        XCTAssertEqual(task.plannedTimeZoneID, "Pacific/Auckland")
        XCTAssertEqual(task.completedAt, later)
        let block = try XCTUnwrap(rows(ScheduleBlock.self, in: container).first)
        XCTAssertEqual(try rows(ScheduleBlock.self, in: container).count, 1)
        XCTAssertEqual(block.id, blockID)
        XCTAssertEqual(block.title, "Personal schedule")
        XCTAssertEqual(block.startAt, start)
        XCTAssertEqual(block.endAt, later)
        XCTAssertEqual(block.note, "Keep schedule note")
        XCTAssertEqual(block.lessonID, "started")
        XCTAssertEqual(block.linkedTitleSnapshot, "started title")
        let focus = try XCTUnwrap(rows(FocusSession.self, in: container).first)
        XCTAssertEqual(try rows(FocusSession.self, in: container).count, 1)
        XCTAssertEqual(focus.id, focusID)
        XCTAssertEqual(focus.state, "ended")
        XCTAssertEqual(focus.plannedSeconds, 1500)
        XCTAssertEqual(focus.accumulatedActiveSeconds, 74.5)
        XCTAssertEqual(focus.startedAt, start)
        XCTAssertEqual(focus.endedAt, later)
        XCTAssertEqual(focus.checkpointAt, later)
        XCTAssertNil(focus.activeSegmentStartedAt)
        XCTAssertNil(focus.deadline)
        XCTAssertNil(focus.pausedAt)
        XCTAssertFalse(focus.recoveryRequired)
        XCTAssertEqual(focus.linkedTaskID, taskID)
        XCTAssertEqual(focus.linkedLessonID, "started")
        XCTAssertEqual(focus.linkedTitleSnapshot, "started title")
        XCTAssertTrue(try rows(LessonSlot.self, in: container).isEmpty,
                      "Schema migration alone must not allocate choices")
    }

    func testRichV3OnlySourceMigratesWithoutImportAndReopensWithPersonalDataIntact() throws {
        let writer = directory("rich-v3-writer")
        let source = directory("rich-v3-closed")
        let copy = directory("rich-v3-copy")
        try seedV3(at: writer.appendingPathComponent("Kontrol.store"))
        try snapshotClosedWriter(writer, to: source)
        let original = try copyClosed(source, to: copy)
        let url = copy.appendingPathComponent("Kontrol.store")
        try autoreleasepool { try assertRichV3(factory.makeContainer(mode: .persistent(url))) }
        try autoreleasepool { try assertRichV3(factory.makeContainer(mode: .persistent(url))) }
        XCTAssertEqual(try bytes(at: source), original)
    }
}
