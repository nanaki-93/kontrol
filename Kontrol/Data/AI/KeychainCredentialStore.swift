import Foundation
import Security

// The only boundary returning credential bytes. Callers must not publish or log them.
protocol CredentialStore {
    func read(reference: String) throws -> Data
    func save(_ credential: Data, reference: String) throws
    func remove(reference: String) throws
}

enum CredentialStoreError: Error, Equatable {
    case invalidReference
    case invalidCredential
    case missing
    case inaccessible
    case alreadyExists
    case operationFailed
}

// Inject Security calls, not a second persistence location. The backend never formats
// Keychain errors or includes query attributes (which may contain secret bytes) in errors.
protocol KeychainItemBackend {
    func add(_ attributes: [String: Any]) -> OSStatus
    func read(_ query: [String: Any]) -> (OSStatus, Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainItemBackend: KeychainItemBackend {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

final class KeychainCredentialStore: CredentialStore {
    // Fixed app namespace, never a user-provided host or access group. Tests may
    // override this with an isolated service; production uses the fixed namespace.
    static let appService = "com.kontrol.app.ai.credentials.v1"
    private let service: String
    private let backend: KeychainItemBackend

    init(backend: KeychainItemBackend = SystemKeychainItemBackend(),
         service: String = KeychainCredentialStore.appService) {
        self.backend = backend
        self.service = service
    }

    private func identity(_ reference: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: reference), uuid.uuidString == reference else {
            throw CredentialStoreError.invalidReference
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: reference,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    private func failure(_ status: OSStatus) -> CredentialStoreError {
        switch status {
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable,
             errSecUserCanceled, errSecMissingEntitlement: return .inaccessible
        case errSecDuplicateItem: return .alreadyExists
        default: return .operationFailed
        }
    }

    func save(_ credential: Data, reference: String) throws {
        let query = try identity(reference)
        guard !credential.isEmpty else { throw CredentialStoreError.invalidCredential }
        var attributes = query
        attributes[kSecValueData as String] = credential
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = backend.add(attributes)
        guard status == errSecSuccess else { throw failure(status) }
    }

    func read(reference: String) throws -> Data {
        var query = try identity(reference)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.read(query)
        guard status == errSecSuccess else { throw failure(status) }
        guard let data, !data.isEmpty else { throw CredentialStoreError.operationFailed }
        return data
    }

    func remove(reference: String) throws {
        let status = backend.delete(try identity(reference))
        guard status == errSecSuccess else { throw failure(status) }
    }
}
