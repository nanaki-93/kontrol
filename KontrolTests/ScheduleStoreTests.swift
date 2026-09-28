import AppKit
import Combine
import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class ScheduleStoreTests: XCTestCase {
    private enum Injected: Error { case read, write }
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private final class Spy: ScheduleRepository {
        let storage: SwiftDataScheduleRepository
        var fetchCount = 0
        var writeCount = 0
        var failReads = false
        var failWrites = false

        init(_ storage: SwiftDataScheduleRepository) { self.storage = storage }
        func fetchAll() throws -> [ScheduleSnapshot] {
            fetchCount += 1
            if failReads { throw Injected.read }
            return try storage.fetchAll()
        }
        func create(input: ScheduleInput, allowOverlap: Bool, review: ScheduleOverlapReview?) throws -> ScheduleSnapshot {
            writeCount += 1
            if failWrites { throw Injected.write }
            return try storage.create(input: input, allowOverlap: allowOverlap, review: review)
        }
        func update(id: UUID, input: ScheduleInput, allowOverlap: Bool,
                    review: ScheduleOverlapReview?) throws -> ScheduleSnapshot {
            writeCount += 1
            if failWrites { throw Injected.write }
            return try storage.update(id: id, input: input, allowOverlap: allowOverlap, review: review)
        }
        func delete(id: UUID) throws {
            writeCount += 1
            if failWrites { throw Injected.write }
            try storage.delete(id: id)
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

    private func makeSpy(container: ModelContainer? = nil) throws -> Spy {
        let container = try container ?? ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = [firstID, secondID].makeIterator()
        return Spy(SwiftDataScheduleRepository(container: container, makeID: { ids.next()! }))
    }

    private func input(_ title: String, offset: TimeInterval = 0, note: String? = nil) -> ScheduleInput {
        ScheduleInput(title: title, startAt: start.addingTimeInterval(offset),
                      endAt: start.addingTimeInterval(offset + 3600), note: note)
    }

    func testTwoConsumersObserveCommittedCreateReplaceAndDeleteOnceWithoutPostSaveFetch() throws {
        let spy = try makeSpy()
        let store = ScheduleStore(repository: spy)
        var first: [[ScheduleSnapshot]] = []
        var second: [[ScheduleSnapshot]] = []
        let a = store.$snapshots.sink { first.append($0) }
        let b = store.$snapshots.sink { second.append($0) }
        defer { a.cancel(); b.cancel() }
        store.refresh()
        XCTAssertEqual(store.readState, .loaded)
        let later = try store.create(input: input("Later", offset: 7200))
        let earlier = try store.create(input: input("Earlier", note: "Note"))
        let edited = try store.update(id: later.id, input: input("Moved", offset: -7200))
        XCTAssertEqual(edited.id, later.id)
        XCTAssertEqual(store.snapshots, [edited, earlier])
        try store.delete(id: earlier.id)
        let expected = [[], [], [later], [earlier, later], [edited, earlier], [edited]]
        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertEqual(spy.fetchCount, 1)
        XCTAssertEqual(spy.writeCount, 4)
        XCTAssertEqual(try spy.storage.fetchAll(), [edited])
        XCTAssertNil(store.mutationError)
    }

    func testFailedReadNeverBecomesEmptyAndCommittedWritesRetainStaleIndicator() throws {
        let spy = try makeSpy()
        let store = ScheduleStore(repository: spy)
        XCTAssertEqual(store.readState, .notLoaded)
        spy.failReads = true
        store.refresh()
        XCTAssertEqual(store.readState, .failed(hasStaleRows: false))
        XCTAssertNotNil(store.readState.message)
        let row = try store.create(input: input("Private note", note: "secret"))
        XCTAssertEqual(store.snapshots, [row])
        XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
        try store.delete(id: row.id)
        XCTAssertEqual(store.readState, .failed(hasStaleRows: false))
        XCTAssertEqual(spy.fetchCount, 1, "writes do not silently retry reads")
        spy.failReads = false
        store.retryRead()
        XCTAssertEqual(store.readState, .loaded)
        XCTAssertEqual(store.snapshots, [], "only a successful read establishes loaded-empty")
        let external = try spy.storage.create(input: input("External"), allowOverlap: false, review: nil)
        store.retryRead()
        XCTAssertEqual(store.snapshots, [external])
        spy.failReads = true
        store.refresh()
        XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
        XCTAssertEqual(store.snapshots, [external])
        spy.failReads = false
        store.retryRead()
        XCTAssertEqual(store.snapshots, [external])
        XCTAssertEqual(store.readState, .loaded)
    }

    func testWriteErrorsAreClassifiedWithoutPublishingOrAutomaticRetry() throws {
        let spy = try makeSpy()
        let store = ScheduleStore(repository: spy)
        store.refresh()
        let row = try store.create(input: input("Kept"))
        var publications: [[ScheduleSnapshot]] = []
        let observer = store.$snapshots.dropFirst().sink { publications.append($0) }
        defer { observer.cancel() }
        XCTAssertThrowsError(try store.create(input: input("  ", offset: 7200)))
        XCTAssertEqual(store.mutationError, .validation(.emptyTitle))
        XCTAssertThrowsError(try store.create(input: input("Conflict"))) { error in
            guard case ScheduleRepositoryError.overlap(let review) = error else {
                return XCTFail("Expected a review receipt")
            }
            XCTAssertEqual(review.conflicts.count, 1)
        }
        XCTAssertEqual(store.mutationError, .overlap)
        spy.failWrites = true
        XCTAssertThrowsError(try store.create(input: input("Secret", offset: 7200)))
        XCTAssertThrowsError(try store.update(id: row.id, input: input("Secret edit", offset: 7200)))
        XCTAssertThrowsError(try store.delete(id: row.id))
        XCTAssertEqual(store.mutationError, .persistence)
        XCTAssertFalse(store.mutationError!.message.contains("Secret"))
        XCTAssertEqual(spy.writeCount, 6)
        XCTAssertEqual(spy.fetchCount, 1)
        XCTAssertTrue(publications.isEmpty)
        XCTAssertEqual(store.snapshots, [row])
        XCTAssertEqual(try spy.storage.fetchAll(), [row])
        spy.failWrites = false
        try store.delete(id: row.id)
        XCTAssertEqual(publications, [[]])
        XCTAssertNil(store.mutationError)
    }

    func testReviewedOverlapPublishesOnlyCommittedTargetAndNeverRefetches() throws {
        let spy = try makeSpy()
        let store = ScheduleStore(repository: spy)
        store.refresh()
        let peer = try store.create(input: input("Peer"))
        var review: ScheduleOverlapReview?
        XCTAssertThrowsError(try store.create(input: input("Keep both"))) {
            if case ScheduleRepositoryError.overlap(let receipt) = $0 { review = receipt }
            else { XCTFail("Expected overlap review") }
        }
        XCTAssertEqual(store.snapshots, [peer])
        let receipt = try XCTUnwrap(review)
        let second = try store.create(input: input("Keep both"), allowOverlap: true, review: receipt)
        XCTAssertEqual(Set(store.snapshots.map(\.id)), Set([peer.id, second.id]))
        XCTAssertEqual(spy.fetchCount, 1)
        XCTAssertEqual(try spy.storage.fetchAll().count, 2)
        XCTAssertThrowsError(try store.create(input: input("Keep both"), allowOverlap: true, review: receipt))
        XCTAssertEqual(store.mutationError, .overlap)
        XCTAssertEqual(store.snapshots.count, 2, "a consumed decision cannot create a duplicate")
    }

    func testMissingTargetRefreshesWithoutResurrectionEvenIfReadFails() throws {
        let spy = try makeSpy()
        let store = ScheduleStore(repository: spy)
        let row = try spy.storage.create(input: input("Removed"), allowOverlap: false, review: nil)
        store.refresh()
        try spy.storage.delete(id: row.id)
        XCTAssertThrowsError(try store.update(id: row.id, input: input("Gone"))) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(row.id))
        }
        XCTAssertEqual(store.mutationError, .notFound)
        XCTAssertEqual(store.snapshots, [])
        XCTAssertEqual(store.readState, .loaded)
        let other = try spy.storage.create(input: input("Again"), allowOverlap: false, review: nil)
        store.refresh()
        try spy.storage.delete(id: other.id)
        spy.failReads = true
        XCTAssertThrowsError(try store.delete(id: other.id)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(other.id))
        }
        XCTAssertEqual(store.mutationError, .notFound)
        XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
        XCTAssertEqual(store.snapshots, [other])
        spy.failReads = false
        store.retryRead()
        XCTAssertTrue(store.snapshots.isEmpty)
    }

    func testOneActivationObserverRefreshesSharedStoreAndIsRemovedOnRelease() throws {
        let spy = try makeSpy()
        let center = NotificationProbe()
        weak var released: ScheduleStore?
        do {
            let store = ScheduleStore(repository: spy, notificationCenter: center)
            released = store
            XCTAssertEqual(center.registered, [NSApplication.didBecomeActiveNotification])
            store.refresh()
            let external = try spy.storage.create(input: input("External"), allowOverlap: false, review: nil)
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            XCTAssertEqual(store.snapshots, [external])
            XCTAssertEqual(spy.fetchCount, 2)
            spy.failReads = true
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
        }
        XCTAssertNil(released)
        XCTAssertEqual(center.removed, 1)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(spy.fetchCount, 3)
    }

    func testScheduleReadFailureDoesNotBlockTaskActionsInSameContainer() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let schedule = ScheduleStore(repository: try makeSpy(container: container))
        let tasks = TaskStore(repository: SwiftDataTaskRepository(container: container))
        let spy = schedule.repository as! Spy
        spy.failReads = true
        schedule.refresh()
        XCTAssertEqual(schedule.readState, .failed(hasStaleRows: false))
        let task = try tasks.create(input: TaskInput(title: "Still works"))
        let completed = try tasks.setCompleted(id: task.id, completed: true)
        XCTAssertNotNil(completed.completedAt)
        XCTAssertEqual(tasks.snapshots, [completed])
        XCTAssertEqual(schedule.readState, .failed(hasStaleRows: false))
        XCTAssertTrue(schedule.snapshots.isEmpty)
    }
}
