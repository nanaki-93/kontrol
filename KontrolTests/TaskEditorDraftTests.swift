import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class TaskEditorDraftTests: XCTestCase {
    private enum InjectedFailure: Error { case save }

    private final class RecordingRepository: TaskRepository {
        let storage: SwiftDataTaskRepository
        var creates: [TaskInput] = []
        var updates: [(UUID, TaskInput)] = []
        var fail = false

        init() throws {
            storage = SwiftDataTaskRepository(container: try ModelContainerFactory().makeContainer(mode: .inMemory))
        }

        func create(title: String, plannedFor: PlannedDay?) throws -> UUID {
            try storage.create(title: title, plannedFor: plannedFor)
        }
        func fetchAll() throws -> [TaskItem] { try storage.fetchAll() }
        func create(input: TaskInput) throws -> TaskSnapshot {
            creates.append(input)
            if fail { throw InjectedFailure.save }
            return try storage.create(input: input)
        }
        func update(id: UUID, input: TaskInput) throws -> TaskSnapshot {
            updates.append((id, input))
            if fail { throw InjectedFailure.save }
            return try storage.update(id: id, input: input)
        }
        func setCompleted(id: UUID, completed: Bool) throws -> TaskSnapshot {
            try storage.setCompleted(id: id, completed: completed)
        }
        func delete(id: UUID) throws { try storage.delete(id: id) }
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, zone: String = "UTC") -> PlannedDay {
        PlannedDay(components: .init(calendarIdentifier: "gregorian", year: year,
                                     month: month, day: day), timeZoneID: zone)
    }

    func testCanceledCreateAndEditNeverCallStore() throws {
        let repository = try RecordingRepository()
        let store = TaskStore(repository: repository)
        let original = try store.create(input: TaskInput(title: "Existing"))
        repository.creates.removeAll()
        let create = TaskEditorDraft(creatingIn: store)
        create.title = "Discard create"
        create.cancel()
        create.submit { _ in XCTFail("Canceled create submitted") }
        let edit = try TaskEditorDraft(editing: original, in: store)
        edit.title = "Discard edit"
        edit.cancel()
        edit.submit { _ in XCTFail("Canceled edit submitted") }
        XCTAssertFalse(create.canSubmit)
        XCTAssertFalse(edit.canSubmit)
        XCTAssertTrue(repository.creates.isEmpty)
        XCTAssertTrue(repository.updates.isEmpty)
        XCTAssertEqual(try repository.fetchAll().map(\.title), ["Existing"])
    }

    func testInvalidTitleOrPlanCannotSubmitAndIdentifiesField() throws {
        let repository = try RecordingRepository()
        let draft = TaskEditorDraft(creatingIn: TaskStore(repository: repository))
        draft.title = " \n "
        XCTAssertEqual(draft.invalidFields, [.title])
        draft.submit { _ in XCTFail("Blank title submitted") }
        draft.title = "Valid"
        draft.plannedFor = day(2026, 2, 30)
        XCTAssertEqual(draft.invalidFields, [.plan])
        XCTAssertFalse(draft.canSubmit)
        draft.submit { _ in XCTFail("Invalid calendar day submitted") }
        draft.plannedFor = day(2026, 2, 17, zone: "Not/AZone")
        XCTAssertEqual(draft.invalidFields, [.plan])
        draft.plannedFor = day(2026, 2, 17)
        XCTAssertTrue(draft.invalidFields.isEmpty)
        XCTAssertTrue(draft.canSubmit)
        XCTAssertTrue(repository.creates.isEmpty)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testFailedCreateRetainsEveryFieldThenCommitsOnceEvenWithReentrantSubmit() throws {
        let repository = try RecordingRepository()
        let store = TaskStore(repository: repository)
        let draft = TaskEditorDraft(creatingIn: store)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = day(2026, 2, 17)
        draft.title = "  Title  "
        draft.notes = "  First line\nSecond line  "
        draft.dueAt = due
        draft.plannedFor = plan
        repository.fail = true
        var successes = 0
        draft.submit { _ in successes += 1 }
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(draft.saveError, .writeFailed)
        XCTAssertEqual(draft.title, "  Title  ")
        XCTAssertEqual(draft.notes, "  First line\nSecond line  ")
        XCTAssertEqual(draft.dueAt, due)
        XCTAssertEqual(draft.plannedFor, plan)
        XCTAssertTrue(draft.canSubmit)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        repository.fail = false
        draft.submit { snapshot in
            successes += 1
            draft.submit { _ in XCTFail("Reentrant creation") }
            XCTAssertEqual(snapshot.title, "Title")
            XCTAssertEqual(snapshot.notes, "First line\nSecond line")
            XCTAssertEqual(snapshot.dueAt, due)
            XCTAssertEqual(snapshot.plannedDay, plan.components)
            XCTAssertEqual(snapshot.plannedTimeZoneID, plan.timeZoneID)
        }
        draft.submit { _ in XCTFail("Duplicate creation") }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(repository.creates.count, 2) // failed attempt + committed retry
        XCTAssertEqual(try repository.fetchAll().count, 1)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertFalse(draft.canSubmit)
    }

    func testEditKeepsIdentityCompletionAndOriginalSnapshotWhenWriteFailsThenClearsOptionalFields() throws {
        let repository = try RecordingRepository()
        let store = TaskStore(repository: repository)
        let original = try store.create(input: TaskInput(title: "Before", notes: "Old",
                                                         dueAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                         plannedFor: day(2026, 3, 12)))
        let draft = try TaskEditorDraft(editing: original, in: store)
        XCTAssertEqual(draft.editingID, original.id)
        XCTAssertEqual(draft.title, "Before")
        XCTAssertEqual(draft.notes, "Old")
        XCTAssertEqual(draft.dueAt, original.dueAt)
        XCTAssertEqual(draft.plannedFor?.components, original.plannedDay)
        _ = try store.setCompleted(id: original.id, completed: true)
        let completedAt = try XCTUnwrap(store.snapshots.first?.completedAt)
        draft.title = "  After  "
        draft.notes = "Changed\nacross lines"
        draft.dueAt = nil
        draft.plannedFor = nil
        repository.fail = true
        draft.submit { _ in XCTFail("Failed edit succeeded") }
        XCTAssertEqual(draft.saveError, .writeFailed)
        XCTAssertEqual(draft.title, "  After  ")
        XCTAssertEqual(draft.notes, "Changed\nacross lines")
        XCTAssertNil(draft.dueAt)
        XCTAssertNil(draft.plannedFor)
        XCTAssertEqual(try repository.fetchAll().first?.title, "Before")
        repository.fail = false
        var saved: TaskSnapshot?
        draft.submit { saved = $0 }
        XCTAssertEqual(saved?.id, original.id)
        XCTAssertEqual(saved?.createdAt, original.createdAt)
        XCTAssertEqual(saved?.completedAt, completedAt)
        XCTAssertEqual(saved?.title, "After")
        XCTAssertEqual(saved?.notes, "Changed\nacross lines")
        XCTAssertNil(saved?.dueAt)
        XCTAssertNil(saved?.plannedDay)
        XCTAssertNil(saved?.plannedTimeZoneID)
        XCTAssertEqual(repository.updates.map(\.0), [original.id, original.id])
        XCTAssertEqual(try repository.fetchAll().count, 1)
    }

    func testStaleEditReportsNotFoundAndNeverFallsBackToCreate() throws {
        let repository = try RecordingRepository()
        let store = TaskStore(repository: repository)
        let original = try store.create(input: TaskInput(title: "Soon deleted"))
        let draft = try TaskEditorDraft(editing: original, in: store)
        try repository.delete(id: original.id) // A different owner removes it.
        draft.title = "Do not resurrect"
        draft.submit { _ in XCTFail("Stale edit succeeded") }
        XCTAssertEqual(draft.saveError, .notFound)
        XCTAssertEqual(draft.title, "Do not resurrect")
        XCTAssertEqual(repository.updates.map(\.0), [original.id])
        XCTAssertEqual(repository.creates.count, 1)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertTrue(store.snapshots.isEmpty) // Store's not-found path refreshed.
    }

    func testSelectedPlanPreservesDayAndZoneAfterTravelAndCanBeCleared() throws {
        let repository = try RecordingRepository()
        let store = TaskStore(repository: repository)
        let draft = TaskEditorDraft(creatingIn: store)
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let selected = Date(timeIntervalSince1970: 1_773_360_000)
        draft.title = "Travel"
        draft.selectPlannedDate(selected, calendar: Calendar(identifier: .gregorian), timeZone: zone)
        let captured = try XCTUnwrap(draft.plannedFor)
        XCTAssertEqual(captured, PlannedDay.today(at: selected, calendar: Calendar(identifier: .gregorian),
                                                  timeZone: zone))
        draft.submit { _ in }
        XCTAssertEqual(store.snapshots.first?.plannedDay, captured.components)
        XCTAssertEqual(store.snapshots.first?.plannedTimeZoneID, zone.identifier)
        let edit = try TaskEditorDraft(editing: XCTUnwrap(store.snapshots.first), in: store)
        XCTAssertEqual(edit.plannedFor, captured)
        edit.plannedFor = nil
        edit.submit { _ in }
        XCTAssertNil(store.snapshots.first?.plannedDay)
        XCTAssertNil(store.snapshots.first?.plannedTimeZoneID)
    }
}
