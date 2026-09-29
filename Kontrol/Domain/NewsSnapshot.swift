import Foundation

// Detached values only: repository and service boundaries never exchange SwiftData models.
struct NewsTopic: Equatable, Identifiable {
    let id: String
    let name: String
}

struct FeedSourceSnapshot: Equatable, Identifiable {
    let id: UUID
    let name: String
    let url: URL
    let topicIDs: Set<String>
    let isEnabled: Bool
    let configurationRevision: UUID
    let etag: String?
    let lastModified: String?
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let lastError: NewsErrorCode?
    let retryNotBefore: Date?
}

/// Editor state is never a persisted feed until local checks and any required validation succeed.
struct FeedDraft: Equatable {
    let id: UUID?
    var name: String
    var urlText: String
    var topicIDs: Set<String>
    var isEnabled: Bool
    let expectedRevision: UUID?
    let draftRevision: UUID
}

struct NewsArticleSource: Equatable {
    let feedID: UUID
    let feedName: String
    let topicIDs: Set<String>
    let guid: String?
}

struct ArticleMetadata: Equatable, Identifiable {
    let id: UUID
    let url: URL // Original validated HTTPS destination, revalidated before opening.
    let canonicalURL: String
    let title: String
    let publishedAt: Date?
    let firstFetchedAt: Date
    let summary: String? // Inert plain text only.
    let sources: [NewsArticleSource]
}

struct NewsPreferences: Equatable {
    let catalogVersion: Int
    let selectedTopicIDs: Set<String>
    let revision: UUID
    let lastRefreshAt: Date? // Only a durably accepted success advances this value.
}

struct NewsPreferencesEdit: Equatable {
    let selectedTopicIDs: Set<String>
}

struct NewsSnapshot: Equatable {
    let topics: [NewsTopic]
    let feeds: [FeedSourceSnapshot]
    /// Complete retained per-feed metadata and aliases for source-aware projection.
    /// Persist and restore these states rather than reconstructing them from flattened rows.
    let articleStates: [NewsSelection.State]
    let preferences: NewsPreferences

    var articles: [ArticleMetadata] { articleStates.map(\.article) }
}

/// Stable, safe classifications; never store raw URLs, credentials, bodies or transport errors.
enum NewsErrorCode: String, Equatable {
    case offline, timeout, http, rateLimited, unsafeURL, oversizedResponse
    case malformedFeed, invalidConfiguration, staleEdit, readFailed, saveFailed, openFailed
}

/// Uncommitted parsed metadata. Stable local IDs and first-fetched times are assigned on merge.
struct NewsFeedEntry: Equatable {
    let title: String
    let url: URL
    let guid: String?
    let publishedAt: Date?
    let summary: String?
}

enum FeedRefreshResult: Equatable {
    case modified([NewsFeedEntry], etag: String?, lastModified: String?)
    case notModified
    case failed(NewsErrorCode, retryNotBefore: Date?)
    case canceled
    case deferred(retryNotBefore: Date)
}

struct FeedRefreshOutcome: Equatable {
    let feedID: UUID
    let configurationRevision: UUID
    let attemptedAt: Date?
    let result: FeedRefreshResult
}
