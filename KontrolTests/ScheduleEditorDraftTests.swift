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

    func testMultipleConflictDecisionListsEveryPeerAndStaleReviewReplacesItWithoutWriting() throws {
        let storage = try store()
        let early = try storage.create(input: ScheduleInput(title: "Early", startAt: date(2026, 5, 1, 9),
                                                           endAt: date(2026, 5, 1, 11)))
        let late = try storage.create(input: ScheduleInput(title: "Late", startAt: date(2026, 5, 1, 12),
                                                          endAt: date(2026, 5, 1, 14)))
        let draft = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        draft.title = "Crossing"
        draft.startAt = date(2026, 5, 1, 10)
        draft.endAt = date(2026, 5, 1, 13)
        draft.submit { _ in XCTFail("Initial warning cannot write") }
        XCTAssertEqual(draft.overlapReview?.conflicts, [ScheduleConflict(block: early, duration: 3_600),
                                                        ScheduleConflict(block: late, duration: 3_600)])
        XCTAssertEqual(try storage.repository.fetchAll(), [early, late])
        let changed = try storage.update(id: late.id, input: ScheduleInput(title: "Renamed late",
                                                     startAt: late.startAt, endAt: late.endAt))
        draft.keepBoth { _ in XCTFail("Stale decision cannot write") }
        XCTAssertEqual(draft.overlapReview?.conflicts, [ScheduleConflict(block: early, duration: 3_600),
                                                        ScheduleConflict(block: changed, duration: 3_600)])
        XCTAssertEqual(try storage.repository.fetchAll(), [early, changed])
        draft.editTime()
        XCTAssertNil(draft.overlapReview)
        XCTAssertEqual(try storage.repository.fetchAll(), [early, changed])
        draft.submit { _ in XCTFail("Fresh warning cannot write") }
        draft.keepBoth { saved in XCTAssertEqual(saved.title, "Crossing") }
        let crossing = try XCTUnwrap(storage.snapshots.first { $0.title == "Crossing" })
        XCTAssertEqual(TodayView.overlaps(for: crossing, in: storage.snapshots).map(\.block.id),
                       [early.id, changed.id])
        XCTAssertEqual(TodayView.overlaps(for: early, in: storage.snapshots).map(\.block.id),
                       [crossing.id])
        XCTAssertEqual(try storage.repository.fetchAll().filter { $0.id == early.id }, [early])
        XCTAssertEqual(try storage.repository.fetchAll().filter { $0.id == changed.id }, [changed])
        XCTAssertEqual(try storage.repository.fetchAll().count, 3)
    }

    func testOverlapRowsIncludeCrossDayPeersAndElapsedDurationIsNotWallClockDuration() throws {
        let storage = try store()
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let first = date(2026, 3, 7, 23, zone: zone)
        let peer = try storage.create(input: ScheduleInput(title: "Overnight", startAt: first,
                                                            endAt: date(2026, 3, 8, 4, zone: zone)))
        let next = try storage.create(input: ScheduleInput(title: "Morning", startAt: date(2026, 3, 8, 4, zone: zone),
                                                            endAt: date(2026, 3, 8, 5, zone: zone)))
        let candidate = ScheduleSnapshot(id: UUID(), title: "Crossing", startAt: date(2026, 3, 8, 1, zone: zone),
                                         endAt: date(2026, 3, 8, 4, zone: zone))
        let conflicts = TodayView.overlaps(for: candidate, in: [peer, next, candidate])
        XCTAssertEqual(conflicts, [ScheduleConflict(block: peer, duration: 7_200)])
        XCTAssertEqual(ScheduleEditorView.overlapDurationLabel(conflicts[0].duration), "2 hr")
        XCTAssertEqual(ScheduleEditorView.overlapDurationLabel(90), "1 min 30 sec")
        XCTAssertEqual(ScheduleEditorView.overlapDurationLabel(0.5),
                       "\(0.5.formatted(.number.precision(.fractionLength(0...3)))) sec")
    }

    func testEndpointLabelsDisambiguateFallBackAndShowBothOvernightDates() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let localCalendar = calendar(zone)
        let locale = Locale(identifier: "en_US")
        let first = Date(timeIntervalSince1970: 1_793_511_000) // 2026-11-01 05:30 UTC
        let second = first.addingTimeInterval(3_600)
        let firstLabel = ScheduleEditorView.endpointLabel(first, calendar: localCalendar,
                                                          timeZone: zone, locale: locale)
        let secondLabel = ScheduleEditorView.endpointLabel(second, calendar: localCalendar,
                                                           timeZone: zone, locale: locale)
        XCTAssertTrue(firstLabel.contains("UTC−04:00"), firstLabel)
        XCTAssertTrue(secondLabel.contains("UTC−05:00"), secondLabel)
        XCTAssertNotEqual(firstLabel, secondLabel)

        let storage = try store()
        let original = try storage.create(input: ScheduleInput(title: "Overnight", startAt: first,
                                                              endAt: date(2026, 11, 2, 3, zone: zone)))
        let draft = ScheduleEditorDraft(editing: original, in: storage)
        let startLabel = ScheduleEditorView.endpointLabel(draft.startAt, calendar: localCalendar,
                                                          timeZone: zone, locale: locale)
        let endLabel = ScheduleEditorView.endpointLabel(draft.endAt, calendar: localCalendar,
                                                        timeZone: zone, locale: locale)
        XCTAssertTrue(startLabel.contains("November 1"), startLabel)
        XCTAssertTrue(endLabel.contains("November 2"), endLabel)
        let utcLabel = ScheduleEditorView.endpointLabel(draft.startAt, calendar: calendar(),
                                                        timeZone: TimeZone(secondsFromGMT: 0)!, locale: locale)
        XCTAssertNotEqual(utcLabel, startLabel)
        XCTAssertEqual(draft.startAt, original.startAt) // Reformatting after travel cannot move an instant.
        XCTAssertEqual(draft.endAt, original.endAt)
        XCTAssertEqual(try storage.repository.fetchAll(), [original])
    }

    func testPickerSelectedInstantsStayInDraftAfterFailedEditAndCancel() throws {
        var fail = false
        let storage = try store(save: { context in
            if fail { throw InjectedFailure.save }
            try context.save()
        })
        let original = try storage.create(input: ScheduleInput(title: "Original", startAt: date(2026, 3, 7, 9),
                                                              endAt: date(2026, 3, 7, 10)))
        let draft = ScheduleEditorDraft(editing: original, in: storage)
        // Dates supplied by a native picker are already resolved instants, even on a 23-hour day.
        let normalized = date(2026, 3, 8, 3, zone: TimeZone(identifier: "America/New_York")!)
        draft.startAt = normalized
        draft.endAt = normalized.addingTimeInterval(3_600)
        draft.note = "still here"
        fail = true
        draft.submit { _ in XCTFail("Failed save") }
        XCTAssertEqual(draft.saveError, .persistence)
        XCTAssertEqual(draft.startAt, normalized)
        XCTAssertEqual(draft.endAt, normalized.addingTimeInterval(3_600))
        XCTAssertEqual(draft.note, "still here")
        draft.cancel()
        XCTAssertEqual(try storage.repository.fetchAll(), [original])
    }

    func testDeletionRequiresConfirmationNamesCommittedBlockAndCancelPreservesEverything() throws {
        let storage = try store()
        let target = try storage.create(input: ScheduleInput(title: "Original", startAt: date(2026, 5, 1, 9),
                                                              endAt: date(2026, 5, 1, 10)))
        let peer = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 11),
                                                            endAt: date(2026, 5, 1, 12)))
        let create = ScheduleEditorDraft(creatingOn: date(2026, 5, 1), calendar: calendar(), in: storage)
        XCTAssertNil(create.deletionTitle)
        XCTAssertFalse(create.canRequestDeletion)
        create.requestDeletion()
        create.confirmDeletion { XCTFail("Create cannot delete") }

        let edit = ScheduleEditorDraft(editing: target, in: storage)
        edit.title = "Unsaved rename"
        edit.note = "Unsaved note"
        XCTAssertEqual(edit.deletionTitle, "Original")
        edit.confirmDeletion { XCTFail("No confirmation") }
        XCTAssertEqual(try storage.repository.fetchAll(), [target, peer])
        edit.requestDeletion()
        XCTAssertTrue(edit.deletionRequested)
        XCTAssertFalse(edit.canSubmit)
        XCTAssertEqual(try storage.repository.fetchAll(), [target, peer])
        edit.cancelDeletion()
        edit.confirmDeletion { XCTFail("Canceled confirmation") }
        XCTAssertEqual(edit.title, "Unsaved rename")
        XCTAssertEqual(try storage.repository.fetchAll(), [target, peer])
        edit.cancel()
        edit.requestDeletion()
        XCTAssertFalse(edit.deletionRequested)
        XCTAssertEqual(try storage.repository.fetchAll(), [target, peer])
    }

    func testFailedDeletionRetainsDraftAndBlockUntilExplicitReconfirmation() throws {
        var fail = false
        let storage = try store(save: { context in
            if fail { throw InjectedFailure.save }
            try context.save()
        })
        let target = try storage.create(input: ScheduleInput(title: "Original", startAt: date(2026, 5, 1, 9),
                                                              endAt: date(2026, 5, 1, 10)))
        let peer = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 11),
                                                            endAt: date(2026, 5, 1, 12)))
        let edit = ScheduleEditorDraft(editing: target, in: storage)
        edit.title = "Unsaved"
        edit.startAt = date(2026, 5, 2, 9)
        edit.note = "Still here"
        fail = true
        edit.requestDeletion()
        var callbacks = 0
        edit.confirmDeletion { callbacks += 1 }
        XCTAssertEqual(edit.deleteError, .persistence)
        XCTAssertFalse(edit.deletionRequested)
        XCTAssertEqual(callbacks, 0)
        edit.confirmDeletion { XCTFail("Failure cannot auto-retry") }
        XCTAssertEqual(edit.title, "Unsaved")
        XCTAssertEqual(edit.startAt, date(2026, 5, 2, 9))
        XCTAssertEqual(edit.note, "Still here")
        XCTAssertEqual(storage.snapshots, [target, peer])
        XCTAssertEqual(try storage.repository.fetchAll(), [target, peer])
        fail = false
        edit.requestDeletion()
        edit.confirmDeletion {
            callbacks += 1
            edit.requestDeletion()
            edit.confirmDeletion { XCTFail("Reentrant delete") }
        }
        edit.confirmDeletion { XCTFail("Repeated delete") }
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(edit.deleteError)
        XCTAssertFalse(edit.canRequestDeletion)
        XCTAssertEqual(storage.snapshots, [peer])
        XCTAssertEqual(try storage.repository.fetchAll(), [peer])
    }

    func testMissingDeletionRefreshesAndOffersSafeDismissalWithoutRecreatingRow() throws {
        let storage = try store()
        let target = try storage.create(input: ScheduleInput(title: "Removed elsewhere",
                                                              startAt: date(2026, 5, 1, 9),
                                                              endAt: date(2026, 5, 1, 10)))
        let peer = try storage.create(input: ScheduleInput(title: "Peer", startAt: date(2026, 5, 1, 11),
                                                            endAt: date(2026, 5, 1, 12)))
        let edit = ScheduleEditorDraft(editing: target, in: storage)
        edit.note = "Unsaved"
        try storage.repository.delete(id: target.id) // Simulate a different owner/process.
        edit.requestDeletion()
        edit.confirmDeletion { XCTFail("Missing target deleted") }
        XCTAssertEqual(edit.deleteError, .notFound)
        XCTAssertFalse(edit.canRequestDeletion)
        XCTAssertFalse(edit.canSubmit)
        XCTAssertEqual(edit.note, "Unsaved")
        XCTAssertEqual(storage.readState, .loaded)
        XCTAssertEqual(storage.snapshots, [peer], "Missing ID triggers a safe refresh")
        XCTAssertEqual(try storage.repository.fetchAll(), [peer])
        XCTAssertTrue(edit.cancel()) // Close editor, never insert a replacement.
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
