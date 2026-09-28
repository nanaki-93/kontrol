import AppKit
import Combine
import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class TaskStoreTests: XCTestCase {
    private enum Injected: Error { case read, write }
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!

    private final class SaveProbe {
        var count = 0
    }

    private final class RepositorySpy: TaskRepository {
        let storage: SwiftDataTaskRepository
        let saves: SaveProbe
        var fetchCount = 0
        var failReads = false
        var failWrites = false

        init(storage: SwiftDataTaskRepository, saves: SaveProbe) {
            self.storage = storage
            self.saves = saves
        }
        func fetchAll() throws -> [TaskItem] {
            fetchCount += 1
            if failReads { throw Injected.read }
            return try storage.fetchAll()
        }
        func create(title: String, plannedFor: PlannedDay?) throws -> UUID {
            if failWrites { throw Injected.write }
            return try storage.create(title: title, plannedFor: plannedFor)
        }
        func create(input: TaskInput) throws -> TaskSnapshot {
            if failWrites { throw Injected.write }
            return try storage.create(input: input)
        }
        func update(id: UUID, input: TaskInput) throws -> TaskSnapshot {
            if failWrites { throw Injected.write }
            return try storage.update(id: id, input: input)
        }
        func setCompleted(id: UUID, completed: Bool) throws -> TaskSnapshot {
            if failWrites { throw Injected.write }
            return try storage.setCompleted(id: id, completed: completed)
        }
        func delete(id: UUID) throws {
            if failWrites { throw Injected.write }
            try storage.delete(id: id)
        }
    }

    private final class TimerProbe {
        struct Entry {
            let boundary: Date
            let fire: () -> Void
            var canceled = false
        }
        var entries: [Entry] = []

        func schedule(_ boundary: Date, _ fire: @escaping () -> Void) -> () -> Void {
            let index = entries.count
            entries.append(Entry(boundary: boundary, fire: fire))
            return { [self] in entries[index].canceled = true }
        }
    }

    private final class NotificationProbe: NotificationCenter, @unchecked Sendable {
        var registered: [Notification.Name] = []
        var removed = 0

        override func addObserver(forName name: NSNotification.Name?, object obj: Any?,
                                  queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
            if let name { registered.append(name) }
            return super.addObserver(forName: name, object: obj, queue: queue, using: block)
        }

        override func removeObserver(_ observer: Any) {
            removed += 1
            super.removeObserver(observer)
        }
    }

    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func makeSpy() throws -> RepositorySpy {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = [firstID, secondID].makeIterator()
        let saves = SaveProbe()
        let repository = SwiftDataTaskRepository(container: container, makeID: { ids.next()! },
                                                  save: { context in
            saves.count += 1
            try context.save()
        })
        return RepositorySpy(storage: repository, saves: saves)
    }

    func testTwoObserversReceiveEveryCommittedMutationSynchronouslyWithoutRefetch() throws {
        let spy = try makeSpy()
        let store = TaskStore(repository: spy)
        var observerA: [[TaskSnapshot]] = []
        var observerB: [[TaskSnapshot]] = []
        let a = store.$snapshots.sink { observerA.append($0) }
        let b = store.$snapshots.sink { observerB.append($0) }
        defer { a.cancel(); b.cancel() }
        store.refresh()
        XCTAssertEqual(store.readState, .loaded)
        XCTAssertEqual(spy.fetchCount, 1)

        let created = try store.create(input: TaskInput(title: "First"))
        XCTAssertEqual(created.id, firstID)
        XCTAssertNil(created.plannedDay)
        XCTAssertEqual(observerA.last, [created])
        XCTAssertEqual(observerB.last, [created])
        XCTAssertEqual(spy.fetchCount, 1)

        let other = try store.create(input: TaskInput(title: "Second"))
        let edited = try store.update(id: firstID, input: TaskInput(title: "Edited", notes: "Notes"))
        XCTAssertEqual(edited.id, firstID)
        XCTAssertEqual(edited.notes, "Notes")
        XCTAssertEqual(observerA.last, [edited, other])
        XCTAssertEqual(observerB.last, observerA.last)
        let completed = try store.setCompleted(id: firstID, completed: true)
        XCTAssertNotNil(completed.completedAt)
        XCTAssertEqual(observerA.last?.first, completed)
        XCTAssertEqual(observerB.last?.first, completed)
        let reopened = try store.setCompleted(id: firstID, completed: false)
        XCTAssertNil(reopened.completedAt)
        XCTAssertEqual(observerA.last?.first, reopened)
        XCTAssertEqual(observerB.last?.first, reopened)
        try store.delete(id: secondID)
        let expectedPublications = [
            [TaskSnapshot](), // subscription's initial value
            [],               // successful empty refresh
            [created],
            [created, other],
            [edited, other],
            [completed, other],
            [reopened, other],
            [reopened]         // committed deletion
        ]
        XCTAssertEqual(observerA, expectedPublications, "replacements must publish exactly once, never a transient removal")
        XCTAssertEqual(observerB, expectedPublications, "both observers receive the same complete sequence")
        XCTAssertEqual(spy.fetchCount, 1, "committed mutations publish without a second read")
        XCTAssertNil(store.mutationError)
    }

    func testCompletionReopeningRepartitionsCachedFiltersWithoutFetchAndFailuresDoNotRepartition() throws {
        let spy = try makeSpy()
        let now = instant("2026-01-01T12:00:00Z")
        let store = TaskStore(repository: spy, clock: { now },
                              timeZone: { TimeZone(secondsFromGMT: 0)! })
        store.refresh()
        let today = try store.create(input: TaskInput(title: "Due now", dueAt: now))
        let upcoming = try store.create(input: TaskInput(title: "No date"))
        XCTAssertEqual(store.select(.today).map(\.id), [today.id])
        XCTAssertEqual(store.select(.upcoming).map(\.id), [upcoming.id])
        spy.failWrites = true
        XCTAssertThrowsError(try store.setCompleted(id: today.id, completed: true))
        XCTAssertEqual(store.select(.today).map(\.id), [today.id])
        XCTAssertTrue(store.select(.completed).isEmpty)
        XCTAssertEqual(store.mutationError, .writeFailed)
        spy.failWrites = false
        let completed = try store.setCompleted(id: today.id, completed: true)
        XCTAssertNotNil(completed.completedAt)
        XCTAssertTrue(store.select(.today).isEmpty)
        XCTAssertEqual(store.select(.completed).map(\.id), [today.id])
        spy.failWrites = true
        XCTAssertThrowsError(try store.setCompleted(id: today.id, completed: false))
        XCTAssertEqual(store.select(.completed), [completed])
        spy.failWrites = false
        let reopened = try store.setCompleted(id: today.id, completed: false)
        XCTAssertNil(reopened.completedAt)
        XCTAssertEqual(store.select(.today).map(\.id), [today.id])
        XCTAssertTrue(store.select(.completed).isEmpty)
        XCTAssertEqual(store.select(.upcoming).map(\.id), [upcoming.id])
        XCTAssertEqual(spy.fetchCount, 1, "actions publish committed snapshots without navigation or refetch")
        XCTAssertEqual(spy.saves.count, 4, "only two creates and two successful transitions save")
    }

    func testReadFailureNeverLooksLikeEmptySuccessAndRetryIsExplicit() throws {
        let spy = try makeSpy()
        let store = TaskStore(repository: spy)
        XCTAssertEqual(store.readState, .notLoaded)
        spy.failReads = true
        store.refresh()
        XCTAssertEqual(store.readState, .failed(hasStaleRows: false))
        XCTAssertEqual(store.readState.message, "Could not load tasks. Retry to update.")
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(spy.fetchCount, 1)
        spy.failReads = false
        store.retryRead()
        XCTAssertEqual(store.readState, .loaded)
        XCTAssertEqual(spy.fetchCount, 2)
        XCTAssertTrue(store.snapshots.isEmpty, "only a successful read may display an empty result")

        let row = try spy.storage.create(input: TaskInput(title: "Stored"))
        store.retryRead()
        XCTAssertEqual(store.snapshots, [row])
        spy.failReads = true
        store.refresh()
        XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
        XCTAssertEqual(store.readState.message,
                       "Could not refresh tasks. Showing previously loaded tasks. Retry to update.")
        XCTAssertEqual(store.snapshots, [row], "failure retains only explicitly stale cached rows")
        XCTAssertEqual(spy.fetchCount, 4)
        spy.failReads = false
        store.retryRead()
        XCTAssertEqual(store.readState, .loaded)
        XCTAssertEqual(store.snapshots, [row])
    }

    func testCommittedWritesDoNotHideAnUnresolvedReadFailure() throws {
        let spy = try makeSpy()
        let store = TaskStore(repository: spy)
        spy.failReads = true
        store.refresh()
        XCTAssertEqual(store.readState, .failed(hasStaleRows: false))
        let row = try store.create(input: TaskInput(title: "Committed despite failed read"))
        XCTAssertEqual(store.snapshots, [row])
        XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
        try store.delete(id: row.id)
        XCTAssertEqual(store.readState, .failed(hasStaleRows: false))
        XCTAssertEqual(spy.fetchCount, 1, "writes do not silently retry failed reads")
    }

    func testFailedMutationsPublishNoSuccessAndExposeOnlySafeErrors() throws {
        let spy = try makeSpy()
        let store = TaskStore(repository: spy)
        store.refresh()
        let first = try store.create(input: TaskInput(title: "Private title"))
        var publications: [[TaskSnapshot]] = []
        let subscription = store.$snapshots.dropFirst().sink { publications.append($0) }
        defer { subscription.cancel() }
        spy.failWrites = true
        XCTAssertThrowsError(try store.create(input: TaskInput(title: "Secret")))
        XCTAssertThrowsError(try store.update(id: firstID, input: TaskInput(title: "Secret edit")))
        XCTAssertThrowsError(try store.setCompleted(id: firstID, completed: true))
        XCTAssertThrowsError(try store.setCompleted(id: firstID, completed: false))
        XCTAssertThrowsError(try store.delete(id: firstID))
        XCTAssertTrue(publications.isEmpty)
        XCTAssertEqual(store.snapshots, [first])
        XCTAssertEqual(spy.fetchCount, 1)
        XCTAssertEqual(store.mutationError, .writeFailed)
        XCTAssertFalse(store.mutationError!.message.contains("Private title"))
        XCTAssertFalse(store.mutationError!.message.contains("Secret"))
        spy.failWrites = false
        try store.delete(id: firstID)
        XCTAssertEqual(publications, [[]])
        XCTAssertNil(store.mutationError)
    }

    func testMidnightAndTravelRecomputeSelectionWithoutPersistenceWrites() throws {
        let spy = try makeSpy()
        let center = NotificationProbe()
        let timers = TimerProbe()
        var now = instant("2024-03-10T08:00:00Z") // Midnight in Los Angeles, before DST jump.
        var zone = TimeZone(identifier: "America/Los_Angeles")!
        let calendar = Calendar(identifier: .gregorian)
        let store = TaskStore(repository: spy, notificationCenter: center,
                              clock: { now }, calendar: { calendar }, timeZone: { zone },
                              scheduleTimer: timers.schedule)
        let plan = PlannedDay.today(at: now, calendar: calendar, timeZone: zone)
        let planned = try store.create(input: TaskInput(title: "Planned", plannedFor: plan))
        let due = try store.create(input: TaskInput(title: "Due at next midnight",
                                                     dueAt: instant("2024-03-11T07:00:00Z")))
        XCTAssertEqual(timers.entries.map(\.boundary), [instant("2024-03-11T07:00:00Z")],
                       "DST spring-forward day is 23 hours, not 86,400 seconds")
        XCTAssertEqual(Set(store.select(.today).map(\.id)), [planned.id])
        XCTAssertEqual(store.select(.upcoming).map(\.id), [due.id])
        var temporalPublications = 0
        let observation = store.$temporalContext.dropFirst().sink { _ in temporalPublications += 1 }
        defer { observation.cancel() }
        now = instant("2024-03-11T07:00:00Z")
        timers.entries[0].fire()
        XCTAssertEqual(temporalPublications, 1)
        XCTAssertTrue(timers.entries[0].canceled)
        XCTAssertEqual(timers.entries[1].boundary, instant("2024-03-12T07:00:00Z"))
        XCTAssertEqual(store.select(.today).map(\.id), [due.id])
        XCTAssertEqual(store.select(.upcoming).map(\.id), [planned.id])
        timers.entries[0].fire() // A queued callback from the canceled timer is harmless.
        XCTAssertEqual(timers.entries.count, 2)

        zone = TimeZone(identifier: "Pacific/Honolulu")!
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(temporalPublications, 2)
        XCTAssertTrue(timers.entries[1].canceled)
        XCTAssertEqual(timers.entries[2].boundary, instant("2024-03-11T10:00:00Z"))
        XCTAssertEqual(store.select(.today).map(\.id), [due.id, planned.id],
                       "Travel changes the selected local day, not the stored plan")
        XCTAssertEqual(store.select(.upcoming).count, 0)
        XCTAssertEqual(store.snapshots.first { $0.id == planned.id }?.plannedDay, plan.components)
        XCTAssertEqual(store.snapshots.first { $0.id == planned.id }?.plannedTimeZoneID, plan.timeZoneID)
        XCTAssertEqual(try spy.storage.fetchAll().first { $0.id == planned.id }?.plannedDay, plan.components)
        XCTAssertEqual(spy.fetchCount, 0, "Temporal changes select cached snapshots without repository reads")
        XCTAssertEqual(spy.saves.count, 2, "Only the two explicit creations write records")
    }

    func testTemporalNotificationsRescheduleAndForegroundRefreshesExternalChanges() throws {
        let spy = try makeSpy()
        let center = NotificationProbe()
        let timers = TimerProbe()
        var now = instant("2025-01-01T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(secondsFromGMT: 0)!
        let store = TaskStore(repository: spy, notificationCenter: center,
                              clock: { now }, calendar: { calendar }, timeZone: { zone },
                              scheduleTimer: timers.schedule)
        XCTAssertEqual(center.registered, [NSApplication.didBecomeActiveNotification,
                                           .NSCalendarDayChanged, .NSSystemClockDidChange,
                                           .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification],
                       "register once per store, not per row")
        store.refresh()
        let external = try spy.storage.create(input: TaskInput(title: "From another owner"))
        XCTAssertTrue(store.snapshots.isEmpty)
        now = instant("2025-01-02T12:00:00Z")
        center.post(name: .NSSystemClockDidChange, object: nil)
        XCTAssertTrue(timers.entries[0].canceled)
        XCTAssertEqual(timers.entries[1].boundary, instant("2025-01-03T00:00:00Z"))
        calendar.firstWeekday = 2
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        XCTAssertTrue(timers.entries[1].canceled)
        XCTAssertEqual(store.temporalContext.calendar.firstWeekday, 2)
        XCTAssertEqual(timers.entries[2].boundary, instant("2025-01-03T00:00:00Z"))
        center.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertTrue(timers.entries[2].canceled)
        XCTAssertEqual(spy.fetchCount, 1, "Temporal changes do not persist or refetch")
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(timers.entries[3].canceled)
        XCTAssertEqual(timers.entries.count, 5)
        XCTAssertEqual(spy.fetchCount, 2)
        XCTAssertEqual(store.snapshots, [external], "Activation discovers externally committed tasks")
        XCTAssertEqual(spy.saves.count, 1, "Activation reads but never saves")
    }

    func testOwnerReleaseCancelsTimerAndRemovesAllObservers() throws {
        let spy = try makeSpy()
        let center = NotificationProbe()
        let timers = TimerProbe()
        weak var released: TaskStore?
        do {
            let store = TaskStore(repository: spy, notificationCenter: center,
                                  scheduleTimer: timers.schedule)
            released = store
            XCTAssertEqual(center.registered.count, 5)
            XCTAssertEqual(timers.entries.count, 1)
        }
        XCTAssertNil(released)
        XCTAssertTrue(timers.entries[0].canceled)
        XCTAssertEqual(center.removed, 5)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        timers.entries[0].fire()
        XCTAssertEqual(spy.fetchCount, 0)
        XCTAssertEqual(timers.entries.count, 1)
    }

    func testNotFoundRefreshesAndClassifiesSeparatelyEvenWhenRefreshFails() throws {
        let spy = try makeSpy()
        let store = TaskStore(repository: spy)
        let first = try spy.storage.create(input: TaskInput(title: "Removed elsewhere"))
        store.refresh()
        try spy.storage.delete(id: firstID)
        XCTAssertThrowsError(try store.update(id: firstID, input: TaskInput(title: "Stale"))) {
            XCTAssertEqual($0 as? TaskRepositoryError, .notFound(self.firstID))
        }
        XCTAssertEqual(store.mutationError, .notFound)
        XCTAssertFalse(store.mutationError!.message.contains(first.title))
        XCTAssertEqual(store.snapshots, [])
        XCTAssertEqual(store.readState, .loaded)
        XCTAssertEqual(spy.fetchCount, 2)

        let second = try spy.storage.create(input: TaskInput(title: "Another stale task"))
        store.refresh()
        XCTAssertEqual(store.snapshots, [second])
        try spy.storage.delete(id: secondID)
        spy.failReads = true
        XCTAssertThrowsError(try store.delete(id: secondID)) {
            XCTAssertEqual($0 as? TaskRepositoryError, .notFound(self.secondID))
        }
        XCTAssertEqual(spy.fetchCount, 4, "not-found always attempts a refresh")
        XCTAssertEqual(store.mutationError, .notFound)
        XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
        XCTAssertEqual(store.snapshots, [second])
        spy.failReads = false
        store.retryRead()
        XCTAssertEqual(store.snapshots, [])
        XCTAssertEqual(store.readState, .loaded)
    }
}
