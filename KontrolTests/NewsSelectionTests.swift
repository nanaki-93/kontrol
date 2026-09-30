import Foundation
import XCTest
@testable import Kontrol

final class NewsSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func feed(_ id: UUID, topics: Set<String> = ["go"], enabled: Bool = true) -> FeedSourceSnapshot {
        FeedSourceSnapshot(id: id, name: id == a ? "Alpha" : "Beta",
            url: URL(string: "https://feeds.example.com/rss")!, topicIDs: topics,
            isEnabled: enabled, configurationRevision: id, etag: nil, lastModified: nil,
            lastAttemptAt: nil, lastSuccessAt: nil, lastError: nil, retryNotBefore: nil)
    }

    private func entry(_ url: String, _ title: String = "Title", _ guid: String? = nil,
                       date: Date? = nil) -> NewsFeedEntry {
        NewsFeedEntry(title: title, url: URL(string: url)!, guid: guid, publishedAt: date, summary: nil)
    }

    private func result(_ id: UUID, _ entries: [NewsFeedEntry]) -> FeedRefreshOutcome {
        FeedRefreshOutcome(feedID: id, configurationRevision: id, attemptedAt: now,
                           result: .modified(entries, etag: nil, lastModified: nil))
    }

    func testGUIDMoveURLBridgeCollisionAndStableID() {
        let feeds = [feed(a), feed(b, topics: ["security"])]
        let original = NewsSelection.reconcile([], outcomes: [result(a, [entry("https://example.com/old", "Old", "story")])], feeds: feeds, at: now)
        let other = NewsSelection.reconcile(original, outcomes: [result(b, [entry("https://example.com/new", "Other", "other")])], feeds: feeds, at: now)
        XCTAssertEqual(other.count, 2)
        let bridged = NewsSelection.reconcile(other, outcomes: [result(a, [entry("https://example.com/new?utm_source=x", "Renamed", "story")])], feeds: feeds, at: now)
        XCTAssertEqual(bridged.count, 1)
        XCTAssertEqual(bridged[0].article.id, original[0].article.id)
        XCTAssertEqual(Set(bridged[0].article.sources.map(\.feedID)), [a, b])
        XCTAssertEqual(bridged[0].aliases[a], ["story"])
        XCTAssertEqual(bridged[0].aliases[b], ["other"])
        let repeated = NewsSelection.reconcile(bridged, outcomes: [result(a, [entry("https://example.com/new", "Renamed again", "story")])], feeds: feeds, at: now.addingTimeInterval(60))
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(repeated[0].article.id, original[0].article.id)
        XCTAssertEqual(repeated[0].article.firstFetchedAt, now)
        XCTAssertEqual(repeated[0].article.title, "Renamed again")
        let removed = NewsSelection.reconcile(repeated, outcomes: [], feeds: [feed(b, topics: ["security"])], at: now)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].article.sources.map(\.feedID), [b])
        XCTAssertEqual(removed[0].article.title, "Other")
        XCTAssertEqual(removed[0].article.url.absoluteString, "https://example.com/new")
        XCTAssertEqual(removed[0].article.canonicalURL, "https://example.com/new")
        XCTAssertEqual(Set(removed[0].contributions.keys), [b])
        XCTAssertNil(removed[0].aliases[a])
        XCTAssertEqual(NewsSelection.reconcile(removed, outcomes: [], feeds: [], at: now).count, 0)
    }

    func testRemovingPreferredFeedRestoresOtherFeedsOwnMetadata() {
        let feeds = [feed(a), feed(b, topics: ["security"])]
        let alpha = NewsFeedEntry(title: "Alpha headline", url: URL(string: "https://example.com/story?utm_source=alpha")!,
            guid: "a", publishedAt: now.addingTimeInterval(-100), summary: "Alpha summary")
        let beta = NewsFeedEntry(title: "Beta headline", url: URL(string: "https://example.com/story#beta")!,
            guid: "b", publishedAt: nil, summary: "Beta summary")
        let merged = NewsSelection.reconcile([], outcomes: [result(b, [beta]), result(a, [alpha])], feeds: feeds, at: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].article.title, "Alpha headline")
        let snapshot = NewsSnapshot(topics: [], feeds: [feed(a, enabled: false), feed(b, topics: ["security"])],
            articleStates: merged, preferences: NewsPreferences(catalogVersion: 1,
                selectedTopicIDs: ["go", "security"], revision: a, lastRefreshAt: now))
        XCTAssertEqual(snapshot.articles.first?.title, "Alpha headline", "Cache retains the preferred source")
        let disabled = NewsSelection.sections(snapshot)
        XCTAssertEqual(disabled.first?.articles.first?.article.title, "Beta headline")
        XCTAssertEqual(disabled.first?.articles.first?.article.url.absoluteString, "https://example.com/story#beta")
        XCTAssertEqual(disabled.first?.kind, .dateUnavailable)
        XCTAssertEqual(disabled.first?.articles.first?.topicIDs, ["security"])
        let surviving = NewsSelection.reconcile(merged, outcomes: [], feeds: [feed(b, topics: ["security"])], at: now)
        XCTAssertEqual(surviving.count, 1)
        XCTAssertEqual(surviving[0].article.title, "Beta headline")
        XCTAssertEqual(surviving[0].article.url.absoluteString, "https://example.com/story#beta")
        XCTAssertNil(surviving[0].article.publishedAt)
        XCTAssertEqual(surviving[0].article.summary, "Beta summary")
        XCTAssertEqual(surviving[0].article.sources.map(\.feedID), [b])
        XCTAssertEqual(surviving[0].aliases, [b: ["b"]])
        XCTAssertEqual(Set(surviving[0].contributions.keys), [b])
        XCTAssertEqual(NewsSelection.reconcile(surviving, outcomes: [], feeds: [feed(b, topics: ["security"])], at: now), surviving)
    }

    func testLaterPublicationCannotReviveExpiredFirstFetch() {
        let feeds = [feed(a)]
        let firstFetch = now.addingTimeInterval(-NewsSelection.maximumAge - 24 * 60 * 60)
        let original = NewsSelection.reconcile([], outcomes: [result(a, [
            entry("https://example.com/old-fetch", "Original", "story")
        ])], feeds: feeds, at: firstFetch)
        XCTAssertEqual(original.count, 1)
        let recent = now.addingTimeInterval(-24 * 60 * 60)
        let updated = NewsSelection.reconcile(original, outcomes: [result(a, [
            entry("https://example.com/old-fetch", "Published", "story", date: recent)
        ])], feeds: feeds, at: now)
        XCTAssertTrue(updated.isEmpty, "A later publication cannot extend immutable first-fetch retention")
        let future = NewsSelection.reconcile(original, outcomes: [result(a, [
            entry("https://example.com/old-fetch", "Future", "story", date: now.addingTimeInterval(86_400))
        ])], feeds: feeds, at: now)
        XCTAssertTrue(future.isEmpty, "Future dates must not revive an expired first fetch")
    }

    func testReissuedURLAfterGUIDMovesAllocatesUniqueStableIDs() {
        let feeds = [feed(a)]
        let original = NewsSelection.reconcile([], outcomes: [result(a, [
            entry("https://example.com/old", "Original", "g1")
        ])], feeds: feeds, at: now)
        let originalID = original[0].article.id
        let moved = NewsSelection.reconcile(original, outcomes: [result(a, [
            entry("https://example.com/new", "Moved", "g1")
        ])], feeds: feeds, at: now.addingTimeInterval(60))
        XCTAssertEqual(moved[0].article.id, originalID)
        let reissued = entry("https://example.com/old", "Reissued", "g2")
        let current = entry("https://example.com/new", "Moved", "g1")
        let separate = NewsSelection.reconcile(moved, outcomes: [result(a, [reissued, current])],
            feeds: feeds, at: now.addingTimeInterval(120))
        XCTAssertEqual(separate.count, 2)
        XCTAssertEqual(Set(separate.map(\.article.id)).count, 2)
        XCTAssertEqual(separate.first { $0.article.url.path == "/new" }?.article.id, originalID)
        let reissuedID = separate.first { $0.article.url.path == "/old" }?.article.id
        XCTAssertNotEqual(reissuedID, originalID)
        XCTAssertEqual(NewsSelection.reconcile(moved, outcomes: [result(a, [current, reissued])],
            feeds: feeds, at: now.addingTimeInterval(120)), separate)
        XCTAssertEqual(NewsSelection.reconcile(separate.reversed(), outcomes: [result(a, [current, reissued])],
            feeds: feeds, at: now.addingTimeInterval(180)), separate)
        // Repeating the move/reissue cycle exercises collision probing beyond the
        // first alternate ID, without changing either existing article's identity.
        let movedAgain = NewsSelection.reconcile(separate, outcomes: [result(a, [
            entry("https://example.com/third", "Moved again", "g2")
        ])], feeds: feeds, at: now.addingTimeInterval(180))
        let third = NewsSelection.reconcile(movedAgain, outcomes: [result(a, [
            entry("https://example.com/old", "Third identity", "g3")
        ])], feeds: feeds, at: now.addingTimeInterval(240))
        XCTAssertEqual(third.count, 3)
        XCTAssertEqual(Set(third.map(\.article.id)).count, 3)
        XCTAssertEqual(third.first { $0.article.url.path == "/third" }?.article.id, reissuedID)
        XCTAssertEqual(third.first { $0.article.url.path == "/new" }?.article.id, originalID)
    }

    func testFuturePublicationRetentionDoesNotChangeWhenClockPassesPublication() {
        let feeds = [feed(a)]
        let publication = now.addingTimeInterval(20 * 86_400)
        let entries = [entry("https://example.com/future", "Future", "future", date: publication)]
        let initial = NewsSelection.reconcile([], outcomes: [result(a, entries)], feeds: feeds, at: now)
        XCTAssertEqual(initial[0].article.publishedAt, publication, "Display keeps the supplied date")
        let day21 = now.addingTimeInterval(21 * 86_400)
        let pastPublication = NewsSelection.reconcile(initial, outcomes: [], feeds: feeds, at: day21)
        XCTAssertEqual(pastPublication, initial)
        let boundary = now.addingTimeInterval(NewsSelection.maximumAge)
        XCTAssertEqual(NewsSelection.reconcile(pastPublication, outcomes: [], feeds: feeds, at: boundary), initial)
        for outcomes in [[], [result(a, entries)], [FeedRefreshOutcome(feedID: a,
            configurationRevision: a, attemptedAt: boundary, result: .notModified)]] {
            XCTAssertTrue(NewsSelection.reconcile(pastPublication, outcomes: outcomes, feeds: feeds,
                at: boundary.addingTimeInterval(1)).isEmpty)
        }
        XCTAssertTrue(NewsSelection.reconcile(initial, outcomes: [], feeds: feeds,
            at: now.addingTimeInterval(31 * 86_400)).isEmpty)
    }

    func testContradictoryAndOversizedGUIDsFallBackToURL() {
        let feeds = [feed(a)]
        let dup = NewsSelection.reconcile([], outcomes: [result(a, [
            entry("https://example.com/one", "One", "reused"),
            entry("https://example.com/two", "Two", "reused")
        ])], feeds: feeds, at: now)
        XCTAssertEqual(dup.count, 2)
        XCTAssertTrue(dup.allSatisfy { $0.aliases.isEmpty && $0.article.sources.first?.guid == nil })
        let bad = NewsSelection.reconcile([], outcomes: [result(a, [
            entry("https://example.com/one", "One", String(repeating: "x", count: 1_025)),
            entry("https://example.com/one#fragment", "Same", "")
        ])], feeds: feeds, at: now)
        XCTAssertEqual(bad.count, 1)
        XCTAssertTrue(bad[0].aliases.isEmpty)
        let conflicting = NewsSelection.reconcile(dup, outcomes: [result(a, [entry("https://example.com/two", "Two", "reused")])], feeds: feeds, at: now)
        XCTAssertEqual(conflicting.count, 2, "A reused GUID must not merge a different same-feed URL")
    }

    func testReassignedOldURLAndReusedGUIDStayDistinctRegardlessOfOrder() {
        let feeds = [feed(a)]
        let stored = NewsSelection.reconcile([], outcomes: [result(a, [
            entry("https://example.com/old", "Old", "reused")
        ])], feeds: feeds, at: now)
        let updated = entry("https://example.com/old", "New identity", "new-guid")
        let reused = entry("https://example.com/different", "Different", "reused")
        for entries in [[updated, reused], [reused, updated]] {
            let result = NewsSelection.reconcile(stored, outcomes: [result(a, entries)], feeds: feeds,
                at: now.addingTimeInterval(60))
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(Set(result.map(\.article.canonicalURL)),
                ["https://example.com/old", "https://example.com/different"])
            XCTAssertEqual(result.first(where: { $0.article.canonicalURL == "https://example.com/old" })?.article.id,
                stored[0].article.id, "URL identity retains the existing row")
            XCTAssertFalse(result.contains { $0.aliases[a]?.contains("reused") == true },
                "A contradicted alias must not bridge a later refresh")
        }
    }

    func testMovingGUIDWithoutURLMatchAndMeaningfulQueryDistinctions() {
        let feeds = [feed(a)]
        let original = NewsSelection.reconcile([], outcomes: [result(a, [entry("https://example.com/story?edition=1", "Old", "guid")])], feeds: feeds, at: now)
        let moved = NewsSelection.reconcile(original, outcomes: [result(a, [entry("https://example.com/story?edition=2", "New", "guid")])], feeds: feeds, at: now.addingTimeInterval(60))
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].article.id, original[0].article.id)
        XCTAssertEqual(moved[0].article.canonicalURL, "https://example.com/story?edition=2")
        let another = NewsSelection.reconcile(moved, outcomes: [result(a, [entry("https://example.com/story?edition=3", "Third", nil)])], feeds: feeds, at: now)
        XCTAssertEqual(another.count, 2, "Meaningful queries must remain distinct without a GUID bridge")
        let stale = FeedRefreshOutcome(feedID: a, configurationRevision: UUID(), attemptedAt: now,
            result: .modified([entry("https://example.com/stale")], etag: nil, lastModified: nil))
        XCTAssertEqual(NewsSelection.reconcile(another, outcomes: [stale], feeds: feeds, at: now), another)
    }

    func testGUIDOwnerWinsBridgeEvenIfURLOwnersIDSortsEarlier() {
        let feeds = [feed(a), feed(b)]
        let first = NewsSelection.reconcile([], outcomes: [result(a, [entry("https://example.com/old", "Old", "guid")])], feeds: feeds, at: now)
        let second = NewsSelection.reconcile([], outcomes: [result(b, [entry("https://example.com/new", "New", "other")])], feeds: feeds, at: now)
        let highID = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
        let lowID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
        let oldArticle = first[0].article
        let newArticle = second[0].article
        let old = NewsSelection.State(article: ArticleMetadata(id: highID, url: oldArticle.url,
            canonicalURL: oldArticle.canonicalURL, title: oldArticle.title,
            publishedAt: nil, firstFetchedAt: now, summary: nil, sources: oldArticle.sources), aliases: first[0].aliases)
        let new = NewsSelection.State(article: ArticleMetadata(id: lowID, url: newArticle.url,
            canonicalURL: newArticle.canonicalURL, title: newArticle.title,
            publishedAt: nil, firstFetchedAt: now, summary: nil, sources: newArticle.sources), aliases: second[0].aliases)
        let joined = NewsSelection.reconcile([new, old], outcomes: [result(a, [entry("https://example.com/new", "Moved", "guid")])], feeds: feeds, at: now)
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].article.id, highID)
    }

    func testCrossFeedURLsAndMetadataIndependentOfResponseOrder() {
        let feeds = [feed(a), feed(b, topics: ["security"])]
        let x = result(a, [entry("https://NEWS.example.com:443/Story?x=1&utm_campaign=a", "Alpha", "a")])
        let y = result(b, [entry("https://news.example.com/Story?x=1#top", "Beta", "b")])
        let first = NewsSelection.reconcile([], outcomes: [x, y], feeds: feeds, at: now)
        let reverse = NewsSelection.reconcile([], outcomes: [y, x], feeds: feeds, at: now)
        XCTAssertEqual(first, reverse)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].article.title, "Alpha")
        func snapshot(_ feeds: [FeedSourceSnapshot], _ topics: Set<String>) -> NewsSnapshot {
            NewsSnapshot(topics: [], feeds: feeds, articleStates: first,
                preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: topics,
                    revision: a, lastRefreshAt: now))
        }
        XCTAssertEqual(NewsSelection.sections(snapshot(feeds, ["security"])).first?.articles.first?.topicIDs, ["security"])
        XCTAssertTrue(NewsSelection.sections(snapshot(feeds, ["go"]), filter: "security").isEmpty)
        XCTAssertEqual(NewsSelection.sections(snapshot([feed(a, enabled: false), feed(b, topics: ["ai"])], ["ai"]))
            .first?.articles.first?.topicIDs, ["ai"])
        XCTAssertTrue(NewsSelection.sections(snapshot(feeds, [])).isEmpty)
    }

    func testDatedAndUndatedSectionsTieBreakingAndImmutableFallbackAge() {
        let feeds = [feed(a)]
        let entries = [entry("https://example.com/dated", date: now.addingTimeInterval(-100)),
                       entry("https://example.com/undated"),
                       entry("https://example.com/future", date: now.addingTimeInterval(60 * 60 * 24 * 365))]
        let initial = NewsSelection.reconcile([], outcomes: [result(a, entries)], feeds: feeds, at: now)
        let sections = NewsSelection.sections(initial, feeds: feeds, selectedTopicIDs: ["go"])
        XCTAssertEqual(sections.map(\.kind), [.dated, .dateUnavailable])
        XCTAssertEqual(sections.last?.title, "Date unavailable")
        XCTAssertNil(sections.last?.articles.first?.article.publishedAt)
        XCTAssertEqual(sections.first?.articles.first?.article.url.path, "/future")
        let cutoff = now.addingTimeInterval(NewsSelection.maximumAge + 1)
        let repeated = NewsSelection.reconcile(initial, outcomes: [result(a, entries)], feeds: feeds, at: cutoff)
        XCTAssertTrue(repeated.isEmpty, "Future dates and repeated fetches cannot extend fallback age")
        let old = NewsSelection.reconcile([], outcomes: [result(a, [entry("https://example.com/old", date: now.addingTimeInterval(-NewsSelection.maximumAge - 1))])], feeds: feeds, at: now)
        XCTAssertTrue(old.isEmpty)
    }

    func testGlobalLimitAndTrimRemoveAliases() {
        let feeds = [feed(a), feed(b)]
        let entries = (0..<510).map { i in entry("https://example.com/\(i)", "Item \(i)", "guid-\(i)") }
        let retained = NewsSelection.reconcile([], outcomes: [result(a, entries), result(b, entries)], feeds: feeds, at: now)
        XCTAssertEqual(retained.count, 500)
        XCTAssertEqual(Set(retained.map { $0.article.canonicalURL }).count, 500)
        XCTAssertTrue(retained.allSatisfy { $0.article.sources.count == 2 && $0.aliases.count == 2 })
        let again = NewsSelection.reconcile(retained, outcomes: [], feeds: feeds, at: now)
        XCTAssertEqual(again, retained)
        let trimmedURLs = Set(entries.map { try! NewsURLPolicy.normalizedArticleURL($0.url.absoluteString) })
            .subtracting(retained.map { $0.article.canonicalURL })
        XCTAssertEqual(trimmedURLs.count, 10)
        XCTAssertFalse(retained.contains { trimmedURLs.contains($0.article.canonicalURL) })
    }
}
