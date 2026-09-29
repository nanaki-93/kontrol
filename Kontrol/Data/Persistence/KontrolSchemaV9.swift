import Foundation
import SwiftData

// Additive news cache. No relationships to Learning topics or project content.
// Callers enforce the global 500-article / 30-day retention policy on load and merge.
enum KontrolSchemaV9: VersionedSchema {
    static var versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        KontrolSchemaV8.models + [NewsPreferencesRecord.self, NewsFeedRecord.self, NewsArticleRecord.self]
    }

    @Model
    final class NewsPreferencesRecord {
        @Attribute(.unique) var key: String
        var catalogVersion: Int
        var selectedTopicIDsPayload: Data
        var revision: UUID
        var lastRefreshAt: Date?

        init(key: String = "news.preferences", catalogVersion: Int,
             selectedTopicIDsPayload: Data, revision: UUID = UUID(), lastRefreshAt: Date? = nil) {
            self.key = key
            self.catalogVersion = catalogVersion
            self.selectedTopicIDsPayload = selectedTopicIDsPayload
            self.revision = revision
            self.lastRefreshAt = lastRefreshAt
        }
    }

    @Model
    final class NewsFeedRecord {
        @Attribute(.unique) var id: UUID
        var name: String
        var endpoint: String
        var topicIDsPayload: Data
        var isEnabled: Bool
        var configurationRevision: UUID
        var etag: String?
        var lastModified: String?
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        // Only NewsErrorCode.rawValue; never persist raw response bodies or transport errors.
        var lastErrorCode: String?
        var retryNotBefore: Date?

        init(id: UUID = UUID(), name: String, endpoint: String, topicIDsPayload: Data,
             isEnabled: Bool = true, configurationRevision: UUID = UUID(),
             etag: String? = nil, lastModified: String? = nil,
             lastAttemptAt: Date? = nil, lastSuccessAt: Date? = nil,
             lastErrorCode: String? = nil, retryNotBefore: Date? = nil) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.topicIDsPayload = topicIDsPayload
            self.isEnabled = isEnabled
            self.configurationRevision = configurationRevision
            self.etag = etag
            self.lastModified = lastModified
            self.lastAttemptAt = lastAttemptAt
            self.lastSuccessAt = lastSuccessAt
            self.lastErrorCode = lastErrorCode
            self.retryNotBefore = retryNotBefore
        }
    }

    @Model
    final class NewsArticleRecord {
        @Attribute(.unique) var id: UUID
        var url: String
        var canonicalURL: String
        var title: String
        var publishedAt: Date?
        var firstFetchedAt: Date
        var summary: String?
        // Complete current source contributions and GUID aliases, not refresh history.
        // Deleting an article deletes its aliases; removing a feed removes its contribution.
        var provenancePayload: Data

        init(id: UUID = UUID(), url: String, canonicalURL: String, title: String,
             publishedAt: Date? = nil, firstFetchedAt: Date, summary: String? = nil,
             provenancePayload: Data) {
            self.id = id
            self.url = url
            self.canonicalURL = canonicalURL
            self.title = title
            self.publishedAt = publishedAt
            self.firstFetchedAt = firstFetchedAt
            self.summary = summary
            self.provenancePayload = provenancePayload
        }
    }
}

typealias NewsPreferencesRecord = KontrolSchemaV9.NewsPreferencesRecord
typealias NewsFeedRecord = KontrolSchemaV9.NewsFeedRecord
typealias NewsArticleRecord = KontrolSchemaV9.NewsArticleRecord

// Explicit version and size ceiling for association data; reject unknown/corrupt payloads
// rather than silently treating a damaged persisted selection or provenance as empty.
enum NewsRecordPayload {
    enum Error: Swift.Error, Equatable { case invalid, unsupportedVersion, oversized }
    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let value: Value
    }

    struct SourceMetadata: Codable, Equatable {
        let url: String
        let canonicalURL: String
        let title: String
        let publishedAt: Date?
        let summary: String?
    }

    struct Contribution: Codable, Equatable {
        let feedID: UUID
        let feedName: String
        let topicIDs: [String]
        // Feed-scoped reliable GUID aliases; replace on merge, never append history.
        let guids: [String]
        // Nil only in legacy v1 rows, whose original per-source metadata was not stored.
        let metadata: SourceMetadata?

        init(feedID: UUID, feedName: String, topicIDs: [String], guids: [String],
             metadata: SourceMetadata? = nil) {
            self.feedID = feedID
            self.feedName = feedName
            self.topicIDs = topicIDs
            self.guids = guids
            self.metadata = metadata
        }
    }

    static func encodeTopics(_ ids: [String]) throws -> Data {
        guard ids.count <= 32, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw Error.invalid }
        return try encode(ids, maximum: 4_096)
    }

    static func topics(_ data: Data) throws -> [String] {
        let ids: [String] = try decode(data, maximum: 4_096)
        _ = try encodeTopics(ids)
        return ids
    }

    static func encodeContributions(_ values: [Contribution]) throws -> Data {
        guard !values.isEmpty, values.count <= 32,
              Set(values.map(\.feedID)).count == values.count,
              values.allSatisfy({ value in
                  !value.feedName.isEmpty && value.feedName.utf8.count <= 256 &&
                  value.topicIDs.count <= 9 && Set(value.topicIDs).count == value.topicIDs.count &&
                  value.topicIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 } &&
                  value.guids.count <= 1_000 && Set(value.guids).count == value.guids.count &&
                  value.guids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1_024 } &&
                  (value.metadata.map { metadata in
                      !metadata.title.isEmpty && metadata.title.count <= 512 &&
                      metadata.url.utf8.count <= 4_096 &&
                      metadata.canonicalURL.utf8.count <= 4_096 &&
                      (metadata.summary?.count ?? 0) <= 2_000 &&
                      metadata.publishedAt?.timeIntervalSinceReferenceDate.isFinite != false
                  } ?? true)
              }) else { throw Error.invalid }
        // Existing v1 fixtures contain only aliases. New rows must contain a complete
        // per-source metadata set; never write a partly reconstructable v2 row.
        let hasMetadata = values.filter { $0.metadata != nil }.count
        guard hasMetadata == 0 || hasMetadata == values.count else { throw Error.invalid }
        return try encode(values, maximum: 1_200_000, version: hasMetadata == 0 ? 1 : 2)
    }

    static func contributions(_ data: Data) throws -> [Contribution] {
        let values: [Contribution] = try decode(data, maximum: 1_200_000, versions: [1, 2])
        _ = try encodeContributions(values)
        return values
    }

    private static func encode<Value: Codable>(_ value: Value, maximum: Int, version: Int = 1) throws -> Data {
        let data = try JSONEncoder().encode(Envelope(version: version, value: value))
        guard data.count <= maximum else { throw Error.oversized }
        return data
    }

    private static func decode<Value: Codable>(_ data: Data, maximum: Int,
                                                versions: Set<Int> = [1]) throws -> Value {
        guard data.count <= maximum else { throw Error.oversized }
        // Inspect the envelope version before decoding the typed value so future formats
        // are not misclassified as corrupted current-version data.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else { throw Error.invalid }
        guard versions.contains(version) else { throw Error.unsupportedVersion }
        guard let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else {
            throw Error.invalid
        }
        if version == 2, let contributions = envelope.value as? [Contribution],
           contributions.contains(where: { $0.metadata == nil }) { throw Error.invalid }
        return envelope.value
    }
}
