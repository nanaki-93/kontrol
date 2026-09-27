import SwiftData
import XCTest
@testable import Kontrol

private actor CatalogGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class LaunchCoordinatorTests: XCTestCase {
    private enum Injected: Error { case failed }

    private func rows<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func testConcurrentStartsPublishOnlyAfterOneOpenAndImport() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let gate = CatalogGate()
        let entered = expectation(description: "catalog loader entered")
        var opens = 0
        var imports = 0
        let coordinator = LaunchCoordinator(open: {
            opens += 1
            return container
        }, loadCatalog: {
            entered.fulfill()
            await gate.wait()
            return try BundledCatalogLoader.load()
        }, makeRepository: { container in
            SwiftDataCatalogRepository(container: container, beforeSave: { imports += 1 })
        })
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.dependencies)
        let first = Task { await coordinator.start() }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(coordinator.state, .opening)
        XCTAssertNil(coordinator.dependencies)
        await coordinator.start()
        await coordinator.start()
        await coordinator.retry()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 0)
        await gate.release()
        await first.value
        XCTAssertEqual(coordinator.state, .ready)
        let graph = try XCTUnwrap(coordinator.dependencies)
        XCTAssertTrue(graph.container === container)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(try rows(CatalogImportState.self, in: container).count, 1)
        XCTAssertEqual(try rows(LessonDefinition.self, in: container).count, 5)
        XCTAssertTrue(try rows(LessonProgress.self, in: container).isEmpty)
        XCTAssertTrue(try rows(LessonAttempt.self, in: container).isEmpty)
        XCTAssertTrue(try rows(TaskItem.self, in: container).isEmpty)
        await coordinator.start()
        await coordinator.retry()
        XCTAssertTrue(coordinator.dependencies === graph)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
    }

    func testCatalogFailureDoesNotPublishGraphAndExplicitRetryKeepsStore() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var opens = 0
        var imports = 0
        let coordinator = LaunchCoordinator(open: {
            opens += 1
            return container
        }, loadCatalog: {
            try BundledCatalogLoader.load()
        }, makeRepository: { container in
            SwiftDataCatalogRepository(container: container, beforeSave: {
                imports += 1
                if imports == 1 { throw Injected.failed }
            })
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.catalog))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(try rows(CatalogImportState.self, in: container).isEmpty)
        await coordinator.start() // no automatic retry
        XCTAssertEqual(imports, 1)
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.dependencies?.container === container)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 2)
    }

    func testDefaultLoaderValidatesBundledResourceBeforeImport() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let coordinator = LaunchCoordinator(open: { container })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.dependencies?.container === container)
        XCTAssertEqual(try rows(CatalogImportState.self, in: container).map(\.lastImportedVersion), [1])
        XCTAssertEqual(try rows(LessonDefinition.self, in: container).count, 5)
    }

    func testFactoryErrorNeverPublishesDependenciesAndCanBeRetried() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var opens = 0
        let coordinator = LaunchCoordinator(open: {
            opens += 1
            if opens == 1 { throw Injected.failed }
            return container
        }, loadCatalog: { try BundledCatalogLoader.load() })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.store))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertEqual(opens, 1)
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.dependencies?.container === container)
        XCTAssertEqual(opens, 2)
    }
}
