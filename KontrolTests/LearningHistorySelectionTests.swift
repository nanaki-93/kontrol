import Foundation
import XCTest
@testable import Kontrol

final class LearningHistorySelectionTests: XCTestCase {
    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private let english = Locale(identifier: "en_US")
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                      _ minute: Int = 0, zone: TimeZone) -> Date {
        var local = calendar
        local.timeZone = zone
        return local.date(from: DateComponents(year: year, month: month, day: day,
                                               hour: hour, minute: minute))!
    }

    private func civil(_ year: Int, _ month: Int, _ day: Int) -> HistoryLocalDate {
        HistoryLocalDate(year: year, month: month, day: day)
    }

    private func row(_ id: String, _ at: Date, _ status: LessonProgressStatus = .completed,
                     topic: String? = "math") -> LessonHistorySnapshot {
        LessonHistorySnapshot(lessonID: id, status: status, date: at, title: id,
                              topicID: topic, content: .unavailable, attempt: nil)
    }

    private func select(_ rows: [LessonHistorySnapshot], _ filters: LearningHistoryFilters = .init(),
                        now: Date, zone: TimeZone? = nil, locale: Locale? = nil) throws -> [LearningHistoryDayGroup] {
        try LearningHistorySelection.select(rows, filters: filters, now: now, calendar: calendar,
                                            timeZone: zone ?? newYork, locale: locale ?? english).get()
    }

    func testTopicUnknownStatusDateIntersectionAndStableTieOrdering() throws {
        let now = date(2026, 3, 10, 12, zone: newYork)
        let same = date(2026, 3, 10, 9, zone: newYork)
        let rows = [row("z", same, topic: nil), row("b", same),
                    row("a", same), row("dismissed", same, .dismissed),
                    row("old", date(2026, 3, 9, zone: newYork)),
                    row("other", same, topic: "science"),
                    row("not-terminal", same, .started)]
        var filters = LearningHistoryFilters(topic: .topic("math"), status: .completed, date: .today)
        let result = try select(rows, filters, now: now)
        XCTAssertEqual(result.map(\.rows.count), [2])
        XCTAssertEqual(result[0].rows.map(\.lessonID), ["a", "b"])
        XCTAssertEqual(result[0].label, "Today")
        filters.topic = .unknown
        filters.status = .all
        XCTAssertEqual(try select(rows, filters, now: now).flatMap(\.rows).map(\.lessonID), ["z"])
        filters.topic = .all
        filters.status = .dismissed
        XCTAssertEqual(try select(rows, filters, now: now).flatMap(\.rows).map(\.lessonID), ["dismissed"])
        XCTAssertEqual(try select(rows, .init(), now: now).map(\.rows.count), [5, 1])
        XCTAssertEqual(try select(rows, .init(), now: now)[1].label, "Yesterday")
        XCTAssertTrue(try select([], now: now).isEmpty)
    }

    func testMidnightAndInclusiveCustomEndUsesExclusiveNextMidnight() throws {
        let first = date(2026, 3, 8, zone: newYork)
        let last = date(2026, 3, 10, zone: newYork)
        let rows = [row("before", first.addingTimeInterval(-1)), row("first", first),
                    row("last-second", last.addingTimeInterval(-1)), row("end", last),
                    row("after", date(2026, 3, 11, zone: newYork))]
        let custom = LearningHistoryFilters(date: .custom(start: civil(2026, 3, 8), end: civil(2026, 3, 10)))
        XCTAssertEqual(try select(rows, custom, now: last).flatMap(\.rows).map(\.lessonID),
                       ["end", "last-second", "first"])
        let today = LearningHistoryFilters(date: .today)
        XCTAssertEqual(try select(rows, today, now: last).flatMap(\.rows).map(\.lessonID), ["end"])
        XCTAssertEqual(try select(rows, today, now: first).flatMap(\.rows).map(\.lessonID),
                       ["first"])
    }

    func testLastSevenDaysIncludesSixPrecedingCivilDaysAcrossSpringDST() throws {
        let now = date(2026, 3, 10, 12, zone: newYork)
        let first = date(2026, 3, 4, zone: newYork)
        let next = date(2026, 3, 11, zone: newYork)
        let rows = [row("outside", first.addingTimeInterval(-1)), row("first", first),
                    row("spring", date(2026, 3, 8, 23, zone: newYork)),
                    row("today", date(2026, 3, 10, 23, zone: newYork)), row("next", next)]
        let result = try select(rows, .init(date: .lastSevenDays), now: now)
        XCTAssertEqual(result.flatMap(\.rows).map(\.lessonID), ["today", "spring", "first"])
        XCTAssertEqual(result[1].day.duration, 23 * 3600)
        XCTAssertEqual(result.map(\.label).prefix(1), ["Today"])
    }

    func testFallDSTAndZoneChangeRegroupSameAbsoluteDatesAndPreserveCivilSelection() throws {
        let now = date(2026, 11, 1, 12, zone: newYork)
        let midnight = date(2026, 11, 1, zone: newYork)
        let following = date(2026, 11, 2, zone: newYork)
        let nearMidnight = row("near-midnight", date(2026, 11, 1, 23, 30, zone: newYork))
        let rows = [row("start", midnight), nearMidnight, row("next", following)]
        let local = try select(rows, .init(date: .today), now: now)
        XCTAssertEqual(local.flatMap(\.rows).map(\.lessonID), ["near-midnight", "start"])
        XCTAssertEqual(local[0].day.duration, 25 * 3600)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let elsewhere = try select(rows, .init(date: .today), now: now, zone: tokyo)
        XCTAssertEqual(elsewhere.flatMap(\.rows).map(\.lessonID), ["next", "near-midnight"])
        let chosen = LearningHistoryFilters(date: .custom(start: civil(2026, 11, 1), end: civil(2026, 11, 1)))
        XCTAssertEqual(try select(rows, chosen, now: now, zone: tokyo).flatMap(\.rows).map(\.lessonID), ["start"])
        XCTAssertEqual(rows[1].date, nearMidnight.date) // selection never rewrites a stored instant
        XCTAssertEqual(HistoryLocalDate(midnight, calendar: calendar, timeZone: newYork), civil(2026, 11, 1))
    }

    func testReversedAndInvalidCustomDatesAreClassifiedEvenWithNoRows() {
        let now = date(2026, 3, 10, zone: newYork)
        let reversed = LearningHistoryFilters(date: .custom(start: civil(2026, 3, 11), end: civil(2026, 3, 10)))
        XCTAssertEqual(LearningHistorySelection.select([], filters: reversed, now: now, calendar: calendar,
            timeZone: newYork, locale: english), .failure(.reversedCustomRange))
        let invalid = LearningHistoryFilters(date: .custom(start: civil(2026, 2, 30), end: civil(2026, 3, 10)))
        XCTAssertEqual(LearningHistorySelection.select([], filters: invalid, now: now, calendar: calendar,
            timeZone: newYork, locale: english), .failure(.invalidLocalDate))
    }

    func testDayLabelsRespectInjectedLocaleAndOlderDaysUseLocalDates() throws {
        let now = date(2026, 3, 10, 12, zone: newYork)
        let rows = [row("today", now), row("yesterday", date(2026, 3, 9, zone: newYork)),
                    row("older", date(2026, 2, 28, zone: newYork))]
        let french = try select(rows, now: now, locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(french.map(\.label).prefix(2), ["Aujourd’hui", "Hier"])
        XCTAssertTrue(french[2].label.contains("février"))
        XCTAssertEqual(french.map(\.rows.first!.lessonID), ["today", "yesterday", "older"])
    }
}
