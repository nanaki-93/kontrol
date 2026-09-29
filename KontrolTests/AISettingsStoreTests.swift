import Foundation
import XCTest
@testable import Kontrol

@MainActor
private final class SettingsMemoryRepository: AISettingsRepository {
    var value: AISettingsSnapshot = .disabled
    var failSave = false
    var failOnSaveNumber: Int?
    var failLoad = false
    var saves: [AISettingsSnapshot] = []

    func load() throws -> AISettingsSnapshot {
        if failLoad { throw AISettingsPersistenceError.invalidSettings }
        return value
    }

    func save(_ settings: AISettingsSnapshot, expectedRevision: UUID?) throws -> AISettingsSnapshot {
        if failSave || failOnSaveNumber == saves.count + 1 {
            throw AISettingsPersistenceError.invalidSettings
        }
        guard expectedRevision == value.revision, settings.revision == value.revision else {
            throw AISettingsPersistenceError.staleRevision
        }
        try settings.validate()
        value = AISettingsSnapshot(enabled: settings.enabled, providerID: settings.providerID,
                                   modelID: settings.modelID, credentialReference: settings.credentialReference,
                                   revision: UUID())
        saves.append(value)
        return value
    }
}

private final class SettingsMemoryCredentials: CredentialStore {
    var items: [String: Data] = [:]
    var failSave = false
    var failRemove = false
    var readError: CredentialStoreError?
    var deletes: [String] = []
    func save(_ credential: Data, reference: String) throws {
        if failSave { throw CredentialStoreError.inaccessible }
        items[reference] = credential
    }
    func read(reference: String) throws -> Data {
        if let readError { throw readError }
        guard let item = items[reference] else { throw CredentialStoreError.missing }
        return item
    }
    func remove(reference: String) throws {
        if failRemove { throw CredentialStoreError.inaccessible }
        deletes.append(reference)
        guard items.removeValue(forKey: reference) != nil else { throw CredentialStoreError.missing }
    }
}

private actor PausedConnectionTester: OpenAIConnectionTesting {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var calls = 0
    func testConnection() async throws {
        calls += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ error: Error? = nil) {
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }
}

@MainActor
final class AISettingsStoreTests: XCTestCase {
    private let first = Data([17, 42, 79])
    private let second = Data([98, 27, 51])

    private func configured(_ repository: SettingsMemoryRepository,
                            _ credentials: SettingsMemoryCredentials) throws -> AISettingsStore {
        let store = AISettingsStore(repository: repository, credentials: credentials)
        try store.saveConfiguration(modelID: "gpt-4o", credential: first, expectedRevision: nil)
        return store
    }

    func testConnectionOnlyOnExplicitActionAndNeverWritesSettingsOrLearning() async throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let tester = PausedConnectionTester()
        let store = AISettingsStore(repository: repository, credentials: credentials,
            connectionTester: { model, reference in
                XCTAssertEqual(model, "gpt-4o-mini")
                XCTAssertEqual(reference, repository.value.credentialReference)
                return tester
            })
        try store.saveConfiguration(modelID: "gpt-4o-mini", credential: first, expectedRevision: nil)
        try store.enable(expectedRevision: store.presentation.revision)
        let initialCalls = await tester.calls
        XCTAssertEqual(initialCalls, 0)
        let saved = repository.value, saves = repository.saves.count
        let task = Task { try await store.testConnection() }
        while await tester.calls == 0 { await Task.yield() }
        XCTAssertEqual(store.connectionStatus, .testing)
        await tester.finish()
        try await task.value
        XCTAssertEqual(store.connectionStatus, .modelAvailable) // metadata only; no inference claim
        XCTAssertEqual(repository.value, saved)
        XCTAssertEqual(repository.saves.count, saves)
        XCTAssertEqual(credentials.items.count, 1)
    }

    func testLateConnectionFailureCannotOverwriteChangedConfiguration() async throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let tester = PausedConnectionTester()
        let store = AISettingsStore(repository: repository, credentials: credentials,
            connectionTester: { _, _ in tester })
        try store.saveConfiguration(modelID: "gpt-4o-mini", credential: first, expectedRevision: nil)
        let task = Task { try await store.testConnection() }
        while await tester.calls == 0 { await Task.yield() }
        do { try await store.testConnection(); XCTFail("Concurrent test should be rejected") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .connectionInProgress) }
        catch { XCTFail("Unexpected error") }
        try store.saveConfiguration(modelID: "gpt-4o-2024-08-06", expectedRevision: store.presentation.revision)
        await tester.finish(LessonGenerationError.authentication)
        do { try await task.value; XCTFail("Stale result published") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .staleRevision) }
        catch { XCTFail("Unexpected error") }
        XCTAssertEqual(store.connectionStatus, .notTested)
        XCTAssertEqual(store.presentation.modelID, "gpt-4o-2024-08-06")
        XCTAssertEqual(repository.saves.count, 2)
    }

    func testConnectionFailureIsSanitizedAndDoesNotMutateSettings() async throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let tester = PausedConnectionTester()
        let store = AISettingsStore(repository: repository, credentials: credentials,
            connectionTester: { _, _ in tester })
        try store.saveConfiguration(modelID: "gpt-4o-mini", credential: first, expectedRevision: nil)
        let saved = repository.value
        let task = Task { try await store.testConnection() }
        while await tester.calls == 0 { await Task.yield() }
        await tester.finish(LessonGenerationError.authentication)
        do { try await task.value; XCTFail("Expected authentication failure") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .authentication) }
        catch { XCTFail("Unexpected error") }
        XCTAssertEqual(store.connectionStatus, .failed(.authentication))
        XCTAssertEqual(repository.value, saved)
        XCTAssertEqual(repository.saves.count, 1)
        XCTAssertEqual(credentials.items.count, 1)
    }

    func testRepositoryReadFailureAfterMetadataReturnsStorageFailureWithoutPublishingResult() async throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let tester = PausedConnectionTester()
        let store = AISettingsStore(repository: repository, credentials: credentials,
            connectionTester: { _, _ in tester })
        try store.saveConfiguration(modelID: "gpt-4o-mini", credential: first, expectedRevision: nil)
        try store.enable(expectedRevision: store.presentation.revision)
        let saved = repository.value, saves = repository.saves.count
        let task = Task { try await store.testConnection() }
        while await tester.calls == 0 { await Task.yield() }
        repository.failLoad = true
        await tester.finish()
        do { try await task.value; XCTFail("Read failure must not publish availability") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .storageFailure) }
        catch { XCTFail("Unexpected error") }
        XCTAssertEqual(store.error, .storageFailure)
        XCTAssertEqual(store.connectionStatus, .notTested)
        XCTAssertFalse(store.presentation.enabled) // fail closed until settings can be read again
        XCTAssertEqual(repository.value, saved)
        XCTAssertEqual(repository.saves.count, saves)
        repository.failLoad = false
        store.refresh()
        XCTAssertEqual(store.connectionStatus, .notTested)
    }

    func testTesterCancellationWithoutTaskCancellationIsNotAConnectionFailure() async throws {
        let cancellations: [Error] = [LessonGenerationError.cancelled, CancellationError(), URLError(.cancelled)]
        for cancellation in cancellations {
            let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
            let tester = PausedConnectionTester()
            let store = AISettingsStore(repository: repository, credentials: credentials,
                connectionTester: { _, _ in tester })
            try store.saveConfiguration(modelID: "gpt-4o-mini", credential: first, expectedRevision: nil)
            let saved = repository.value, saves = repository.saves.count
            let task = Task { try await store.testConnection() }
            while await tester.calls == 0 { await Task.yield() }
            await tester.finish(cancellation)
            do { try await task.value; XCTFail("Cancellation should not publish a failure") }
            catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
            catch { XCTFail("Unexpected error") }
            XCTAssertEqual(store.connectionStatus, .notTested)
            XCTAssertEqual(repository.value, saved)
            XCTAssertEqual(repository.saves.count, saves)
        }
    }

    func testConnectionRequiresLocalCredentialAndSupportedModelBeforeTransport() async throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let tester = PausedConnectionTester()
        let store = AISettingsStore(repository: repository, credentials: credentials,
            connectionTester: { _, _ in tester })
        do { try await store.testConnection(); XCTFail("Unconfigured test must fail") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .invalidConfiguration) }
        try store.saveConfiguration(modelID: "unsupported", credential: first, expectedRevision: nil)
        do { try await store.testConnection(); XCTFail("Unsupported model must fail locally") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .invalidConfiguration) }
        try store.saveConfiguration(modelID: "gpt-4o-mini", expectedRevision: store.presentation.revision)
        credentials.readError = .missing
        do { try await store.testConnection(); XCTFail("Missing key must fail locally") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .missingCredential) }
        credentials.readError = .inaccessible
        do { try await store.testConnection(); XCTFail("Locked key must fail locally") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .inaccessibleCredential) }
        let calls = await tester.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.connectionStatus, .notTested)
    }

    func testExternalRevisionChangeAlsoDiscardsLateSuccess() async throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let tester = PausedConnectionTester()
        let store = AISettingsStore(repository: repository, credentials: credentials,
            connectionTester: { _, _ in tester })
        try store.saveConfiguration(modelID: "gpt-4o-mini", credential: first, expectedRevision: nil)
        let task = Task { try await store.testConnection() }
        while await tester.calls == 0 { await Task.yield() }
        let other = AISettingsStore(repository: repository, credentials: credentials)
        try other.disable(expectedRevision: other.presentation.revision)
        await tester.finish()
        do { try await task.value; XCTFail("External revision accepted") }
        catch let error as AISettingsStoreError { XCTAssertEqual(error, .staleRevision) }
        catch { XCTFail("Unexpected error") }
        XCTAssertNotEqual(store.connectionStatus, .modelAvailable)
    }

    func testSaveDoesNotEnableAndEnabledConfigurationHasNoPublishedSecret() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        XCTAssertFalse(store.presentation.enabled)
        XCTAssertEqual(store.credentialStatus, .available)
        XCTAssertEqual(credentials.items.count, 1)
        XCTAssertFalse(String(describing: store.presentation).contains(String(decoding: first, as: UTF8.self)))
        XCTAssertThrowsError(try store.generationConfiguration())
        try store.enable(expectedRevision: store.presentation.revision)
        XCTAssertTrue(try store.generationConfiguration().enabled)
        XCTAssertEqual(repository.saves.count, 2) // no network boundary involved
        let reference = try XCTUnwrap(repository.value.credentialReference)
        try store.disable(expectedRevision: store.presentation.revision)
        XCTAssertFalse(store.presentation.enabled)
        XCTAssertEqual(credentials.items[reference], first)
        XCTAssertThrowsError(try store.generationConfiguration())
    }

    func testFailedReplacementLeavesOldEnabledConfigurationAndCleansStagedKey() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        try store.enable(expectedRevision: store.presentation.revision)
        let old = repository.value
        repository.failSave = true
        XCTAssertThrowsError(try store.saveConfiguration(modelID: "gpt-4o", credential: second,
                                                          expectedRevision: old.revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .storageFailure)
        }
        XCTAssertEqual(repository.value, old)
        XCTAssertEqual(repository.value, old)
        XCTAssertEqual(credentials.items, [old.credentialReference!: first])
        XCTAssertTrue(try store.generationConfiguration().enabled)
        repository.failSave = false
        credentials.failSave = true
        XCTAssertThrowsError(try store.saveConfiguration(modelID: "gpt-4o", credential: second,
                                                          expectedRevision: old.revision))
        XCTAssertEqual(repository.value, old)
        XCTAssertEqual(credentials.items.count, 1)
    }

    func testStagedCleanupFailureIsReportedAndRetryableWithoutPublishingKey() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        let original = repository.value
        repository.failSave = true
        credentials.failRemove = true
        XCTAssertThrowsError(try store.saveConfiguration(modelID: "gpt-4o", credential: second,
                                                          expectedRevision: original.revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .stagedCleanupFailed)
        }
        XCTAssertEqual(repository.value, original)
        XCTAssertEqual(credentials.items.count, 2)
        credentials.failRemove = false
        try store.retryCleanup()
        XCTAssertEqual(credentials.items.count, 1)
        XCTAssertEqual(repository.value, original)
    }

    func testRemovalDisablesBeforeDeleteAndFailedDeletionNeverClaimsSuccess() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        try store.enable(expectedRevision: store.presentation.revision)
        var invalidations = 0
        store.invalidateOperations = { invalidations += 1 }
        let reference = try XCTUnwrap(repository.value.credentialReference)
        credentials.failRemove = true
        XCTAssertThrowsError(try store.removeKey(expectedRevision: store.presentation.revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .removalFailed)
            XCTAssertEqual(repository.value.credentialReference, reference)
            XCTAssertFalse(repository.value.enabled)
            XCTAssertEqual(credentials.items[reference], first)
        }
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(store.error, .removalFailed)
        XCTAssertThrowsError(try store.generationConfiguration())
        credentials.failRemove = false
        // A fresh store can retry using the durable disabled reference.
        let reopened = AISettingsStore(repository: repository, credentials: credentials)
        try reopened.removeKey(expectedRevision: reopened.presentation.revision)
        XCTAssertNil(repository.value.credentialReference)
        XCTAssertNil(credentials.items[reference])
    }

    func testFailedDurableDisableDoesNotDeleteAndFinalizationCanRetryAfterRelaunch() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        try store.enable(expectedRevision: store.presentation.revision)
        repository.failSave = true
        XCTAssertThrowsError(try store.removeKey(expectedRevision: store.presentation.revision))
        XCTAssertTrue(repository.value.enabled)
        XCTAssertEqual(credentials.items.count, 1)
        XCTAssertTrue(credentials.deletes.isEmpty)
        XCTAssertThrowsError(try store.generationConfiguration()) // in-memory authorization revoked
        repository.failSave = false
        let ref = try XCTUnwrap(repository.value.credentialReference)
        try store.removeKey(expectedRevision: store.presentation.revision)
        XCTAssertFalse(repository.value.enabled)
        XCTAssertNil(repository.value.credentialReference)
        XCTAssertNil(credentials.items[ref])
    }

    func testSuccessfulReplacementUsesNewReferenceAndDeletesOldKey() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        try store.enable(expectedRevision: store.presentation.revision)
        let old = try XCTUnwrap(repository.value.credentialReference)
        var invalidations = 0
        store.invalidateOperations = { invalidations += 1 }
        try store.saveConfiguration(modelID: "gpt-4o", credential: second,
                                    expectedRevision: store.presentation.revision)
        let new = try XCTUnwrap(repository.value.credentialReference)
        XCTAssertNotEqual(old, new)
        XCTAssertNil(credentials.items[old])
        XCTAssertEqual(credentials.items[new], second)
        XCTAssertFalse(repository.value.enabled) // replacement requires explicit re-enable
        XCTAssertEqual(invalidations, 1)
        XCTAssertTrue(credentials.deletes.contains(old))
        XCTAssertFalse(String(describing: store.presentation).contains(new))
    }

    func testDeleteSucceededButClearingReferenceFailedCanBeRetried() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        let reference = try XCTUnwrap(repository.value.credentialReference)
        repository.failOnSaveNumber = repository.saves.count + 2
        XCTAssertThrowsError(try store.removeKey(expectedRevision: store.presentation.revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .removalFinalizationFailed)
        }
        XCTAssertFalse(repository.value.enabled)
        XCTAssertEqual(repository.value.credentialReference, reference)
        XCTAssertNil(credentials.items[reference])
        repository.failOnSaveNumber = nil
        let reopened = AISettingsStore(repository: repository, credentials: credentials)
        XCTAssertEqual(reopened.credentialStatus, .missing)
        try reopened.removeKey(expectedRevision: reopened.presentation.revision)
        XCTAssertNil(repository.value.credentialReference)
    }

    func testMissingLockedAndStaleRevisionsFailClosed() throws {
        let repository = SettingsMemoryRepository(), credentials = SettingsMemoryCredentials()
        let store = try configured(repository, credentials)
        let revision = store.presentation.revision
        credentials.readError = .missing
        XCTAssertThrowsError(try store.enable(expectedRevision: revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .missingCredential)
        }
        credentials.readError = .inaccessible
        XCTAssertThrowsError(try store.enable(expectedRevision: revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .inaccessibleCredential)
        }
        credentials.readError = nil
        try store.enable(expectedRevision: revision)
        XCTAssertThrowsError(try store.disable(expectedRevision: revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .staleRevision)
        }
        XCTAssertTrue(repository.value.enabled)
        let other = AISettingsStore(repository: repository, credentials: credentials)
        try other.disable(expectedRevision: other.presentation.revision)
        XCTAssertThrowsError(try store.saveConfiguration(modelID: "gpt-4o", credential: second,
                                                          expectedRevision: store.presentation.revision)) {
            XCTAssertEqual($0 as? AISettingsStoreError, .staleRevision)
        }
        XCTAssertEqual(credentials.items.count, 1)
    }
}
