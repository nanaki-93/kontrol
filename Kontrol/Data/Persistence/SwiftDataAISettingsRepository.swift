import Foundation
import SwiftData

// Values leaving SwiftData are detached and contain only nonsecret configuration.
struct AISettingsSnapshot: Equatable {
    let enabled: Bool
    let providerID: String
    let modelID: String?
    let credentialReference: String?
    let revision: UUID?

    static let disabled = AISettingsSnapshot(enabled: false, providerID: "openai",
                                              modelID: nil, credentialReference: nil, revision: nil)

    // No free-form secret can be stored as an item reference. The credential
    // lifecycle creates opaque UUID references; model IDs are short identifiers.
    func validate() throws {
        guard providerID == "openai",
              modelID == nil || (modelID!.count <= 128 && !modelID!.isEmpty &&
                modelID!.utf8.allSatisfy { byte in
                    (65...90).contains(byte) || (97...122).contains(byte) ||
                    (48...57).contains(byte) || [45, 46, 58, 95].contains(byte)
                }),
              credentialReference == nil || UUID(uuidString: credentialReference!) != nil,
              !enabled || (modelID != nil && credentialReference != nil) else {
            throw AISettingsPersistenceError.invalidSettings
        }
    }
}

enum AISettingsPersistenceError: Error, Equatable {
    case invalidSettings
    case staleRevision
}

@MainActor
protocol AISettingsRepository {
    func load() throws -> AISettingsSnapshot
    func save(_ settings: AISettingsSnapshot, expectedRevision: UUID?) throws -> AISettingsSnapshot
}

@MainActor
final class SwiftDataAISettingsRepository: AISettingsRepository {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func settingsRow(in context: ModelContext) throws -> AISettingsRecord? {
        let rows = try context.fetch(FetchDescriptor<AISettingsRecord>())
        // Reject any extra/foreign rows rather than selecting an arbitrary one.
        guard rows.count <= 1, rows.allSatisfy({ $0.key == "ai.settings" }) else {
            throw AISettingsPersistenceError.invalidSettings
        }
        return rows.first
    }

    private func snapshot(_ row: AISettingsRecord?) throws -> AISettingsSnapshot {
        guard let row else { return .disabled }
        guard row.payloadVersion == 1 else { throw AISettingsPersistenceError.invalidSettings }
        let value = AISettingsSnapshot(enabled: row.enabled, providerID: row.providerID,
                                       modelID: row.modelID, credentialReference: row.credentialReference,
                                       revision: row.revision)
        try value.validate()
        return value
    }

    func load() throws -> AISettingsSnapshot {
        try snapshot(settingsRow(in: context()))
    }

    func save(_ settings: AISettingsSnapshot, expectedRevision: UUID?) throws -> AISettingsSnapshot {
        // Each operation reads authoritative persisted state in a fresh, non-autosaving
        // context. A failed validation or save must not publish a new revision.
        let context = context()
        let row = try settingsRow(in: context)
        let current = try snapshot(row)
        guard current.revision == expectedRevision, settings.revision == expectedRevision else {
            throw AISettingsPersistenceError.staleRevision
        }
        try settings.validate()
        let next = AISettingsSnapshot(enabled: settings.enabled, providerID: settings.providerID,
                                      modelID: settings.modelID,
                                      credentialReference: settings.credentialReference,
                                      revision: UUID())
        if let row {
            row.enabled = next.enabled
            row.providerID = next.providerID
            row.modelID = next.modelID
            row.credentialReference = next.credentialReference
            row.revision = next.revision!
        } else {
            context.insert(AISettingsRecord(enabled: next.enabled, providerID: next.providerID,
                                            modelID: next.modelID,
                                            credentialReference: next.credentialReference,
                                            revision: next.revision!))
        }
        try context.save()
        return next
    }
}
