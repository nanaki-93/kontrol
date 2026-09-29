import Foundation
import SwiftData

// Additive schema: progress remains the sole authority for terminal status.
enum KontrolSchemaV6: VersionedSchema {
    static var versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        KontrolSchemaV5.models + [LessonTerminalRecord.self, CatalogMembership.self]
    }

    @Model
    final class LessonTerminalRecord {
        @Attribute(.unique) var lessonID: String
        var payload: Data

        init(lessonID: String, payload: Data) {
            self.lessonID = lessonID
            self.payload = payload
        }

        convenience init(metadata: LessonTerminalMetadata) throws {
            try self.init(lessonID: metadata.lessonID, payload: EvidencePayload.encode(metadata))
        }

        func metadata() throws -> LessonTerminalMetadata {
            let value: LessonTerminalMetadata = try EvidencePayload.decode(payload)
            guard value.lessonID == lessonID else { throw LearningEvidenceError.identityMismatch }
            try value.validate()
            return value
        }
    }

    @Model
    final class CatalogMembership {
        @Attribute(.unique) var catalogID: String
        var payload: Data

        init(catalogID: String, payload: Data) {
            self.catalogID = catalogID
            self.payload = payload
        }

        convenience init(membership: CurrentCatalogMembership) throws {
            try self.init(catalogID: membership.catalogID, payload: EvidencePayload.encode(membership))
        }

        func membership() throws -> CurrentCatalogMembership {
            let value: CurrentCatalogMembership = try EvidencePayload.decode(payload)
            guard value.catalogID == catalogID else { throw LearningEvidenceError.identityMismatch }
            try value.validate()
            return value
        }
    }
}

typealias LessonTerminalRecord = KontrolSchemaV6.LessonTerminalRecord
typealias CatalogMembership = KontrolSchemaV6.CatalogMembership

// Version is checked before decoding the body; a future payload cannot be
// interpreted as today's shape even if it happens to contain compatible keys.
private enum EvidencePayload {
    private struct Header: Decodable { let version: Int }
    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let value: Value
    }

    static func encode<Value: Codable>(_ value: Value) throws -> Data {
        if let metadata = value as? LessonTerminalMetadata { try metadata.validate() }
        if let membership = value as? CurrentCatalogMembership { try membership.validate() }
        return try JSONEncoder().encode(Envelope(version: 1, value: value))
    }

    static func decode<Value: Codable>(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw LearningEvidenceError.corruptPayload
        }
        guard header.version == 1 else { throw LearningEvidenceError.unsupportedVersion(header.version) }
        guard let envelope = try? decoder.decode(Envelope<Value>.self, from: data) else {
            throw LearningEvidenceError.corruptPayload
        }
        return envelope.value
    }
}

// Reject ambiguous fetched rows before projecting or mutating evidence. The
// unique attributes also constrain persisted identity; they are not a substitute
// for detecting duplicate unsaved rows or damaged imported stores.
enum EvidenceIdentity {
    static func terminalMetadata(_ rows: [LessonTerminalRecord]) throws -> [String: LessonTerminalMetadata] {
        let unique = try requireUnique(rows, id: { $0.lessonID })
        return try unique.mapValues { try $0.metadata() }
    }

    static func membership(_ rows: [CatalogMembership], catalogID: String,
                           installedVersion: Int) throws -> CatalogMembershipAvailability {
        let unique = try requireUnique(rows, id: { $0.catalogID })
        // Validate all stored rows; unsupported versions or corruption must not
        // disappear just because a different catalog was requested.
        let decoded = try unique.mapValues { try $0.membership() }
        guard let value = decoded[catalogID], value.catalogVersion == installedVersion else {
            return .unavailable
        }
        return .available(value)
    }

    static func requireUnique<Identity: Hashable, Value>(
        _ rows: [Value], id: (Value) -> Identity
    ) throws -> [Identity: Value] {
        var result: [Identity: Value] = [:]
        for row in rows {
            let key = id(row)
            guard result.updateValue(row, forKey: key) == nil else {
                throw LearningEvidenceError.duplicateIdentity
            }
        }
        return result
    }
}
