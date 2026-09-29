import CryptoKit
import Foundation

/// Pure cache reconciliation. Persist `State`'s aliases alongside its detached article;
/// a repository must revision-check outcomes and save the returned states atomically.
enum NewsSelection {
    static let maximumArticles = 500
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let undatedLabel = "Date unavailable"

    /// The latest metadata contributed by a feed. Kept separately so removal or disabling
    /// a preferred source cannot leave its title/link attributed to another source.
    struct SourceMetadata: Equatable {
        let url: URL
        let canonicalURL: String
        let title: String
        let publishedAt: Date?
        let summary: String?
    }

    struct State: Equatable {
        var article: ArticleMetadata
        /// Feed-scoped GUIDs, never browser destinations. Bounded to the schema's 1,000 per feed.
        var aliases: [UUID: [String]]
        var contributions: [UUID: SourceMetadata]

        init(article: ArticleMetadata, aliases: [UUID: [String]],
             contributions: [UUID: SourceMetadata]? = nil) {
            self.article = article
            self.aliases = aliases
            // Legacy/synthetic rows without provenance still have a usable fallback.
            let fallback = SourceMetadata(url: article.url, canonicalURL: article.canonicalURL,
                title: article.title, publishedAt: article.publishedAt, summary: article.summary)
            self.contributions = contributions ?? Dictionary(uniqueKeysWithValues:
                article.sources.map { ($0.feedID, fallback) })
        }
    }

    struct VisibleArticle: Equatable {
        let article: ArticleMetadata
        let topicIDs: Set<String>
    }

    struct Section: Equatable {
        enum Kind: Equatable { case dated, dateUnavailable }
        let kind: Kind
        let title: String
        let articles: [VisibleArticle]
    }

    /// Presentation must use the source-aware states, not the flattened article cache.
    static func sections(_ snapshot: NewsSnapshot, filter: String? = nil) -> [Section] {
        sections(snapshot.articleStates, feeds: snapshot.feeds,
                 selectedTopicIDs: snapshot.preferences.selectedTopicIDs, filter: filter)
    }

    /// Keep the intersection with *current* enabled feed mappings, rather than cached
    /// source topic IDs. A deselected topic or disabled feed only hides its contribution.
    private static func sections(_ articles: [ArticleMetadata], feeds: [FeedSourceSnapshot],
                                 selectedTopicIDs: Set<String>, filter: String? = nil) -> [Section] {
        let current = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        let visible = articles.compactMap { article -> VisibleArticle? in
            let ids = article.sources.reduce(into: Set<String>()) { result, source in
                if let feed = current[source.feedID], feed.isEnabled {
                    result.formUnion(feed.topicIDs.intersection(selectedTopicIDs))
                }
            }
            guard !ids.isEmpty, filter == nil || ids.contains(filter!) else { return nil }
            return VisibleArticle(article: article, topicIDs: ids)
        }
        let dated = visible.filter { $0.article.publishedAt != nil }.sorted {
            if $0.article.publishedAt != $1.article.publishedAt {
                return $0.article.publishedAt! > $1.article.publishedAt!
            }
            return $0.article.id.uuidString < $1.article.id.uuidString
        }
        let undated = visible.filter { $0.article.publishedAt == nil }.sorted {
            if $0.article.firstFetchedAt != $1.article.firstFetchedAt {
                return $0.article.firstFetchedAt > $1.article.firstFetchedAt
            }
            return $0.article.id.uuidString < $1.article.id.uuidString
        }
        return [Section(kind: .dated, title: "Dated", articles: dated),
                Section(kind: .dateUnavailable, title: undatedLabel, articles: undated)]
            .filter { !$0.articles.isEmpty }
    }

    /// Project the preferred *visible* source without changing cached provenance. A disabled
    /// feed keeps its contribution for re-enabling, but cannot supply a visible headline/link.
    static func sections(_ states: [State], feeds: [FeedSourceSnapshot],
                         selectedTopicIDs: Set<String>, filter: String? = nil) -> [Section] {
        let current = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        let projected = states.compactMap { state -> ArticleMetadata? in
            let eligible = state.article.sources.filter { source in
                guard let feed = current[source.feedID], feed.isEnabled else { return false }
                let topics = feed.topicIDs.intersection(selectedTopicIDs)
                return !topics.isEmpty && (filter == nil || topics.contains(filter!))
            }
            guard let source = eligible.min(by: { $0.feedID.uuidString < $1.feedID.uuidString }),
                  let metadata = state.contributions[source.feedID] else { return nil }
            return ArticleMetadata(id: state.article.id, url: metadata.url,
                canonicalURL: metadata.canonicalURL, title: metadata.title,
                publishedAt: metadata.publishedAt, firstFetchedAt: state.article.firstFetchedAt,
                summary: metadata.summary, sources: eligible)
        }
        return sections(projected, feeds: feeds, selectedTopicIDs: selectedTopicIDs, filter: filter)
    }

    /// Empty successful feeds do not erase cache. Removing a feed from `feeds` removes its
    /// contribution and orphaned articles; merely disabling it retains its bounded cache.
    static func reconcile(_ stored: [State], outcomes: [FeedRefreshOutcome],
                          feeds: [FeedSourceSnapshot], at now: Date) -> [State] {
        struct Node {
            let article: ArticleMetadata
            let aliases: [UUID: [String]]
            let incomingFeed: UUID?
            let contributions: [UUID: SourceMetadata]
        }
        let feedByID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        var nodes: [Node] = stored.compactMap { state in
            let sources = state.article.sources.filter { feedByID[$0.feedID] != nil }
            guard !sources.isEmpty else { return nil }
            let article = ArticleMetadata(id: state.article.id, url: state.article.url,
                canonicalURL: state.article.canonicalURL, title: state.article.title,
                publishedAt: state.article.publishedAt, firstFetchedAt: state.article.firstFetchedAt,
                summary: state.article.summary, sources: sources)
            let sourceIDs = Set(sources.map(\.feedID))
            return Node(article: article, aliases: state.aliases.filter { sourceIDs.contains($0.key) },
                        incomingFeed: nil, contributions: state.contributions.filter { sourceIDs.contains($0.key) })
        }
        for outcome in outcomes {
            guard let feed = feedByID[outcome.feedID], feed.isEnabled,
                  feed.configurationRevision == outcome.configurationRevision,
                  case let .modified(entries, _, _) = outcome.result else { continue }
            for entry in entries {
                guard let url = try? NewsURLPolicy.articleURL(entry.url),
                      let canonical = try? NewsURLPolicy.normalizedArticleURL(url.absoluteString),
                      !entry.title.isEmpty, entry.title.count <= 512 else { continue }
                let guid = reliableGUID(entry.guid)
                let source = NewsArticleSource(feedID: feed.id, feedName: feed.name,
                                               topicIDs: feed.topicIDs, guid: guid)
                nodes.append(Node(article: ArticleMetadata(id: stableID(canonical), url: url,
                    canonicalURL: canonical, title: entry.title, publishedAt: entry.publishedAt,
                    firstFetchedAt: now, summary: entry.summary, sources: [source]),
                    aliases: guid.map { [feed.id: [$0]] } ?? [:], incomingFeed: feed.id,
                    contributions: [feed.id: SourceMetadata(url: url, canonicalURL: canonical,
                        title: entry.title, publishedAt: entry.publishedAt, summary: entry.summary)]))
            }
        }
        guard !nodes.isEmpty else { return [] }
        var parent = Array(nodes.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current { current = parent[current] }
            return current
        }
        func connect(_ a: Int, _ b: Int) {
            let x = root(a), y = root(b)
            if x != y { parent[max(x, y)] = min(x, y) }
        }
        // URL identity wins even when a GUID is absent or unreliable.
        var urls: [String: Int] = [:]
        for i in nodes.indices {
            for key in Set(nodes[i].contributions.values.map(\.canonicalURL)) {
                if let previous = urls[key] { connect(previous, i) } else { urls[key] = i }
            }
        }
        let urlGroupOf = nodes.indices.map { root($0) }
        var urlGroups: [Int: [Int]] = [:]
        for i in nodes.indices { urlGroups[urlGroupOf[i], default: []].append(i) }
        struct ScopedGUID: Hashable { let feed: UUID; let value: String }
        var matches: [ScopedGUID: [Int]] = [:]
        for i in nodes.indices {
            for (feed, guids) in nodes[i].aliases {
                for guid in guids.compactMap(reliableGUID) {
                    matches[ScopedGUID(feed: feed, value: guid), default: []].append(i)
                }
            }
        }
        var unreliable = Set<ScopedGUID>()
        for (key, indices) in matches {
            // A feed issuing one GUID for two distinct URLs in the same response has
            // contradicted itself. Never use that GUID to bridge those URLs.
            let incomingURLs = Set(indices.filter { nodes[$0].incomingFeed == key.feed }
                .map { nodes[$0].article.canonicalURL })
            if incomingURLs.count > 1 { unreliable.insert(key); continue }
            let old = indices.filter { nodes[$0].incomingFeed == nil }
            if Set(old.map { urlGroupOf[$0] }).count > 1 { unreliable.insert(key); continue }
            // An old URL explicitly reissued with another GUID in this response
            // contradicts a move of its former GUID to a different URL. Check the
            // whole response before connecting GUID groups (URL unions already exist).
            let oldURLs = Set(old.flatMap { nodes[$0].contributions.values.map(\.canonicalURL) })
            let reassignedOldURL = nodes.indices.contains { index in
                guard nodes[index].incomingFeed == key.feed,
                      oldURLs.contains(nodes[index].article.canonicalURL) else { return false }
                let newGUIDs = nodes[index].aliases[key.feed, default: []]
                return !newGUIDs.isEmpty && !newGUIDs.contains(key.value)
            }
            let moved = indices.contains { index in
                nodes[index].incomingFeed == key.feed &&
                    !oldURLs.contains(nodes[index].article.canonicalURL)
            }
            if reassignedOldURL && moved { unreliable.insert(key); continue }
            // If the new URL already belongs to a *different* article with a
            // different GUID from this same feed, the reused GUID is not reliable.
            let contradiction = indices.contains { index in
                guard nodes[index].incomingFeed == key.feed else { return false }
                return urlGroups[urlGroupOf[index], default: []].contains { other in
                    guard other != index,
                          nodes[other].article.sources.contains(where: { $0.feedID == key.feed }) else { return false }
                    let others = nodes[other].aliases[key.feed, default: []]
                    return !others.isEmpty && !others.contains(key.value)
                }
            }
            if contradiction { unreliable.insert(key) }
            else if let first = indices.first {
                for index in indices.dropFirst() { connect(first, index) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in nodes.indices { groups[root(i), default: []].append(i) }
        var result: [State] = []
        for indices in groups.values {
            let members = indices.map { nodes[$0] }
            let existing = members.filter { $0.incomingFeed == nil }
            let firstFetched = members.map(\.article.firstFetchedAt).min()!
            // When two existing rows are bridged, keep the GUID owner's ID even
            // if the URL owner's UUID sorts earlier. Otherwise prefer the oldest ID.
            let guidOwners = existing.filter { node in
                node.aliases.contains { feed, guids in
                    guids.contains { guid in
                        let key = ScopedGUID(feed: feed, value: guid)
                        return !unreliable.contains(key) && members.contains { incoming in
                            incoming.incomingFeed == feed && incoming.aliases[feed]?.contains(guid) == true
                        }
                    }
                }
            }
            let id = (guidOwners.isEmpty ? existing : guidOwners).sorted {
                if $0.article.firstFetchedAt != $1.article.firstFetchedAt {
                    return $0.article.firstFetchedAt < $1.article.firstFetchedAt
                }
                return $0.article.id.uuidString < $1.article.id.uuidString
            }.first?.article.id ?? members.map(\.article.id).min(by: { $0.uuidString < $1.uuidString })!
            let replaced = Set(members.compactMap(\.incomingFeed))
            // Replace only the refreshed feed's contribution. A shared article must
            // retain the other feeds' own metadata for subsequent removals/edits.
            var candidates: [(feed: UUID, metadata: SourceMetadata, fresh: Bool)] = []
            for node in members {
                for (feed, metadata) in node.contributions {
                    if node.incomingFeed == nil && replaced.contains(feed) { continue }
                    candidates.append((feed, metadata, node.incomingFeed == feed))
                }
            }
            func metadataLess(_ a: SourceMetadata, _ b: SourceMetadata) -> Bool {
                let left = (a.canonicalURL, a.title, a.url.absoluteString,
                            a.publishedAt?.timeIntervalSinceReferenceDate ?? -.infinity, a.summary ?? "")
                let right = (b.canonicalURL, b.title, b.url.absoluteString,
                             b.publishedAt?.timeIntervalSinceReferenceDate ?? -.infinity, b.summary ?? "")
                return left < right
            }
            candidates.sort {
                if $0.feed != $1.feed { return $0.feed.uuidString < $1.feed.uuidString }
                if $0.fresh != $1.fresh { return $0.fresh }
                return metadataLess($0.metadata, $1.metadata)
            }
            var contributions: [UUID: SourceMetadata] = [:]
            for candidate in candidates where contributions[candidate.feed] == nil {
                contributions[candidate.feed] = candidate.metadata
            }
            var aliases: [UUID: [String]] = [:]
            for node in members where node.incomingFeed == nil {
                for (feed, guids) in node.aliases where !replaced.contains(feed) {
                    aliases[feed, default: []].append(contentsOf: guids)
                }
            }
            for node in members where node.incomingFeed != nil {
                for (feed, guids) in node.aliases { aliases[feed, default: []].append(contentsOf: guids) }
            }
            aliases = aliases.mapValues { Array(Set($0.compactMap(reliableGUID))).sorted().prefix(1_000).map { $0 } }
            for (feed, guids) in aliases {
                let valid = guids.filter { !unreliable.contains(ScopedGUID(feed: feed, value: $0)) }
                if valid.isEmpty { aliases.removeValue(forKey: feed) }
                else { aliases[feed] = valid }
            }
            contributions = contributions.filter { feedByID[$0.key] != nil }
            let sources = contributions.keys.compactMap { feedID -> NewsArticleSource? in
                guard let feed = feedByID[feedID] else { return nil }
                return NewsArticleSource(feedID: feedID, feedName: feed.name,
                    topicIDs: feed.topicIDs, guid: aliases[feedID]?.first)
            }.sorted { $0.feedID.uuidString < $1.feedID.uuidString }
            guard let preferred = sources.first, let chosen = contributions[preferred.feedID] else { continue }
            let metadata = ArticleMetadata(id: id, url: chosen.url,
                canonicalURL: chosen.canonicalURL, title: chosen.title,
                publishedAt: chosen.publishedAt, firstFetchedAt: firstFetched,
                summary: chosen.summary, sources: sources)
            // Valid publication time governs age, even for articles first seen long ago.
            // Only future publication times fall back to immutable first-fetch age.
            let ageDate = retentionDate(metadata, now: now)
            if ageDate <= now, now.timeIntervalSince(ageDate) <= maximumAge {
                result.append(State(article: metadata, aliases: aliases, contributions: contributions))
            }
        }
        return result.sorted {
            let a = retentionDate($0.article, now: now)
            let b = retentionDate($1.article, now: now)
            if a != b { return a > b }
            return $0.article.id.uuidString < $1.article.id.uuidString
        }.prefix(maximumArticles).map { $0 }
    }

    private static func retentionDate(_ article: ArticleMetadata, now: Date) -> Date {
        guard let published = article.publishedAt, published <= now else { return article.firstFetchedAt }
        return published
    }

    private static func reliableGUID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.utf8.count <= 1_024 else { return nil }
        return trimmed
    }

    private static func stableID(_ canonical: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(canonical.utf8)))
        var id = Array(bytes.prefix(16))
        id[6] = (id[6] & 0x0f) | 0x50
        id[8] = (id[8] & 0x3f) | 0x80
        return UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                           id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]))
    }
}
