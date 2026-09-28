import AppKit
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
        var receipts: [FocusSessionSnapshot] = []

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
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                throw FocusError.missingSession
            }
            let original = rows[index]
            let change: FocusTimingChange
            switch command {
            case .reconcile(let payload):
                guard case .changed(let result) = try FocusTiming.reconcileOnRelaunch(
                    original, at: payload.sampledAt) else { throw FocusError.invalidTransition }
                change = result
            case .checkpoint(let payload):
                let delta = payload.accumulatedActiveSeconds - original.accumulatedActiveSeconds
                change = try FocusTiming.checkpoint(original,
                    at: payload.wallAnchorAt ?? payload.sampledAt, monotonicDelta: delta)
            case .complete(let payload):
                guard let effectiveEndedAt else { throw FocusError.invalidTransition }
                let receipt = try FocusSessionSnapshot(id: original.id, state: .completed,
                    plannedSeconds: original.plannedSeconds,
                    accumulatedActiveSeconds: payload.accumulatedActiveSeconds,
                    startedAt: original.startedAt, endedAt: effectiveEndedAt,
                    checkpointAt: payload.sampledAt)
                change = FocusTimingChange(transition: command, snapshot: receipt)
            default: throw FocusError.invalidTransition
            }
            guard change.transition == command else { throw FocusError.invalidTransition }
            rows[index] = change.snapshot
            receipts.append(change.snapshot)
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

    private final class FakeTicks {
        var callbacks: [() -> Void] = []
        var cancellations = 0
        func schedule(_ callback: @escaping () -> Void) -> () -> Void {
            callbacks.append(callback)
            return { [weak self] in self?.cancellations += 1 }
        }
        func fire(_ index: Int? = nil) { callbacks[index ?? callbacks.count - 1]() }
    }

    func testTicksCheckpointWithMonotonicTimeAndRebaseWallClock() throws {
        let repo = FakeRepository()
        let ticks = FakeTicks()
        let base = ContinuousClock().now
        var seconds = 0.0
        var wall = start
        let notifications = NotificationCenter()
        let sleep = NotificationCenter()
        let service = FocusService(repository: repo, wallClock: { wall },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: notifications,
            workspaceNotificationCenter: sleep)
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        XCTAssertEqual(ticks.callbacks.count, 1)
        seconds = 4.25
        wall = start.addingTimeInterval(4.25)
        ticks.fire()
        XCTAssertEqual(service.countdownSeconds, 56)
        XCTAssertEqual(repo.transitions, 0)
        seconds = 15.5
        wall = start.addingTimeInterval(15.5)
        ticks.fire()
        XCTAssertEqual(repo.receipts.last?.accumulatedActiveSeconds, 15.5)
        XCTAssertEqual(repo.receipts.last?.activeSegmentStartedAt, wall)
        seconds = 18.5
        wall = start.addingTimeInterval(-1000) // system clock correction
        ticks.fire()
        XCTAssertEqual(service.countdownSeconds, 42)
        XCTAssertEqual(repo.receipts.last?.accumulatedActiveSeconds, 18.5)
        XCTAssertEqual(repo.receipts.last?.activeSegmentStartedAt, wall)
        XCTAssertEqual(repo.receipts.last?.deadline, wall.addingTimeInterval(41.5))
        let writesAfterRebase = repo.transitions
        seconds = 19.5
        wall = start.addingTimeInterval(-999)
        ticks.fire()
        XCTAssertEqual(repo.transitions, writesAfterRebase) // no repeated drift writes
        XCTAssertEqual(ticks.callbacks.count, 1)
        XCTAssertEqual(ticks.cancellations, 0)
        // Notifications do not install another timer. Sleep forces a best-effort checkpoint.
        seconds = 19.5
        wall = start.addingTimeInterval(19.5)
        sleep.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(repo.receipts.last?.accumulatedActiveSeconds, 19.5)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        service.loadIfNeeded() // navigation or window reopen
        XCTAssertEqual(ticks.callbacks.count, 1)
    }

    func testLateCallbackCompletesOnlyOnceAndCanceledOwnerCannotMutateNewSession() throws {
        let repo = FakeRepository()
        let ticks = FakeTicks()
        let base = ContinuousClock().now
        var seconds = 0.0
        var wall = start
        let service = FocusService(repository: repo, wallClock: { wall },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        seconds = 120
        wall = start.addingTimeInterval(120)
        ticks.fire()
        XCTAssertEqual(service.countdownSeconds, 0)
        XCTAssertEqual(service.snapshots.first?.state, .completed)
        XCTAssertEqual(service.snapshots.first?.endedAt, start.addingTimeInterval(60))
        XCTAssertEqual(repo.transitions, 1)
        XCTAssertEqual(ticks.cancellations, 1)
        ticks.fire(0)
        XCTAssertEqual(repo.transitions, 1)
        try service.start(configuration: FocusConfiguration())
        XCTAssertEqual(ticks.callbacks.count, 2)
        ticks.fire(0)
        XCTAssertEqual(repo.transitions, 1)
        XCTAssertEqual(service.activeSession?.state, .running)
        XCTAssertEqual(service.countdownSeconds, 1500)
    }

    func testCheckpointFailureRetainsAnchorAndSleepNotificationIsBestEffort() throws {
        let repo = FakeRepository()
        let ticks = FakeTicks()
        let base = ContinuousClock().now
        var seconds = 0.0
        let sleep = NotificationCenter()
        let service = FocusService(repository: repo, wallClock: { self.start.addingTimeInterval(seconds) },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: sleep)
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        repo.writeError = .persistenceFailure
        seconds = 16
        sleep.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(repo.rows.first?.accumulatedActiveSeconds, 0)
        XCTAssertEqual(service.countdownSeconds, 44)
        XCTAssertEqual(service.checkpointError, .persistenceFailure)
        repo.writeError = nil
        seconds = 21
        ticks.fire()
        XCTAssertEqual(repo.rows.first?.accumulatedActiveSeconds, 21)
        XCTAssertNil(service.checkpointError)
        XCTAssertEqual(service.countdownSeconds, 39)
    }

    func testPausedSessionStaysFrozenAndLifecycleObserversBelongToService() throws {
        let repo = FakeRepository()
        let paused = try FocusSessionSnapshot(id: UUID(), state: .paused, plannedSeconds: 60,
            accumulatedActiveSeconds: 12.25, pausedAt: start.addingTimeInterval(13),
            startedAt: start, checkpointAt: start.addingTimeInterval(13))
        repo.rows = [paused]
        let ticks = FakeTicks()
        let notifications = NotificationCenter()
        let sleep = NotificationCenter()
        var service: FocusService? = FocusService(repository: repo,
            wallClock: { self.start.addingTimeInterval(500) },
            scheduleTick: ticks.schedule, notificationCenter: notifications,
            workspaceNotificationCenter: sleep)
        service?.loadIfNeeded()
        XCTAssertEqual(service?.countdownSeconds, 48)
        XCTAssertEqual(ticks.callbacks.count, 0)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        notifications.post(name: .NSSystemClockDidChange, object: nil)
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        sleep.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(repo.transitions, 0)
        XCTAssertEqual(service?.activeSession, paused)
        weak var weakService = service
        service = nil
        XCTAssertNil(weakService)
        notifications.post(name: .NSSystemClockDidChange, object: nil)
        sleep.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(repo.transitions, 0)
    }

    func testScheduledCheckpointIsDurableAndCompletionIsOneStoredRow() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataFocusRepository(container: container)
        let ticks = FakeTicks()
        let base = ContinuousClock().now
        var seconds = 0.0
        let service = FocusService(repository: repo,
            wallClock: { self.start.addingTimeInterval(seconds) },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        let id = try XCTUnwrap(service.activeSession?.id)
        seconds = 15.375
        ticks.fire()
        let checkpoint = try XCTUnwrap(repo.fetchAll().first)
        XCTAssertEqual(checkpoint.id, id)
        XCTAssertEqual(checkpoint.accumulatedActiveSeconds, 15.375)
        XCTAssertEqual(checkpoint.activeSegmentStartedAt, checkpoint.checkpointAt)
        XCTAssertEqual(checkpoint.deadline, checkpoint.checkpointAt.addingTimeInterval(44.625))
        seconds = 90
        ticks.fire()
        let completed = try XCTUnwrap(repo.fetchAll().first)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.accumulatedActiveSeconds, 60)
        XCTAssertEqual(completed.endedAt, start.addingTimeInterval(60))
        XCTAssertEqual(completed.id, id)
        ticks.fire() // a canceled callback cannot write twice
        XCTAssertEqual(try repo.fetchAll(), [completed])
    }

    func testReadRetryDoesNotResetTheRunningMonotonicAnchor() throws {
        let repo = FakeRepository()
        let ticks = FakeTicks()
        let base = ContinuousClock().now
        var seconds = 0.0
        let service = FocusService(repository: repo,
            wallClock: { self.start.addingTimeInterval(seconds) },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        seconds = 5
        repo.readError = .persistenceFailure
        service.retryRead()
        XCTAssertTrue(service.readState.isStale)
        seconds = 10
        repo.readError = nil
        service.retryRead()
        XCTAssertEqual(ticks.callbacks.count, 1)
        seconds = 16
        ticks.fire()
        XCTAssertEqual(repo.rows.first?.accumulatedActiveSeconds, 16)
        XCTAssertEqual(service.countdownSeconds, 44)
    }

    func testFailedRetryKeepsRunningTickAndTerminationCheckpointButBlocksStart() throws {
        let repo = FakeRepository()
        let ticks = FakeTicks()
        let notifications = NotificationCenter()
        let base = ContinuousClock().now
        var seconds = 0.0
        let service = FocusService(repository: repo,
            wallClock: { self.start.addingTimeInterval(seconds) },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: notifications,
            workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        repo.readError = .persistenceFailure
        service.retryRead()
        XCTAssertEqual(service.readState, .failed(.persistenceFailure, hasStaleRows: true))
        XCTAssertThrowsError(try service.start(configuration: FocusConfiguration())) {
            XCTAssertEqual($0 as? FocusServiceError, .activeStatusUnknown)
        }
        seconds = 5.25
        ticks.fire()
        XCTAssertEqual(service.countdownSeconds, 55)
        XCTAssertEqual(repo.transitions, 0)
        seconds = 16.5
        ticks.fire()
        XCTAssertEqual(repo.rows.first?.accumulatedActiveSeconds, 16.5)
        seconds = 19.75
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(repo.rows.first?.accumulatedActiveSeconds, 19.75)
        XCTAssertEqual(service.countdownSeconds, 41)
        XCTAssertEqual(ticks.callbacks.count, 1)
        XCTAssertEqual(repo.creates, 1)
    }

    func testPersistedBackwardRebaseKeepsWatermarkAndCorrectedRecoveryAnchor() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataFocusRepository(container: container)
        let ticks = FakeTicks()
        let base = ContinuousClock().now
        var seconds = 0.0
        var wall = start
        let service = FocusService(repository: repo, wallClock: { wall },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        seconds = 15
        wall = start.addingTimeInterval(15)
        ticks.fire()
        let old = try XCTUnwrap(repo.fetchAll().first)
        seconds = 18
        wall = start.addingTimeInterval(-1000)
        ticks.fire()
        let rebased = try XCTUnwrap(repo.fetchAll().first)
        XCTAssertEqual(rebased.accumulatedActiveSeconds, 18)
        XCTAssertEqual(rebased.activeSegmentStartedAt, wall)
        XCTAssertEqual(rebased.deadline, wall.addingTimeInterval(42))
        XCTAssertGreaterThan(rebased.checkpointAt, old.checkpointAt)
        XCTAssertThrowsError(try repo.transition(id: old.id, command:
            .checkpoint(FocusTransitionPayload(expectedCheckpointAt: old.checkpointAt,
                sampledAt: old.checkpointAt.addingTimeInterval(20), accumulatedActiveSeconds: 20)))) {
            XCTAssertEqual($0 as? FocusError, .staleBaseline)
        }
        // A later tick in the corrected clock no longer causes another drift write.
        seconds = 19
        wall = start.addingTimeInterval(-999)
        ticks.fire()
        XCTAssertEqual(try repo.fetchAll().first, rebased)
        // Relaunch treats the different watermark/anchor as ambiguous and offers
        // recovery rather than completing from an obsolete wall interval.
        guard case .changed(let recovery) = try FocusTiming.reconcileOnRelaunch(rebased,
            at: wall.addingTimeInterval(5)) else { return XCTFail("Expected recovery") }
        XCTAssertEqual(recovery.snapshot.state, .paused)
        XCTAssertEqual(recovery.snapshot.accumulatedActiveSeconds, 18)
    }

    func testTerminationCheckpointsWithoutWaitingForAnotherTick() throws {
        let repo = FakeRepository()
        let ticks = FakeTicks()
        let notifications = NotificationCenter()
        let base = ContinuousClock().now
        var seconds = 0.0
        let service = FocusService(repository: repo,
            wallClock: { self.start.addingTimeInterval(seconds) },
            monotonicClock: { base.advanced(by: .milliseconds(Int64(seconds * 1000))) },
            scheduleTick: ticks.schedule, notificationCenter: notifications,
            workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        seconds = 7.125
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(repo.rows.first?.accumulatedActiveSeconds, 7.125)
        XCTAssertEqual(ticks.callbacks.count, 1)
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
