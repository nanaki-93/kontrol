import AppKit
import Combine
import Foundation

/// A failed read (including a failed startup reconciliation) is not an empty store.
/// Snapshots remain available for display, but cannot authorize a new session.
enum FocusReadState: Equatable {
    case notLoaded
    case loaded
    case failed(FocusError, hasStaleRows: Bool)

    var canStart: Bool { self == .loaded }
    var isStale: Bool {
        if case .failed(_, let hasStaleRows) = self { return hasStaleRows }
        return false
    }
}

enum FocusServiceError: Error, Equatable {
    case activeStatusUnknown
}

/// One publication point per app dependency graph. View appearance never invokes
/// startup reconciliation; a failed attempt is retried explicitly via retryRead.
@MainActor
final class FocusService: ObservableObject {
    let repository: any FocusRepository
    @Published private(set) var snapshots: [FocusSessionSnapshot] = []
    @Published private(set) var activeSession: FocusSessionSnapshot?
    @Published private(set) var readState: FocusReadState = .notLoaded
    @Published private(set) var countdownSeconds: Int?
    @Published private(set) var checkpointError: FocusError?

    private let wallClock: () -> Date
    private let monotonicClock: () -> ContinuousClock.Instant
    private let scheduleTick: (@escaping () -> Void) -> () -> Void
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancelTick: (() -> Void)?
    private var generation = 0
    private var monotonicAnchor: ContinuousClock.Instant?
    private var clockSessionID: UUID?
    private var didCompleteInitialLoad = false
    private let checkpointInterval: TimeInterval = 15

    init(repository: any FocusRepository,
         wallClock: @escaping () -> Date = Date.init,
         monotonicClock: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
         scheduleTick: @escaping (@escaping () -> Void) -> () -> Void = { callback in
             let timer = Timer(timeInterval: 1, repeats: true) { _ in callback() }
             RunLoop.main.add(timer, forMode: .common)
             return { timer.invalidate() }
         },
         notificationCenter: NotificationCenter = .default,
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.repository = repository
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.scheduleTick = scheduleTick
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        observeLifecycle()
    }

    deinit {
        cancelTick?()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    private func observeLifecycle() {
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemClockDidChange,
                     NSApplication.willTerminateNotification] {
            let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sampleTick(forceCheckpoint: name != NSApplication.didBecomeActiveNotification)
                }
            }
            observers.append((notificationCenter, token))
        }
        let token = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleTick(forceCheckpoint: true) }
            }
        observers.append((workspaceNotificationCenter, token))
    }

    func loadIfNeeded() {
        guard readState == .notLoaded else { return }
        load()
    }

    func retryRead() {
        guard readState != .notLoaded else { return }
        load()
    }

    private func load() {
        do {
            var rows = try repository.fetchAll()
            // Only a successful first process load consumes the old wall interval.
            // If the write fails, leave startup unresolved and retry against disk.
            if !didCompleteInitialLoad, let index = rows.firstIndex(where: { $0.state == .running }) {
                let result = try FocusTiming.reconcileOnRelaunch(rows[index], at: wallClock())
                if case .changed(let change) = result {
                    rows[index] = try repository.transition(id: rows[index].id,
                        command: change.transition, effectiveEndedAt: nil)
                }
            }
            publish(rows)
            didCompleteInitialLoad = true
            readState = .loaded
            if let activeSession, activeSession.state == .running {
                // A read retry must not discard time since the last committed
                // anchor when it finds the same running row again.
                if clockSessionID != activeSession.id { startClock() }
            } else { stopClock() }
        } catch {
            // Keep the previous display values explicitly stale. Do not infer an
            // empty history or a safe Start from a failed read or reconciliation.
            readState = .failed(error as? FocusError ?? .persistenceFailure,
                                hasStaleRows: !snapshots.isEmpty)
        }
    }

    func start(configuration: FocusConfiguration) throws {
        guard readState.canStart else { throw FocusServiceError.activeStatusUnknown }
        guard activeSession == nil else { throw FocusError.activeSessionConflict }
        let input = FocusStartInput(plannedSeconds: try configuration.plannedSeconds(),
                                    startedAt: wallClock(), linkedTaskID: configuration.linkedTaskID)
        let receipt = try repository.create(input: input)
        // Save succeeds before any observable state or timing anchor changes.
        publish([receipt] + snapshots)
        startClock()
    }

    private func startClock() {
        stopClock()
        guard let activeSession, activeSession.state == .running else { return }
        monotonicAnchor = monotonicClock()
        clockSessionID = activeSession.id
        countdownSeconds = activeSession.plannedSeconds - Int(activeSession.accumulatedActiveSeconds.rounded(.down))
        let owner = generation
        cancelTick = scheduleTick { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == owner else { return }
                self.sampleTick()
            }
        }
    }

    private func stopClock() {
        generation &+= 1
        cancelTick?()
        cancelTick = nil
        monotonicAnchor = nil
        clockSessionID = nil
    }

    /// The callback is only an opportunity to sample ContinuousClock. Persisted
    /// checkpoints replace both the wall and monotonic anchors after the save.
    private func sampleTick(forceCheckpoint: Bool = false) {
        // A failed refresh blocks a *new* Start, not the clock already owned by
        // this process. Its committed row and monotonic anchor remain usable for
        // ticks, sleep and termination checkpoints while the read is retried.
        guard let session = activeSession, session.state == .running,
              clockSessionID == session.id, let monotonicAnchor else { return }
        let now = monotonicClock()
        let duration = monotonicAnchor.duration(to: now).components
        let delta = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        do {
            let sample = try FocusTiming.sample(session, monotonicDelta: delta)
            countdownSeconds = sample.countdownSeconds
            let wall = wallClock()
            // A clock correction changes only the relaunch anchors, not accrued time.
            // The same checkpoint mechanism also bounds loss when notifications are missed.
            let wallDrift = session.activeSegmentStartedAt.map {
                abs(wall.timeIntervalSince($0) - delta)
            } ?? 0
            guard sample.isComplete || forceCheckpoint || delta >= checkpointInterval || wallDrift > 2 else { return }
            let change = try FocusTiming.checkpoint(session, at: wall, monotonicDelta: delta)
            let receipt = try repository.transition(id: session.id, command: change.transition,
                                                     effectiveEndedAt: change.snapshot.endedAt)
            checkpointError = nil
            publish(snapshots.map { $0.id == receipt.id ? receipt : $0 })
            if receipt.state == .running {
                // Do not reschedule the same repeating callback; it retains its owner.
                self.monotonicAnchor = now
            } else {
                stopClock()
                countdownSeconds = 0
            }
        } catch {
            // Keep the old anchor after a failed save: a later sample measures the
            // entire unsaved segment, never a second addition to the durable value.
            checkpointError = error as? FocusError ?? .persistenceFailure
            if countdownSeconds == 0 { stopClock() } // unresolved completion; no duplicate write
        }
    }

    private func publish(_ rows: [FocusSessionSnapshot]) {
        snapshots = rows
        activeSession = rows.first(where: { $0.state.isActive })
        if let activeSession, activeSession.state == .paused {
            countdownSeconds = Int(ceil(Double(activeSession.plannedSeconds) - activeSession.accumulatedActiveSeconds))
        } else if activeSession == nil {
            countdownSeconds = nil
        }
    }
}
