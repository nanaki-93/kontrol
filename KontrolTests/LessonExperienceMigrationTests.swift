import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LessonExperienceMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()
    private let started = Date(timeIntervalSince1970: 1_730_000_000)
    private let finished = Date(timeIntervalSince1970: 1_730_004_000)
    private let draftID = UUID(uuidString: "F0414550-B724-405A-9C0E-46DF30758637")!
    private let completedID = UUID(uuidString: "44EF5C0E-E759-4550-87DE-868EDBC2F839")!
    private let taskID = UUID(uuidString: "0F828A93-677D-4169-A10B-02BE06E27C74")!
    private let blockID = UUID(uuidString: "5FD09744-51C0-4E92-B737-828954030854")!
    private let focusID = UUID(uuidString: "0336DB65-A5FB-4E7F-BB98-75BF15D0CE04")!

    private func snapshot() -> KontrolSchemaV1.LessonContentSnapshot {
        .init(title: "Studied title", objectiveKey: "old-objective", conceptIDs: ["concept"],
              difficulty: "basic", format: "code", explanation: "Old explanation",
              workedExample: "Old example", exercise: "Old exercise",
              referenceAnswer: "Old reference", selfCheckCriteria: ["Check A", "Check B"])
    }

    private func seedV4(_ url: URL) throws {
        let schema = Schema(versionedSchema: KontrolSchemaV4.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.insert(Topic(id: "topic", name: "Original topic"))
        context.insert(Subtopic(id: "subtopic", topicID: "topic", name: "Subtopic"))
        context.insert(Concept(id: "concept", subtopicID: "subtopic", name: "Concept"))
        for id in ["draft", "completed"] {
            context.insert(KontrolSchemaV4.LessonDefinition(
                id: id, objectiveKey: "old-objective", title: "Studied title",
                topicID: "topic", subtopicID: "subtopic", conceptIDs: ["concept"],
                difficulty: "basic", format: "code", estimatedMinutes: 15,
                explanation: "Old explanation", workedExample: "Old example",
                exercise: "Old exercise", referenceAnswer: "Old reference",
                selfCheckCriteria: ["Check A", "Check B"], contentVersion: 9,
                normalizedContentHash: "hash-\(id)", source: "seed", provenance: "V4",
                objective: "Original objective"))
        }
        context.insert(LessonProgress(lessonID: "draft", status: .started,
                                      firstShownAt: started, startedAt: started, lastOpenedAt: finished))
        context.insert(LessonProgress(lessonID: "completed", status: .completed,
                                      firstShownAt: started, startedAt: started,
                                      completedAt: finished, lastOpenedAt: finished))
        context.insert(KontrolSchemaV1.LessonAttempt(
            id: draftID, lessonID: "draft", contentVersion: 9,
            answerDraft: "  Unicode 🧪\n    indented\n\n", solutionRevealedAt: finished))
        context.insert(KontrolSchemaV1.LessonAttempt(
            id: completedID, lessonID: "completed", contentVersion: 8,
            answerDraft: "  archived\n答え\n", solutionRevealedAt: started,
            selfCheckAcknowledgedAt: finished, completedAt: finished,
            completedContentSnapshot: snapshot()))
        context.insert(LessonSlot(topicID: "topic", slotIndex: 2, lessonID: "draft", assignedAt: started))
        context.insert(CatalogImportState(catalogID: "starter", lastImportedVersion: 17))
        context.insert(try TaskItem(id: taskID, title: "Keep task", createdAt: started))
        context.insert(ScheduleBlock(id: blockID, title: "Keep block", startAt: started,
                                     endAt: finished, lessonID: "draft", linkedTitleSnapshot: "Studied title"))
        context.insert(FocusSession(id: focusID, state: "ended", plannedSeconds: 900,
                                    accumulatedActiveSeconds: 60, startedAt: started,
                                    endedAt: finished, checkpointAt: finished,
                                    linkedLessonID: "draft", linkedTitleSnapshot: "Studied title"))
        try context.save()
    }

    // Snapshot the live writer into a closed V4-only SQLite file, then copy it.
    // SwiftData may keep the writer's WAL open after the container leaves scope.
    private func backup(_ writer: URL, to destination: URL) throws {
        var input: OpaquePointer?
        var output: OpaquePointer?
        guard sqlite3_open_v2(writer.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let input { sqlite3_close(input) }
            throw NSError(domain: "V4Backup", code: 1)
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(destination.path, &output,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let output { sqlite3_close(output) }
            throw NSError(domain: "V4Backup", code: 2)
        }
        defer { sqlite3_close(output) }
        guard let handle = sqlite3_backup_init(output, "main", input, "main") else {
            throw NSError(domain: "V4Backup", code: 3)
        }
        var result: Int32 = SQLITE_BUSY
        for _ in 0..<100 {
            result = sqlite3_backup_step(handle, -1)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_BUSY || result == SQLITE_LOCKED || result == SQLITE_OK else { break }
            sqlite3_sleep(10)
        }
        let finish = sqlite3_backup_finish(handle)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw NSError(domain: "V4Backup", code: Int(result))
        }
    }

    private func assertMigrated(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        let attempts = try context.fetch(FetchDescriptor<LessonAttempt>())
        XCTAssertEqual(attempts.count, 2)
        let draft = try XCTUnwrap(attempts.first { $0.id == draftID })
        XCTAssertEqual(draft.lessonID, "draft")
        XCTAssertEqual(draft.contentVersion, 9)
        XCTAssertEqual(draft.answerDraft, "  Unicode 🧪\n    indented\n\n")
        XCTAssertEqual(draft.solutionRevealedAt, finished)
        XCTAssertNil(draft.selfCheckAcknowledgedAt)
        XCTAssertNil(draft.completedAt)
        XCTAssertNil(draft.completedContentSnapshot)
        let completed = try XCTUnwrap(attempts.first { $0.id == completedID })
        XCTAssertEqual(completed.lessonID, "completed")
        XCTAssertEqual(completed.contentVersion, 8)
        XCTAssertEqual(completed.answerDraft, "  archived\n答え\n")
        XCTAssertEqual(completed.solutionRevealedAt, started)
        XCTAssertEqual(completed.selfCheckAcknowledgedAt, finished)
        XCTAssertEqual(completed.completedAt, finished)
        XCTAssertEqual(completed.completedContentSnapshot, snapshot())
        for attempt in attempts {
            XCTAssertNil(attempt.pinnedContentData)
            XCTAssertEqual(attempt.revision, 0)
        }
        let progress = try context.fetch(FetchDescriptor<LessonProgress>())
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(progress.first { $0.lessonID == "draft" }?.status, .started)
        XCTAssertEqual(progress.first { $0.lessonID == "draft" }?.startedAt, started)
        XCTAssertEqual(progress.first { $0.lessonID == "draft" }?.lastOpenedAt, finished)
        XCTAssertEqual(progress.first { $0.lessonID == "completed" }?.status, .completed)
        XCTAssertEqual(progress.first { $0.lessonID == "completed" }?.completedAt, finished)
        let slot = try XCTUnwrap(context.fetch(FetchDescriptor<LessonSlot>()).first)
        XCTAssertEqual(slot.key, LessonSlot.canonicalKey(topicID: "topic", slotIndex: 2))
        XCTAssertEqual(slot.lessonID, "draft")
        XCTAssertEqual(slot.assignedAt, started)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonDefinition>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Topic>()).map(\.name), ["Original topic"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subtopic>()).map(\.name), ["Subtopic"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Concept>()).map(\.name), ["Concept"])
        try assertUnrelatedData(in: container, catalogVersion: 17)
    }

    private func assertUnrelatedData(in container: ModelContainer, catalogVersion: Int) throws {
        let context = ModelContext(container)
        let marker = try XCTUnwrap(context.fetch(FetchDescriptor<CatalogImportState>()).first)
        XCTAssertEqual(marker.catalogID, "starter")
        XCTAssertEqual(marker.lastImportedVersion, catalogVersion)
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(task.id, taskID)
        XCTAssertEqual(task.title, "Keep task")
        XCTAssertEqual(task.createdAt, started)
        XCTAssertNil(task.completedAt)
        let block = try XCTUnwrap(context.fetch(FetchDescriptor<ScheduleBlock>()).first)
        XCTAssertEqual(block.id, blockID)
        XCTAssertEqual(block.title, "Keep block")
        XCTAssertEqual(block.startAt, started)
        XCTAssertEqual(block.endAt, finished)
        XCTAssertEqual(block.lessonID, "draft")
        XCTAssertEqual(block.linkedTitleSnapshot, "Studied title")
        let focus = try XCTUnwrap(context.fetch(FetchDescriptor<FocusSession>()).first)
        XCTAssertEqual(focus.id, focusID)
        XCTAssertEqual(focus.state, "ended")
        XCTAssertEqual(focus.plannedSeconds, 900)
        XCTAssertEqual(focus.accumulatedActiveSeconds, 60)
        XCTAssertEqual(focus.startedAt, started)
        XCTAssertEqual(focus.endedAt, finished)
        XCTAssertEqual(focus.checkpointAt, finished)
        XCTAssertEqual(focus.linkedLessonID, "draft")
        XCTAssertEqual(focus.linkedTitleSnapshot, "Studied title")
    }

    func testMigratedV4DraftPinsInstalledExerciseBeforeCatalogOverwritesIt() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("KontrolV4Pin-\(UUID())")
        let writer = base.appendingPathComponent("writer/Kontrol.store")
        let copy = base.appendingPathComponent("copy/Kontrol.store")
        try FileManager.default.createDirectory(at: writer.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try seedV4(writer)
        try backup(writer, to: copy)
        var catalog = try BundledCatalogLoader.load(from: Bundle.main).value
        catalog.catalogID = "starter"
        catalog.version = 18
        catalog.topics = [TopicDTO(id: "topic", name: "Revised topic")]
        catalog.subtopics = [SubtopicDTO(id: "subtopic", topicID: "topic", name: "Subtopic")]
        catalog.concepts = [ConceptDTO(id: "concept", subtopicID: "subtopic", name: "Concept",
                                       prerequisiteConceptIDs: [])]
        var revised = catalog.lessons[0]
        revised.id = "draft"
        revised.objectiveKey = "old-objective"
        revised.objective = "Revised objective"
        revised.title = "Revised title"
        revised.topicID = "topic"
        revised.subtopicID = "subtopic"
        revised.conceptIDs = ["concept"]
        revised.prerequisiteConceptIDs = []
        revised.contentVersion = 10
        revised.exercise = "Replacement exercise"
        revised.normalizedContentHash = CatalogValidator.fingerprint(for: revised)
        catalog.lessons = [revised]
        let upgrade = try CatalogValidator.validate(catalog)
        try autoreleasepool {
            let container = try factory.makeContainer(mode: .persistent(copy))
            try assertMigrated(container)
            XCTAssertEqual(try SwiftDataCatalogRepository(container: container).importIfNeeded(upgrade), .imported)
        }
        try autoreleasepool {
            let reopened = try factory.makeContainer(mode: .persistent(copy))
            let context = ModelContext(reopened)
            let attempts = try context.fetch(FetchDescriptor<LessonAttempt>())
            let draft = try XCTUnwrap(attempts.first { $0.id == draftID })
            let pin = try PinnedLessonContent.decode(draft.pinnedContentData,
                lessonID: "draft", contentVersion: 9)
            XCTAssertEqual(pin.definition.title, "Studied title")
            XCTAssertEqual(pin.definition.exercise, "Old exercise")
            XCTAssertEqual(pin.definition.objective, "Original objective")
            XCTAssertEqual(pin.definition.normalizedContentHash, "hash-draft")
            XCTAssertEqual(draft.answerDraft, "  Unicode 🧪\n    indented\n\n")
            XCTAssertEqual(draft.revision, 0)
            XCTAssertEqual(try context.fetch(FetchDescriptor<LessonDefinition>()).first {
                $0.id == "draft"
            }?.exercise, "Replacement exercise")
            let archived = try XCTUnwrap(attempts.first { $0.id == completedID })
            XCTAssertNil(archived.pinnedContentData)
            XCTAssertEqual(archived.completedContentSnapshot, snapshot())
            XCTAssertEqual(archived.contentVersion, 8)
            try assertUnrelatedData(in: reopened, catalogVersion: 18)
            let progress = try context.fetch(FetchDescriptor<LessonProgress>())
            XCTAssertEqual(progress.first { $0.lessonID == "draft" }?.status, .started)
            XCTAssertEqual(progress.first { $0.lessonID == "draft" }?.startedAt, started)
            XCTAssertEqual(progress.first { $0.lessonID == "completed" }?.completedAt, finished)
            let slot = try XCTUnwrap(context.fetch(FetchDescriptor<LessonSlot>()).first {
                $0.lessonID == "draft"
            })
            XCTAssertEqual(slot.key, LessonSlot.canonicalKey(topicID: "topic", slotIndex: 2))
            XCTAssertEqual(slot.assignedAt, started)
        }
    }

    func testCopiedRichV4MigratesLightweightAndReopensWithoutModifyingSource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("KontrolV5-\(UUID())")
        let writer = base.appendingPathComponent("writer", isDirectory: true)
        let original = base.appendingPathComponent("original", isDirectory: true)
        let copy = base.appendingPathComponent("copy", isDirectory: true)
        for directory in [writer, original, copy] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Do not remove opened stores: SwiftData can retain their SQLite handles.
        try seedV4(writer.appendingPathComponent("Kontrol.store"))
        let source = original.appendingPathComponent("Kontrol.store")
        let target = copy.appendingPathComponent("Kontrol.store")
        try backup(writer.appendingPathComponent("Kontrol.store"), to: source)
        let originalBytes = try Data(contentsOf: source)
        try FileManager.default.copyItem(at: source, to: target)
        try autoreleasepool { try assertMigrated(factory.makeContainer(mode: .persistent(target))) }
        try autoreleasepool { try assertMigrated(factory.makeContainer(mode: .persistent(target))) }
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }
}
