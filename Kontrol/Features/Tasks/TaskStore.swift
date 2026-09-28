import AppKit
import Combine
import Foundation

/// Disposable clock and locale values used by selectors; never written to SwiftData.
struct TaskTemporalContext {
    let now: Date
    let calendar: Calendar
    let timeZone: TimeZone
}

/// A read failure is never equivalent to a successfully loaded empty collection.
/// Cached values remain visible only while explicitly marked stale.
enum TaskReadState: Equatable {
    case notLoaded
    case loaded
    case failed(hasStaleRows: Bool)

    var message: String? {
        switch self {
        case .notLoaded, .loaded:
            return nil
        case .failed(hasStaleRows: true):
            return "Could not refresh tasks. Showing previously loaded tasks. Retry to update."
        case .failed(hasStaleRows: false):
            return "Could not load tasks. Retry to update."
        }
    }
}

enum TaskMutationError: Equatable {
    case writeFailed
    case notFound

    var message: String {
        switch self {
        case .writeFailed:
            return "Could not save the task. Please try again."
        case .notFound:
            return "This task is no longer available. Refresh the list and try again."
        }
    }
}

/// One main-actor publication point for committed task values. This store owns
/// no ModelContext: every value is copied before leaving the repository.
@MainActor
final class TaskStore: ObservableObject {
    let repository: any TaskRepository
    /// Invoked only after the repository has committed a deletion. The dependency
    /// graph wires this to the focus owner; no notification bus or second read.
    var didDeleteTask: (@MainActor (UUID) -> Void)?
    @Published private(set) var snapshots: [TaskSnapshot] = []
    @Published private(set) var readState: TaskReadState = .notLoaded
    @Published private(set) var mutationError: TaskMutationError?
    @Published private(set) var temporalContext: TaskTemporalContext

    // One timer and one set of system observers per app-owned store. The seams
    // allow deterministic midnight, travel, and lifecycle tests without sleeping.
    typealias TimerScheduler = @MainActor (Date, @escaping () -> Void) -> () -> Void
    private let clock: () -> Date
    private let currentCalendar: () -> Calendar
    private let currentTimeZone: () -> TimeZone
    private let notificationCenter: NotificationCenter
    private let scheduleTimer: TimerScheduler
    private var cancelTimer: (() -> Void)?
    private var timerGeneration = 0
    private var observers: [NSObjectProtocol] = []

    init(repository: any TaskRepository,
         notificationCenter: NotificationCenter = .default,
         clock: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { .current },
         timeZone: @escaping () -> TimeZone = { .current },
         scheduleTimer: @escaping TimerScheduler = TaskStore.makeMidnightTimer) {
        self.repository = repository
        self.notificationCenter = notificationCenter
        self.clock = clock
        currentCalendar = calendar
        currentTimeZone = timeZone
        self.scheduleTimer = scheduleTimer
        temporalContext = TaskTemporalContext(now: clock(), calendar: calendar(), timeZone: timeZone())
        observeSystemChanges()
        rescheduleMidnight()
    }

    deinit {
        cancelTimer?()
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    /// Membership is always derived from snapshots and the current local context.
    /// An explicit selected date supports the Tasks day selection without shifting plans.
    func select(_ filter: TaskFilter, selectedDate: Date? = nil) -> [TaskSnapshot] {
        TaskSelection.select(snapshots, filter: filter,
                             selectedDate: selectedDate ?? temporalContext.now,
                             now: temporalContext.now, calendar: temporalContext.calendar,
                             timeZone: temporalContext.timeZone)
    }

    private func observeSystemChanges() {
        for name in [NSApplication.didBecomeActiveNotification,
                     .NSCalendarDayChanged, .NSSystemClockDidChange,
                     .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateTemporalContext()
                    if name == NSApplication.didBecomeActiveNotification {
                        self?.refresh() // External owners may have changed the store.
                    }
                }
            })
        }
    }

    private func updateTemporalContext() {
        temporalContext = TaskTemporalContext(now: clock(), calendar: currentCalendar(),
                                              timeZone: currentTimeZone())
        rescheduleMidnight()
    }

    private func rescheduleMidnight() {
        timerGeneration += 1
        cancelTimer?()
        cancelTimer = nil
        var local = temporalContext.calendar
        local.timeZone = temporalContext.timeZone
        guard let boundary = local.dateInterval(of: .day, for: temporalContext.now)?.end else { return }
        let generation = timerGeneration
        cancelTimer = scheduleTimer(boundary) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timerGeneration == generation else { return }
                self.updateTemporalContext()
            }
        }
    }

    private static func makeMidnightTimer(at boundary: Date, fire: @escaping () -> Void) -> () -> Void {
        let timer = Timer(fire: boundary, interval: 0, repeats: false) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// Called on appearance or by an explicit Retry action. No automatic retry
    /// of a write is safe, especially for a destructive operation.
    func refresh() {
        do {
            let values = try repository.fetchAll().map(TaskSnapshot.init)
            snapshots = values
            readState = .loaded
        } catch {
            readState = .failed(hasStaleRows: !snapshots.isEmpty)
        }
    }

    func retryRead() {
        refresh()
    }

    @discardableResult
    func create(input: TaskInput) throws -> TaskSnapshot {
        try perform {
            let committed = try repository.create(input: input)
            publish(committed)
            return committed
        }
    }

    @discardableResult
    func update(id: UUID, input: TaskInput) throws -> TaskSnapshot {
        try perform {
            let committed = try repository.update(id: id, input: input)
            publish(committed)
            return committed
        }
    }

    @discardableResult
    func setCompleted(id: UUID, completed: Bool) throws -> TaskSnapshot {
        try perform {
            let committed = try repository.setCompleted(id: id, completed: completed)
            publish(committed)
            return committed
        }
    }

    func delete(id: UUID) throws {
        try perform {
            try repository.delete(id: id)
            snapshots.removeAll { $0.id == id }
            updateStaleFlag()
            didDeleteTask?(id)
        }
    }

    private func publish(_ committed: TaskSnapshot) {
        // The returned value is the commit receipt. Never refetch here: a read
        // error after save must not invite a duplicate creation or conceal success.
        var next = snapshots.filter { $0.id != committed.id }
        next.append(committed)
        next.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        snapshots = next
        updateStaleFlag()
    }

    private func updateStaleFlag() {
        if case .failed = readState {
            readState = .failed(hasStaleRows: !snapshots.isEmpty)
        }
    }

    private func perform<T>(_ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            mutationError = nil
            return result
        } catch {
            if case TaskRepositoryError.notFound = error {
                mutationError = .notFound
                // A missing UUID can mean an external owner removed it. Read
                // again; if that fails, leave cached values marked stale.
                refresh()
            } else {
                mutationError = .writeFailed
            }
            throw error
        }
    }
}
