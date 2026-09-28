import Foundation

/// A read failure cannot masquerade as an empty catalog. A cached projection is
/// available after failure only with the explicit stale flag on that state.
enum LearningCatalogReadState: Equatable {
    case notLoaded
    case loading
    case empty(LearningCatalogSnapshot)
    case current(LearningCatalogSnapshot)
    case failed(stale: LearningCatalogSnapshot?)

    var snapshot: LearningCatalogSnapshot? {
        switch self {
        case .empty(let value), .current(let value): return value
        case .failed(let stale): return stale
        case .notLoaded, .loading: return nil
        }
    }

    var isStale: Bool {
        if case .failed(stale: .some) = self { return true }
        return false
    }

    var isAuthoritative: Bool {
        switch self {
        case .empty, .current: return true
        default: return false
        }
    }
}

enum LessonDetailReadState: Equatable {
    case notLoaded
    case current(LessonDetailSnapshot)
    case failed(lessonID: String, stale: LessonDetailSnapshot?)
}

enum LessonHistoryReadState: Equatable {
    case notLoaded
    case current([LessonHistorySnapshot])
    case failed(stale: [LessonHistorySnapshot]?)
}

/// One publication for all projections affected by a committed learning command.
/// Stale content is retained for display, but never treated as an authoritative baseline.
struct LearningExperienceProjection: Equatable {
    var catalog: LearningCatalogReadState = .notLoaded
    var detail: LessonDetailReadState = .notLoaded
    var history: LessonHistoryReadState = .notLoaded
    var error: LessonExperienceError?
}

/// One app-owned publication point, shared by every window. No store method
/// reconciles slots or performs a fallible read after a successful commit.
@MainActor
final class LearningCatalogStore: ObservableObject {
    private let repository: any CatalogRepository
    @Published private(set) var projection = LearningExperienceProjection()
    var state: LearningCatalogReadState { projection.catalog }
    var detailState: LessonDetailReadState { projection.detail }
    var historyState: LessonHistoryReadState { projection.history }
    var error: LessonExperienceError? { projection.error }

    init(repository: any CatalogRepository) {
        self.repository = repository
    }

    func loadIfNeeded() {
        guard case .notLoaded = state else { return }
        refresh()
    }

    /// Explicit refresh for a later committed catalog change; no automatic polling.
    func refresh() {
        let last = state.snapshot
        projection.catalog = .loading
        do {
            let complete = try repository.loadSnapshot()
            projection.catalog = complete.slots.isEmpty ? .empty(complete) : .current(complete)
            clearErrorIfHealthy()
        } catch {
            projection.catalog = .failed(stale: last)
            projection.error = Self.classification(error)
        }
    }

    /// Retry only the failed catalog read. Detail and History failures have their
    /// own recovery paths and remain blocking until those reads succeed.
    func retry() {
        guard case .failed = state else { return }
        refresh()
    }

    @discardableResult
    func retryDetail(lessonID: String) throws -> LessonDetailSnapshot {
        guard case .failed(let requestedID, _) = detailState,
              requestedID == lessonID else { throw LessonExperienceError.invalidTransition }
        return try loadDetail(lessonID: lessonID)
    }

    @discardableResult
    func retryHistory() throws -> [LessonHistorySnapshot] {
        guard case .failed = historyState else { throw LessonExperienceError.invalidTransition }
        return try loadHistory()
    }

    /// Reading a detail or History never creates progress. A failed read retains
    /// only a same-ID detail as stale, and disables writes until repaired.
    @discardableResult
    func loadDetail(lessonID: String) throws -> LessonDetailSnapshot {
        do {
            let detail = try repository.loadLesson(lessonID: lessonID)
            guard detail.id == lessonID else { throw LessonExperienceError.invalidStoredData }
            projection.detail = .current(detail)
            clearErrorIfHealthy()
            return detail
        } catch {
            let stale: LessonDetailSnapshot?
            switch projection.detail {
            case .current(let value): stale = value.id == lessonID ? value : nil
            case .failed(_, let value): stale = value?.id == lessonID ? value : nil
            case .notLoaded: stale = nil
            }
            projection.detail = .failed(lessonID: lessonID, stale: stale)
            projection.error = Self.classification(error)
            throw error
        }
    }

    @discardableResult
    func loadHistory() throws -> [LessonHistorySnapshot] {
        do {
            let history = try repository.loadHistory()
            projection.history = .current(history)
            clearErrorIfHealthy()
            return history
        } catch {
            let stale: [LessonHistorySnapshot]?
            switch projection.history {
            case .current(let value): stale = value
            case .failed(let value): stale = value
            case .notLoaded: stale = nil
            }
            projection.history = .failed(stale: stale)
            projection.error = Self.classification(error)
            throw error
        }
    }

    @discardableResult
    func openLesson(lessonID: String, now: Date = Date()) throws -> LessonMutationResult {
        try mutate { try repository.openLesson(lessonID: lessonID, now: now) }
    }

    @discardableResult
    func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult {
        try mutate { try repository.saveAnswer(attemptID: attemptID, expectedRevision: expectedRevision, answer: answer) }
    }

    @discardableResult
    func revealSolution(attemptID: UUID, expectedRevision: Int, now: Date = Date()) throws -> LessonMutationResult {
        try mutate { try repository.revealSolution(attemptID: attemptID, expectedRevision: expectedRevision, now: now) }
    }

    @discardableResult
    func setSelfCheckAcknowledged(attemptID: UUID, expectedRevision: Int,
                                  acknowledged: Bool, now: Date = Date()) throws -> LessonMutationResult {
        try mutate { try repository.setSelfCheckAcknowledged(attemptID: attemptID, expectedRevision: expectedRevision,
                                                              acknowledged: acknowledged, now: now) }
    }

    @discardableResult
    func complete(attemptID: UUID, expectedRevision: Int, now: Date = Date()) throws -> LessonMutationResult {
        try mutate { try repository.complete(attemptID: attemptID, expectedRevision: expectedRevision, now: now) }
    }

    @discardableResult
    func dismiss(lessonID: String, expectedSlot: LessonSlotSnapshot, now: Date = Date()) throws -> LessonMutationResult {
        try mutate { try repository.dismiss(lessonID: lessonID, expectedSlot: expectedSlot, now: now) }
    }

    @discardableResult
    func restoreDismissed(lessonID: String, now: Date = Date()) throws -> LessonMutationResult {
        try mutate { try repository.restoreDismissed(lessonID: lessonID, now: now) }
    }

    private func mutate(_ operation: () throws -> LessonMutationResult) throws -> LessonMutationResult {
        guard state.isAuthoritative,
              !isDetailReadFailed, !isHistoryReadFailed else {
            // Keep the original read classification visible until an explicit retry.
            if projection.error == nil { projection.error = .invalidTransition }
            throw LessonExperienceError.invalidTransition
        }
        do {
            let receipt = try operation()
            // The repository constructed the entire receipt before its one save.
            // Never follow this with a read: a failing refresh cannot undo a commit.
            projection = LearningExperienceProjection(
                catalog: receipt.catalog.slots.isEmpty ? .empty(receipt.catalog) : .current(receipt.catalog),
                detail: .current(receipt.detail), history: .current(receipt.history), error: nil)
            return receipt
        } catch {
            projection.error = Self.classification(error)
            throw error
        }
    }

    private var isDetailReadFailed: Bool {
        if case .failed = detailState { return true }
        return false
    }

    private var isHistoryReadFailed: Bool {
        if case .failed = historyState { return true }
        return false
    }

    private func clearErrorIfHealthy() {
        if state.isAuthoritative, !isDetailReadFailed, !isHistoryReadFailed {
            projection.error = nil
        }
    }

    private static func classification(_ error: Error) -> LessonExperienceError {
        (error as? LessonExperienceError) ?? .persistenceFailure
    }
}
