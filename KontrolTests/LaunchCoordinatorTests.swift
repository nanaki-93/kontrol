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

private actor LaunchNewsService: NewsRefreshing {
    private(set) var refreshes = 0
    private(set) var validations = 0
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] {
        refreshes += 1
        return []
    }
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        validations += 1
        throw FeedServiceError(code: .offline, retryNotBefore: nil)
    }
}

@MainActor
private final class LaunchPreferencesRepository: AppPreferencesRepository {
    var failRead = true
    var loads = 0
    var saves = 0
    var value: AppPreferencesSnapshot = .defaults
    func load() throws -> AppPreferencesSnapshot {
        loads += 1
        if failRead { throw AppPreferencesError.invalidStoredData }
        return value
    }
    func save(_ draft: AppPreferencesDraft, expectedRevision: UUID?) throws -> AppPreferencesSnapshot {
        saves += 1
        guard expectedRevision == value.revision else { throw AppPreferencesError.staleRevision }
        value = AppPreferencesSnapshot(preferences: try draft.validated(), revision: UUID())
        return value
    }
}

// Shared launch test seams: a bookmark grant fails only after Projects is entered.
actor LaunchProjectInspector: ProjectInspecting {
    private(set) var reads = 0
    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        throw ProjectInspectionFailure.selectedAccess(.accessDenied)
    }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        reads += 1
        throw ProjectInspectionFailure.access(.staleBookmark)
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data {
        throw ProjectFolderAccessError.bookmarkCreationFailed
    }
}

@MainActor
final class LaunchProjectRepository: ProjectReferenceRepository {
    var references: [ProjectReferenceSnapshot] = []
    private(set) var fetches = 0
    func fetchAll() throws -> [ProjectReferenceSnapshot] {
        fetches += 1
        return references
    }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot {
        throw ProjectReferencePersistenceError.invalidReference
    }
    func remove(id: UUID, expectedRevision: UUID) throws {
        throw ProjectReferencePersistenceError.invalidReference
    }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot {
        throw ProjectReferencePersistenceError.invalidReference
    }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID,
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot {
        throw ProjectReferencePersistenceError.invalidReference
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
        XCTAssertEqual(graph.appPreferencesStore.state, .loaded)
        XCTAssertEqual(graph.appPreferencesStore.committed, .defaults)
        XCTAssertTrue(try rows(AppPreferencesRecord.self, in: container).isEmpty)
        await coordinator.start()
        await coordinator.retry()
        XCTAssertTrue(coordinator.dependencies === graph)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
    }

    func testLaunchSharesOneLazyProjectStoreAcrossConsumers() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let inspector = LaunchProjectInspector()
        let projectRepository = LaunchProjectRepository()
        let coordinator = LaunchCoordinator(open: { container }, makeDependencies: { container, catalog in
            AppDependencies(container: container, catalogRepository: catalog,
                projectInspector: inspector, projectRepository: projectRepository)
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        let graph = try XCTUnwrap(coordinator.dependencies)
        let firstWindowStore = graph.projectStore
        let secondWindowStore = try XCTUnwrap(coordinator.dependencies).projectStore
        XCTAssertTrue(firstWindowStore === secondWindowStore)
        XCTAssertFalse(firstWindowStore.isLoaded)
        XCTAssertEqual(projectRepository.fetches, 0)
        let reads = await inspector.reads
        XCTAssertEqual(reads, 0)
        await coordinator.start()
        XCTAssertTrue(coordinator.dependencies === graph)
        XCTAssertTrue(coordinator.dependencies?.projectStore === firstWindowStore)
        XCTAssertEqual(projectRepository.fetches, 0)
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

    func testPreferencesReadFailureIsIsolatedAndExplicitRecoveryAndSaveNeverContactNetwork() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let preferences = LaunchPreferencesRepository()
        let provider = LaunchProvider()
        let news = LaunchNewsService()
        let coordinator = LaunchCoordinator(open: { container }, makeDependencies: { container, catalog in
            AppDependencies(container: container, catalogRepository: catalog,
                appPreferencesRepository: preferences,
                aiSettingsRepository: LaunchAISettingsRepository(), credentialStore: LaunchCredentials(),
                aiGenerator: { _, _, _ in provider }, aiConnectionTester: { _, _, _ in provider },
                newsService: news)
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        let graph = try XCTUnwrap(coordinator.dependencies)
        let mainPreferences = graph.appPreferencesStore
        let nativePreferences = try XCTUnwrap(coordinator.dependencies).appPreferencesStore
        XCTAssertTrue(mainPreferences === nativePreferences)
        XCTAssertEqual(mainPreferences.state, .failed(.invalidStoredData))
        XCTAssertNil(mainPreferences.committed)
        XCTAssertEqual(preferences.loads, 1)
        XCTAssertEqual(preferences.saves, 0)
        XCTAssertNil(graph.newsStore.snapshot, "Construction must not load or refresh News")
        XCTAssertFalse(graph.aiSettingsStore.presentation.enabled)
        // Independent persisted offline operations still work with damaged preferences.
        let task = try graph.taskStore.create(input: TaskInput(title: "Offline work"))
        graph.taskStore.refresh()
        XCTAssertEqual(graph.taskStore.readState, .loaded)
        XCTAssertEqual(graph.taskStore.snapshots, [task])
        graph.learningCatalogStore.loadIfNeeded()
        let lessonID = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        _ = try graph.learningCatalogStore.openLesson(lessonID: lessonID)
        await coordinator.start()
        await coordinator.retry()
        XCTAssertTrue(coordinator.dependencies === graph)
        XCTAssertEqual(preferences.loads, 1, "Launch must not silently retry preferences")
        let generationsBefore = await provider.generations
        let connectionsBefore = await provider.connections
        let refreshesBefore = await news.refreshes
        let validationsBefore = await news.validations
        XCTAssertEqual(generationsBefore, 0)
        XCTAssertEqual(connectionsBefore, 0)
        XCTAssertEqual(refreshesBefore, 0)
        XCTAssertEqual(validationsBefore, 0)
        preferences.failRead = false
        nativePreferences.retry()
        XCTAssertEqual(mainPreferences.state, .loaded)
        let editor = AppPreferencesEditorDraft(snapshot: nativePreferences.editableSnapshot)
        editor.draft.focusDefaultMinutes = "37"
        editor.draft.textSize = .large
        try editor.save(using: nativePreferences)
        XCTAssertEqual(mainPreferences.committed, preferences.value)
        XCTAssertEqual(mainPreferences.committed?.preferences.focusDefaultMinutes, 37)
        XCTAssertEqual(preferences.saves, 1)
        XCTAssertEqual(preferences.loads, 2)
        XCTAssertEqual(graph.taskStore.snapshots, [task])
        let generationsAfter = await provider.generations
        let connectionsAfter = await provider.connections
        let refreshesAfter = await news.refreshes
        let validationsAfter = await news.validations
        XCTAssertEqual(generationsAfter, 0)
        XCTAssertEqual(connectionsAfter, 0)
        XCTAssertEqual(refreshesAfter, 0)
        XCTAssertEqual(validationsAfter, 0)
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
