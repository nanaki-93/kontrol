import Foundation
import SwiftData

enum LaunchState: Equatable {
    case idle
    case opening
    case ready
    case failed(LaunchFailure)
}

@MainActor
final class LaunchCoordinator: ObservableObject {
    @Published private(set) var state: LaunchState = .idle
    private(set) var dependencies: AppDependencies?

    private let open: () throws -> ModelContainer
    private let loadCatalog: @Sendable () async throws -> ValidatedCatalog
    private let makeRepository: (ModelContainer) -> any CatalogRepository
    private let makeDependencies: ((ModelContainer, any CatalogRepository) -> AppDependencies)?
    // Keep a successfully opened store if catalog loading/import fails. Retry
    // must never open a competing container against that store.
    private var openedContainer: ModelContainer?

    init(open: @escaping () throws -> ModelContainer = {
        try ModelContainerFactory().makeProductionContainer()
    }, loadCatalog: @escaping @Sendable () async throws -> ValidatedCatalog = {
        try await Task.detached(priority: .userInitiated) {
            try BundledCatalogLoader.load()
        }.value
    }, makeRepository: ((ModelContainer) -> any CatalogRepository)? = nil,
       makeDependencies: ((ModelContainer, any CatalogRepository) -> AppDependencies)? = nil) {
        self.open = open
        self.loadCatalog = loadCatalog
        self.makeRepository = makeRepository ?? { SwiftDataCatalogRepository(container: $0) }
        self.makeDependencies = makeDependencies
    }

    /// Multiple window or scene requests during an attempt share that attempt.
    /// Once ready, subsequent calls cannot re-open or re-import.
    func start() async {
        guard state == .idle else { return }
        await attempt()
    }

    /// Explicit recovery, never an automatic retry loop. Opening/ready calls
    /// are no-ops; catalog retries reuse the open container.
    func retry() async {
        guard case .failed = state else { return }
        await attempt()
    }

    private func attempt() async {
        let previousState = state
        state = .opening // synchronous main-actor gate, before the first suspension
        if Task.isCancelled {
            state = previousState
            return
        }
        let container: ModelContainer
        if let openedContainer {
            container = openedContainer
        } else {
            do {
                container = try open()
                // A successful open is retained even if catalog work is cancelled.
                openedContainer = container
            } catch {
                if Task.isCancelled {
                    state = previousState
                } else {
                    SafeLaunchLogger.failure(stage: .storeOpen, error: error)
                    state = .failed(.store)
                }
                return
            }
        }
        if Task.isCancelled {
            state = previousState
            return
        }
        do {
            // This boundary returns only value data; the default loader performs
            // resource IO, decoding, fingerprint checks and validation off-main.
            let catalog = try await loadCatalog()
            try Task.checkCancellation() // loaders need not cooperate with cancellation
            let repository = makeRepository(container)
            _ = try repository.importIfNeeded(catalog)
            try Task.checkCancellation() // do not publish a stale result
            // AI settings are optional: their store handles read/credential failures
            // locally, never as a catalog launch prerequisite.
            dependencies = makeDependencies?(container, repository) ??
                AppDependencies(container: container, catalogRepository: repository)
            state = .ready
        } catch {
            if Task.isCancelled {
                state = previousState
            } else {
                SafeLaunchLogger.failure(stage: .catalogInitialization, error: error)
                state = .failed(.catalog)
            }
        }
    }
}
