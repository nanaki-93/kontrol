import Foundation
import Security
import XCTest
@testable import Kontrol

private final class FakeKeychainBackend: KeychainItemBackend {
    var items: [String: Data] = [:]
    var addStatus: OSStatus?
    var readStatus: OSStatus?
    var deleteStatus: OSStatus?
    var added: [String: Any] = [:]
    var readQuery: [String: Any] = [:]
    var deleteQuery: [String: Any] = [:]

    func add(_ attributes: [String: Any]) -> OSStatus {
        added = attributes
        if let addStatus { return addStatus }
        let account = attributes[kSecAttrAccount as String] as! String
        guard items[account] == nil else { return errSecDuplicateItem }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        readQuery = query
        if let readStatus { return (readStatus, nil) }
        guard let data = items[query[kSecAttrAccount as String] as! String] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deleteQuery = query
        if let deleteStatus { return deleteStatus }
        guard items.removeValue(forKey: query[kSecAttrAccount as String] as! String) != nil else {
            return errSecItemNotFound
        }
        return errSecSuccess
    }
}

final class KeychainCredentialStoreTests: XCTestCase {
    func testSaveReadRemoveAndExactDeviceLocalQueryPolicy() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let reference = UUID().uuidString
        let secret = Data([0, 1, 255])
        try store.save(secret, reference: reference)
        XCTAssertEqual(backend.added[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(backend.added[kSecAttrService as String] as? String,
                       KeychainCredentialStore.appService)
        XCTAssertEqual(backend.added[kSecAttrAccount as String] as? String, reference)
        XCTAssertEqual(backend.added[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(backend.added[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(backend.added[kSecAttrAccessGroup as String])
        XCTAssertEqual(backend.added[kSecValueData as String] as? Data, secret)
        XCTAssertEqual(try store.read(reference: reference), secret)
        XCTAssertEqual(backend.readQuery[kSecAttrService as String] as? String,
                       KeychainCredentialStore.appService)
        XCTAssertEqual(backend.readQuery[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(backend.readQuery[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(backend.readQuery[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(backend.readQuery[kSecValueData as String])
        try store.remove(reference: reference)
        XCTAssertEqual(backend.deleteQuery[kSecAttrAccount as String] as? String, reference)
        XCTAssertEqual(backend.deleteQuery[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(backend.deleteQuery[kSecValueData as String])
        XCTAssertThrowsError(try store.read(reference: reference)) {
            XCTAssertEqual($0 as? CredentialStoreError, .missing)
        }
        XCTAssertThrowsError(try store.remove(reference: reference)) {
            XCTAssertEqual($0 as? CredentialStoreError, .missing)
        }
    }

    func testMissingIsDistinctFromLockedDeniedAndOtherFailures() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let reference = UUID().uuidString
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable,
                       errSecUserCanceled, errSecMissingEntitlement] {
            backend.readStatus = status
            XCTAssertThrowsError(try store.read(reference: reference)) {
                XCTAssertEqual($0 as? CredentialStoreError, .inaccessible)
            }
            backend.deleteStatus = status
            XCTAssertThrowsError(try store.remove(reference: reference)) {
                XCTAssertEqual($0 as? CredentialStoreError, .inaccessible)
            }
            backend.addStatus = status
            XCTAssertThrowsError(try store.save(Data([42]), reference: reference)) {
                XCTAssertEqual($0 as? CredentialStoreError, .inaccessible)
            }
        }
        backend.readStatus = errSecDecode
        XCTAssertThrowsError(try store.read(reference: reference)) {
            XCTAssertEqual($0 as? CredentialStoreError, .operationFailed)
        }
        backend.readStatus = errSecSuccess // success without bytes must still fail closed
        XCTAssertThrowsError(try store.read(reference: reference)) {
            XCTAssertEqual($0 as? CredentialStoreError, .operationFailed)
        }
    }

    func testRejectsInvalidReferencesEmptySecretsAndOverwritesWithoutExposingBytes() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        for reference in ["", "not-a-uuid", UUID().uuidString.lowercased()] {
            XCTAssertThrowsError(try store.save(Data([77]), reference: reference)) {
                XCTAssertEqual($0 as? CredentialStoreError, .invalidReference)
            }
            XCTAssertThrowsError(try store.read(reference: reference)) {
                XCTAssertEqual($0 as? CredentialStoreError, .invalidReference)
            }
            XCTAssertThrowsError(try store.remove(reference: reference)) {
                XCTAssertEqual($0 as? CredentialStoreError, .invalidReference)
            }
        }
        XCTAssertTrue(backend.items.isEmpty)
        let reference = UUID().uuidString
        XCTAssertThrowsError(try store.save(Data(), reference: reference)) {
            XCTAssertEqual($0 as? CredentialStoreError, .invalidCredential)
        }
        try store.save(Data([71, 72]), reference: reference)
        XCTAssertThrowsError(try store.save(Data([73, 74]), reference: reference)) {
            XCTAssertEqual($0 as? CredentialStoreError, .alreadyExists)
            XCTAssertFalse(String(describing: $0).contains(reference))
            XCTAssertFalse(String(describing: $0).contains("71"))
        }
        XCTAssertEqual(try store.read(reference: reference), Data([71, 72]))
    }

    // Independently isolated from the fake-backed tests: a unique service and
    // reference, never the production namespace. Cleanup runs even on failure.
    // Requires an unlocked test account with usable Keychain access; signed sandbox
    // behavior remains a separate manual F13 acceptance check.
    func testIsolatedSystemKeychainRoundTrip() throws {
        let service = "com.kontrol.app.ai.test.\(UUID().uuidString)"
        let reference = UUID().uuidString
        let store = KeychainCredentialStore(service: service)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: reference,
                                    kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        defer { _ = SecItemDelete(query as CFDictionary) }
        let secret = Data([19, 41, 93])
        try store.save(secret, reference: reference)
        XCTAssertEqual(try store.read(reference: reference), secret)
        try store.remove(reference: reference)
        XCTAssertThrowsError(try store.read(reference: reference)) {
            XCTAssertEqual($0 as? CredentialStoreError, .missing)
        }
    }
}
