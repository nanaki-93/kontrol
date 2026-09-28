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

    private final class RepositorySpy: TaskRepository {
        let storage: SwiftDataTaskRepository
        var fetchCount = 0
        var failReads = false
        var failWrites = false

        init(storage: SwiftDataTaskRepository) { self.storage = storage }
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

    private func makeSpy() throws -> RepositorySpy {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = [firstID, secondID].makeIterator()
        let repository = SwiftDataTaskRepository(container: container, makeID: { ids.next()! })
        return RepositorySpy(storage: repository)
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
