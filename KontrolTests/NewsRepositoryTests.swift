import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class NewsRepositoryTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_750_000_000)

    private func store() throws -> (ModelContainer, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store"))), directory)
    }

    private func catalog(version: Int = 1, name: String = "Original") -> DefaultFeedCatalog {
        DefaultFeedCatalog(version: version,
            topics: [NewsTopic(id: "go", name: "Go"), NewsTopic(id: "ai", name: "AI")],
            initialSelectedTopicIDs: ["go"],
            feeds: [.init(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                          name: name, url: URL(string: "https://feeds.example.com/rss")!,
                          topicIDs: ["go"])])
    }

    private func draft(_ feed: FeedSourceSnapshot? = nil, name: String = "Custom",
                       url: String = "https://custom.example.com/rss", topics: Set<String> = ["ai"],
                       enabled: Bool = false) -> FeedDraft {
        FeedDraft(id: feed?.id, name: name, urlText: url, topicIDs: topics,
            isEnabled: enabled, expectedRevision: feed?.configurationRevision, draftRevision: UUID())
    }

    private func receipt(_ draft: FeedDraft) throws -> ValidatedFeed {
        ValidatedFeed(draftRevision: draft.draftRevision,
            url: try NewsURLPolicy.feedURL(draft.urlText), validatedAt: instant,
            etag: "new-etag", lastModified: "new-date")
    }

    func testDisabledDraftOfflineAndRevisionCheckedEditsSurviveReopen() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let original = try repo.loadOrInitialize(catalog())
        let added = try repo.saveFeed(draft())
        XCTAssertEqual(added.feeds.count, 2)
        let custom = try XCTUnwrap(added.feeds.first { $0.name == "Custom" })
        XCTAssertFalse(custom.isEnabled)
        XCTAssertNil(custom.lastSuccessAt)
        XCTAssertEqual(original.preferences.revision, added.preferences.revision)
        let edit = draft(custom, name: "  Renamed  ", url: custom.url.absoluteString,
                         topics: ["go", "ai"])
        let edited = try repo.saveFeed(edit)
        XCTAssertEqual(edited.feeds.first { $0.id == custom.id }?.name, "Renamed")
        XCTAssertEqual(edited.feeds.first { $0.id == custom.id }?.topicIDs, ["go", "ai"])
        XCTAssertThrowsError(try repo.saveFeed(edit)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .staleRevision)
        }
        XCTAssertThrowsError(try repo.removeFeed(id: custom.id, expectedRevision: custom.configurationRevision)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .staleRevision)
        }
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataNewsRepository(container: reopened, now: { self.instant })
            .loadOrInitialize(catalog(version: 2)).feeds, edited.feeds)
    }

    func testInvalidDuplicateLimitAndValidationReceiptsLeaveRowsIntact() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let original = try repo.loadOrInitialize(catalog())
        for invalid in [draft(name: "   "), draft(url: "http://bad.example.com/rss"),
                        draft(topics: []), draft(topics: ["unknown"])] {
            XCTAssertThrowsError(try repo.saveFeed(invalid)) {
                XCTAssertEqual($0 as? NewsRepositoryError, .invalidFeed)
            }
        }
        XCTAssertThrowsError(try repo.saveFeed(draft(url: "https://FEEDS.example.com:443/rss"))) {
            XCTAssertEqual($0 as? NewsRepositoryError, .duplicateEndpoint)
        }
        let enabled = draft(enabled: true)
        XCTAssertThrowsError(try repo.saveFeed(enabled)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .validationRequired)
        }
        let other = draft(enabled: true)
        XCTAssertThrowsError(try repo.saveFeed(other, validation: try receipt(enabled))) {
            XCTAssertEqual($0 as? NewsRepositoryError, .validationRequired)
        }
        let wrongURL = ValidatedFeed(draftRevision: enabled.draftRevision,
            url: URL(string: "https://wrong.example.com/rss")!, validatedAt: instant,
            etag: nil, lastModified: nil)
        XCTAssertThrowsError(try repo.saveFeed(enabled, validation: wrongURL))
        XCTAssertEqual(try repo.loadOrInitialize(catalog()), original)
        let added = try repo.saveFeed(enabled, validation: receipt(enabled))
        XCTAssertEqual(added.feeds.first { $0.name == "Custom" }?.lastSuccessAt, instant)
        for index in 0..<30 {
            _ = try repo.saveFeed(draft(name: "Feed \(index)", url: "https://feed\(index).example.com/rss"))
        }
        XCTAssertEqual(try repo.loadOrInitialize(catalog()).feeds.count, 32)
        XCTAssertThrowsError(try repo.saveFeed(draft(url: "https://overflow.example.com/rss"))) {
            XCTAssertEqual($0 as? NewsRepositoryError, .feedLimitReached)
        }
    }

    func testEnablingUnvalidatedFeedNeedsReceiptAndNameOnlyEditNeedsNone() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let initial = try repo.loadOrInitialize(catalog())
        let disabled = try XCTUnwrap(repo.saveFeed(draft()).feeds.first { $0.name == "Custom" })
        let enabling = draft(disabled, url: disabled.url.absoluteString, enabled: true)
        XCTAssertThrowsError(try repo.saveFeed(enabling)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .validationRequired)
        }
        let enabled = try repo.saveFeed(enabling, validation: receipt(enabling))
        let checked = try XCTUnwrap(enabled.feeds.first { $0.id == disabled.id })
        XCTAssertEqual(checked.lastSuccessAt, instant)
        let renamed = try repo.saveFeed(draft(checked, name: "New name", url: checked.url.absoluteString,
            enabled: true))
        XCTAssertEqual(renamed.feeds.first { $0.id == checked.id }?.name, "New name")
        XCTAssertEqual(renamed.preferences.revision, initial.preferences.revision)
        let defaultEdit = draft(initial.feeds[0], name: "Changed default",
            url: initial.feeds[0].url.absoluteString, topics: ["ai"], enabled: true)
        XCTAssertEqual(try repo.saveFeed(defaultEdit).feeds.first { $0.id == initial.feeds[0].id }?.name,
                       "Changed default")
    }

    func testEndpointEditAndRemovalCleanOnlyTheirContributionAndFailedSaveIsAtomic() throws {
        enum Failure: Error { case injected }
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let initial = try repo.loadOrInitialize(catalog())
        let primary = initial.feeds[0]
        let secondary = try XCTUnwrap(repo.saveFeed(draft()).feeds.first { $0.name == "Custom" })
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let shared = "https://news.example.com/shared"
        let solo = "https://news.example.com/solo"
        for (link, ids) in [(shared, [primary.id, secondary.id]), (solo, [primary.id])] {
            context.insert(NewsArticleRecord(url: link, canonicalURL: link, title: link,
                firstFetchedAt: instant, provenancePayload: try NewsRecordPayload.encodeContributions(
                    ids.map { id in .init(feedID: id, feedName: id == primary.id ? primary.name : secondary.name,
                        topicIDs: id == primary.id ? ["go"] : ["ai"], guids: [link]) })))
        }
        let feedRow = try XCTUnwrap(context.fetch(FetchDescriptor<NewsFeedRecord>()).first { $0.id == primary.id })
        feedRow.etag = "old"
        feedRow.lastModified = "old-date"
        feedRow.lastErrorCode = NewsErrorCode.http.rawValue
        feedRow.retryNotBefore = instant.addingTimeInterval(3600)
        feedRow.lastAttemptAt = instant
        try context.save()
        let cached = try repo.loadOrInitialize(catalog())
        XCTAssertEqual(cached.articles.count, 2)
        XCTAssertEqual(NewsSelection.sections(cached).flatMap(\.articles).count, 2)
        let disabled = try repo.saveFeed(draft(primary, name: "  Edited  ",
            url: primary.url.absoluteString, topics: ["ai"], enabled: false))
        XCTAssertEqual(disabled.articles.count, 2)
        XCTAssertTrue(NewsSelection.sections(disabled).isEmpty) // secondary is also disabled
        XCTAssertEqual(disabled.articleStates.first { $0.article.canonicalURL == shared }?.article.sources
            .first { $0.feedID == primary.id }?.feedName, "Edited")
        let old = try XCTUnwrap(disabled.feeds.first { $0.id == primary.id })
        let changed = draft(old, url: "https://replacement.example.com/rss", enabled: true)
        let failing = SwiftDataNewsRepository(container: container, now: { self.instant },
            beforeSave: { throw Failure.injected })
        _ = try failing.loadOrInitialize(catalog())
        XCTAssertThrowsError(try failing.saveFeed(changed, validation: receipt(changed))) {
            XCTAssertTrue($0 is Failure)
        }
        XCTAssertEqual(try repo.loadOrInitialize(catalog()), disabled)
        XCTAssertThrowsError(try repo.saveFeed(changed)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .validationRequired)
        }
        let replaced = try repo.saveFeed(changed, validation: receipt(changed))
        let updated = try XCTUnwrap(replaced.feeds.first { $0.id == primary.id })
        XCTAssertNil(updated.etag)
        XCTAssertNil(updated.lastModified)
        XCTAssertNil(updated.retryNotBefore)
        XCTAssertNil(updated.lastError)
        XCTAssertNil(updated.lastAttemptAt)
        XCTAssertEqual(replaced.articles.map(\.canonicalURL), [shared])
        XCTAssertEqual(replaced.articles[0].sources.map(\.feedID), [secondary.id])
        XCTAssertThrowsError(try failing.removeFeed(id: updated.id,
            expectedRevision: updated.configurationRevision)) {
            XCTAssertTrue($0 is Failure)
        }
        XCTAssertEqual(try repo.loadOrInitialize(catalog()), replaced)
        let removed = try repo.removeFeed(id: updated.id, expectedRevision: updated.configurationRevision)
        XCTAssertEqual(removed.articles.count, 1)
        let last = try XCTUnwrap(removed.feeds.first)
        let empty = try repo.removeFeed(id: last.id, expectedRevision: last.configurationRevision)
        XCTAssertTrue(empty.articles.isEmpty)
        XCTAssertTrue(empty.feeds.isEmpty)
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataNewsRepository(container: reopened, now: { self.instant })
            .loadOrInitialize(catalog()), empty)
    }

    func testDefaultsOnlyOnceAndZeroSelectionSurvivesReopenAndCatalogUpdate() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let original = try repo.loadOrInitialize(catalog())
        XCTAssertEqual(original.preferences.selectedTopicIDs, ["go"])
        XCTAssertEqual(original.feeds.count, 1)
        let empty = try repo.savePreferences(.init(selectedTopicIDs: []),
                                             expectedRevision: original.preferences.revision)
        XCTAssertTrue(empty.preferences.selectedTopicIDs.isEmpty)
        XCTAssertNotEqual(empty.preferences.revision, original.preferences.revision)
        let context = ModelContext(container)
        let feed = try XCTUnwrap(context.fetch(FetchDescriptor<NewsFeedRecord>()).first)
        feed.name = "Edited"
        feed.isEnabled = false
        try context.save()
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        let next = try SwiftDataNewsRepository(container: reopened, now: { self.instant })
            .loadOrInitialize(catalog(version: 2, name: "Catalog changed"))
        XCTAssertTrue(next.preferences.selectedTopicIDs.isEmpty)
        XCTAssertEqual(next.preferences.revision, empty.preferences.revision)
        XCTAssertEqual(next.preferences.catalogVersion, 1)
        XCTAssertEqual(next.feeds.map(\.name), ["Edited"])
        XCTAssertEqual(next.feeds.map(\.isEnabled), [false])
        context.delete(feed)
        try context.save()
        let removed = try repo.loadOrInitialize(catalog(version: 3))
        XCTAssertTrue(removed.feeds.isEmpty)
        XCTAssertTrue(try repo.loadOrInitialize(catalog()).feeds.isEmpty)
    }

    func testRevisionChecksAndInvalidSelectionDoNotChangeFeeds() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container)
        let first = try repo.loadOrInitialize(catalog())
        XCTAssertThrowsError(try repo.savePreferences(.init(selectedTopicIDs: ["unknown"]),
            expectedRevision: first.preferences.revision)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .invalidSelection)
        }
        let saved = try repo.savePreferences(.init(selectedTopicIDs: ["ai"]),
            expectedRevision: first.preferences.revision)
        XCTAssertEqual(saved.feeds, first.feeds)
        XCTAssertThrowsError(try repo.savePreferences(.init(selectedTopicIDs: []),
            expectedRevision: first.preferences.revision)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .staleRevision)
        }
        XCTAssertEqual(try repo.loadOrInitialize(catalog()), saved)
    }

    func testFailedInitialAndPreferenceSavesNeverPublishOrPersist() throws {
        enum Failure: Error { case injected }
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = SwiftDataNewsRepository(container: container, beforeSave: { throw Failure.injected })
        XCTAssertThrowsError(try failing.loadOrInitialize(catalog())) {
            XCTAssertTrue($0 is Failure)
        }
        let working = SwiftDataNewsRepository(container: container)
        let initial = try working.loadOrInitialize(catalog())
        XCTAssertEqual(initial.feeds.count, 1)
        _ = try failing.loadOrInitialize(catalog())
        XCTAssertThrowsError(try failing.savePreferences(.init(selectedTopicIDs: []),
            expectedRevision: initial.preferences.revision)) {
            XCTAssertTrue($0 is Failure)
        }
        XCTAssertEqual(try working.loadOrInitialize(catalog()), initial)
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataNewsRepository(container: reopened).loadOrInitialize(catalog()), initial)
    }

    func testCorruptPayloadAndReadFailureNeverInitializeEmptyState() throws {
        enum Failure: Error { case injected }
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let brokenRead = SwiftDataNewsRepository(container: container,
                                                  beforeRead: { throw Failure.injected })
        XCTAssertThrowsError(try brokenRead.loadOrInitialize(catalog())) {
            XCTAssertTrue($0 is Failure)
        }
        let repo = SwiftDataNewsRepository(container: container)
        let original = try repo.loadOrInitialize(catalog())
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<NewsPreferencesRecord>()).first)
        row.selectedTopicIDsPayload = Data("bad payload".utf8)
        try context.save()
        XCTAssertThrowsError(try repo.loadOrInitialize(catalog()))
        XCTAssertThrowsError(try repo.savePreferences(.init(selectedTopicIDs: []),
            expectedRevision: original.preferences.revision))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsFeedRecord>()).count, 1)
    }

    func testPersistedArticleIsDetachedAndUnsafeOrCorruptDataIsNotAnEmptyFeed() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let first = try repo.loadOrInitialize(catalog())
        let context = ModelContext(container)
        let row = NewsArticleRecord(url: "https://news.example.com/one",
            canonicalURL: "https://news.example.com/one", title: "Safe",
            firstFetchedAt: instant.addingTimeInterval(-86_400),
            provenancePayload: try NewsRecordPayload.encodeContributions([
                .init(feedID: first.feeds[0].id, feedName: "Original", topicIDs: ["go"], guids: ["g1"])
            ]))
        context.insert(row)
        try context.save()
        let cached = try repo.loadOrInitialize(catalog())
        XCTAssertEqual(cached.articles.map(\.title), ["Safe"])
        XCTAssertEqual(cached.articleStates[0].aliases[first.feeds[0].id], ["g1"])
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataNewsRepository(container: reopened, now: { self.instant })
            .loadOrInitialize(catalog()).articles, cached.articles)
        row.url = "http://news.example.com/one"
        try context.save()
        XCTAssertThrowsError(try repo.loadOrInitialize(catalog()))
        XCTAssertThrowsError(try repo.savePreferences(.init(selectedTopicIDs: []),
            expectedRevision: first.preferences.revision))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count, 1)
    }

    func testLoadTrimsValidOverLimitCacheAndSaveFailurePreservesRows() throws {
        enum Failure: Error { case injected }
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let initial = try repo.loadOrInitialize(catalog())
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for i in 0...NewsSelection.maximumArticles {
            let link = "https://news.example.com/\(i)"
            context.insert(NewsArticleRecord(url: link, canonicalURL: link, title: "Article \(i)",
                firstFetchedAt: instant.addingTimeInterval(TimeInterval(i - 501) * 60),
                provenancePayload: try NewsRecordPayload.encodeContributions([
                    .init(feedID: initial.feeds[0].id, feedName: "Original",
                          topicIDs: ["go"], guids: ["id-\(i)"])
                ])))
        }
        try context.save()
        let failing = SwiftDataNewsRepository(container: container, now: { self.instant },
                                              beforeSave: { throw Failure.injected })
        XCTAssertThrowsError(try failing.loadOrInitialize(catalog())) {
            XCTAssertTrue($0 is Failure)
        }
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count, 501)
        let trimmed = try repo.loadOrInitialize(catalog())
        XCTAssertEqual(trimmed.articleStates.count, NewsSelection.maximumArticles)
        XCTAssertFalse(trimmed.articles.contains { $0.url.absoluteString == "https://news.example.com/0" })
        XCTAssertTrue(trimmed.articleStates.allSatisfy { $0.aliases[initial.feeds[0].id]?.count == 1 })
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count, 500)
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        let again = try SwiftDataNewsRepository(container: reopened, now: { self.instant })
            .loadOrInitialize(catalog())
        XCTAssertEqual(again, trimmed)
    }

    func testSharedArticleRestoresEachSourcesLinkAndTitleAfterReopen() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let initial = try repo.loadOrInitialize(catalog())
        let primary = initial.feeds[0]
        let secondaryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let context = ModelContext(container)
        context.insert(NewsFeedRecord(id: secondaryID, name: "Secondary",
            endpoint: "https://other.example.com/feed",
            topicIDsPayload: try NewsRecordPayload.encodeTopics(["ai"])))
        let primaryLink = "https://news.example.com/story?utm_source=primary"
        let secondaryLink = "https://news.example.com/story#secondary"
        context.insert(NewsArticleRecord(url: primaryLink,
            canonicalURL: "https://news.example.com/story", title: "Primary title",
            publishedAt: instant.addingTimeInterval(-60), firstFetchedAt: instant.addingTimeInterval(-120),
            summary: "Primary summary",
            provenancePayload: try NewsRecordPayload.encodeContributions([
                .init(feedID: primary.id, feedName: primary.name, topicIDs: ["go"], guids: ["p"],
                      metadata: .init(url: primaryLink, canonicalURL: "https://news.example.com/story",
                                      title: "Primary title", publishedAt: instant.addingTimeInterval(-60),
                                      summary: "Primary summary")),
                .init(feedID: secondaryID, feedName: "Secondary", topicIDs: ["ai"], guids: ["s"],
                      metadata: .init(url: secondaryLink, canonicalURL: "https://news.example.com/story",
                                      title: "Secondary title", publishedAt: nil,
                                      summary: "Secondary summary"))
            ])))
        try context.save()
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<NewsArticleRecord>()).first)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: stored.provenancePayload) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 2)
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        let snapshot = try SwiftDataNewsRepository(container: reopened, now: { self.instant })
            .loadOrInitialize(catalog())
        XCTAssertEqual(snapshot.articles.count, 1)
        XCTAssertEqual(snapshot.articleStates[0].contributions[secondaryID]?.title, "Secondary title")
        XCTAssertEqual(snapshot.articleStates[0].contributions[secondaryID]?.url.absoluteString, secondaryLink)
        XCTAssertEqual(snapshot.articleStates[0].aliases[secondaryID], ["s"])
        let remaining = NewsSelection.reconcile(snapshot.articleStates, outcomes: [],
            feeds: snapshot.feeds.filter { $0.id == secondaryID }, at: instant)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].article.title, "Secondary title")
        XCTAssertEqual(remaining[0].article.url.absoluteString, secondaryLink)
        XCTAssertNil(remaining[0].article.publishedAt)
        XCTAssertEqual(remaining[0].article.summary, "Secondary summary")
        XCTAssertEqual(remaining[0].article.sources.map(\.feedID), [secondaryID])
        XCTAssertEqual(remaining[0].aliases, [secondaryID: ["s"]])
        // A corrupt or unsafe secondary link is a read failure, not an empty cache
        // or a silently substituted primary link.
        stored.provenancePayload = try NewsRecordPayload.encodeContributions([
            .init(feedID: primary.id, feedName: primary.name, topicIDs: ["go"], guids: ["p"],
                  metadata: .init(url: primaryLink, canonicalURL: "https://news.example.com/story",
                                  title: "Primary title", publishedAt: nil, summary: nil)),
            .init(feedID: secondaryID, feedName: "Secondary", topicIDs: ["ai"], guids: ["s"],
                  metadata: .init(url: "http://news.example.com/story", canonicalURL: "https://news.example.com/story",
                                  title: "Secondary title", publishedAt: nil, summary: nil))
        ])
        try context.save()
        XCTAssertThrowsError(try repo.loadOrInitialize(catalog())) {
            XCTAssertEqual($0 as? NewsRepositoryError, .invalidStoredData)
        }
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count, 1)
    }

    func testLoadTrimsExpiredArticlesAndFailureLeavesThemUntouched() throws {
        enum Failure: Error { case injected }
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let original = try repo.loadOrInitialize(catalog())
        let context = ModelContext(container)
        let old = NewsArticleRecord(url: "https://news.example.com/old",
            canonicalURL: "https://news.example.com/old", title: "Old",
            firstFetchedAt: instant.addingTimeInterval(-31 * 86_400),
            provenancePayload: try NewsRecordPayload.encodeContributions([
                .init(feedID: original.feeds[0].id, feedName: "Original", topicIDs: ["go"], guids: ["old"])
            ]))
        context.insert(old)
        try context.save()
        let failing = SwiftDataNewsRepository(container: container, now: { self.instant },
                                              beforeSave: { throw Failure.injected })
        XCTAssertThrowsError(try failing.loadOrInitialize(catalog())) {
            XCTAssertTrue($0 is Failure)
        }
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count, 1)
        XCTAssertTrue(try repo.loadOrInitialize(catalog()).articles.isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).isEmpty)
    }
}
