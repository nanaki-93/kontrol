import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
private final class GateSettingsRepository: AISettingsRepository {
    var value: AISettingsSnapshot = .disabled
    var failLoad = false
    func load() throws -> AISettingsSnapshot {
        if failLoad { throw AISettingsPersistenceError.invalidSettings }
        return value
    }
    func save(_ settings: AISettingsSnapshot, expectedRevision: UUID?) throws -> AISettingsSnapshot {
        guard value.revision == expectedRevision else { throw AISettingsPersistenceError.staleRevision }
        value = AISettingsSnapshot(enabled: settings.enabled, providerID: settings.providerID,
            modelID: settings.modelID, credentialReference: settings.credentialReference, revision: UUID())
        return value
    }
}
private final class GateCredentials: CredentialStore {
    var items: [String: Data] = [:]
    var readError: CredentialStoreError?
    func read(reference: String) throws -> Data {
        if let readError { throw readError }
        guard let data = items[reference] else { throw CredentialStoreError.missing }
        return data
    }
    func save(_ credential: Data, reference: String) throws { items[reference] = credential }
    func remove(reference: String) throws { items.removeValue(forKey: reference) }
}
private actor PausedGenerator: LessonGenerator, OpenAIConnectionTesting {
    private var continuation: CheckedContinuation<CandidateLesson, Error>?
    private var connection: CheckedContinuation<Void, Error>?
    private(set) var calls = 0
    private(set) var tests = 0
    func generate(_ request: LessonGenerationRequest) async throws -> CandidateLesson {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func testConnection() async throws {
        tests += 1
        try await withCheckedThrowingContinuation { connection = $0 }
    }
    func finish(_ candidate: CandidateLesson) { continuation?.resume(returning: candidate); continuation = nil }
    func fail(_ error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func finishTest() { connection?.resume(); connection = nil }
}

@MainActor
final class LessonGenerationStoreTests: XCTestCase {
    private let selection = LessonGenerationSelection(topicID: "go",
        objectiveKey: "expansion.go.concurrency.cancellation-race", format: "code", difficulty: "intermediate")

    private func fixture() throws -> (ModelContainer, SwiftDataCatalogRepository, AISettingsStore,
                                     LearningCatalogStore, PausedGenerator, LessonGenerationStore,
                                     GateSettingsRepository, GateCredentials) {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let context = try repository.generationContext(topicID: "go")
        let source = try XCTUnwrap(context.definitions.first {
            $0.conceptIDs.contains("go.concurrency.cancel-work") &&
                $0.objectiveKey != "expansion.go.concurrency.cancellation-race"
        })
        let writer = ModelContext(container)
        writer.insert(LessonProgress(lessonID: source.id, status: .completed, completedAt: Date(timeIntervalSince1970: 20)))
        writer.insert(LessonAttempt(id: UUID(), lessonID: source.id, contentVersion: source.contentVersion,
            completedAt: Date(timeIntervalSince1970: 20), pinnedContentData: try PinnedLessonContent(definition: source).encoded()))
        writer.insert(try LessonTerminalRecord(metadata: LessonTerminalMetadata(lessonID: source.id,
            provenance: .studiedPin, title: source.title, topicID: source.topicID,
            subtopicID: source.subtopicID, contentVersion: source.contentVersion,
            objectiveKey: source.objectiveKey, conceptIDs: source.conceptIDs.sorted(),
            normalizedContentHash: source.normalizedContentHash, format: source.format,
            dismissalTimeDefinition: nil)))
        try writer.save()
        let config = GateSettingsRepository(), credentials = GateCredentials()
        let provider = PausedGenerator()
        let settings = AISettingsStore(repository: config, credentials: credentials,
            connectionTester: { _, _ in provider })
        try settings.saveConfiguration(modelID: "gpt-4o-mini", credential: Data([1, 2, 3]), expectedRevision: nil)
        try settings.enable(expectedRevision: settings.presentation.revision)
        let learning = LearningCatalogStore(repository: repository)
        learning.refresh()
        let store = LessonGenerationStore(settings: settings, repository: repository, learning: learning,
            generator: { _, _ in provider })
        return (container, repository, settings, learning, provider, store, config, credentials)
    }

    private func candidate(_ request: LessonGenerationRequest) -> CandidateLesson {
        CandidateLesson(title: "Cancellation race", objectiveKey: request.objectiveKey,
            objective: request.objective, topicID: request.topicID, subtopicID: request.subtopicID,
            conceptIDs: request.conceptIDs, difficulty: request.difficulty, format: request.format,
            estimatedMinutes: 20, prerequisiteConceptIDs: request.prerequisiteConceptIDs,
            explanation: "Unique race explanation", workedExample: "Unique race example",
            exercise: "Unique race exercise", referenceAnswer: "Unique race answer",
            selfCheckCriteria: ["Verify race outcome"])
    }

    private func wait(_ provider: PausedGenerator, calls: Int = 1) async {
        while await provider.calls < calls { await Task.yield() }
    }

    func testOneGateRejectsSecondWindowAndConnectionWhileGenerationRuns() async throws {
        let (container, repository, settings, _, provider, store, _, _) = try fixture()
        let before = try repository.loadSnapshot()
        let owner = UUID()
        let task = Task { try await store.generate(selection: selection, owner: owner) }
        await wait(provider)
        let other = LessonGenerationStore(settings: settings, repository: repository,
            learning: LearningCatalogStore(repository: repository), generator: { _, _ in provider })
        do { _ = try await other.generate(selection: selection, owner: UUID()); XCTFail("Second request started") }
        catch let error as LessonGenerationStoreError { XCTAssertEqual(error, .operationInProgress) }
        do { try await settings.testConnection(); XCTFail("Connection started") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .connectionInProgress) }
        let tests = await provider.tests
        XCTAssertEqual(tests, 0)
        store.cancel(owner: owner)
        do { _ = try await other.generate(selection: selection, owner: UUID()); XCTFail("Queued before late response") }
        catch let error as LessonGenerationStoreError { XCTAssertEqual(error, .operationInProgress) }
        let context = try repository.generationContext(topicID: "go")
        let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
        let request = try LessonGenerationRequestBuilder.make(selection: selection, operationID: UUID(), context: context, registry: registry)
        await provider.finish(candidate(request))
        do { _ = try await task.value; XCTFail("Canceled response saved") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonDefinition>()).count, before.definitions.count)
        if case .idle = store.state {} else { XCTFail("Cancellation published failure") }
    }

    func testDisableAndExternalRevisionRejectLateResults() async throws {
        for external in [false, true] {
            let (_, repository, settings, _, provider, store, _, _) = try fixture()
            let before = try repository.loadSnapshot()
            let task = Task { try await store.generate(selection: selection, owner: UUID()) }
            await wait(provider)
            if external {
                // Simulates another configuration writer sharing the same persistence.
                let snapshot = try settings.generationConfiguration()
                // Local refresh is the application boundary for external writes.
                try settings.saveConfiguration(modelID: "gpt-4o-2024-08-06", expectedRevision: snapshot.revision)
            } else { try settings.disable(expectedRevision: settings.presentation.revision) }
            let context = try repository.generationContext(topicID: "go")
            let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
            let request = try LessonGenerationRequestBuilder.make(selection: selection, operationID: UUID(), context: context, registry: registry)
            await provider.finish(candidate(request))
            do { _ = try await task.value; XCTFail("Late response saved") }
            catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
            XCTAssertEqual(try repository.loadSnapshot(), before)
        }
    }

    func testLateSuccessReportsStorageOrCredentialFailureWithoutSaving() async throws {
        for storageFailure in [true, false] {
            let (container, repository, settings, _, provider, store, config, credentials) = try fixture()
            let before = try repository.loadSnapshot()
            let task = Task { try await store.generate(selection: selection, owner: UUID()) }
            await wait(provider)
            let context = try repository.generationContext(topicID: "go")
            let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
            let request = try LessonGenerationRequestBuilder.make(selection: selection,
                operationID: UUID(), context: context, registry: registry)
            if storageFailure { config.failLoad = true }
            else { credentials.readError = .inaccessible }
            await provider.finish(candidate(request)) // a transport ignoring changes/cancellation
            let expected: LessonGenerationError = storageFailure ? .persistenceFailure : .inaccessibleCredential
            do { _ = try await task.value; XCTFail("Late response saved without authorization") }
            catch let error as LessonGenerationError { XCTAssertEqual(error, expected) }
            config.failLoad = false // allow inspection of durable learning state
            XCTAssertEqual(try repository.loadSnapshot(), before)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonDefinition>()).count,
                before.definitions.count)
            XCTAssertFalse(settings.operationGate.isBusy)
            if case .failed(let error) = store.state { XCTAssertEqual(error, expected) }
            else { XCTFail("Actionable authorization failure was hidden") }
            if storageFailure { XCTAssertFalse(settings.presentation.enabled) }
            else { XCTAssertEqual(settings.credentialStatus, .inaccessible) }
        }
    }

    func testNavigationDismissalDiscardsLateProviderFailureAndReleasesGate() async throws {
        let (_, repository, settings, _, provider, store, _, _) = try fixture()
        let before = try repository.loadSnapshot()
        let owner = UUID()
        let task = Task { try await store.generate(selection: selection, owner: owner) }
        await wait(provider)
        store.cancel(owner: UUID()) // unrelated presentation cannot revoke the owner
        XCTAssertTrue(settings.operationGate.isBusy)
        store.cancel(owner: owner) // navigation away after its draft guard succeeds
        await provider.fail(LessonGenerationError.authentication)
        do { _ = try await task.value; XCTFail("Dismissed request published failure") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
        XCTAssertFalse(settings.operationGate.isBusy)
        if case .idle = store.state {} else { XCTFail("Dismissal became provider failure") }
        XCTAssertEqual(try repository.loadSnapshot(), before)
    }

    func testConnectionOccupiesGateUntilItsLateResponse() async throws {
        let (_, repository, settings, _, provider, store, _, _) = try fixture()
        let task = Task { try await settings.testConnection() }
        while await provider.tests == 0 { await Task.yield() }
        do { _ = try await store.generate(selection: selection, owner: UUID()); XCTFail("Generation started") }
        catch let error as LessonGenerationStoreError { XCTAssertEqual(error, .operationInProgress) }
        try settings.removeKey(expectedRevision: settings.presentation.revision)
        await provider.finishTest()
        do { try await task.value; XCTFail("Late metadata accepted") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(settings.connectionStatus, .notTested)
        XCTAssertFalse(settings.presentation.enabled)
        XCTAssertEqual(try repository.loadSnapshot().definitions.filter { $0.source == "generated" }.count, 0)
    }

    func testTaskCancellationAlsoPreventsLateCommit() async throws {
        let (_, repository, settings, _, provider, store, _, _) = try fixture()
        let before = try repository.loadSnapshot()
        let task = Task { try await store.generate(selection: selection, owner: UUID()) }
        await wait(provider)
        task.cancel()
        let context = try repository.generationContext(topicID: "go")
        let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
        let request = try LessonGenerationRequestBuilder.make(selection: selection, operationID: UUID(), context: context, registry: registry)
        await provider.finish(candidate(request))
        do { _ = try await task.value; XCTFail("Cancelled task committed") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
        XCTAssertFalse(settings.operationGate.isBusy)
        XCTAssertEqual(try repository.loadSnapshot(), before)
    }

    func testConnectionOwnerDismissalCancelsWithoutPublishingFailure() async throws {
        let (_, repository, settings, _, provider, store, _, _) = try fixture()
        let owner = UUID()
        let task = Task { try await settings.testConnection(owner: owner) }
        while await provider.tests == 0 { await Task.yield() }
        settings.cancelConnection(owner: UUID())
        XCTAssertEqual(settings.connectionStatus, .testing)
        settings.cancelConnection(owner: owner)
        do { _ = try await store.generate(selection: selection, owner: UUID()); XCTFail("Canceled transport still active") }
        catch let error as LessonGenerationStoreError { XCTAssertEqual(error, .operationInProgress) }
        await provider.finishTest()
        do { try await task.value; XCTFail("Dismissed test published success") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
        XCTAssertEqual(settings.connectionStatus, .notTested)
        XCTAssertFalse(settings.operationGate.isBusy)
        XCTAssertEqual(try repository.loadSnapshot().definitions.filter { $0.source == "generated" }.count, 0)
    }

    func testCommitIsNotUndoneAndNoWorkResumesAfterNewStore() async throws {
        let (container, repository, settings, learning, provider, store, _, _) = try fixture()
        let context = try repository.generationContext(topicID: "go")
        let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
        let request = try LessonGenerationRequestBuilder.make(selection: selection, operationID: UUID(), context: context, registry: registry)
        let owner = UUID()
        let task = Task { try await store.generate(selection: selection, owner: owner) }
        await wait(provider)
        await provider.finish(candidate(request))
        let receipt = try await task.value
        store.cancel(owner: owner)
        XCTAssertTrue(try repository.loadSnapshot().definitions.contains { $0.id == receipt.lessonID })
        XCTAssertEqual(learning.state.snapshot?.definitions.filter { $0.id == receipt.lessonID }.count, 1)
        let reopened = LessonGenerationStore(settings: settings, repository: repository,
            learning: learning, generator: { _, _ in provider })
        if case .idle = reopened.state {} else { XCTFail("Operation restored on relaunch") }
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonDefinition>())
            .filter { $0.id == receipt.lessonID }.count, 1)
    }
}
