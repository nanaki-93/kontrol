import Foundation
import XCTest
@testable import Kontrol

final class ScheduleSelectionTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let ny = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func block(_ number: Int, _ start: String, _ end: String) -> ScheduleSnapshot {
        ScheduleSnapshot(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
                         title: "Block \(number)", startAt: date(start), endAt: date(end))
    }

    private func ids(_ blocks: [ScheduleSnapshot], _ selected: String,
                     _ zone: TimeZone) -> [UUID] {
        ScheduleSelection.select(blocks, selectedDate: date(selected), calendar: calendar,
                                 timeZone: zone).map(\.id)
    }

    func testValidationNormalizesTitleAndOptionalNoteWithoutChangingInput() throws {
        let start = date("2026-06-05T10:00:00Z")
        let end = date("2026-06-07T10:00:00Z")
        let input = ScheduleInput(title: " \n Plan \t", startAt: start, endAt: end,
                                  note: " \n details \t")
        let normalized = try input.validated()
        XCTAssertEqual(normalized, ScheduleInput(title: "Plan", startAt: start, endAt: end,
                                                 note: "details"))
        XCTAssertEqual(input.title, " \n Plan \t")
        XCTAssertNil(try ScheduleInput(title: "Plan", startAt: start, endAt: end,
                                       note: " \t\n ").validated().note)
        XCTAssertNil(try ScheduleInput(title: "Plan", startAt: start, endAt: end)
            .validated().note)
    }

    func testValidationPreservesOptionalLessonIDAndEqualityDistinguishesLinks() throws {
        let start = date("2026-06-05T10:00:00Z")
        let end = start.addingTimeInterval(3600)
        let linked = ScheduleInput(title: " Study ", startAt: start, endAt: end,
                                   note: " Note ", lessonID: "lesson-1")
        XCTAssertEqual(try linked.validated(), ScheduleInput(title: "Study", startAt: start,
            endAt: end, note: "Note", lessonID: "lesson-1"))
        XCTAssertEqual(linked.lessonID, "lesson-1")
        XCTAssertNotEqual(linked, ScheduleInput(title: " Study ", startAt: start, endAt: end,
                                                note: " Note ", lessonID: "lesson-2"))
        XCTAssertNotEqual(linked, ScheduleInput(title: " Study ", startAt: start, endAt: end,
                                                note: " Note "))
        XCTAssertNil(try ScheduleInput(title: "Study", startAt: start, endAt: end)
            .validated().lessonID)
    }

    func testValidationRejectsBlankAndNonFiniteOrUnorderedEndpoints() {
        let start = date("2026-06-05T10:00:00Z")
        let end = start.addingTimeInterval(60)
        func expect(_ input: ScheduleInput, _ error: ScheduleValidationError,
                    file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try input.validated(), file: file, line: line) {
                XCTAssertEqual($0 as? ScheduleValidationError, error, file: file, line: line)
            }
        }
        expect(ScheduleInput(title: " \t\n ", startAt: start, endAt: end), .emptyTitle)
        expect(ScheduleInput(title: "OK", startAt: Date(timeIntervalSinceReferenceDate: .nan),
                             endAt: end), .invalidStart)
        expect(ScheduleInput(title: "OK", startAt: start,
                             endAt: Date(timeIntervalSinceReferenceDate: .infinity)), .invalidEnd)
        expect(ScheduleInput(title: "OK", startAt: start, endAt: start), .endNotAfterStart)
        expect(ScheduleInput(title: "OK", startAt: end, endAt: start), .endNotAfterStart)
    }

    func testSnapshotCopiesAllFieldsWithoutRetainingModel() {
        let model = ScheduleBlock(id: UUID(), title: "Original",
                                  startAt: date("2026-06-05T10:00:00Z"),
                                  endAt: date("2026-06-05T11:00:00Z"), note: "Private",
                                  lessonID: "missing-lesson", linkedTitleSnapshot: "Old lesson")
        let copy = ScheduleSnapshot(model)
        model.title = "Changed"
        model.note = nil
        model.endAt = date("2026-06-05T12:00:00Z")
        model.lessonID = nil
        model.linkedTitleSnapshot = nil
        XCTAssertEqual(copy.id, model.id)
        XCTAssertEqual(copy.title, "Original")
        XCTAssertEqual(copy.note, "Private")
        XCTAssertEqual(copy.endAt, date("2026-06-05T11:00:00Z"))
        XCTAssertEqual(copy.lessonID, "missing-lesson")
        XCTAssertEqual(copy.linkedTitleSnapshot, "Old lesson")
    }

    func testOrderingUsesStartThenEndThenUUIDAndDeduplicatesIdentities() {
        let long = block(4, "2026-06-05T10:00:00Z", "2026-06-05T13:00:00Z")
        let short2 = block(2, "2026-06-05T10:00:00Z", "2026-06-05T11:00:00Z")
        let short1 = block(1, "2026-06-05T10:00:00Z", "2026-06-05T11:00:00Z")
        let early = block(3, "2026-06-05T09:00:00Z", "2026-06-05T12:00:00Z")
        XCTAssertEqual(ids([long, short2, early, short1, short2],
                           "2026-06-05T12:00:00Z", utc),
                       [early.id, short1.id, short2.id, long.id])
    }

    func testTouchingIsNotOverlapButContainmentAndMultiplePeersAre() {
        let left = block(1, "2026-06-05T09:00:00Z", "2026-06-05T10:00:00Z")
        let contained = block(2, "2026-06-05T10:15:00Z", "2026-06-05T10:30:00Z")
        let enclosing = block(3, "2026-06-05T09:00:00Z", "2026-06-05T13:00:00Z")
        let right = block(4, "2026-06-05T11:00:00Z", "2026-06-05T12:00:00Z")
        let input = ScheduleInput(title: "Edit", startAt: date("2026-06-05T10:00:00Z"),
                                  endAt: date("2026-06-05T11:00:00Z"))
        XCTAssertNil(ScheduleSelection.intersectionDuration(startAt: input.startAt,
            endAt: input.endAt, withStartAt: left.startAt, endAt: left.endAt))
        XCTAssertNil(ScheduleSelection.intersectionDuration(startAt: input.startAt,
            endAt: input.endAt, withStartAt: right.startAt, endAt: right.endAt))
        let peers = [right, contained, enclosing, left, contained]
        XCTAssertEqual(ScheduleSelection.conflicts(for: input, against: peers),
                       [ScheduleConflict(block: enclosing, duration: 3600),
                        ScheduleConflict(block: contained, duration: 900)])
        XCTAssertEqual(ScheduleSelection.conflicts(for: input, against: peers,
                                                   excluding: enclosing.id),
                       [ScheduleConflict(block: contained, duration: 900)])
        XCTAssertEqual(ScheduleSelection.conflicts(for: input, against: [enclosing],
                                                   excluding: enclosing.id), [])
    }

    func testUTCOvernightMultiDayAndExactMidnightMembership() {
        let overnight = block(1, "2026-06-05T23:00:00Z", "2026-06-06T02:00:00Z")
        let multi = block(2, "2026-06-04T12:00:00Z", "2026-06-07T00:00:00Z")
        let ending = block(3, "2026-06-05T22:00:00Z", "2026-06-06T00:00:00Z")
        let next = block(4, "2026-06-06T00:00:00Z", "2026-06-06T01:00:00Z")
        let rows = [next, overnight, multi, ending]
        XCTAssertEqual(ids(rows, "2026-06-04T18:00:00Z", utc), [multi.id])
        XCTAssertEqual(ids(rows, "2026-06-05T18:00:00Z", utc),
                       [multi.id, ending.id, overnight.id])
        XCTAssertEqual(ids(rows, "2026-06-06T18:00:00Z", utc),
                       [multi.id, overnight.id, next.id])
        XCTAssertEqual(ids(rows, "2026-06-07T18:00:00Z", utc), [])
    }

    func testNewYorkSpringAndFallDaysAre23And25HoursWithRealOverlapDurations() {
        for (selected, start, end, hours) in [
            ("2026-03-08T12:00:00Z", "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23.0),
            ("2026-11-01T12:00:00Z", "2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25.0)
        ] {
            var local = calendar
            local.timeZone = ny
            let day = local.dateInterval(of: .day, for: date(selected))!
            XCTAssertEqual(day.start, date(start))
            XCTAssertEqual(day.end, date(end))
            XCTAssertEqual(day.duration, hours * 3600)
            let fullDay = block(1, start, end)
            let endsAtStart = ScheduleSnapshot(id: UUID(), title: "Earlier",
                startAt: day.start.addingTimeInterval(-3600), endAt: day.start)
            let startsAtEnd = ScheduleSnapshot(id: UUID(), title: "Later", startAt: day.end,
                endAt: day.end.addingTimeInterval(3600))
            XCTAssertEqual(ids([startsAtEnd, fullDay, endsAtStart], selected, ny), [fullDay.id])
            let input = ScheduleInput(title: "Whole day", startAt: day.start, endAt: day.end)
            XCTAssertEqual(ScheduleSelection.conflicts(for: input, against: [fullDay]),
                           [ScheduleConflict(block: fullDay, duration: hours * 3600)])
        }
        let spring = block(2, "2026-03-08T06:30:00Z", "2026-03-08T07:30:00Z")
        let fall = block(3, "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z")
        XCTAssertEqual(ScheduleSelection.conflicts(for: ScheduleInput(title: "Spring",
            startAt: date("2026-03-08T06:45:00Z"), endAt: date("2026-03-08T07:15:00Z")),
            against: [spring]).first?.duration, 1800)
        XCTAssertEqual(ScheduleSelection.conflicts(for: ScheduleInput(title: "Fall",
            startAt: date("2026-11-01T05:45:00Z"), endAt: date("2026-11-01T06:15:00Z")),
            against: [fall]).first?.duration, 1800)
    }

    func testTravelReinterpretsSameInstantsInNewZoneWithoutShiftingStoredValues() {
        let crossing = block(1, "2026-06-05T20:00:00Z", "2026-06-05T23:00:00Z")
        let selected = "2026-06-05T12:00:00Z" // June 5 in both UTC and Tokyo.
        XCTAssertEqual(ids([crossing], selected, utc), [crossing.id])
        XCTAssertEqual(ids([crossing], selected, tokyo), []) // June 6 in Tokyo for block.
        XCTAssertEqual(ids([crossing], "2026-06-06T12:00:00Z", tokyo), [crossing.id])
        XCTAssertEqual(crossing.startAt, date("2026-06-05T20:00:00Z"))
        XCTAssertEqual(crossing.endAt, date("2026-06-05T23:00:00Z"))
    }
}
