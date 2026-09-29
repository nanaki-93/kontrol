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
private final class LaunchAISettingsRepository: AISettingsRepository {
    var value: AISettingsSnapshot = .disabled
    func load() throws -> AISettingsSnapshot { value }
    func save(_ snapshot: AISettingsSnapshot, expectedRevision: UUID?) throws -> AISettingsSnapshot {
        guard value.revision == expectedRevision else { throw AISettingsPersistenceError.staleRevision }
        value = AISettingsSnapshot(enabled: snapshot.enabled, providerID: snapshot.providerID,
            modelID: snapshot.modelID, credentialReference: snapshot.credentialReference, revision: UUID())
        return value
    }
}

private final class LaunchCredentials: CredentialStore {
    var keys: [String: Data] = [:]
    func read(reference: String) throws -> Data {
        guard let key = keys[reference] else { throw CredentialStoreError.missing }
        return key
    }
    func save(_ credential: Data, reference: String) throws { keys[reference] = credential }
    func remove(reference: String) throws { keys.removeValue(forKey: reference) }
}

private actor LaunchProvider: LessonGenerator, OpenAIConnectionTesting {
    private(set) var generations = 0
    private(set) var connections = 0
    func generate(_ request: LessonGenerationRequest) async throws -> GeneratedLessonResponse {
        generations += 1
        throw LessonGenerationError.providerFailure
    }
    func testConnection() async throws { connections += 1 }
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
        XCTAssertEqual(graph.learningCatalogStore.state, .notLoaded)
        let firstConsumer = graph.learningCatalogStore
        let secondConsumer = graph.learningCatalogStore
        XCTAssertTrue(firstConsumer === secondConsumer)
        firstConsumer.loadIfNeeded()
        XCTAssertEqual(firstConsumer.state.snapshot?.slots.count, 20)
        XCTAssertEqual(secondConsumer.state.snapshot?.slots, try graph.catalogRepository.loadSnapshot().slots)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(try rows(CatalogImportState.self, in: container).count, 1)
        XCTAssertEqual(try rows(LessonDefinition.self, in: container).count, 40)
        XCTAssertEqual(try rows(LessonSlot.self, in: container).count, 20)
        XCTAssertTrue(try rows(LessonProgress.self, in: container).isEmpty)
        XCTAssertTrue(try rows(LessonAttempt.self, in: container).isEmpty)
        XCTAssertTrue(try rows(TaskItem.self, in: container).isEmpty)
        await coordinator.start()
        await coordinator.retry()
        XCTAssertTrue(coordinator.dependencies === graph)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
    }

    func testSharedAIConfigurationIsOptInAndOrdinaryLearningNeverContactsProvider() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let config = LaunchAISettingsRepository()
        let credentials = LaunchCredentials()
        let provider = LaunchProvider()
        let coordinator = LaunchCoordinator(open: { container }, makeDependencies: { container, repository in
            AppDependencies(container: container, catalogRepository: repository,
                aiSettingsRepository: config, credentialStore: credentials,
                aiGenerator: { _, _, _ in provider }, aiConnectionTester: { _, _, _ in provider })
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        let graph = try XCTUnwrap(coordinator.dependencies)
        XCTAssertFalse(graph.aiSettingsStore.presentation.enabled)
        XCTAssertNil(graph.aiSettingsStore.presentation.revision)
        XCTAssertFalse(graph.aiSettingsStore.operationGate.isBusy)
        graph.learningCatalogStore.loadIfNeeded()
        let before = try graph.catalogRepository.loadSnapshot()
        let choice = try XCTUnwrap(before.slots.first?.lessonID)
        _ = try graph.learningCatalogStore.openLesson(lessonID: choice)
        let initialGenerations = await provider.generations
        let initialConnections = await provider.connections
        XCTAssertEqual(initialGenerations, 0)
        XCTAssertEqual(initialConnections, 0)
        try graph.aiSettingsStore.saveConfiguration(modelID: "gpt-4o-mini", credential: Data([1, 2, 3]),
            expectedRevision: nil)
        XCTAssertFalse(graph.aiSettingsStore.presentation.enabled, "Saving a key does not opt in")
        let savedGenerations = await provider.generations
        let savedConnections = await provider.connections
        XCTAssertEqual(savedGenerations, 0)
        XCTAssertEqual(savedConnections, 0)
        let settingsFromMain = graph.aiSettingsStore
        let settingsFromNativeScene = coordinator.dependencies!.aiSettingsStore
        XCTAssertTrue(settingsFromMain === settingsFromNativeScene)
        XCTAssertTrue(graph.lessonGenerationStore === coordinator.dependencies!.lessonGenerationStore)
        XCTAssertTrue((graph.credentialStore as AnyObject) === credentials)
        try settingsFromNativeScene.enable(expectedRevision: settingsFromMain.presentation.revision)
        XCTAssertEqual(settingsFromMain.presentation.revision, settingsFromNativeScene.presentation.revision)
        XCTAssertTrue(settingsFromMain.presentation.enabled)
        let enabledGenerations = await provider.generations
        let enabledConnections = await provider.connections
        XCTAssertEqual(enabledGenerations, 0)
        XCTAssertEqual(enabledConnections, 0)
        await coordinator.start()
        XCTAssertTrue(coordinator.dependencies === graph)
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
        XCTAssertEqual(try rows(CatalogImportState.self, in: container).map(\.lastImportedVersion), [2])
        XCTAssertEqual(try rows(LessonDefinition.self, in: container).count, 40)
        XCTAssertEqual(try rows(LessonSlot.self, in: container).count, 20)
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
