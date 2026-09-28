import Foundation
import XCTest
@testable import Kontrol

@MainActor
final class TaskSelectionTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let la = TimeZone(identifier: "America/Los_Angeles")!
    private let auckland = TimeZone(identifier: "Pacific/Auckland")!
    private let calendar = Calendar(identifier: .gregorian)

    private func instant(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func task(_ number: Int, created: Date, due: Date? = nil,
                      plan: (Int, Int, Int)? = nil, planZone: TimeZone? = nil,
                      planCalendar: String = "gregorian",
                      completed: Date? = nil) throws -> TaskSnapshot {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        let components = plan.map {
            KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: planCalendar,
                                                  year: $0.0, month: $0.1, day: $0.2)
        }
        return TaskSnapshot(try TaskItem(id: id, title: "Task \(number)", createdAt: created,
                                         dueAt: due, plannedDay: components,
                                         plannedTimeZoneID: components.map { _ in
                                             (planZone ?? utc).identifier
                                         }, completedAt: completed))
    }

    private func ids(_ tasks: [TaskSnapshot], _ filter: TaskFilter,
                     selected: Date, now: Date, zone: TimeZone,
                     calendar: Calendar = Calendar(identifier: .gregorian)) -> [UUID] {
        TaskSelection.select(tasks, filter: filter, selectedDate: selected, now: now,
                             calendar: calendar, timeZone: zone).map(\.id)
    }

    func testOpenFiltersPartitionEveryTaskAndPlanPlusDueAppearsOnce() throws {
        let day = instant("2026-06-05T12:00:00Z")
        let tomorrow = instant("2026-06-06T00:00:00Z")
        let rows = try [
            task(1, created: day, plan: (2026, 6, 5)),
            task(2, created: day, due: day, plan: (2026, 6, 5)),
            task(3, created: day, due: tomorrow),
            task(4, created: day), // No plan and no due date remains discoverable.
            task(5, created: day, plan: (2026, 6, 4)), // Past plan, no due.
            task(6, created: day, due: tomorrow, completed: day)
        ]
        let today = ids(rows, .today, selected: day, now: day, zone: utc)
        let upcoming = ids(rows, .upcoming, selected: day, now: day, zone: utc)
        let completed = ids(rows, .completed, selected: day, now: day, zone: utc)
        XCTAssertEqual(today, [rows[1].id, rows[0].id])
        XCTAssertEqual(upcoming, [rows[2].id, rows[3].id, rows[4].id])
        XCTAssertEqual(completed, [rows[5].id])
        XCTAssertEqual(Set(today).intersection(upcoming), [])
        XCTAssertEqual(Set(today + upcoming), Set(rows.filter { !$0.isCompleted }.map(\.id)))
        XCTAssertEqual(Set(today + upcoming + completed), Set(rows.map(\.id)))
    }

    func testExactNextMidnightIsExcludedWhileOneSecondEarlierIsIncluded() throws {
        let selected = instant("2026-06-05T23:00:00Z")
        let boundary = instant("2026-06-06T00:00:00Z")
        let rows = try [
            task(1, created: selected, due: boundary.addingTimeInterval(-1)),
            task(2, created: selected, due: boundary),
            task(3, created: selected, due: boundary, plan: (2026, 6, 5))
        ]
        XCTAssertEqual(ids(rows, .today, selected: selected, now: selected, zone: utc),
                       [rows[0].id, rows[2].id])
        XCTAssertEqual(ids(rows, .upcoming, selected: selected, now: selected, zone: utc),
                       [rows[1].id])
    }

    func testSpringAndFallDSTUseCalendarDayBoundariesNotFixedSeconds() throws {
        let spring = instant("2026-03-08T12:00:00Z") // LA: Mar 8, 05:00 PDT
        let springEnd = instant("2026-03-09T07:00:00Z") // 23-hour local day
        let fall = instant("2026-11-01T12:00:00Z") // LA: Nov 1, 04:00 PST
        let fallEnd = instant("2026-11-02T08:00:00Z") // 25-hour local day
        for (selected, boundary) in [(spring, springEnd), (fall, fallEnd)] {
            let rows = try [task(1, created: selected, due: boundary.addingTimeInterval(-1)),
                            task(2, created: selected, due: boundary)]
            XCTAssertEqual(ids(rows, .today, selected: selected, now: selected, zone: la),
                           [rows[0].id])
            XCTAssertEqual(ids(rows, .upcoming, selected: selected, now: selected, zone: la),
                           [rows[1].id])
        }
    }

    func testTravelRecomputesLocalMembershipWithoutShiftingStoredPlan() throws {
        let selected = instant("2026-06-05T10:00:00Z") // Jun 5 LA, Jun 5 Auckland
        let nearBoundary = instant("2026-06-05T13:00:00Z") // Jun 5 LA, Jun 6 Auckland
        let stored = try task(1, created: selected, plan: (2026, 6, 5), planZone: la)
        let due = try task(2, created: selected, due: nearBoundary)
        let rows = [stored, due]
        XCTAssertEqual(ids(rows, .today, selected: selected, now: selected, zone: la),
                       [due.id, stored.id])
        XCTAssertEqual(ids(rows, .today, selected: nearBoundary, now: nearBoundary,
                           zone: auckland), [due.id])
        XCTAssertEqual(ids(rows, .upcoming, selected: nearBoundary, now: nearBoundary,
                           zone: auckland), [stored.id])
        XCTAssertEqual(stored.plannedDay, .init(calendarIdentifier: "gregorian",
                                               year: 2026, month: 6, day: 5))
        XCTAssertEqual(stored.plannedTimeZoneID, la.identifier)
        // On the user's next Auckland June 5, the original LA plan still reads June 5.
        XCTAssertEqual(ids([stored], .today, selected: selected, now: selected,
                           zone: auckland), [stored.id])
    }

    func testPlanUsesItsCalendarWhenDeviceCalendarChanges() throws {
        let selected = instant("2026-06-05T12:00:00Z")
        let stored = try task(1, created: selected, plan: (2026, 6, 5), planZone: la)
        let buddhist = Calendar(identifier: .buddhist)
        XCTAssertEqual(ids([stored], .today, selected: selected, now: selected,
                           zone: utc, calendar: buddhist), [stored.id])
    }

    func testOpenOrderingOverdueThenDueThenCreationThenUUIDIncludingNilDue() throws {
        let now = instant("2026-06-05T12:00:00Z")
        let earlier = now.addingTimeInterval(-3_600)
        let later = now.addingTimeInterval(3_600)
        // Overdue tasks can be Upcoming when browsing an earlier selected day.
        // Compare all ordering levels within that filter.
        let selected = instant("2026-06-04T12:00:00Z")
        let rows = try [
            task(8, created: now, due: later),
            task(4, created: now, due: earlier),
            task(3, created: now, due: earlier),
            task(1, created: now.addingTimeInterval(-1), due: earlier),
            task(6, created: now),
            task(5, created: now.addingTimeInterval(-1)),
            task(7, created: now, due: now)
        ]
        XCTAssertEqual(ids(rows, .today, selected: selected, now: now, zone: utc), [])
        XCTAssertEqual(ids(rows, .upcoming, selected: selected, now: now, zone: utc),
                       [rows[3].id, rows[2].id, rows[1].id, rows[6].id, rows[0].id,
                        rows[5].id, rows[4].id])
        // Same due instant at now is not overdue; nil dates sort after dated rows.
        XCTAssertEqual(ids(rows, .today, selected: now, now: now, zone: utc),
                       [rows[3].id, rows[2].id, rows[1].id, rows[6].id, rows[0].id])
    }

    func testCompletedSortsNewestCompletionFirstWithCreationAndUUIDTies() throws {
        let now = instant("2026-06-05T12:00:00Z")
        let old = now.addingTimeInterval(-10)
        let rows = try [task(4, created: now, completed: old),
                        task(3, created: now, completed: now),
                        task(2, created: old, completed: now),
                        task(1, created: now, completed: now),
                        task(5, created: old)]
        XCTAssertEqual(ids(rows, .completed, selected: now, now: now, zone: utc),
                       [rows[2].id, rows[3].id, rows[1].id, rows[0].id])
        XCTAssertFalse(ids(rows, .today, selected: now, now: now, zone: utc)
            .contains(rows[0].id))
    }
}
