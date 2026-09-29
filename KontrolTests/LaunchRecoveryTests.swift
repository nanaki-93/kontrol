import Foundation
import SwiftData
import XCTest
@testable import Kontrol

private actor RecoveryGate {
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
private final class UnavailableAISettings: AISettingsRepository {
    func load() throws -> AISettingsSnapshot { throw AISettingsPersistenceError.invalidSettings }
    func save(_ settings: AISettingsSnapshot, expectedRevision: UUID?) throws -> AISettingsSnapshot {
        throw AISettingsPersistenceError.invalidSettings
    }
}

private final class UnavailableCredentials: CredentialStore {
    func read(reference: String) throws -> Data { throw CredentialStoreError.inaccessible }
    func save(_ credential: Data, reference: String) throws { throw CredentialStoreError.inaccessible }
    func remove(reference: String) throws { throw CredentialStoreError.inaccessible }
}

@MainActor
private final class EnabledAISettings: AISettingsRepository {
    private let snapshot = AISettingsSnapshot(enabled: true, providerID: "openai", modelID: "gpt-4o-mini",
        credentialReference: UUID().uuidString, revision: UUID())
    func load() throws -> AISettingsSnapshot { snapshot }
    func save(_ settings: AISettingsSnapshot, expectedRevision: UUID?) throws -> AISettingsSnapshot {
        throw AISettingsPersistenceError.staleRevision
    }
}

@MainActor
final class LaunchRecoveryTests: XCTestCase {
    private enum Injected: Error { case store, catalog }

    private func fileBytes(in directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return try Dictionary(uniqueKeysWithValues: files.compactMap { file in
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil as (String, Data)?
            }
            return (file.lastPathComponent, try Data(contentsOf: file))
        })
    }

    func testStoreFailurePreservesEveryFileOfClosedV1CopyAndRetryUsesSameLocation() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V1", withExtension: nil))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        for name in try fileBytes(in: source).keys {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                             to: work.appendingPathComponent(name))
        }
        let before = try fileBytes(in: work)
        XCTAssertEqual(Set(before.keys), ["Kontrol.store", "Kontrol.store-shm", "Kontrol.store-wal"])
        let storeURL = work.appendingPathComponent("Kontrol.store")
        var opens = 0
        let coordinator = LaunchCoordinator(open: {
            opens += 1
            if opens == 1 { throw Injected.store } // fail before factory touches the closed copy
            return try ModelContainerFactory().makeContainer(mode: .persistent(storeURL))
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.store))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertEqual(opens, 1)
        // Compare the full set and contents BEFORE any successful open can change
        // SQLite WAL/SHM files. This is the preservation guarantee on failure.
        XCTAssertEqual(try fileBytes(in: work), before)
        await coordinator.start() // failure cannot initiate an automatic retry
        XCTAssertEqual(opens, 1)
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(opens, 2)
        let container = try XCTUnwrap(coordinator.dependencies?.container)
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.map(\.id), [UUID(uuidString: "D07A6D98-65ED-4B59-92B2-DA3CED39F3E5")!])
    }

    func testSignedAppDebugInjectionIsOptInAndUsesOnlyAnIsolatedStore() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolSignedRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }

        let coordinator = makeAppLaunchCoordinator(
            environment: ["KONTROL_F00_RECOVERY_TEST": "1"], temporaryDirectory: work)
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.store))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty,
                      "Injected first open must do no disk IO")
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        let directories = try FileManager.default.contentsOfDirectory(
            at: work, includingPropertiesForKeys: nil)
        XCTAssertEqual(directories.count, 1)
        let directory = try XCTUnwrap(directories.first)
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("KontrolF00Recovery-"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Kontrol.store").path))
        await coordinator.start()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).count, 1)
    }

    func testCatalogFailureSerializesRepeatedRetriesAndRetainsOpenedStore() async throws {
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
                if imports == 1 { throw Injected.catalog }
            })
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.catalog))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.dependencies?.container === container)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 2)
    }

    func testRetryWhileOpeningIsIgnoredAndCancellationCannotPublishLateResult() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let gate = RecoveryGate()
        let entered = expectation(description: "retry loader entered")
        let calls = RecoveryCalls()
        var opens = 0
        let coordinator = LaunchCoordinator(open: {
            opens += 1
            return container
        }, loadCatalog: {
            let count = await calls.next()
            if count == 1 { throw Injected.catalog }
            if count == 2 {
                entered.fulfill()
                await gate.wait() // deliberately ignores cancellation
            }
            return try BundledCatalogLoader.load()
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.catalog))
        XCTAssertNil(coordinator.dependencies)
        let pending = Task { await coordinator.retry() }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(coordinator.state, .opening)
        await coordinator.retry()
        await coordinator.retry()
        await coordinator.start()
        let countWhileOpening = await calls.count
        XCTAssertEqual(countWhileOpening, 2)
        XCTAssertEqual(opens, 1)
        XCTAssertNil(coordinator.dependencies)
        pending.cancel()
        await gate.release()
        await pending.value
        XCTAssertEqual(coordinator.state, .failed(.catalog))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertEqual(opens, 1)
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        let finalCount = await calls.count
        XCTAssertEqual(finalCount, 3)
        XCTAssertEqual(opens, 1)
    }

    func testCancelledFirstStartReturnsToIdleWithoutPublishingAndMayStartAgain() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let gate = RecoveryGate()
        let entered = expectation(description: "initial loader entered")
        let calls = RecoveryCalls()
        let coordinator = LaunchCoordinator(open: { container }, loadCatalog: {
            if await calls.next() == 1 {
                entered.fulfill()
                await gate.wait()
            }
            return try BundledCatalogLoader.load()
        })
        let pending = Task { await coordinator.start() }
        await fulfillment(of: [entered], timeout: 10)
        pending.cancel()
        await gate.release()
        await pending.value
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.dependencies)
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.dependencies?.container === container)
    }

    func testInvalidCatalogAndFailedSaveRetryOnOpenedContainerWithoutPartialPublication() async throws {
        for failure in ["validation", "beforeSave", "save"] {
            let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
            let calls = RecoveryCalls()
            var opens = 0
            var commits = 0
            let coordinator = LaunchCoordinator(open: {
                opens += 1
                return container
            }, loadCatalog: {
                let seed = try BundledCatalogLoader.load()
                let loadNumber = await calls.next()
                if failure == "validation" && loadNumber == 1 {
                    var invalid = seed.value
                    invalid.lessons[0].exercise += " Unhashed change"
                    return try CatalogValidator.validate(invalid)
                }
                return seed
            }, makeRepository: { container in
                SwiftDataCatalogRepository(container: container,
                    beforeSave: {
                        if failure == "beforeSave" && commits == 0 {
                            commits += 1
                            throw Injected.catalog
                        }
                    }, save: { context in
                        if failure == "save" && commits == 0 {
                            commits += 1
                            throw Injected.catalog
                        }
                        commits += 1
                        try context.save()
                    })
            })
            await coordinator.start()
            XCTAssertEqual(coordinator.state, .failed(.catalog))
            XCTAssertNil(coordinator.dependencies)
            XCTAssertEqual(opens, 1)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonDefinition>()).isEmpty)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonSlot>()).isEmpty)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CatalogImportState>()).isEmpty)
            await coordinator.retry()
            XCTAssertEqual(coordinator.state, .ready)
            XCTAssertTrue(coordinator.dependencies?.container === container)
            XCTAssertEqual(opens, 1)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonSlot>()).count, 20)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CatalogImportState>())
                .map(\.lastImportedVersion), [2])
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        }
    }

    func testCancellationAfterSynchronousCommitKeepsDataAndRetryRecognizesIt() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var opens = 0
        var saves = 0
        var attempts = 0
        let coordinator = LaunchCoordinator(open: {
            opens += 1
            return container
        }, loadCatalog: { try BundledCatalogLoader.load() }, makeRepository: { container in
            SwiftDataCatalogRepository(container: container, beforeSave: {
                attempts += 1
                if attempts == 1 { throw Injected.catalog }
            }, save: { context in
                saves += 1
                try context.save()
                // ModelContext.save has completed; cancel before launch can publish.
                withUnsafeCurrentTask { $0?.cancel() }
            })
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.catalog))
        XCTAssertNil(coordinator.dependencies)
        let pending = Task { await coordinator.retry() }
        await pending.value
        XCTAssertEqual(coordinator.state, .failed(.catalog))
        XCTAssertNil(coordinator.dependencies)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(saves, 1)
        let persisted = try SwiftDataCatalogRepository(container: container).loadSnapshot()
        XCTAssertEqual(persisted.definitions.count, 40)
        XCTAssertEqual(persisted.slots.count, 20)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CatalogImportState>())
            .map(\.lastImportedVersion), [2])
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.dependencies?.container === container)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(attempts, 2, "equal-version retry needs no second commit")
        XCTAssertEqual(saves, 1, "equal-version retry must recognize the completed commit")
        XCTAssertEqual(try SwiftDataCatalogRepository(container: container).loadSnapshot(), persisted)
    }

    func testFailedProjectGrantDoesNotBecomeLaunchFailureOrDisableOfflineFeatures() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let inspector = LaunchProjectInspector()
        let projects = LaunchProjectRepository()
        let id = UUID()
        projects.references = [ProjectReferenceSnapshot(id: id, manifestID: "offline",
            bookmarkData: Data([1]), displayOrder: 0, displayNameHint: "Unavailable",
            lastSuccessfulReadAt: nil, revision: UUID())]
        let coordinator = LaunchCoordinator(open: { container }, makeDependencies: { container, catalog in
            AppDependencies(container: container, catalogRepository: catalog,
                projectInspector: inspector, projectRepository: projects)
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        let graph = try XCTUnwrap(coordinator.dependencies)
        XCTAssertEqual(projects.fetches, 0)
        let readsBeforeEntry = await inspector.reads
        XCTAssertEqual(readsBeforeEntry, 0)
        XCTAssertFalse(graph.projectStore.isLoaded)
        XCTAssertEqual(graph.focusService.readState, .loaded)
        graph.learningCatalogStore.loadIfNeeded()
        let lesson = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        _ = try graph.learningCatalogStore.openLesson(lessonID: lesson)
        let task = try graph.taskStore.create(input: TaskInput(title: "Offline task"))
        XCTAssertEqual(graph.taskStore.snapshots.map(\.id), [task.id])
        try graph.projectStore.enterProjects()
        for _ in 0..<500 {
            if graph.projectStore.rows.first?.refreshFailure == .inspection(.access(.staleBookmark)) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(graph.projectStore.rows.first?.refreshFailure,
                       .inspection(.access(.staleBookmark)))
        XCTAssertEqual(graph.projectStore.rows.map(\.reference.id), [id])
        XCTAssertEqual(projects.fetches, 1)
        let readsAfterEntry = await inspector.reads
        XCTAssertEqual(readsAfterEntry, 1)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.dependencies?.projectStore === graph.projectStore)
        XCTAssertEqual(graph.focusService.readState, .loaded)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map(\.id), [task.id])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
    }

    func testOptionalSettingsReadFailureDoesNotBlockCatalogOrDraftOwnership() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let coordinator = LaunchCoordinator(open: { container }, makeDependencies: { container, repository in
            AppDependencies(container: container, catalogRepository: repository,
                aiSettingsRepository: UnavailableAISettings(), credentialStore: UnavailableCredentials())
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        let graph = try XCTUnwrap(coordinator.dependencies)
        XCTAssertEqual(graph.aiSettingsStore.error, .storageFailure)
        XCTAssertFalse(graph.aiSettingsStore.presentation.enabled)
        XCTAssertEqual(graph.aiSettingsStore.credentialStatus, .notConfigured)
        XCTAssertEqual(graph.learningCatalogStore.state, .notLoaded)
        graph.learningCatalogStore.loadIfNeeded()
        let choice = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        _ = try graph.learningCatalogStore.openLesson(lessonID: choice)
        XCTAssertNotNil(graph.learningCatalogStore.state.snapshot)
        XCTAssertTrue(graph.lessonDraftStore === coordinator.dependencies?.lessonDraftStore)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonDefinition>()).count, 40)
    }

    func testInaccessibleKeychainCannotAuthorizeGenerationButOfflineLessonsStillOpen() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let coordinator = LaunchCoordinator(open: { container }, makeDependencies: { container, repository in
            AppDependencies(container: container, catalogRepository: repository,
                aiSettingsRepository: EnabledAISettings(), credentialStore: UnavailableCredentials())
        })
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .ready)
        let graph = try XCTUnwrap(coordinator.dependencies)
        XCTAssertEqual(graph.aiSettingsStore.credentialStatus, .inaccessible)
        XCTAssertThrowsError(try graph.aiSettingsStore.generationConfiguration()) { error in
            XCTAssertEqual(error as? AISettingsStoreError, .inaccessibleCredential)
        }
        graph.learningCatalogStore.loadIfNeeded()
        let choice = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        _ = try graph.learningCatalogStore.openLesson(lessonID: choice)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonDefinition>()).count, 40)
    }

    func testDiagnosticsNeverIncludeUntrustedDomainOrDescription() {
        let hostile = NSError(domain: "/Users/person/secret answer", code: 42,
                              userInfo: [NSLocalizedDescriptionKey: "private task and catalog body"])
        let safe = SafeLaunchLogger.diagnostic(stage: .storeOpen, error: hostile)
        XCTAssertEqual(safe.stage, .storeOpen)
        XCTAssertEqual(safe.domain, "redacted")
        XCTAssertEqual(safe.code, 42)
        let known = SafeLaunchLogger.diagnostic(
            stage: .catalogInitialization, error: NSError(domain: NSCocoaErrorDomain, code: 4))
        XCTAssertEqual(known.domain, NSCocoaErrorDomain)
        XCTAssertEqual(known.stage, .catalogInitialization)
    }
}

private actor RecoveryCalls {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
