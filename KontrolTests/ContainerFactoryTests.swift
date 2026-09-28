import Foundation
import SwiftData
import XCTest
@testable import Kontrol

final class ContainerFactoryTests: XCTestCase {
    private let factory = ModelContainerFactory()

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolContainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func taskIDs(in container: ModelContainer) throws -> [UUID] {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map(\.id)
    }

    func testInMemoryContainersAreIndependent() throws {
        let first = try factory.makeContainer(mode: .inMemory)
        let second = try factory.makeContainer(mode: .inMemory)
        let id = UUID()
        let context = ModelContext(first)
        context.insert(try TaskItem(id: id, title: "Only in memory", createdAt: Date()))
        try context.save()
        XCTAssertEqual(try taskIDs(in: first), [id])
        XCTAssertTrue(try taskIDs(in: second).isEmpty)
    }

    func testClosedDiskStoreReopensAtSameLocationButNotOtherDiskOrMemory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first/Kontrol.store")
        let otherURL = directory.appendingPathComponent("other/Kontrol.store")
        let id = UUID()

        // Scope both owners before reopening: no context or container from the
        // writing session may serve the read after this function returns.
        func writeAndClose() throws {
            let container = try factory.makeContainer(mode: .persistent(firstURL))
            let context = ModelContext(container)
            context.insert(try TaskItem(id: id, title: "Persisted", createdAt: Date()))
            try context.save()
        }
        try writeAndClose()

        func reopenAndCheck() throws {
            let reopened = try factory.makeContainer(mode: .persistent(firstURL))
            let records = try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>())
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.id, id)
            XCTAssertEqual(records.first?.title, "Persisted")
        }
        try reopenAndCheck()
        let other = try factory.makeContainer(mode: .persistent(otherURL))
        XCTAssertTrue(try taskIDs(in: other).isEmpty)
        let memory = try factory.makeContainer(mode: .inMemory)
        XCTAssertTrue(try taskIDs(in: memory).isEmpty)
    }

    func testCopiedFrozenV2AndV3StoresOpenAsV4WithoutChangingOriginals() throws {
        for version in ["V2", "V3"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: version, withExtension: nil))
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = try FileManager.default.contentsOfDirectory(at: source,
                includingPropertiesForKeys: [.isRegularFileKey]).filter {
                    try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                }
            let originals = try Dictionary(uniqueKeysWithValues: files.map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
            XCTAssertNotNil(originals["Kontrol.store"])
            for file in files {
                try FileManager.default.copyItem(at: file,
                    to: directory.appendingPathComponent(file.lastPathComponent))
            }
            func checkOpen() throws {
                let container = try factory.makeContainer(mode: .persistent(
                    directory.appendingPathComponent("Kontrol.store")))
                let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
                XCTAssertEqual(tasks.count, 1)
                XCTAssertEqual(tasks.first?.title, "\(version) fixture task")
                XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ScheduleBlock>()).count, 1)
                XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FocusSession>()).count,
                               version == "V3" ? 1 : 0)
                XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonSlot>()).isEmpty)
            }
            try checkOpen()
            try checkOpen()
            let after = try FileManager.default.contentsOfDirectory(at: source,
                includingPropertiesForKeys: [.isRegularFileKey])
            XCTAssertEqual(Set(after.map(\.lastPathComponent)), Set(originals.keys))
            for file in after {
                XCTAssertEqual(try Data(contentsOf: file), originals[file.lastPathComponent])
            }
        }
    }

    func testCopiedV3DefinitionMigratesWithIdentityAndObjectiveDefault() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let copy = directory.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        let sourceURL = source.appendingPathComponent("Kontrol.store")
        let copiedURL = copy.appendingPathComponent("Kontrol.store")
        let lessonID = "go.historical.v1"
        let attemptID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // Write against the released V3 schema, without the production migration plan.
        func writeV3AndClose() throws -> PersistentIdentifier {
            let schema = Schema(versionedSchema: KontrolSchemaV3.self)
            let config = ModelConfiguration(schema: schema, url: sourceURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let historical = KontrolSchemaV1.LessonDefinition(
                id: lessonID, objectiveKey: "go.historical", title: "Historical title",
                topicID: "go", subtopicID: "go.old", conceptIDs: ["go.old.concept"],
                difficulty: "basic", format: "learn", estimatedMinutes: 12,
                explanation: "Explanation", workedExample: "Example", exercise: "Exercise",
                referenceAnswer: "Answer", selfCheckCriteria: ["Criterion"], contentVersion: 3,
                normalizedContentHash: "historical-hash", source: "seed", provenance: "old-bundle")
            context.insert(historical)
            context.insert(LessonProgress(lessonID: lessonID, status: .started, startedAt: startedAt))
            context.insert(LessonAttempt(id: attemptID, lessonID: lessonID, contentVersion: 3,
                                         answerDraft: "Do not discard"))
            context.insert(CatalogImportState(catalogID: "kontrol.starter", lastImportedVersion: 1))
            try context.save()
            return historical.persistentModelID
        }
        let originalIdentity = try writeV3AndClose()
        let originals = try FileManager.default.contentsOfDirectory(at: source,
            includingPropertiesForKeys: [.isRegularFileKey]).filter {
                try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
        XCTAssertTrue(originals.contains { $0.lastPathComponent == "Kontrol.store" })
        let bytes = try Dictionary(uniqueKeysWithValues: originals.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
        for file in originals {
            try FileManager.default.copyItem(at: file,
                to: copy.appendingPathComponent(file.lastPathComponent))
        }
        func openAndCheck() throws {
            let container = try factory.makeContainer(mode: .persistent(copiedURL))
            let context = ModelContext(container)
            let definitions = try context.fetch(FetchDescriptor<LessonDefinition>())
            XCTAssertEqual(definitions.count, 1)
            let definition = try XCTUnwrap(definitions.first)
            XCTAssertEqual(definition.id, lessonID)
            // SwiftData wraps Core Data object IDs per coordinator; the wrappers
            // are not Equatable across distinct opens even for the same SQLite row.
            // Retain the entity and store identity as well as its unique stable ID.
            XCTAssertEqual(definition.persistentModelID.entityName, originalIdentity.entityName)
            XCTAssertEqual(definition.persistentModelID.storeIdentifier, originalIdentity.storeIdentifier)
            XCTAssertEqual(definition.objectiveKey, "go.historical")
            XCTAssertEqual(definition.title, "Historical title")
            XCTAssertEqual(definition.conceptIDs, ["go.old.concept"])
            XCTAssertEqual(definition.contentVersion, 3)
            XCTAssertEqual(definition.objective, "")
            XCTAssertEqual(try context.fetch(FetchDescriptor<LessonProgress>()).first?.startedAt, startedAt)
            XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>()).first?.id, attemptID)
            XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>()).first?.answerDraft, "Do not discard")
            XCTAssertEqual(try context.fetch(FetchDescriptor<CatalogImportState>()).first?.lastImportedVersion, 1)
            XCTAssertTrue(try context.fetch(FetchDescriptor<LessonSlot>()).isEmpty)
        }
        try openAndCheck()
        try openAndCheck()
        let after = try FileManager.default.contentsOfDirectory(at: source,
            includingPropertiesForKeys: [.isRegularFileKey])
        XCTAssertEqual(Set(after.map(\.lastPathComponent)), Set(bytes.keys))
        for file in after {
            XCTAssertEqual(try Data(contentsOf: file), bytes[file.lastPathComponent])
        }
    }

    func testFreshFactoryStorePersistsV3FocusV2BlockAndV1TaskAcrossReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kontrol.store")
        let blockID = UUID()
        let taskID = UUID()
        let focusID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3_600)

        func writeAndClose() throws {
            let container = try factory.makeContainer(mode: .persistent(url))
            let context = ModelContext(container)
            context.insert(ScheduleBlock(id: blockID, title: "Study", startAt: start,
                                         endAt: end, note: "Bring notes",
                                         lessonID: "missing-lesson",
                                         linkedTitleSnapshot: "Old title"))
            context.insert(try TaskItem(id: taskID, title: "Review", createdAt: start))
            context.insert(FocusSession(id: focusID, state: "paused", plannedSeconds: 900,
                                        accumulatedActiveSeconds: 42.25, pausedAt: end,
                                        startedAt: start, checkpointAt: end,
                                        recoveryRequired: true, linkedTaskID: taskID,
                                        linkedTitleSnapshot: "Review"))
            try context.save()
        }
        try writeAndClose()

        func reopenAndCheck() throws {
            let container = try factory.makeContainer(mode: .persistent(url))
            let block = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<ScheduleBlock>()).first)
            XCTAssertEqual(block.id, blockID)
            XCTAssertEqual(block.title, "Study")
            XCTAssertEqual(block.startAt, start)
            XCTAssertEqual(block.endAt, end)
            XCTAssertEqual(block.note, "Bring notes")
            XCTAssertEqual(block.lessonID, "missing-lesson")
            XCTAssertEqual(block.linkedTitleSnapshot, "Old title")
            XCTAssertEqual(try taskIDs(in: container), [taskID])
            let focus = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<FocusSession>()).first)
            XCTAssertEqual(focus.id, focusID)
            XCTAssertEqual(focus.state, "paused")
            XCTAssertEqual(focus.plannedSeconds, 900)
            XCTAssertEqual(focus.accumulatedActiveSeconds, 42.25)
            XCTAssertNil(focus.activeSegmentStartedAt)
            XCTAssertNil(focus.deadline)
            XCTAssertEqual(focus.pausedAt, end)
            XCTAssertEqual(focus.startedAt, start)
            XCTAssertNil(focus.endedAt)
            XCTAssertEqual(focus.checkpointAt, end)
            XCTAssertTrue(focus.recoveryRequired)
            XCTAssertEqual(focus.linkedTaskID, taskID)
            XCTAssertNil(focus.linkedLessonID)
            XCTAssertEqual(focus.linkedTitleSnapshot, "Review")
        }
        try reopenAndCheck()
        let empty = try factory.makeContainer(mode: .inMemory)
        XCTAssertTrue(try ModelContext(empty).fetch(FetchDescriptor<ScheduleBlock>()).isEmpty)
        XCTAssertTrue(try ModelContext(empty).fetch(FetchDescriptor<FocusSession>()).isEmpty)
    }

    func testOpenErrorPropagatesWithoutReplacingExistingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("Kontrol.store")
        let original = Data("not a SQLite database; preserve these bytes".utf8)
        try original.write(to: store)

        XCTAssertThrowsError(try factory.makeContainer(mode: .persistent(store)))
        XCTAssertEqual(try Data(contentsOf: store), original)
        // A bad disk store must not be replaced with a fresh empty database.
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.path)[.size] as? Int,
                       original.count)
    }

    func testProductionLocationIsStableAndAppSpecificWithoutOpeningStore() throws {
        let first = try StoreLocation.productionStoreURL()
        XCTAssertEqual(first, try StoreLocation.productionStoreURL())
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask, appropriateFor: nil,
                                                   create: false)
        XCTAssertEqual(first.deletingLastPathComponent().deletingLastPathComponent(), support)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Kontrol")
        XCTAssertEqual(first.lastPathComponent, "Kontrol.store")
    }
}
