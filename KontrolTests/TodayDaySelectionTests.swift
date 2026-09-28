import AppKit
import Foundation
import XCTest
@testable import Kontrol

@MainActor
final class TodayDaySelectionTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let ny = TimeZone(identifier: "America/New_York")!

    private func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func context(_ now: Date, _ zone: TimeZone,
                         _ calendar: Calendar = Calendar(identifier: .gregorian)) -> TaskTemporalContext {
        TaskTemporalContext(now: now, calendar: calendar, timeZone: zone)
    }

    private func day(_ selection: TodayDaySelection, _ context: TaskTemporalContext,
                     calendarIdentifier: Calendar.Identifier = .gregorian) -> DateComponents? {
        guard let date = selection.selectedDate(in: context) else { return nil }
        var calendar = Calendar(identifier: calendarIdentifier)
        calendar.timeZone = context.timeZone
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    private func assertDay(_ selection: TodayDaySelection, _ context: TaskTemporalContext,
                           _ year: Int, _ month: Int, _ date: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        let parts = day(selection, context)
        XCTAssertEqual(parts?.year, year, file: file, line: line)
        XCTAssertEqual(parts?.month, month, file: file, line: line)
        XCTAssertEqual(parts?.day, date, file: file, line: line)
    }

    func testRelativeTodayRollsAtMidnightAndReturnToTodayResumesFollowingClock() {
        var selection = TodayDaySelection()
        let before = context(instant("2026-06-05T23:59:59Z"), utc)
        let after = context(instant("2026-06-06T00:00:00Z"), utc)
        XCTAssertTrue(selection.followsToday)
        XCTAssertEqual(selection.selectedDate(in: before), before.now)
        assertDay(selection, before, 2026, 6, 5)
        assertDay(selection, after, 2026, 6, 6)

        selection.previous(in: after)
        XCTAssertFalse(selection.followsToday)
        assertDay(selection, after, 2026, 6, 5)
        assertDay(selection, context(instant("2026-06-09T12:00:00Z"), utc), 2026, 6, 5)
        selection.returnToToday()
        XCTAssertTrue(selection.followsToday)
        assertDay(selection, context(instant("2026-06-09T12:00:00Z"), utc), 2026, 6, 9)
    }

    func testDSTNavigationUsesCivilDaysAcrossTwentyThreeAndTwentyFiveHourDays() {
        for (start, expected, nextBoundary, length) in [
            ("2026-03-08T17:00:00Z", "2026-03-09T16:00:00Z", "2026-03-10T04:00:00Z", 23.0),
            ("2026-11-01T17:00:00Z", "2026-11-02T17:00:00Z", "2026-11-03T05:00:00Z", 25.0)
        ] {
            let temporal = context(instant(start), ny)
            var local = Calendar(identifier: .gregorian)
            local.timeZone = ny
            var selection = TodayDaySelection()
            let today = selection.selectedDate(in: temporal)!
            XCTAssertEqual(local.dateInterval(of: .day, for: today)!.duration, length * 3_600)
            selection.next(in: temporal)
            XCTAssertEqual(selection.selectedDate(in: temporal), instant(expected))
            XCTAssertEqual(local.dateInterval(of: .day, for: selection.selectedDate(in: temporal)!)!.end,
                           instant(nextBoundary))
            selection.previous(in: temporal)
            XCTAssertEqual(day(selection, temporal), local.dateComponents([.year, .month, .day], from: today))
            XCTAssertFalse(selection.followsToday, "navigating back stays explicit until Return to Today")
        }
    }

    func testExplicitCivilDateSurvivesMidnightTravelAndCalendarChange() {
        let initial = context(instant("2026-06-05T23:00:00Z"), utc)
        var selection = TodayDaySelection()
        selection.next(in: initial) // Jun 6 is stored as components, not UTC midnight.
        assertDay(selection, initial, 2026, 6, 6)
        let travel = context(instant("2026-06-07T04:00:00Z"), ny)
        assertDay(selection, travel, 2026, 6, 6)
        XCTAssertEqual(selection.selectedDate(in: travel), instant("2026-06-06T16:00:00Z"))
        let buddhist = context(travel.now, ny, Calendar(identifier: .buddhist))
        assertDay(selection, buddhist, 2026, 6, 6)
        XCTAssertEqual(day(selection, buddhist, calendarIdentifier: .buddhist)?.year, 2569)
        selection.next(in: buddhist)
        assertDay(selection, buddhist, 2026, 6, 7)
        selection.previous(in: buddhist)
        assertDay(selection, buddhist, 2026, 6, 6)
    }

    func testJapaneseEraBoundaryRetainsTheChosenCivilDate() {
        let japanese = Calendar(identifier: .japanese)
        let temporal = context(instant("2019-05-01T12:00:00Z"), utc, japanese)
        var selection = TodayDaySelection()
        selection.previous(in: temporal)
        XCTAssertEqual(selection.selectedDate(in: temporal), instant("2019-04-30T12:00:00Z"))
        selection.next(in: temporal)
        XCTAssertEqual(selection.selectedDate(in: temporal), instant("2019-05-01T12:00:00Z"))
    }

    func testIndependentWindowsAndTemporalNotificationsDoNotWriteTasksOrBlocks() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let center = NotificationCenter()
        var now = instant("2026-06-05T23:59:00Z")
        var zone = utc
        var calendar = Calendar(identifier: .gregorian)
        var fired: (() -> Void)?
        let store = TaskStore(repository: repository, notificationCenter: center,
                              clock: { now }, calendar: { calendar }, timeZone: { zone },
                              scheduleTimer: { _, fire in fired = fire; return {} })
        let task = try store.create(input: TaskInput(title: "Keep", plannedFor: PlannedDay.today(
            at: now, calendar: calendar, timeZone: zone)))
        let schedule = SwiftDataScheduleRepository(container: container)
        let block = try schedule.create(input: ScheduleInput(title: "Keep block", startAt: now,
                                                               endAt: now.addingTimeInterval(3_600)),
                                        allowOverlap: false)
        var first = TodayDaySelection()
        var second = TodayDaySelection()
        first.next(in: store.temporalContext)
        assertDay(first, store.temporalContext, 2026, 6, 6)
        assertDay(second, store.temporalContext, 2026, 6, 5)
        XCTAssertEqual(store.select(.today, selectedDate: second.selectedDate(in: store.temporalContext)!).map(\.id), [task.id])
        XCTAssertTrue(store.select(.today, selectedDate: first.selectedDate(in: store.temporalContext)!).isEmpty)
        for selection in [first, second] {
            XCTAssertEqual(ScheduleSelection.select([block], selectedDate: selection.selectedDate(in: store.temporalContext)!,
                                                    calendar: store.temporalContext.calendar,
                                                    timeZone: store.temporalContext.timeZone), [block])
        }
        now = instant("2026-06-06T00:00:00Z")
        fired?()
        assertDay(first, store.temporalContext, 2026, 6, 6)
        assertDay(second, store.temporalContext, 2026, 6, 6)
        now = instant("2026-06-07T15:00:00Z")
        center.post(name: .NSSystemClockDidChange, object: nil)
        assertDay(first, store.temporalContext, 2026, 6, 6)
        assertDay(second, store.temporalContext, 2026, 6, 7)
        zone = ny
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        assertDay(first, store.temporalContext, 2026, 6, 6)
        calendar = Calendar(identifier: .buddhist)
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        assertDay(first, store.temporalContext, 2026, 6, 6)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        assertDay(first, store.temporalContext, 2026, 6, 6)
        first.returnToToday()
        assertDay(first, store.temporalContext, 2026, 6, 7)
        second.previous(in: store.temporalContext)
        assertDay(second, store.temporalContext, 2026, 6, 6)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [task.id])
        XCTAssertEqual(try schedule.fetchAll().map(\.id), [block.id])
        XCTAssertEqual(try repository.fetchAll().first?.plannedDay, task.plannedDay)
        XCTAssertEqual(try schedule.fetchAll().first, block)
    }
}
