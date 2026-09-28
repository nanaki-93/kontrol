import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusServiceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    @MainActor
    private final class FakeRepository: FocusRepository {
        var rows: [FocusSessionSnapshot] = []
        var reads = 0
        var transitions = 0
        var creates = 0
        var readError: FocusError?
        var writeError: FocusError?
        var lastInput: FocusStartInput?
        var lastTransition: FocusTransition?

        func fetchAll() throws -> [FocusSessionSnapshot] {
            reads += 1
            if let readError { throw readError }
            return rows
        }

        func create(input: FocusStartInput) throws -> FocusSessionSnapshot {
            creates += 1
            lastInput = input
            if let writeError { throw writeError }
            guard !rows.contains(where: { $0.state.isActive }) else {
                throw FocusError.activeSessionConflict
            }
            let receipt = try FocusSessionSnapshot(id: UUID(), state: .running,
                plannedSeconds: input.plannedSeconds, accumulatedActiveSeconds: 0,
                activeSegmentStartedAt: input.startedAt,
                deadline: input.startedAt.addingTimeInterval(Double(input.plannedSeconds)),
                startedAt: input.startedAt, checkpointAt: input.startedAt,
                linkedTaskID: input.linkedTaskID)
            rows.insert(receipt, at: 0)
            return receipt
        }

        func transition(id: UUID, command: FocusTransition, effectiveEndedAt: Date?) throws -> FocusSessionSnapshot {
            transitions += 1
            lastTransition = command
            if let writeError { throw writeError }
            guard let index = rows.firstIndex(where: { $0.id == id }),
                  case .reconcile(let payload) = command else { throw FocusError.invalidTransition }
            let original = rows[index]
            let result = try FocusTiming.reconcileOnRelaunch(original, at: payload.sampledAt)
            guard case .changed(let change) = result, change.transition == command else {
                throw FocusError.invalidTransition
            }
            rows[index] = change.snapshot
            return change.snapshot
        }
    }

    private func running() throws -> FocusSessionSnapshot {
        try FocusSessionSnapshot(id: UUID(), state: .running, plannedSeconds: 1500,
            accumulatedActiveSeconds: 0, activeSegmentStartedAt: start,
            deadline: start.addingTimeInterval(1500), startedAt: start, checkpointAt: start)
    }

    private func ended() throws -> FocusSessionSnapshot {
        try FocusSessionSnapshot(id: UUID(), state: .ended, plannedSeconds: 1500,
            accumulatedActiveSeconds: 45, startedAt: start,
            endedAt: start.addingTimeInterval(60), checkpointAt: start.addingTimeInterval(60))
    }

    func testEmptyLoadAndRepeatedConsumersDoNotReloadOrInventHistory() throws {
        let repo = FakeRepository()
        let service = FocusService(repository: repo, wallClock: { self.start })
        XCTAssertEqual(service.readState, .notLoaded)
        service.loadIfNeeded()
        service.loadIfNeeded()
        XCTAssertEqual(repo.reads, 1)
        XCTAssertEqual(service.readState, .loaded)
        XCTAssertTrue(service.snapshots.isEmpty)
        XCTAssertNil(service.activeSession)
        XCTAssertTrue(service.readState.canStart)
    }

    func testReadFailureBlocksStartUntilExplicitRetryAndNeverMeansEmpty() throws {
        let repo = FakeRepository()
        repo.readError = .persistenceFailure
        let service = FocusService(repository: repo, wallClock: { self.start })
        service.loadIfNeeded()
        XCTAssertEqual(service.readState, .failed(.persistenceFailure, hasStaleRows: false))
        XCTAssertThrowsError(try service.start(configuration: FocusConfiguration())) {
            XCTAssertEqual($0 as? FocusServiceError, .activeStatusUnknown)
        }
        XCTAssertEqual(repo.creates, 0)
        service.loadIfNeeded() // a new view cannot silently retry
        XCTAssertEqual(repo.reads, 1)
        repo.readError = nil
        service.retryRead()
        XCTAssertEqual(repo.reads, 2)
        XCTAssertEqual(service.readState, .loaded)
        try service.start(configuration: FocusConfiguration())
        XCTAssertEqual(repo.lastInput?.plannedSeconds, 1500)
        XCTAssertEqual(repo.lastInput?.startedAt, start)
        XCTAssertEqual(service.activeSession?.id, repo.rows.first?.id)
        XCTAssertThrowsError(try service.start(configuration: FocusConfiguration())) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(repo.creates, 1)
    }

    func testFailedRefreshRetainsExplicitlyStaleCachedHistoryAndDoesNotPermitStart() throws {
        let repo = FakeRepository()
        let history = try ended()
        repo.rows = [history]
        let service = FocusService(repository: repo, wallClock: { self.start })
        service.loadIfNeeded()
        XCTAssertEqual(service.snapshots, [history])
        repo.readError = .persistenceFailure
        service.retryRead()
        XCTAssertEqual(service.readState, .failed(.persistenceFailure, hasStaleRows: true))
        XCTAssertTrue(service.readState.isStale)
        XCTAssertEqual(service.snapshots, [history])
        XCTAssertThrowsError(try service.start(configuration: FocusConfiguration())) {
            XCTAssertEqual($0 as? FocusServiceError, .activeStatusUnknown)
        }
        repo.readError = nil
        repo.rows = []
        service.retryRead()
        XCTAssertEqual(service.readState, .loaded)
        XCTAssertFalse(service.readState.isStale)
        XCTAssertTrue(service.snapshots.isEmpty)
    }

    func testInitialRunningReconcilesOnceAndRetryAfterFailedSaveUsesDurableBaseline() throws {
        let repo = FakeRepository()
        let original = try running()
        repo.rows = [original, try ended()]
        let service = FocusService(repository: repo, wallClock: { self.start.addingTimeInterval(40) })
        repo.writeError = .persistenceFailure
        service.loadIfNeeded()
        XCTAssertEqual(repo.transitions, 1)
        XCTAssertEqual(repo.rows.first, original)
        XCTAssertEqual(service.readState, .failed(.persistenceFailure, hasStaleRows: false))
        XCTAssertThrowsError(try service.start(configuration: FocusConfiguration())) {
            XCTAssertEqual($0 as? FocusServiceError, .activeStatusUnknown)
        }
        repo.writeError = nil
        service.retryRead()
        XCTAssertEqual(repo.transitions, 2)
        XCTAssertEqual(service.readState, .loaded)
        XCTAssertEqual(service.activeSession?.state, .paused)
        XCTAssertEqual(service.activeSession?.accumulatedActiveSeconds, 40)
        XCTAssertEqual(service.activeSession?.recoveryRequired, true)
        XCTAssertEqual(service.snapshots.count, 2)
        service.loadIfNeeded()
        XCTAssertEqual(repo.reads, 2)
        XCTAssertEqual(repo.transitions, 2)
    }

    func testDeadlineCompletionAndAlreadyPausedDoNotReplayOnLoad() throws {
        let repo = FakeRepository()
        repo.rows = [try running()]
        let service = FocusService(repository: repo, wallClock: { self.start.addingTimeInterval(1800) })
        service.loadIfNeeded()
        XCTAssertEqual(service.activeSession, nil)
        XCTAssertEqual(service.snapshots.first?.state, .completed)
        XCTAssertEqual(service.snapshots.first?.endedAt, start.addingTimeInterval(1500))
        XCTAssertEqual(repo.transitions, 1)
        let paused = try FocusSessionSnapshot(id: UUID(), state: .paused, plannedSeconds: 1500,
            accumulatedActiveSeconds: 23, pausedAt: start.addingTimeInterval(23),
            startedAt: start, checkpointAt: start.addingTimeInterval(23))
        let pausedRepo = FakeRepository()
        pausedRepo.rows = [paused]
        let pausedService = FocusService(repository: pausedRepo, wallClock: { self.start.addingTimeInterval(3000) })
        pausedService.loadIfNeeded()
        XCTAssertEqual(pausedService.activeSession, paused)
        XCTAssertEqual(pausedRepo.transitions, 0)
    }

    func testClassifiedIntegrityFailureCannotAuthorizeStartOrAlterRecords() throws {
        let repo = FakeRepository()
        let original = try running()
        repo.rows = [original]
        repo.readError = .activeSessionConflict
        let service = FocusService(repository: repo, wallClock: { self.start.addingTimeInterval(1800) })
        service.loadIfNeeded()
        XCTAssertEqual(service.readState, .failed(.activeSessionConflict, hasStaleRows: false))
        XCTAssertEqual(repo.transitions, 0)
        XCTAssertEqual(repo.rows, [original])
        XCTAssertThrowsError(try service.start(configuration: FocusConfiguration())) {
            XCTAssertEqual($0 as? FocusServiceError, .activeStatusUnknown)
        }
    }

    func testFailedStartDoesNotPublishAnUncommittedSession() throws {
        let repo = FakeRepository()
        var clockSamples = 0
        let service = FocusService(repository: repo, wallClock: { self.start },
            monotonicClock: { clockSamples += 1; return ContinuousClock().now })
        service.loadIfNeeded()
        XCTAssertEqual(clockSamples, 0)
        repo.writeError = .persistenceFailure
        let selection = FocusConfiguration(duration: .fifty, linkedTaskID: UUID())
        XCTAssertThrowsError(try service.start(configuration: selection)) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertEqual(repo.lastInput?.linkedTaskID, selection.linkedTaskID)
        XCTAssertEqual(clockSamples, 0)
        XCTAssertNil(service.activeSession)
        XCTAssertTrue(service.snapshots.isEmpty)
        XCTAssertEqual(service.readState, .loaded)
    }

    func testGraphRecoversOnConstructionNotOnWindowReopen() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataFocusRepository(container: container)
        let original = try repository.create(input: FocusStartInput(plannedSeconds: 1500, startedAt: start))
        let dependencies = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container),
            focusRepository: repository, focusWallClock: { self.start.addingTimeInterval(40) })
        let recovered = try XCTUnwrap(dependencies.focusService.activeSession)
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertEqual(recovered.accumulatedActiveSeconds, 40)
        XCTAssertTrue(recovered.recoveryRequired)
        let first = AppShell(navigation: NavigationStore(), dependencies: dependencies)
        let second = AppShell(navigation: NavigationStore(), dependencies: dependencies)
        XCTAssertTrue(first.dependencies.focusService === second.dependencies.focusService)
        first.dependencies.focusService.loadIfNeeded()
        second.dependencies.focusService.loadIfNeeded()
        XCTAssertEqual(try repository.fetchAll(), [recovered])
    }

    func testDependencyGraphOwnsOneServiceAndFailedFocusReadDoesNotBlockTasks() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = FakeRepository()
        repo.readError = .persistenceFailure
        let dependencies = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container), focusRepository: repo)
        let first = AppShell(navigation: NavigationStore(), dependencies: dependencies)
        let second = AppShell(navigation: NavigationStore(), dependencies: dependencies)
        XCTAssertTrue(first.dependencies.focusService === second.dependencies.focusService)
        XCTAssertTrue(first.dependencies.container === second.dependencies.container)
        XCTAssertEqual(repo.reads, 1)
        XCTAssertEqual(dependencies.focusService.readState,
                       .failed(.persistenceFailure, hasStaleRows: false))
        let task = try dependencies.taskStore.create(input: TaskInput(title: "Still works"))
        XCTAssertEqual(dependencies.taskStore.snapshots.first?.id, task.id)
        dependencies.focusService.loadIfNeeded() // window reopen
        XCTAssertEqual(repo.reads, 1)
        let otherContainer = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let other = AppDependencies(container: otherContainer,
            catalogRepository: SwiftDataCatalogRepository(container: otherContainer))
        XCTAssertFalse(other.focusService === dependencies.focusService)
    }
}
