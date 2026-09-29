import Foundation
import SwiftData

enum NewsRepositoryError: Error, Equatable {
    case invalidCatalog
    case invalidSelection
    case invalidStoredData
    case staleRevision
}

@MainActor
protocol NewsRepository {
    func loadOrInitialize(_ catalog: DefaultFeedCatalog) throws -> NewsSnapshot
    func savePreferences(_ edit: NewsPreferencesEdit, expectedRevision: UUID) throws -> NewsSnapshot
}

/// All operations read authoritative rows in a new context. No model or context escapes.
@MainActor
final class SwiftDataNewsRepository: NewsRepository {
    private let container: ModelContainer
    private let now: () -> Date
    private let beforeSave: () throws -> Void
    private let beforeRead: () throws -> Void
    private var catalog: DefaultFeedCatalog?

    init(container: ModelContainer, now: @escaping () -> Date = Date.init,
         beforeSave: @escaping () throws -> Void = {},
         beforeRead: @escaping () throws -> Void = {}) {
        self.container = container
        self.now = now
        self.beforeSave = beforeSave
        self.beforeRead = beforeRead
    }

    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func commit(_ context: ModelContext) throws {
        try beforeSave()
        try context.save()
    }

    private func validatedCatalog(_ catalog: DefaultFeedCatalog) throws {
        let ids = Set(catalog.topics.map(\.id))
        guard catalog.version > 0, !ids.isEmpty, ids.count == catalog.topics.count,
              ids.count <= 32, catalog.topics.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              catalog.initialSelectedTopicIDs.isSubset(of: ids),
              catalog.feeds.count <= 32,
              Set(catalog.feeds.compactMap { try? NewsURLPolicy.normalizedFeedURL($0.url.absoluteString) }).count == catalog.feeds.count,
              Set(catalog.feeds.map(\.id)).count == catalog.feeds.count,
              catalog.feeds.allSatisfy({ feed in
                  !feed.name.isEmpty && feed.name.utf8.count <= 256 &&
                  !feed.topicIDs.isEmpty && feed.topicIDs.isSubset(of: ids) &&
                  (try? NewsURLPolicy.feedURL(feed.url.absoluteString)) != nil
              }) else { throw NewsRepositoryError.invalidCatalog }
    }

    private struct Rows {
        let preference: NewsPreferencesRecord?
        let feeds: [NewsFeedRecord]
        let articles: [NewsArticleRecord]
    }

    private func rows(_ context: ModelContext) throws -> Rows {
        try beforeRead()
        let preferences = try context.fetch(FetchDescriptor<NewsPreferencesRecord>())
        let feeds = try context.fetch(FetchDescriptor<NewsFeedRecord>())
        let articles = try context.fetch(FetchDescriptor<NewsArticleRecord>())
        guard preferences.count <= 1, preferences.allSatisfy({ $0.key == "news.preferences" }),
              feeds.count <= 32, Set(feeds.map(\.id)).count == feeds.count,
              Set(articles.map(\.id)).count == articles.count,
              preferences.count == 1 || (feeds.isEmpty && articles.isEmpty) else {
            throw NewsRepositoryError.invalidStoredData
        }
        return Rows(preference: preferences.first, feeds: feeds, articles: articles)
    }

    private func snapshot(_ rows: Rows, catalog: DefaultFeedCatalog) throws -> NewsSnapshot {
        guard let row = rows.preference else { throw NewsRepositoryError.invalidStoredData }
        let known = Set(catalog.topics.map(\.id))
        let selection = try NewsRecordPayload.topics(row.selectedTopicIDsPayload)
        guard row.catalogVersion > 0, Set(selection).isSubset(of: known),
              row.lastRefreshAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            throw NewsRepositoryError.invalidStoredData
        }
        let feeds = try rows.feeds.map { feed -> FeedSourceSnapshot in
            let topics = try NewsRecordPayload.topics(feed.topicIDsPayload)
            guard !feed.name.isEmpty, feed.name.utf8.count <= 256,
                  feed.name == feed.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !topics.isEmpty, Set(topics).isSubset(of: known),
                  let url = try? NewsURLPolicy.feedURL(feed.endpoint),
                  feed.lastErrorCode == nil || NewsErrorCode(rawValue: feed.lastErrorCode!) != nil,
                  (feed.etag?.utf8.count ?? 0) <= 4_096,
                  (feed.lastModified?.utf8.count ?? 0) <= 4_096,
                  [feed.lastAttemptAt, feed.lastSuccessAt, feed.retryNotBefore]
                    .allSatisfy({ $0?.timeIntervalSinceReferenceDate.isFinite != false }) else {
                throw NewsRepositoryError.invalidStoredData
            }
            return FeedSourceSnapshot(id: feed.id, name: feed.name, url: url,
                topicIDs: Set(topics), isEnabled: feed.isEnabled,
                configurationRevision: feed.configurationRevision, etag: feed.etag,
                lastModified: feed.lastModified, lastAttemptAt: feed.lastAttemptAt,
                lastSuccessAt: feed.lastSuccessAt,
                lastError: feed.lastErrorCode.flatMap(NewsErrorCode.init(rawValue:)),
                retryNotBefore: feed.retryNotBefore)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let ids = Set(feeds.map(\.id))
        let endpoints = try feeds.map { try NewsURLPolicy.normalizedFeedURL($0.url.absoluteString) }
        guard Set(endpoints).count == endpoints.count else { throw NewsRepositoryError.invalidStoredData }
        let states = try rows.articles.map { article -> NewsSelection.State in
            guard !article.title.isEmpty, article.title.count <= 512,
                  (article.summary?.count ?? 0) <= 2_000,
                  article.firstFetchedAt.timeIntervalSinceReferenceDate.isFinite,
                  article.publishedAt?.timeIntervalSinceReferenceDate.isFinite != false,
                  let url = try? NewsURLPolicy.articleURL(article.url),
                  let canonical = try? NewsURLPolicy.normalizedArticleURL(url.absoluteString),
                  canonical == article.canonicalURL else { throw NewsRepositoryError.invalidStoredData }
            let contributions = try NewsRecordPayload.contributions(article.provenancePayload)
            guard contributions.allSatisfy({ ids.contains($0.feedID) &&
                !$0.topicIDs.isEmpty && Set($0.topicIDs).isSubset(of: known) }) else {
                throw NewsRepositoryError.invalidStoredData
            }
            let sources = contributions.map { entry in
                NewsArticleSource(feedID: entry.feedID, feedName: entry.feedName,
                    topicIDs: Set(entry.topicIDs), guid: entry.guids.first)
            }.sorted { $0.feedID.uuidString < $1.feedID.uuidString }
            let perSource = try contributions.map { entry -> (UUID, NewsSelection.SourceMetadata) in
                // v1 rows predate source-level metadata. Only those rows may fall back
                // to the flattened article fields; v2 restores each feed's own link.
                guard let metadata = entry.metadata else {
                    return (entry.feedID, NewsSelection.SourceMetadata(url: url,
                        canonicalURL: canonical, title: article.title,
                        publishedAt: article.publishedAt, summary: article.summary))
                }
                guard let sourceURL = try? NewsURLPolicy.articleURL(metadata.url),
                      let sourceCanonical = try? NewsURLPolicy.normalizedArticleURL(sourceURL.absoluteString),
                      sourceCanonical == metadata.canonicalURL else {
                    throw NewsRepositoryError.invalidStoredData
                }
                return (entry.feedID, NewsSelection.SourceMetadata(url: sourceURL,
                    canonicalURL: sourceCanonical, title: metadata.title,
                    publishedAt: metadata.publishedAt, summary: metadata.summary))
            }
            return NewsSelection.State(article: ArticleMetadata(id: article.id, url: url,
                canonicalURL: canonical, title: article.title, publishedAt: article.publishedAt,
                firstFetchedAt: article.firstFetchedAt, summary: article.summary, sources: sources),
                aliases: Dictionary(uniqueKeysWithValues: contributions.map { ($0.feedID, $0.guids) }),
                contributions: Dictionary(uniqueKeysWithValues: perSource))
        }
        return NewsSnapshot(topics: catalog.topics, feeds: feeds, articleStates: states,
            preferences: NewsPreferences(catalogVersion: row.catalogVersion,
                selectedTopicIDs: Set(selection), revision: row.revision,
                lastRefreshAt: row.lastRefreshAt))
    }

    func loadOrInitialize(_ catalog: DefaultFeedCatalog) throws -> NewsSnapshot {
        try validatedCatalog(catalog)
        let context = context()
        let existing = try rows(context)
        if existing.preference == nil {
            let topics = try NewsRecordPayload.encodeTopics(catalog.initialSelectedTopicIDs.sorted())
            context.insert(NewsPreferencesRecord(catalogVersion: catalog.version,
                selectedTopicIDsPayload: topics))
            for feed in catalog.feeds {
                context.insert(NewsFeedRecord(id: feed.id, name: feed.name,
                    endpoint: feed.url.absoluteString,
                    topicIDsPayload: try NewsRecordPayload.encodeTopics(feed.topicIDs.sorted())))
            }
            try commit(context)
        } else {
            // Decode *before* trimming; a damaged cache must not be treated as an empty cache.
            let current = try snapshot(existing, catalog: catalog)
            let trimmed = NewsSelection.reconcile(current.articleStates, outcomes: [],
                                                   feeds: current.feeds, at: now())
            let retained = Set(trimmed.map { $0.article.id })
            if retained.count != existing.articles.count {
                for article in existing.articles where !retained.contains(article.id) {
                    context.delete(article)
                }
                try commit(context)
            }
        }
        // Read back only committed state, including after a trim or initial insert.
        let result = try snapshot(rows(self.context()), catalog: catalog)
        self.catalog = catalog
        return result
    }

    func savePreferences(_ edit: NewsPreferencesEdit, expectedRevision: UUID) throws -> NewsSnapshot {
        guard let catalog else { throw NewsRepositoryError.invalidCatalog }
        let known = Set(catalog.topics.map(\.id))
        guard edit.selectedTopicIDs.isSubset(of: known) else {
            throw NewsRepositoryError.invalidSelection
        }
        let context = context()
        let current = try rows(context)
        _ = try snapshot(current, catalog: catalog)
        guard let preference = current.preference else { throw NewsRepositoryError.invalidStoredData }
        guard preference.revision == expectedRevision else { throw NewsRepositoryError.staleRevision }
        preference.selectedTopicIDsPayload = try NewsRecordPayload.encodeTopics(edit.selectedTopicIDs.sorted())
        preference.revision = UUID()
        try commit(context)
        return try snapshot(rows(self.context()), catalog: catalog)
    }
}
