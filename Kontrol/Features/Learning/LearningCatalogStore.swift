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

/// Unavailable membership and incomplete evidence are successful coverage reads.
/// A failed read is distinct from either, and its cached value is display-only.
enum LearningCoverageReadState: Equatable {
    case notLoaded
    case current(LearningCoverageSnapshot)
    case failed(stale: LearningCoverageSnapshot?)

    var snapshot: LearningCoverageSnapshot? {
        switch self {
        case .current(let value), .failed(stale: .some(let value)): return value
        case .notLoaded, .failed(stale: nil): return nil
        }
    }

    var isStale: Bool {
        if case .failed(stale: .some) = self { return true }
        return false
    }
}

/// One publication for all projections affected by a committed learning command.
/// Stale content is retained for display, but never treated as an authoritative baseline.
struct LearningExperienceProjection: Equatable {
    var catalog: LearningCatalogReadState = .notLoaded
    var detail: LessonDetailReadState = .notLoaded
    var history: LessonHistoryReadState = .notLoaded
    var coverage: LearningCoverageReadState = .notLoaded
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
    var coverageState: LearningCoverageReadState { projection.coverage }
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

    /// Coverage has its own retry path. Its failure does not poison catalog,
    /// detail or History reads (or discard local draft buffers).
    @discardableResult
    func loadCoverage() throws -> LearningCoverageSnapshot {
        do {
            let coverage = try repository.loadCoverage()
            projection.coverage = .current(coverage)
            return coverage
        } catch {
            projection.coverage = .failed(stale: coverageState.snapshot)
            throw error
        }
    }

    @discardableResult
    func retryCoverage() throws -> LearningCoverageSnapshot {
        guard case .failed = coverageState else { throw LessonExperienceError.invalidTransition }
        return try loadCoverage()
    }

    /// Schedule links can outlive an unstarted lesson's definition. A confirmed
    /// absence is local to that block, not a failed shared read that should prevent
    /// all other lessons from being opened. Other failures remain retryable here.
    @discardableResult
    func loadLinkedBlockDetail(lessonID: String) throws -> LessonDetailSnapshot {
        try readDetail(lessonID: lessonID, missingLinkIsLocal: true)
    }

    /// Reading a detail or History never creates progress. A failed read retains
    /// only a same-ID detail as stale, and disables writes until repaired.
    @discardableResult
    func loadDetail(lessonID: String) throws -> LessonDetailSnapshot {
        try readDetail(lessonID: lessonID, missingLinkIsLocal: false)
    }

    private func readDetail(lessonID: String, missingLinkIsLocal: Bool) throws -> LessonDetailSnapshot {
        do {
            let detail = try repository.loadLesson(lessonID: lessonID)
            guard detail.id == lessonID else { throw LessonExperienceError.invalidStoredData }
            projection.detail = .current(detail)
            clearErrorIfHealthy()
            return detail
        } catch {
            // Do not publish a permanent global failure for a deleted schedule
            // target. Preserve any prior detail/read error rather than clearing it.
            if missingLinkIsLocal, (error as? LessonExperienceError) == .lessonNotFound {
                throw error
            }
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

    /// Carry both the displayed assignment and concept across the write boundary.
    /// The repository checks the current slot and authoritative content before opening.
    @discardableResult
    func openConceptLesson(lessonID: String, expectedSlot: LessonSlotSnapshot?, expectedConceptID: String, now: Date = Date()) throws -> LessonMutationResult {
        try mutate { try repository.openConceptLesson(lessonID: lessonID, expectedSlot: expectedSlot,
                                                       expectedConceptID: expectedConceptID, now: now) }
    }

    @discardableResult
    func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult {
        try mutate { try repository.saveAnswer(attemptID: attemptID, expectedRevision: expectedRevision, answer: answer) }
    }

    /// Saving a draft cannot rotate a slot. If Coverage is unreadable, keep that
    /// failure visible while committing only the answer and its validated detail.
    /// All selection-dependent commands still require an authoritative Coverage read.
    func saveAnswerForDraft(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonDetailSnapshot {
        guard isCoverageReadFailed else {
            return try saveAnswer(attemptID: attemptID, expectedRevision: expectedRevision, answer: answer).detail
        }
        guard state.isAuthoritative, !isDetailReadFailed, !isHistoryReadFailed else {
            throw LessonExperienceError.invalidTransition
        }
        do {
            let detail = try repository.saveDraftAnswer(attemptID: attemptID,
                                                        expectedRevision: expectedRevision, answer: answer)
            projection.detail = .current(detail)
            clearErrorIfHealthy()
            return detail
        } catch {
            projection.error = Self.classification(error)
            throw error
        }
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
              !isDetailReadFailed, !isHistoryReadFailed, !isCoverageReadFailed else {
            // Keep the original read classification visible until an explicit retry.
            if projection.error == nil && !isCoverageReadFailed { projection.error = .invalidTransition }
            throw LessonExperienceError.invalidTransition
        }
        do {
            let receipt = try operation()
            // The repository constructed the entire receipt before its one save.
            // Never follow this with a read: a failing refresh cannot undo a commit.
            projection = LearningExperienceProjection(
                catalog: receipt.catalog.slots.isEmpty ? .empty(receipt.catalog) : .current(receipt.catalog),
                detail: .current(receipt.detail), history: .current(receipt.history),
                coverage: .current(receipt.coverage), error: nil)
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

    private var isCoverageReadFailed: Bool {
        if case .failed = coverageState { return true }
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
