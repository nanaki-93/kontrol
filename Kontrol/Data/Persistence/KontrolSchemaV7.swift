import Foundation
import SwiftData

// Additive settings only. Missing row means AI is disabled; credentials live in Keychain.
enum KontrolSchemaV7: VersionedSchema {
    static var versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        KontrolSchemaV6.models + [AISettingsRecord.self]
    }

    @Model
    final class AISettingsRecord {
        @Attribute(.unique) var key: String
        var payloadVersion: Int
        var enabled: Bool
        var providerID: String
        var modelID: String?
        var credentialReference: String?
        var revision: UUID

        init(key: String = "ai.settings", payloadVersion: Int = 1, enabled: Bool = false,
             providerID: String = "openai", modelID: String? = nil,
             credentialReference: String? = nil, revision: UUID = UUID()) {
            self.key = key
            self.payloadVersion = payloadVersion
            self.enabled = enabled
            self.providerID = providerID
            self.modelID = modelID
            self.credentialReference = credentialReference
            self.revision = revision
        }
    }
}

typealias AISettingsRecord = KontrolSchemaV7.AISettingsRecord
