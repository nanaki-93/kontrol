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

    func testExplicitCreationCommitsOneSnapshotWithAllFieldsAndUnplannedNil() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var saves = 0
        var ids = 0
        let repository = SwiftDataTaskRepository(container: container, now: { self.instant },
            makeID: { ids += 1; return ids == 1 ? self.firstID : self.secondID },
            save: { context in saves += 1; try context.save() })
        let due = instant.addingTimeInterval(2_345)
        let plan = PlannedDay(components: .init(calendarIdentifier: "gregorian", year: 2026,
                                                month: 6, day: 5), timeZoneID: "Pacific/Auckland")
        let snapshot = try repository.create(input: TaskInput(title: "  Explicit  \n",
            notes: " \n Line one\nLine two \n ", dueAt: due, plannedFor: plan))
        XCTAssertEqual(snapshot.id, firstID)
        XCTAssertEqual(snapshot.title, "Explicit")
        XCTAssertEqual(snapshot.notes, "Line one\nLine two")
        XCTAssertEqual(snapshot.dueAt, due)
        XCTAssertEqual(snapshot.plannedDay, plan.components)
        XCTAssertEqual(snapshot.plannedTimeZoneID, plan.timeZoneID)
        XCTAssertEqual(snapshot.createdAt, instant)
        XCTAssertNil(snapshot.completedAt)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(ids, 1)

        // Explicit nil never silently becomes Today; the legacy nil path still does.
        let unplanned = try repository.create(input: TaskInput(title: " Unplanned ", notes: " \n "))
        XCTAssertEqual(unplanned.id, secondID)
        XCTAssertNil(unplanned.plannedDay)
        XCTAssertNil(unplanned.plannedTimeZoneID)
        XCTAssertNil(unplanned.notes)
        XCTAssertNil(unplanned.dueAt)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [secondID, firstID],
                       "fetchAll keeps creation-time then UUID tie ordering")
        let persisted = try XCTUnwrap(repository.fetchAll().first { $0.id == firstID })
        XCTAssertEqual(TaskSnapshot(persisted), snapshot)
    }

    func testExplicitValidationDoesNotAllocateIDOrSaveAndFailedSaveIsIsolated() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let independent = ModelContext(container)
        independent.autosaveEnabled = false
        let draft = try TaskItem(id: secondID, title: "Pending elsewhere", createdAt: instant)
        independent.insert(draft)
        var ids = 0
        var saves = 0
        let repository = SwiftDataTaskRepository(container: container, now: { self.instant },
            makeID: { ids += 1; return self.firstID }, save: { _ in
                saves += 1
                throw Injected.saveFailed
            })
        XCTAssertThrowsError(try repository.create(input: TaskInput(title: "  \n  "))) {
            XCTAssertTrue($0 is KontrolSchemaV1.TaskValidationError)
        }
        let invalid = PlannedDay(components: .init(calendarIdentifier: "gregorian", year: 2025,
                                                    month: 2, day: 29), timeZoneID: "UTC")
        XCTAssertThrowsError(try repository.create(input: TaskInput(title: "Valid title", plannedFor: invalid))) {
            XCTAssertEqual($0 as? PlannedDay.ValidationError, .invalidDate)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertThrowsError(try repository.create(input: TaskInput(title: "Will fail", dueAt: instant))) {
            XCTAssertTrue($0 is Injected)
        }
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertTrue(independent.hasChanges)
        XCTAssertEqual(draft.title, "Pending elsewhere")
        try independent.save()
        XCTAssertEqual(try repository.fetchAll().map(\.id), [secondID])
        let retry = try makeRepository(container, id: firstID).create(input: TaskInput(title: "Retry"))
        XCTAssertEqual(retry.id, firstID)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [secondID, firstID])
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

    func testSnapshotCopiesAllFieldsWithoutHoldingTheSourceModel() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let due = instant.addingTimeInterval(3_600)
        let completed = instant.addingTimeInterval(7_200)
        let plan = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian",
                                                         year: 2026, month: 2, day: 28)
        let snapshot: TaskSnapshot
        do {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let task = try TaskItem(id: firstID, title: "Original", createdAt: instant,
                                    notes: "First\nSecond", dueAt: due, plannedDay: plan,
                                    plannedTimeZoneID: "Pacific/Auckland", completedAt: completed)
            context.insert(task)
            snapshot = TaskSnapshot(task)
            task.title = "Changed"
            task.notes = nil
            task.dueAt = nil
            task.plannedDay = nil
            task.plannedTimeZoneID = nil
            task.completedAt = nil
        }
        XCTAssertEqual(snapshot.id, firstID)
        XCTAssertEqual(snapshot.title, "Original")
        XCTAssertEqual(snapshot.notes, "First\nSecond")
        XCTAssertEqual(snapshot.dueAt, due)
        XCTAssertEqual(snapshot.plannedDay, plan)
        XCTAssertEqual(snapshot.plannedTimeZoneID, "Pacific/Auckland")
        XCTAssertEqual(snapshot.createdAt, instant)
        XCTAssertEqual(snapshot.completedAt, completed)
        XCTAssertTrue(snapshot.isCompleted)
    }

    func testInputNormalizesTitleAndNotesButKeepsDueInstantAndMultilineContent() throws {
        let plan = PlannedDay(components: .init(calendarIdentifier: "gregorian", year: 2024,
                                                 month: 2, day: 29), timeZoneID: "Pacific/Auckland")
        let input = TaskInput(title: " \n  Write tests  \t", notes: " \n  Line one\nLine two  \n ",
                              dueAt: instant, plannedFor: plan)
        let clean = try input.validated()
        XCTAssertEqual(clean.title, "Write tests")
        XCTAssertEqual(clean.notes, "Line one\nLine two")
        XCTAssertEqual(clean.dueAt, instant)
        XCTAssertEqual(clean.plannedFor, plan)
        XCTAssertEqual(input.title, " \n  Write tests  \t")
        XCTAssertNil(try TaskInput(title: "Open", notes: " \n\t ", dueAt: nil,
                                   plannedFor: nil).validated().notes)
        XCTAssertNil(try TaskInput(title: "Unplanned", notes: nil, dueAt: nil,
                                   plannedFor: nil).validated().plannedFor)
        XCTAssertThrowsError(try TaskInput(title: " \t\n ", notes: "kept", dueAt: instant,
                                           plannedFor: plan).validated()) {
            XCTAssertTrue($0 is KontrolSchemaV1.TaskValidationError)
        }
    }

    func testPlannedDayRejectsInvalidIdentifiersZonesDatesAndUnpairedFields() throws {
        let valid = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian",
                                                         year: 2026, month: 3, day: 8)
        XCTAssertEqual(try PlannedDay.validated(components: nil, timeZoneID: nil), nil)
        XCTAssertThrowsError(try PlannedDay.validated(components: valid, timeZoneID: nil)) {
            XCTAssertTrue($0 is KontrolSchemaV1.TaskValidationError)
        }
        XCTAssertThrowsError(try PlannedDay.validated(components: nil, timeZoneID: "UTC")) {
            XCTAssertTrue($0 is KontrolSchemaV1.TaskValidationError)
        }
        func expectInvalid(_ components: KontrolSchemaV1.PlannedDayComponents,
                           zone: String, error: PlannedDay.ValidationError) {
            XCTAssertThrowsError(try TaskInput(title: "Test", notes: nil, dueAt: nil,
                plannedFor: PlannedDay(components: components, timeZoneID: zone)).validated()) {
                XCTAssertEqual($0 as? PlannedDay.ValidationError, error)
            }
        }
        expectInvalid(.init(calendarIdentifier: "not-a-calendar", year: 2026, month: 3, day: 8),
                      zone: "UTC", error: .invalidCalendarIdentifier)
        expectInvalid(valid, zone: "Mars/Olympus", error: .invalidTimeZoneID)
        expectInvalid(valid, zone: "", error: .invalidTimeZoneID)
        for (year, month, day) in [(2025, 2, 29), (2026, 13, 1), (2026, 4, 31),
                                   (0, 1, 1), (2026, 1, 0)] {
            expectInvalid(.init(calendarIdentifier: "gregorian", year: year, month: month, day: day),
                          zone: "UTC", error: .invalidDate)
        }
        XCTAssertEqual(try PlannedDay(components: valid, timeZoneID: "America/Los_Angeles")
            .validated().components, valid)
        XCTAssertEqual(try PlannedDay(components: .init(calendarIdentifier: "gregorian",
            year: 2024, month: 2, day: 29), timeZoneID: "UTC").validated().timeZoneID, "UTC")
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
