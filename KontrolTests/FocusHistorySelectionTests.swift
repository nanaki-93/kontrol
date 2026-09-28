import AppKit
import Foundation
import XCTest
@testable import Kontrol

@MainActor
final class FocusHistorySelectionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                      zone: TimeZone) -> Date {
        var calendar = self.calendar
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute))!
    }

    private func row(_ id: String, _ finish: Date, _ seconds: Double,
                     state: FocusSessionState = .ended) throws -> FocusSessionSnapshot {
        let started = finish.addingTimeInterval(-3600)
        return try FocusSessionSnapshot(id: UUID(uuidString: id)!, state: state,
            plannedSeconds: 3600, accumulatedActiveSeconds: seconds,
            activeSegmentStartedAt: state == .running ? started : nil,
            deadline: state == .running ? started.addingTimeInterval(3600 - seconds) : nil,
            startedAt: started, endedAt: state.isActive ? nil : finish,
            checkpointAt: state.isActive ? started : finish)
    }

    func testFinishDateNotStartDateOrderingAndAggregateBeforeRounding() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        let now = date(2026, 3, 10, 12, 0, zone: zone)
        let midnight = date(2026, 3, 10, 0, 0, zone: zone)
        let older = try row("00000000-0000-0000-0000-000000000003", midnight.addingTimeInterval(-1), 300)
        let first = try row("00000000-0000-0000-0000-000000000002", midnight.addingTimeInterval(30), 30.25)
        let tie = try row("00000000-0000-0000-0000-000000000001", midnight.addingTimeInterval(30), 31.25)
        let active = try row("00000000-0000-0000-0000-000000000004", now, 500, state: .running)
        let result = FocusHistorySelection.select([first, active, older, tie], filter: .recent,
            now: now, calendar: calendar, timeZone: zone)
        XCTAssertEqual(result.groups.map(\.sessions.count), [2, 1])
        XCTAssertEqual(result.groups[0].sessions.map(\.id), [tie.id, first.id])
        XCTAssertEqual(result.todaySeconds, 61.5)
        XCTAssertEqual(result.todayWholeMinutes, 1)
        XCTAssertEqual(FocusHistorySelection.select([first, active, older, tie], filter: .today,
            now: now, calendar: calendar, timeZone: zone).groups.count, 1)
        XCTAssertEqual(FocusHistorySelection.select([older], filter: .thisWeek,
            now: now, calendar: calendar, timeZone: zone).groups.count, 1)
        XCTAssertTrue(FocusHistorySelection.select([], filter: .recent,
            now: now, calendar: calendar, timeZone: zone).groups.isEmpty)
    }

    func testExactMidnightBelongsOnlyToNewLocalDay() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let midnight = date(2026, 3, 9, 0, 0, zone: zone) // after the spring DST change
        let before = try row("00000000-0000-0000-0000-000000000001",
                             midnight.addingTimeInterval(-1), 30)
        let boundary = try row("00000000-0000-0000-0000-000000000002", midnight, 60)
        let nextMidnight = try row("00000000-0000-0000-0000-000000000003",
                                   date(2026, 3, 10, 0, 0, zone: zone), 90)
        let rows = [before, boundary, nextMidnight]
        let yesterday = FocusHistorySelection.select(rows, filter: .today,
            now: date(2026, 3, 8, 12, 0, zone: zone), calendar: calendar, timeZone: zone)
        XCTAssertEqual(yesterday.groups.flatMap(\.sessions), [before])
        XCTAssertEqual(yesterday.todaySeconds, 30)
        let today = FocusHistorySelection.select(rows, filter: .today,
            now: date(2026, 3, 9, 12, 0, zone: zone), calendar: calendar, timeZone: zone)
        XCTAssertEqual(today.groups.flatMap(\.sessions), [boundary])
        XCTAssertEqual(today.todaySeconds, 60)
    }

    func testExactWeekBoundaryBelongsOnlyToNewLocalWeek() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let monday = date(2026, 3, 9, 0, 0, zone: zone)
        let before = try row("00000000-0000-0000-0000-000000000001",
                             monday.addingTimeInterval(-1), 30)
        let boundary = try row("00000000-0000-0000-0000-000000000002", monday, 60)
        let nextMonday = try row("00000000-0000-0000-0000-000000000003",
                                 date(2026, 3, 16, 0, 0, zone: zone), 90)
        let rows = [before, boundary, nextMonday]
        let previousWeek = FocusHistorySelection.select(rows, filter: .thisWeek,
            now: date(2026, 3, 8, 12, 0, zone: zone), calendar: calendar, timeZone: zone)
        XCTAssertEqual(previousWeek.groups.flatMap(\.sessions), [before])
        let currentWeek = FocusHistorySelection.select(rows, filter: .thisWeek,
            now: date(2026, 3, 9, 12, 0, zone: zone), calendar: calendar, timeZone: zone)
        XCTAssertEqual(currentWeek.groups.flatMap(\.sessions), [boundary])
    }

    func testDSTDayIntervalsAndTravelReclassifyWithoutMutatingFinish() throws {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = date(2026, 3, 8, 12, 0, zone: la)
        let start = date(2026, 3, 8, 0, 0, zone: la)
        let nearEnd = date(2026, 3, 8, 23, 59, zone: la)
        XCTAssertEqual(nearEnd.timeIntervalSince(start), 23 * 3600 - 60)
        let session = try row("00000000-0000-0000-0000-000000000001", nearEnd, 45)
        let local = FocusHistorySelection.select([session], filter: .today,
            now: now, calendar: calendar, timeZone: la)
        XCTAssertEqual(local.groups.first?.day.duration, 23 * 3600)
        XCTAssertEqual(local.todaySeconds, 45)
        let early = date(2026, 3, 8, 0, 30, zone: la)
        let traveler = try row("00000000-0000-0000-0000-000000000002", early, 45)
        let traveling = FocusHistorySelection.select([traveler], filter: .today,
            now: now, calendar: calendar, timeZone: tokyo)
        XCTAssertTrue(traveling.groups.isEmpty)
        XCTAssertEqual(traveling.todaySeconds, 0)
        XCTAssertEqual(session.endedAt, nearEnd)
        let week = FocusHistorySelection.select([session], filter: .thisWeek,
            now: now, calendar: calendar, timeZone: la)
        XCTAssertEqual(week.groups.first?.sessions, [session])
    }

    func testFallBackAndWeekBoundaryUseCivilIntervals() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let sunday = date(2026, 11, 1, 12, 0, zone: zone)
        let day = calendarWithZone(zone).dateInterval(of: .day, for: sunday)!
        XCTAssertEqual(day.duration, 25 * 3600)
        let saturday = try row("00000000-0000-0000-0000-000000000001",
                               date(2026, 10, 31, 23, 59, zone: zone), 20)
        let monday = try row("00000000-0000-0000-0000-000000000002",
                             date(2026, 11, 2, 0, 0, zone: zone), 40)
        let result = FocusHistorySelection.select([saturday, monday], filter: .thisWeek,
            now: monday.endedAt!, calendar: calendar, timeZone: zone)
        XCTAssertEqual(result.groups.flatMap(\.sessions), [monday])
        XCTAssertEqual(result.todayWholeMinutes, 0)
    }

    private func calendarWithZone(_ zone: TimeZone) -> Calendar {
        var local = calendar
        local.timeZone = zone
        return local
    }

    func testServiceRefreshesContextWithoutReadingOrWritingHistory() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        var now = date(2026, 3, 10, 23, 59, zone: zone)
        var currentZone = zone
        let finish = now
        let session = try row("00000000-0000-0000-0000-000000000001", finish, 60)
        let repository = HistoryRepository(rows: [session])
        let notifications = NotificationCenter()
        var callbacks: [(Date, () -> Void)] = []
        var cancellations = 0
        let service = FocusService(repository: repository, wallClock: { now },
            notificationCenter: notifications, workspaceNotificationCenter: NotificationCenter(),
            calendar: { self.calendar }, timeZone: { currentZone },
            scheduleMidnight: { boundary, callback in
                callbacks.append((boundary, callback))
                return { cancellations += 1 }
            })
        service.loadIfNeeded()
        XCTAssertEqual(service.history(.today).todayWholeMinutes, 1)
        let old = callbacks.count - 1
        now = date(2026, 3, 11, 0, 1, zone: zone)
        callbacks[old].1()
        XCTAssertEqual(service.history(.today).todayWholeMinutes, 0)
        XCTAssertEqual(callbacks.last?.0, date(2026, 3, 12, 0, 0, zone: zone))
        callbacks[old].1() // superseded callback is inert
        currentZone = TimeZone(secondsFromGMT: -3600)!
        notifications.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(service.history(.today).todayWholeMinutes, 1)
        notifications.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertGreaterThan(cancellations, 0)
        XCTAssertEqual(repository.reads, 1)
        XCTAssertEqual(repository.writes, 0)
        XCTAssertEqual(repository.rows, [session])
        repository.fail = true
        service.retryRead()
        XCTAssertTrue(service.readState.isStale)
        XCTAssertEqual(service.history(.recent).groups.first?.sessions, [session])
        XCTAssertEqual(service.readState, .failed(.persistenceFailure, hasStaleRows: true))
    }

    private final class HistoryRepository: FocusRepository {
        var rows: [FocusSessionSnapshot]
        var reads = 0
        var writes = 0
        var fail = false
        init(rows: [FocusSessionSnapshot]) { self.rows = rows }
        func fetchAll() throws -> [FocusSessionSnapshot] {
            reads += 1
            if fail { throw FocusError.persistenceFailure }
            return rows
        }
        func create(input: FocusStartInput) throws -> FocusSessionSnapshot {
            writes += 1
            throw FocusError.persistenceFailure
        }
        func transition(id: UUID, command: FocusTransition, effectiveEndedAt: Date?) throws -> FocusSessionSnapshot {
            writes += 1
            throw FocusError.persistenceFailure
        }
    }
}
