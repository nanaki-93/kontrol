import Foundation
import SwiftData

// Failure presentation and diagnostics are added in the recovery step. Never
// publish a partially initialized graph, including on catalog import failure.
enum LaunchFailure: Equatable {
    case store
    case catalog
}

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
    // Keep a successfully opened store if catalog loading/import fails. Retry
    // must never open a competing container against that store.
    private var openedContainer: ModelContainer?

    init(open: @escaping () throws -> ModelContainer = {
        try ModelContainerFactory().makeProductionContainer()
    }, loadCatalog: @escaping @Sendable () async throws -> ValidatedCatalog = {
        try await Task.detached(priority: .userInitiated) {
            try BundledCatalogLoader.load()
        }.value
    }, makeRepository: ((ModelContainer) -> any CatalogRepository)? = nil) {
        self.open = open
        self.loadCatalog = loadCatalog
        self.makeRepository = makeRepository ?? { SwiftDataCatalogRepository(container: $0) }
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
        state = .opening
        let container: ModelContainer
        if let openedContainer {
            container = openedContainer
        } else {
            do {
                container = try open()
                openedContainer = container
            } catch {
                state = .failed(.store)
                return
            }
        }
        do {
            // This boundary returns only value data; the default loader performs
            // resource IO, decoding, fingerprint checks and validation off-main.
            let catalog = try await loadCatalog()
            let repository = makeRepository(container)
            _ = try repository.importIfNeeded(catalog)
            dependencies = AppDependencies(container: container, catalogRepository: repository)
            state = .ready
        } catch {
            state = .failed(.catalog)
        }
    }
}
