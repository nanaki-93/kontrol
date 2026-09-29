import Foundation
import SwiftData

enum NewsRepositoryError: Error, Equatable {
    case invalidCatalog
    case invalidSelection
    case invalidStoredData
    case staleRevision
    case invalidFeed
    case duplicateEndpoint
    case feedLimitReached
    case validationRequired
}

@MainActor
protocol NewsRepository {
    func loadOrInitialize(_ catalog: DefaultFeedCatalog) throws -> NewsSnapshot
    func savePreferences(_ edit: NewsPreferencesEdit, expectedRevision: UUID) throws -> NewsSnapshot
    func saveFeed(_ draft: FeedDraft, validation: ValidatedFeed?) throws -> NewsSnapshot
    func removeFeed(id: UUID, expectedRevision: UUID) throws -> NewsSnapshot
    func applyRefresh(_ outcomes: [FeedRefreshOutcome], at: Date) throws -> NewsSnapshot
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

    /// A receipt belongs to exactly one editor revision and endpoint. Only the store/service
    /// can obtain one; a locally valid disabled draft needs no network at all.
    func saveFeed(_ draft: FeedDraft, validation: ValidatedFeed? = nil) throws -> NewsSnapshot {
        guard let catalog else { throw NewsRepositoryError.invalidCatalog }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointText = draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = Set(catalog.topics.map(\.id))
        guard !name.isEmpty, name.utf8.count <= 256, !draft.topicIDs.isEmpty,
              draft.topicIDs.isSubset(of: known),
              let endpoint = try? NewsURLPolicy.feedURL(endpointText),
              let normalized = try? NewsURLPolicy.normalizedFeedURL(endpoint.absoluteString) else {
            throw NewsRepositoryError.invalidFeed
        }
        let context = context()
        let current = try rows(context)
        let before = try snapshot(current, catalog: catalog)
        let record: NewsFeedRecord?
        if let id = draft.id {
            guard let found = current.feeds.first(where: { $0.id == id }),
                  found.configurationRevision == draft.expectedRevision else {
                throw NewsRepositoryError.staleRevision
            }
            record = found
        } else {
            guard draft.expectedRevision == nil else { throw NewsRepositoryError.staleRevision }
            guard current.feeds.count < 32 else { throw NewsRepositoryError.feedLimitReached }
            record = nil
        }
        guard !before.feeds.contains(where: {
            $0.id != record?.id && (try? NewsURLPolicy.normalizedFeedURL($0.url.absoluteString)) == normalized
        }) else { throw NewsRepositoryError.duplicateEndpoint }
        let changedEndpoint = record.map { (try? NewsURLPolicy.normalizedFeedURL($0.endpoint)) != normalized } ?? true
        let needsValidation = draft.isEnabled && (record == nil || changedEndpoint ||
            (record?.isEnabled == false && record?.lastSuccessAt == nil))
        if needsValidation {
            guard let validation, validation.draftRevision == draft.draftRevision,
                  validation.url == endpoint, validation.validatedAt.timeIntervalSinceReferenceDate.isFinite,
                  (validation.etag?.utf8.count ?? 0) <= 4_096,
                  (validation.lastModified?.utf8.count ?? 0) <= 4_096 else {
                throw NewsRepositoryError.validationRequired
            }
        }
        let topics = try NewsRecordPayload.encodeTopics(draft.topicIDs.sorted())
        if let record {
            record.name = name
            record.topicIDsPayload = topics
            record.isEnabled = draft.isEnabled
            record.endpoint = endpoint.absoluteString
            record.configurationRevision = UUID()
            if changedEndpoint {
                // Even a validated endpoint has no cached entries yet. Sending its
                // receipt's validators could yield a 304 before the first cache merge.
                record.etag = nil
                record.lastModified = nil
                record.retryNotBefore = nil
                record.lastErrorCode = nil
                record.lastAttemptAt = nil
                record.lastSuccessAt = nil
            }
            if needsValidation { record.lastSuccessAt = validation?.validatedAt }
        } else {
            let new = NewsFeedRecord(name: name, endpoint: endpoint.absoluteString,
                topicIDsPayload: topics, isEnabled: draft.isEnabled,
                lastSuccessAt: needsValidation ? validation?.validatedAt : nil)
            context.insert(new)
        }
        // Endpoint changes evict this feed's old metadata. Other feeds keep their own
        // contribution; disabled and name/topic-only edits retain the bounded cache.
        if changedEndpoint, let id = record?.id {
            try rewriteArticles(before.articleStates, rows: current.articles,
                                feeds: before.feeds.filter { $0.id != id }, context: context)
        } else if record != nil {
            try rewriteArticles(before.articleStates, rows: current.articles,
                                feeds: try feedSnapshots(current.feeds, catalog: catalog), context: context)
        }
        try commit(context)
        return try snapshot(rows(self.context()), catalog: catalog)
    }

    func removeFeed(id: UUID, expectedRevision: UUID) throws -> NewsSnapshot {
        guard let catalog else { throw NewsRepositoryError.invalidCatalog }
        let context = context()
        let current = try rows(context)
        let before = try snapshot(current, catalog: catalog)
        guard let record = current.feeds.first(where: { $0.id == id }),
              record.configurationRevision == expectedRevision else {
            throw NewsRepositoryError.staleRevision
        }
        try rewriteArticles(before.articleStates, rows: current.articles,
                            feeds: before.feeds.filter { $0.id != id }, context: context)
        context.delete(record)
        try commit(context)
        return try snapshot(rows(self.context()), catalog: catalog)
    }

    private func feedSnapshots(_ records: [NewsFeedRecord], catalog: DefaultFeedCatalog) throws -> [FeedSourceSnapshot] {
        // Decoding through the normal read boundary keeps all validation in one place.
        // Used only after an already validated snapshot, with the edited rows in this context.
        let known = Set(catalog.topics.map(\.id))
        return try records.map { record in
            let topics = try NewsRecordPayload.topics(record.topicIDsPayload)
            guard Set(topics).isSubset(of: known) else { throw NewsRepositoryError.invalidStoredData }
            return FeedSourceSnapshot(id: record.id, name: record.name,
                url: try NewsURLPolicy.feedURL(record.endpoint), topicIDs: Set(topics),
                isEnabled: record.isEnabled, configurationRevision: record.configurationRevision,
                etag: record.etag, lastModified: record.lastModified,
                lastAttemptAt: record.lastAttemptAt, lastSuccessAt: record.lastSuccessAt,
                lastError: record.lastErrorCode.flatMap(NewsErrorCode.init(rawValue:)),
                retryNotBefore: record.retryNotBefore)
        }
    }

    private func rewriteArticles(_ states: [NewsSelection.State], rows: [NewsArticleRecord], feeds: [FeedSourceSnapshot],
                                 context: ModelContext, at date: Date? = nil) throws {
        let kept = NewsSelection.reconcile(states, outcomes: [], feeds: feeds, at: date ?? now())
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let retained = Set(kept.map { $0.article.id })
        for row in rows where !retained.contains(row.id) { context.delete(row) }
        for state in kept {
            let article = state.article
            let contributions = try article.sources.map { source -> NewsRecordPayload.Contribution in
                guard let metadata = state.contributions[source.feedID] else {
                    throw NewsRepositoryError.invalidStoredData
                }
                return .init(feedID: source.feedID, feedName: source.feedName,
                    topicIDs: source.topicIDs.sorted(), guids: state.aliases[source.feedID] ?? [],
                    metadata: .init(url: metadata.url.absoluteString, canonicalURL: metadata.canonicalURL,
                        title: metadata.title, publishedAt: metadata.publishedAt, summary: metadata.summary))
            }
            let payload = try NewsRecordPayload.encodeContributions(contributions)
            let row = byID[article.id] ?? NewsArticleRecord(id: article.id,
                url: article.url.absoluteString, canonicalURL: article.canonicalURL,
                title: article.title, publishedAt: article.publishedAt,
                firstFetchedAt: article.firstFetchedAt, summary: article.summary,
                provenancePayload: payload)
            row.url = article.url.absoluteString
            row.canonicalURL = article.canonicalURL
            row.title = article.title
            row.publishedAt = article.publishedAt
            row.firstFetchedAt = article.firstFetchedAt
            row.summary = article.summary
            row.provenancePayload = payload
            if byID[article.id] == nil { context.insert(row) }
        }
    }

    /// Fence late responses against the authoritative rows, not a previously published
    /// snapshot. One fresh context owns the entire batch and retention rewrite.
    func applyRefresh(_ outcomes: [FeedRefreshOutcome], at date: Date) throws -> NewsSnapshot {
        guard let catalog else { throw NewsRepositoryError.invalidCatalog }
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw NewsRepositoryError.invalidStoredData }
        let context = context()
        let current = try rows(context)
        let before = try snapshot(current, catalog: catalog)
        let feeds = Dictionary(uniqueKeysWithValues: before.feeds.map { ($0.id, $0) })
        let records = Dictionary(uniqueKeysWithValues: current.feeds.map { ($0.id, $0) })
        var accepted: [FeedRefreshOutcome] = []
        var seen = Set<UUID>()
        var succeeded = false
        for outcome in outcomes {
            guard let feed = feeds[outcome.feedID], feed.isEnabled,
                  feed.configurationRevision == outcome.configurationRevision,
                  let record = records[outcome.feedID], seen.insert(outcome.feedID).inserted else { continue }
            switch outcome.result {
            case .canceled, .deferred:
                continue // Neither an attempt nor a successful check was committed.
            case .modified(_, let etag, let lastModified):
                guard let attempt = outcome.attemptedAt,
                      attempt.timeIntervalSinceReferenceDate.isFinite,
                      (etag?.utf8.count ?? 0) <= 4_096,
                      (lastModified?.utf8.count ?? 0) <= 4_096 else {
                    throw NewsRepositoryError.invalidStoredData
                }
                record.lastAttemptAt = attempt
                record.lastSuccessAt = attempt
                record.lastErrorCode = nil
                record.retryNotBefore = nil
                record.etag = etag
                record.lastModified = lastModified
                succeeded = true
                accepted.append(outcome)
            case .notModified:
                guard let attempt = outcome.attemptedAt,
                      attempt.timeIntervalSinceReferenceDate.isFinite else {
                    throw NewsRepositoryError.invalidStoredData
                }
                record.lastAttemptAt = attempt
                record.lastSuccessAt = attempt
                record.lastErrorCode = nil
                record.retryNotBefore = nil
                // A 304 cannot replace the validators or source contributions.
                succeeded = true
                accepted.append(outcome)
            case .failed(let code, let retry):
                guard outcome.attemptedAt?.timeIntervalSinceReferenceDate.isFinite != false,
                      retry?.timeIntervalSinceReferenceDate.isFinite != false else {
                    throw NewsRepositoryError.invalidStoredData
                }
                if let attempt = outcome.attemptedAt { record.lastAttemptAt = attempt }
                record.lastErrorCode = code.rawValue
                record.retryNotBefore = retry
                accepted.append(outcome)
            }
        }
        guard !accepted.isEmpty else { return before }
        if succeeded {
            let merged = NewsSelection.reconcile(before.articleStates, outcomes: accepted,
                                                 feeds: before.feeds, at: date)
            try rewriteArticles(merged, rows: current.articles, feeds: before.feeds,
                                context: context, at: date)
            guard let preference = current.preference else { throw NewsRepositoryError.invalidStoredData }
            preference.lastRefreshAt = max(preference.lastRefreshAt ?? date, date)
        }
        try commit(context)
        return try snapshot(rows(self.context()), catalog: catalog)
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
