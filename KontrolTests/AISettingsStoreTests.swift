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
