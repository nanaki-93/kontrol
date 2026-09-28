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
    case noRetryPending
    case completionPending
}

/// Only a classification and action are published; no task or store data is logged.
enum FocusMutationAction: Equatable {
    case start(FocusConfiguration)
    case pause, resume, end
    case recover(FocusRecoveryChoice)
}

struct FocusMutationFailure: Equatable {
    let action: FocusMutationAction
    let error: FocusError
}

struct FocusTemporalContext {
    let now: Date
    let calendar: Calendar
    let timeZone: TimeZone
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
    @Published private(set) var mutationFailure: FocusMutationFailure?
    @Published private(set) var completionPendingError: FocusError?
    @Published private(set) var temporalContext: FocusTemporalContext

    func history(_ filter: FocusHistoryFilter) -> FocusHistoryResult {
        FocusHistorySelection.select(snapshots, filter: filter, now: temporalContext.now,
                                     calendar: temporalContext.calendar, timeZone: temporalContext.timeZone)
    }

    private let wallClock: () -> Date
    private let monotonicClock: () -> ContinuousClock.Instant
    private let scheduleTick: (@escaping () -> Void) -> () -> Void
    private let currentCalendar: () -> Calendar
    private let currentTimeZone: () -> TimeZone
    private let scheduleMidnight: (Date, @escaping () -> Void) -> () -> Void
    private var cancelMidnight: (() -> Void)?
    private var midnightGeneration = 0
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancelTick: (() -> Void)?
    private var generation = 0
    private var monotonicAnchor: ContinuousClock.Instant?
    private var clockSessionID: UUID?
    private var didCompleteInitialLoad = false
    private let checkpointInterval: TimeInterval = 15
    private var nextCheckpointRetry: ContinuousClock.Instant?
    private var pendingCompletion: FocusTimingChange?

    init(repository: any FocusRepository,
         wallClock: @escaping () -> Date = Date.init,
         monotonicClock: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
         scheduleTick: @escaping (@escaping () -> Void) -> () -> Void = { callback in
             let timer = Timer(timeInterval: 1, repeats: true) { _ in callback() }
             RunLoop.main.add(timer, forMode: .common)
             return { timer.invalidate() }
         },
         notificationCenter: NotificationCenter = .default,
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         calendar: @escaping () -> Calendar = { .current },
         timeZone: @escaping () -> TimeZone = { .current },
         scheduleMidnight: @escaping (Date, @escaping () -> Void) -> () -> Void = { boundary, callback in
             let timer = Timer(fire: boundary, interval: 0, repeats: false) { _ in callback() }
             RunLoop.main.add(timer, forMode: .common)
             return { timer.invalidate() }
         }) {
        self.repository = repository
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.scheduleTick = scheduleTick
        self.currentCalendar = calendar
        self.currentTimeZone = timeZone
        self.scheduleMidnight = scheduleMidnight
        temporalContext = FocusTemporalContext(now: wallClock(), calendar: calendar(), timeZone: timeZone())
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        observeLifecycle()
        rescheduleMidnight()
    }

    deinit {
        cancelMidnight?()
        cancelTick?()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    private func observeLifecycle() {
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemClockDidChange,
                     NSApplication.willTerminateNotification] {
            let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshTemporalContext()
                    self?.sampleTick(forceCheckpoint: name != NSApplication.didBecomeActiveNotification)
                }
            }
            observers.append((notificationCenter, token))
        }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                     NSLocale.currentLocaleDidChangeNotification] {
            let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTemporalContext() }
            }
            observers.append((notificationCenter, token))
        }
        let token = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleTick(forceCheckpoint: true) }
            }
        observers.append((workspaceNotificationCenter, token))
    }

    private func refreshTemporalContext() {
        temporalContext = FocusTemporalContext(now: wallClock(), calendar: currentCalendar(),
                                               timeZone: currentTimeZone())
        rescheduleMidnight()
    }

    private func rescheduleMidnight() {
        midnightGeneration &+= 1
        cancelMidnight?()
        cancelMidnight = nil
        var local = temporalContext.calendar
        local.timeZone = temporalContext.timeZone
        guard let boundary = local.dateInterval(of: .day, for: temporalContext.now)?.end else { return }
        let owner = midnightGeneration
        cancelMidnight = scheduleMidnight(boundary) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.midnightGeneration == owner else { return }
                self.refreshTemporalContext()
            }
        }
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
            if pendingCompletion != nil { stopClock() }
            else if let activeSession, activeSession.state == .running {
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

    /// The task repository cleared these links in the deletion transaction. Update
    /// only affected cached metadata: a fetch or load here could replay startup
    /// recovery, discard unsaved monotonic time, or reset a running tick owner.
    func taskWasDeleted(id: UUID) {
        guard snapshots.contains(where: { $0.linkedTaskID == id }) else { return }
        let updated = snapshots.map { row -> FocusSessionSnapshot in
            guard row.linkedTaskID == id else { return row }
            // A valid row remains valid when its scalar task link is removed. Keep
            // the captured title and every timing field exactly as committed.
            return try! FocusSessionSnapshot(
                id: row.id, state: row.state, plannedSeconds: row.plannedSeconds,
                accumulatedActiveSeconds: row.accumulatedActiveSeconds,
                activeSegmentStartedAt: row.activeSegmentStartedAt, deadline: row.deadline,
                pausedAt: row.pausedAt, startedAt: row.startedAt, endedAt: row.endedAt,
                checkpointAt: row.checkpointAt, recoveryRequired: row.recoveryRequired,
                linkedLessonID: row.linkedLessonID, linkedTitleSnapshot: row.linkedTitleSnapshot)
        }
        snapshots = updated
        if let activeSession, activeSession.linkedTaskID == id {
            self.activeSession = updated.first { $0.id == activeSession.id }
        }
    }

    func start(configuration: FocusConfiguration) throws {
        try perform(.start(configuration))
    }

    func pause() throws { try perform(.pause) }
    func resume() throws { try perform(.resume) }
    func end() throws { try perform(.end) }
    func resolveRecovery(_ choice: FocusRecoveryChoice) throws { try perform(.recover(choice)) }

    /// Explicit user retry, not an automatic second submission. Calculations for a
    /// running session sample the *original* monotonic anchor at retry time.
    func retryMutation() throws {
        guard let failure = mutationFailure else { throw FocusServiceError.noRetryPending }
        try perform(failure.action)
    }

    func retryCheckpoint() {
        guard checkpointError != nil, pendingCompletion == nil else { return }
        sampleTick(forceCheckpoint: true, bypassRetryDelay: true)
    }

    func retryCompletion() throws {
        guard let change = pendingCompletion, let session = activeSession else {
            throw FocusServiceError.noRetryPending
        }
        do {
            let receipt = try repository.transition(id: session.id, command: change.transition,
                                                     effectiveEndedAt: change.snapshot.endedAt)
            pendingCompletion = nil
            completionPendingError = nil
            checkpointError = nil
            mutationFailure = nil
            publish(snapshots.map { $0.id == receipt.id ? receipt : $0 })
        } catch {
            completionPendingError = classify(error)
            throw error
        }
    }

    private func perform(_ action: FocusMutationAction) throws {
        // Preflight failures never replace a pending write retry. In particular a
        // failed Start must remain retryable after an unrelated Pause is rejected.
        if pendingCompletion != nil { throw FocusServiceError.completionPending }
        let receipt: FocusSessionSnapshot
        switch action {
        case .start(let configuration):
            guard readState.canStart else { throw FocusServiceError.activeStatusUnknown }
            guard activeSession == nil else { throw FocusError.activeSessionConflict }
            let input = FocusStartInput(plannedSeconds: try configuration.plannedSeconds(),
                startedAt: wallClock(), linkedTaskID: configuration.linkedTaskID)
            do { receipt = try repository.create(input: input) }
            catch {
                recordMutationFailure(error, for: action)
                throw error
            }
            publish([receipt] + snapshots)
            startClock()
        case .pause, .resume, .end, .recover:
            guard let session = activeSession else { throw FocusError.invalidTransition }
            let wall = wallClock()
            let change: FocusTimingChange
            switch action {
            case .pause:
                change = try FocusTiming.pause(session, at: wall, monotonicDelta: runningDelta())
            case .resume:
                change = try FocusTiming.resume(session, at: wall)
            case .end:
                if session.state == .running {
                    change = try FocusTiming.end(session, at: wall, monotonicDelta: runningDelta())
                } else {
                    guard session.state == .paused, !session.recoveryRequired else {
                        throw FocusError.invalidTransition
                    }
                    let stamp = max(wall, session.checkpointAt)
                    let payload = FocusTransitionPayload(expectedCheckpointAt: session.checkpointAt,
                        sampledAt: stamp, accumulatedActiveSeconds: session.accumulatedActiveSeconds)
                    change = FocusTimingChange(transition: .end(payload), snapshot: session)
                }
            case .recover(let choice):
                guard session.state == .paused, session.recoveryRequired else {
                    throw FocusError.invalidTransition
                }
                let stamp = max(wall, session.checkpointAt)
                let payload = FocusTransitionPayload(expectedCheckpointAt: session.checkpointAt,
                    sampledAt: stamp, accumulatedActiveSeconds: session.accumulatedActiveSeconds)
                change = FocusTimingChange(transition: .recover(choice, payload), snapshot: session)
            case .start: fatalError("Handled above")
            }
            do {
                let finish: Date?
                if case .complete = change.transition { finish = change.snapshot.endedAt }
                else { finish = nil }
                receipt = try repository.transition(id: session.id, command: change.transition,
                                                    effectiveEndedAt: finish)
            } catch {
                if case .complete = change.transition {
                    // Completion supersedes any earlier retry: only its frozen finish
                    // may now resolve this active session.
                    mutationFailure = nil
                    pendingCompletion = change
                    completionPendingError = classify(error)
                    stopClock()
                    countdownSeconds = 0
                } else {
                    recordMutationFailure(error, for: action)
                }
                throw error
            }
            publish(snapshots.map { $0.id == receipt.id ? receipt : $0 })
            if receipt.state == .running { startClock() } else { stopClock() }
        }
        mutationFailure = nil
        checkpointError = nil
    }

    private func recordMutationFailure(_ error: Error, for action: FocusMutationAction) {
        // Repository preconditions (conflict, stale baseline, missing task, etc.)
        // are returned to the caller, not advertised as failed persistence writes.
        guard case .persistenceFailure = error as? FocusError else { return }
        if mutationFailure == nil || mutationFailure?.action == action {
            mutationFailure = FocusMutationFailure(action: action, error: .persistenceFailure)
        }
    }

    private func classify(_ error: Error) -> FocusError {
        error as? FocusError ?? .persistenceFailure
    }

    private func runningDelta() -> TimeInterval {
        guard let monotonicAnchor else { return 0 }
        let parts = monotonicAnchor.duration(to: monotonicClock()).components
        return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
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
        nextCheckpointRetry = nil
    }

    /// The callback is only an opportunity to sample ContinuousClock. Persisted
    /// checkpoints replace both the wall and monotonic anchors after the save.
    private func sampleTick(forceCheckpoint: Bool = false, bypassRetryDelay: Bool = false) {
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
            if let nextCheckpointRetry, now < nextCheckpointRetry,
               !sample.isComplete, !bypassRetryDelay { return }
            let change = try FocusTiming.checkpoint(session, at: wall, monotonicDelta: delta)
            let receipt: FocusSessionSnapshot
            do {
                receipt = try repository.transition(id: session.id, command: change.transition,
                                                    effectiveEndedAt: change.snapshot.endedAt)
            } catch {
                if sample.isComplete {
                    mutationFailure = nil // completion supersedes an earlier transition retry
                    pendingCompletion = change
                    completionPendingError = classify(error)
                    stopClock() // no automatic duplicate terminal write
                } else {
                    nextCheckpointRetry = now.advanced(by: .seconds(checkpointInterval))
                    checkpointError = classify(error)
                }
                return
            }
            nextCheckpointRetry = nil
            checkpointError = nil
            if receipt.state == .completed { mutationFailure = nil }
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
            if countdownSeconds == 0 { stopClock() } // invalid calculation; never claim success
        }
    }

    private func publish(_ rows: [FocusSessionSnapshot]) {
        refreshTemporalContext()
        snapshots = rows
        activeSession = rows.first(where: { $0.state.isActive })
        if let activeSession, activeSession.state == .paused {
            countdownSeconds = Int(ceil(Double(activeSession.plannedSeconds) - activeSession.accumulatedActiveSeconds))
        } else if activeSession == nil {
            countdownSeconds = nil
        }
    }
}
