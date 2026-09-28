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

    private let wallClock: () -> Date
    private let monotonicClock: () -> ContinuousClock.Instant
    private var monotonicAnchor: ContinuousClock.Instant?
    private var didCompleteInitialLoad = false

    init(repository: any FocusRepository,
         wallClock: @escaping () -> Date = Date.init,
         monotonicClock: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.repository = repository
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
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
        monotonicAnchor = monotonicClock()
        publish([receipt] + snapshots)
    }

    private func publish(_ rows: [FocusSessionSnapshot]) {
        snapshots = rows
        activeSession = rows.first(where: { $0.state.isActive })
    }
}
