import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class ScheduleEditorDraftTests: XCTestCase {
    private enum InjectedFailure: Error { case save }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                      zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour))!
    }

    private func store(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws
        -> ScheduleStore {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        return ScheduleStore(repository: SwiftDataScheduleRepository(container: container, save: save))
    }

    private func calendar(_ zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    func testSeedIsOnSelectedCivilDayAndEditRetainsExactInstantsAndIdentity() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let storage = try store()
        for day in [8, 9, 10] { // spring-forward day has 23 hours
            let selected = date(2026, 3, day, 12, zone: zone)
            let draft = ScheduleEditorDraft(creatingOn: selected, calendar: calendar(zone), in: storage)
            XCTAssertEqual(calendar(zone).component(.day, from: draft.startAt), day)
            XCTAssertEqual(calendar(zone).component(.hour, from: draft.startAt), 9)
            XCTAssertEqual(draft.endAt.timeIntervalSince(draft.startAt), 3_600)
            XCTAssertEqual(draft.invalidFields, [.title])
        }
        let original = try storage.create(input: ScheduleInput(title: "Overnight", startAt: date(2026, 3, 8, 22),
                                                              endAt: date(2026, 3, 11, 3), note: "Old"))
        let edit = ScheduleEditorDraft(editing: original, in: storage)
        XCTAssertEqual(edit.editingID, original.id)
        XCTAssertEqual(edit.startAt, original.startAt)
        XCTAssertEqual(edit.endAt, original.endAt)
        XCTAssertEqual(edit.note, "Old")
        XCTAssertEqual(edit.title, "Overnight")
    }

    func testFieldSpecificValidationRejectsInvalidEndpointsBeforeAnyWrite() throws {
        let storage = try store()
        let draft = ScheduleEditorDraft(creatingOn: date(2026, 2, 17), calendar: calendar(), in: storage)
        draft.startAt = Date(timeIntervalSinceReferenceDate: .infinity)
        draft.endAt = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertEqual(draft.invalidFields, [.title, .start, .end])
        draft.title = "Valid"
        draft.startAt = date(2026, 2, 17, 12)
        draft.endAt = draft.startAt
        XCTAssertEqual(draft.invalidFields, [.end])
        draft.submit { _ in XCTFail("Equal endpoints submitted") }
        draft.endAt = date(2026, 2, 17, 11)
        XCTAssertEqual(draft.invalidFields, [.end])
        draft.submit { _ in XCTFail("Reversed endpoints submitted") }
        XCTAssertTrue(storage.snapshots.isEmpty)
        XCTAssertTrue(try storage.repository.fetchAll().isEmpty)
        draft.endAt = date(2026, 2, 19, 10)
        XCTAssertTrue(draft.canSubmit) // Multi-day ranges are allowed.
    }

    func testCancelAndEditTimeNeverChangeOriginals() throws {
        let storage = try store()
        let original = try storage.create(input: ScheduleInput(title: "Original", startAt: date(2026, 4, 2, 9),
                                                              endAt: date(2026, 4, 2, 10)))
        let create = ScheduleEditorDraft(creatingOn: date(2026, 4, 2), calendar: calendar(), in: storage)
        create.title = "Discarded"
        create.cancel()
        create.submit { _ in XCTFail("Canceled create") }
        let edit = ScheduleEditorDraft(editing: original, in: storage)
        edit.title = "Changed"
        edit.startAt = date(2026, 4, 3, 8)
        edit.cancel()
        edit.submit { _ in XCTFail("Canceled edit") }
        XCTAssertEqual(try storage.repository.fetchAll(), [original])
        XCTAssertEqual(storage.snapshots, [original])
    }

    func testFailedSaveKeepsEveryFieldThenRetriesOnceWithNormalizedNote() throws {
        var fail = true
        let storage = try store(save: { context in
            if fail { throw InjectedFailure.save }
            try context.save()
        })
        let draft = ScheduleEditorDraft(creatingOn: date(2026, 4, 2), calendar: calendar(), in: storage)
        draft.title = "  Overnight  "
        draft.note = " \n "
        draft.startAt = date(2026, 4, 2, 22)
        draft.endAt = date(2026, 4, 4, 2)
        var successes = 0
        draft.submit { _ in successes += 1 }
        XCTAssertEqual(draft.saveError, .persistence)
        XCTAssertEqual(draft.title, "  Overnight  ")
        XCTAssertEqual(draft.note, " \n ")
        XCTAssertEqual(draft.startAt, date(2026, 4, 2, 22))
        XCTAssertEqual(draft.endAt, date(2026, 4, 4, 2))
        XCTAssertTrue(draft.canSubmit)
        XCTAssertEqual(successes, 0)
        XCTAssertTrue(try storage.repository.fetchAll().isEmpty)
        fail = false
        draft.submit { saved in
            successes += 1
            draft.submit { _ in XCTFail("Reentrant submit") }
            XCTAssertEqual(saved.title, "Overnight")
            XCTAssertNil(saved.note)
            XCTAssertEqual(saved.startAt, date(2026, 4, 2, 22))
            XCTAssertEqual(saved.endAt, date(2026, 4, 4, 2))
        }
        draft.submit { _ in XCTFail("Second create") }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try storage.repository.fetchAll().count, 1)
        XCTAssertFalse(draft.canSubmit)
    }

    func testInitialOverlapEditTimeAndCancelLeavePeerUnchanged() throws {
        let storage = try store()
        let peer = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 10),
                                                          endAt: date(2026, 5, 1, 12)))
        let draft = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        draft.title = "New"
        draft.startAt = date(2026, 5, 1, 11)
        draft.endAt = date(2026, 5, 1, 13)
        draft.submit { _ in XCTFail("Unreviewed overlap") }
        XCTAssertEqual(draft.overlapReview?.conflicts.map(\.block.id), [peer.id])
        XCTAssertTrue(draft.canKeepBoth)
        draft.editTime()
        XCTAssertNil(draft.overlapReview)
        XCTAssertFalse(draft.canKeepBoth)
        XCTAssertEqual(draft.startAt, date(2026, 5, 1, 11))
        draft.submit { _ in XCTFail("Unreviewed overlap") }
        draft.cancel()
        draft.keepBoth { _ in XCTFail("Canceled approval") }
        XCTAssertEqual(try storage.repository.fetchAll(), [peer])
    }

    func testKeepBothCommitsOnceAndChangingAnyFieldRevokesApproval() throws {
        let storage = try store()
        let peer = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 10),
                                                          endAt: date(2026, 5, 1, 12)))
        let draft = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        draft.title = "New"
        draft.startAt = date(2026, 5, 1, 11)
        draft.endAt = date(2026, 5, 1, 13)
        draft.submit { _ in XCTFail("Unreviewed overlap") }
        draft.note = "note"
        XCTAssertNil(draft.overlapReview)
        draft.keepBoth { _ in XCTFail("Changed draft approved") }
        draft.submit { _ in XCTFail("Unreviewed overlap") }
        XCTAssertTrue(draft.canKeepBoth)
        var successes = 0
        draft.keepBoth { saved in
            successes += 1
            draft.keepBoth { _ in XCTFail("Reentrant Keep both") }
            XCTAssertEqual(saved.note, "note")
        }
        draft.keepBoth { _ in XCTFail("Repeated Keep both") }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try storage.repository.fetchAll().count, 2)
        XCTAssertEqual(try storage.repository.fetchAll().first(where: { $0.id == peer.id }), peer)
    }

    func testChangedPeersRefreshDecisionAndMissingEditNeverCreates() throws {
        let storage = try store()
        let peer = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 10),
                                                          endAt: date(2026, 5, 1, 12)))
        let draft = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        draft.title = "New"
        draft.startAt = date(2026, 5, 1, 11)
        draft.endAt = date(2026, 5, 1, 13)
        draft.submit { _ in XCTFail("Unreviewed overlap") }
        let oldReview = draft.overlapReview
        let changed = try storage.update(id: peer.id, input: ScheduleInput(title: "Moved peer",
                                                     startAt: peer.startAt, endAt: peer.endAt))
        draft.keepBoth { _ in XCTFail("Stale approval") }
        XCTAssertNotEqual(draft.overlapReview, oldReview)
        XCTAssertEqual(draft.overlapReview?.conflicts.map(\.block), [changed])
        XCTAssertEqual(try storage.repository.fetchAll(), [changed])
        draft.keepBoth { _ in }
        XCTAssertEqual(try storage.repository.fetchAll().count, 2)

        let edit = ScheduleEditorDraft(editing: changed, in: storage)
        try storage.delete(id: changed.id)
        edit.title = "Do not resurrect"
        edit.submit { _ in XCTFail("Missing edit") }
        XCTAssertEqual(edit.saveError, .notFound)
        XCTAssertEqual(edit.editingID, changed.id)
        XCTAssertEqual(edit.title, "Do not resurrect")
        XCTAssertEqual(try storage.repository.fetchAll().count, 1)
    }

    func testFailedEditPreservesOriginalAndAllUnsavedFieldsUntilRetry() throws {
        var fail = false
        let storage = try store(save: { context in
            if fail { throw InjectedFailure.save }
            try context.save()
        })
        let original = try storage.create(input: ScheduleInput(title: "Original", startAt: date(2026, 5, 1, 9),
                                                              endAt: date(2026, 5, 1, 10), note: "Old"))
        let draft = ScheduleEditorDraft(editing: original, in: storage)
        draft.title = "  Moved  "
        draft.startAt = date(2026, 5, 2, 23)
        draft.endAt = date(2026, 5, 4, 1)
        draft.note = "  Updated  "
        fail = true
        draft.submit { _ in XCTFail("Failed edit committed") }
        XCTAssertEqual(draft.saveError, .persistence)
        XCTAssertEqual(draft.editingID, original.id)
        XCTAssertEqual(draft.title, "  Moved  ")
        XCTAssertEqual(draft.startAt, date(2026, 5, 2, 23))
        XCTAssertEqual(draft.endAt, date(2026, 5, 4, 1))
        XCTAssertEqual(draft.note, "  Updated  ")
        XCTAssertEqual(try storage.repository.fetchAll(), [original])
        fail = false
        draft.submit { saved in
            XCTAssertEqual(saved.id, original.id)
            XCTAssertEqual(saved.title, "Moved")
            XCTAssertEqual(saved.note, "Updated")
            XCTAssertEqual(saved.endAt, date(2026, 5, 4, 1))
        }
        XCTAssertEqual(try storage.repository.fetchAll().count, 1)
    }

    func testFailedKeepBothRetainsReviewForExplicitRetryAndVanishedPeerRequiresNormalSave() throws {
        var fail = false
        let storage = try store(save: { context in
            if fail { throw InjectedFailure.save }
            try context.save()
        })
        let peer = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 10),
                                                          endAt: date(2026, 5, 1, 12)))
        let draft = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        draft.title = "New"
        draft.startAt = date(2026, 5, 1, 11)
        draft.endAt = date(2026, 5, 1, 13)
        draft.submit { _ in XCTFail("Unreviewed overlap") }
        fail = true
        draft.keepBoth { _ in XCTFail("Failed confirmation") }
        XCTAssertEqual(draft.saveError, .persistence)
        XCTAssertTrue(draft.canKeepBoth)
        XCTAssertEqual(draft.title, "New")
        XCTAssertEqual(try storage.repository.fetchAll(), [peer])
        fail = false
        draft.keepBoth { _ in }
        XCTAssertEqual(try storage.repository.fetchAll().count, 2)

        let other = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        other.title = "Other"
        other.startAt = date(2026, 5, 1, 10)
        other.endAt = date(2026, 5, 1, 11)
        other.submit { _ in XCTFail("Unreviewed overlap") }
        try storage.delete(id: peer.id)
        // The remaining New block starts at 11; this draft now has no conflicts.
        other.keepBoth { _ in XCTFail("Vanished conflict approved") }
        XCTAssertNil(other.overlapReview)
        XCTAssertFalse(other.canKeepBoth)
        XCTAssertEqual(try storage.repository.fetchAll().count, 1)
        other.submit { _ in }
        XCTAssertEqual(try storage.repository.fetchAll().count, 2)
    }

    func testIndependentDraftsNeverShareUnsavedFieldsOrApproval() throws {
        let storage = try store()
        _ = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 10),
                                                    endAt: date(2026, 5, 1, 12)))
        let first = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        let second = ScheduleEditorDraft(creatingOn: date(2026, 5, 2), calendar: calendar(), in: storage)
        first.title = "First"
        first.startAt = date(2026, 5, 1, 11)
        first.endAt = date(2026, 5, 1, 13)
        first.submit { _ in XCTFail("Overlap") }
        second.title = "Second"
        XCTAssertNil(second.overlapReview)
        XCTAssertEqual(second.startAt, date(2026, 5, 2, 9))
        second.cancel()
        XCTAssertEqual(first.title, "First")
        XCTAssertTrue(first.canKeepBoth)
        XCTAssertEqual(try storage.repository.fetchAll().count, 1)
    }
}
