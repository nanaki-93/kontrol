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
}

/// One app-owned publication point. Repository reads copy committed values out
/// of a private context; the store never reconciles slots or creates progress.
@MainActor
final class LearningCatalogStore: ObservableObject {
    private let repository: any CatalogRepository
    @Published private(set) var state: LearningCatalogReadState = .notLoaded
    private var lastSuccessfulSnapshot: LearningCatalogSnapshot?

    init(repository: any CatalogRepository) {
        self.repository = repository
    }

    func loadIfNeeded() {
        guard case .notLoaded = state else { return }
        refresh()
    }

    /// Explicit refresh for a later committed catalog change; no automatic polling.
    func refresh() {
        state = .loading
        do {
            let complete = try repository.loadSnapshot()
            lastSuccessfulSnapshot = complete
            state = complete.slots.isEmpty ? .empty(complete) : .current(complete)
        } catch {
            state = .failed(stale: lastSuccessfulSnapshot)
        }
    }

    func retry() {
        guard case .failed = state else { return }
        refresh()
    }
}
