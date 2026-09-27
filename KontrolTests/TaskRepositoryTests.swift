import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class TaskRepositoryTests: XCTestCase {
    private enum Injected: Error { case saveFailed }
    private let instant = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func makeRepository(_ container: ModelContainer, id: UUID,
                                save: @escaping (ModelContext) throws -> Void = { try $0.save() }) -> SwiftDataTaskRepository {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        return SwiftDataTaskRepository(container: container, now: { self.instant },
                                       makeID: { id }, calendar: { Calendar(identifier: .gregorian) },
                                       timeZone: { zone }, save: save)
    }

    func testCaptureUsesLocalDayTrimsTitleAndLeavesUnrequestedFieldsUnset() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = makeRepository(container, id: firstID)
        XCTAssertEqual(try repository.create(title: "  Read docs \n", plannedFor: nil), firstID)
        let task = try XCTUnwrap(repository.fetchAll().first)
        XCTAssertEqual(try repository.fetchAll().count, 1)
        XCTAssertEqual(task.id, firstID)
        XCTAssertEqual(task.title, "Read docs")
        XCTAssertEqual(task.createdAt, instant)
        XCTAssertEqual(task.plannedDay, .init(calendarIdentifier: "gregorian", year: 2025, month: 12, day: 31))
        XCTAssertEqual(task.plannedTimeZoneID, "America/Los_Angeles")
        XCTAssertNil(task.notes)
        XCTAssertNil(task.dueAt)
        XCTAssertNil(task.completedAt)
        XCTAssertFalse(task.isCompleted)
    }

    func testSuccessfulCreateSavesOnceAndBlankDoesNotConsumeDependencies() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var clockCalls = 0
        var idCalls = 0
        var saveCalls = 0
        let repository = SwiftDataTaskRepository(container: container, now: {
            clockCalls += 1
            return self.instant
        }, makeID: {
            idCalls += 1
            return self.firstID
        }, save: { context in
            saveCalls += 1
            try context.save()
        })
        XCTAssertThrowsError(try repository.create(title: " \n ", plannedFor: nil))
        XCTAssertEqual(clockCalls, 0)
        XCTAssertEqual(idCalls, 0)
        XCTAssertEqual(saveCalls, 0)
        XCTAssertEqual(try repository.create(title: "Once", plannedFor: nil), firstID)
        XCTAssertEqual(clockCalls, 1)
        XCTAssertEqual(idCalls, 1)
        XCTAssertEqual(saveCalls, 1)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [firstID])
    }

    func testExplicitPlannedDayKeepsSelectedZoneAndCalendarDate() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let selected = PlannedDay(components: .init(calendarIdentifier: "gregorian", year: 2026,
                                                     month: 6, day: 5), timeZoneID: "Pacific/Auckland")
        _ = try makeRepository(container, id: firstID).create(title: "Later", plannedFor: selected)
        let task = try XCTUnwrap(makeRepository(container, id: secondID).fetchAll().first)
        XCTAssertEqual(task.plannedDay, selected.components)
        XCTAssertEqual(task.plannedTimeZoneID, selected.timeZoneID)
    }

    func testBlankAndInjectedSaveFailurePersistNothingAndDoNotTouchOtherEdits() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let independent = ModelContext(container)
        independent.autosaveEnabled = false
        let draft = try TaskItem(id: secondID, title: "Other owner draft", createdAt: instant)
        independent.insert(draft)
        var saveCalls = 0
        let failing = makeRepository(container, id: firstID, save: { _ in
            saveCalls += 1
            throw Injected.saveFailed
        })
        XCTAssertThrowsError(try failing.create(title: " \t\n ", plannedFor: nil)) {
            XCTAssertTrue($0 is KontrolSchemaV1.TaskValidationError)
        }
        XCTAssertEqual(saveCalls, 0)
        XCTAssertThrowsError(try failing.create(title: "Not saved", plannedFor: nil)) {
            XCTAssertTrue($0 is Injected)
        }
        XCTAssertEqual(saveCalls, 1)
        XCTAssertTrue(try failing.fetchAll().isEmpty)
        XCTAssertTrue(independent.hasChanges)
        XCTAssertEqual(draft.title, "Other owner draft")
        try independent.save()
        XCTAssertEqual(try failing.fetchAll().map(\.id), [secondID])
        XCTAssertEqual(try makeRepository(container, id: firstID).create(title: "Retry", plannedFor: nil), firstID)
        XCTAssertEqual(try failing.fetchAll().map(\.id), [secondID, firstID])
    }

    func testFetchOrderUsesCreationInstantThenUUIDForTies() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let later = SwiftDataTaskRepository(container: container, now: { self.instant.addingTimeInterval(1) },
                                             makeID: { self.firstID })
        _ = try later.create(title: "Later", plannedFor: nil)
        _ = try makeRepository(container, id: secondID).create(title: "Earlier", plannedFor: nil)
        XCTAssertEqual(try later.fetchAll().map(\.id), [secondID, firstID])

        let tied = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        _ = try makeRepository(container, id: tied).create(title: "Tie", plannedFor: nil)
        XCTAssertEqual(try later.fetchAll().map(\.id), [secondID, tied, firstID])
    }

    func testClosedTemporaryDiskStoreReopensWithSameIDAndValuesAndNoFailedInsert() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolTaskRepository-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Kontrol.store")
        // SwiftData may retain SQLite file descriptors after Swift owners leave
        // scope; keep this UUID-isolated test store until the test host exits.
        weak var lastContainer: ModelContainer?
        func writeAndClose() throws {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let repository = makeRepository(container, id: firstID)
            XCTAssertEqual(try repository.create(title: "  Durable task  ", plannedFor: nil), firstID)
            XCTAssertThrowsError(try makeRepository(container, id: secondID,
                save: { _ in throw Injected.saveFailed }).create(title: "Lost task", plannedFor: nil))
        }
        func reopenAndCheck() throws {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            lastContainer = container
            let rows = try makeRepository(container, id: secondID).fetchAll()
            XCTAssertEqual(rows.count, 1)
            let task = try XCTUnwrap(rows.first)
            XCTAssertEqual(task.id, firstID)
            XCTAssertEqual(task.title, "Durable task")
            XCTAssertEqual(task.createdAt, instant)
            XCTAssertEqual(task.plannedDay, .init(calendarIdentifier: "gregorian", year: 2025, month: 12, day: 31))
            XCTAssertEqual(task.plannedTimeZoneID, "America/Los_Angeles")
            XCTAssertNil(task.dueAt)
            XCTAssertNil(task.completedAt)
            XCTAssertNil(task.notes)
        }
        // All explicit repository/context/container owners leave scope before a
        // distinct factory open. SwiftData may still cache internal store owners.
        try autoreleasepool { try writeAndClose() }
        try autoreleasepool { try reopenAndCheck() }
        XCTAssertNil(lastContainer, "The reopened container must not remain owned by the test")
    }
}
