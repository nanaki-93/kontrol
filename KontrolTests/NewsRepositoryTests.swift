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

    func testRefreshBatchIsAtomicAndPreservesCacheOnFailure304AndEmptySuccess() throws {
        enum Failure: Error { case injected }
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let initial = try repo.loadOrInitialize(catalog())
        let first = initial.feeds[0]
        let newDraft = draft(enabled: true)
        let second = try XCTUnwrap(repo.saveFeed(newDraft, validation: receipt(newDraft))
            .feeds.first { $0.name == "Custom" })
        let attempt = instant.addingTimeInterval(60)
        let entry = NewsFeedEntry(title: "Shared", url: URL(string: "https://news.example.com/story")!,
            guid: "guid", publishedAt: nil, summary: "Plain")
        func outcome(_ feed: FeedSourceSnapshot, _ result: FeedRefreshResult, at: Date? = attempt) -> FeedRefreshOutcome {
            FeedRefreshOutcome(feedID: feed.id, configurationRevision: feed.configurationRevision,
                attemptedAt: at, result: result)
        }
        let modified = outcome(first, .modified([entry], etag: "etag", lastModified: "modified"))
        let failed = outcome(second, .failed(.rateLimited, retryNotBefore: attempt.addingTimeInterval(120)))
        let failing = SwiftDataNewsRepository(container: container, now: { self.instant },
            beforeSave: { throw Failure.injected })
        _ = try failing.loadOrInitialize(catalog())
        let failedOnly = try repo.applyRefresh([failed], at: attempt)
        XCTAssertNil(failedOnly.preferences.lastRefreshAt)
        XCTAssertEqual(failedOnly.feeds.first { $0.id == second.id }?.lastError, .rateLimited)
        XCTAssertEqual(try repo.applyRefresh([
            outcome(first, .canceled),
            outcome(second, .deferred(retryNotBefore: attempt.addingTimeInterval(120)), at: nil)
        ], at: attempt), failedOnly)
        XCTAssertThrowsError(try failing.applyRefresh([modified, failed], at: attempt)) {
            XCTAssertTrue($0 is Failure)
        }
        XCTAssertEqual(try repo.loadOrInitialize(catalog()), failedOnly)
        let partial = try repo.applyRefresh([modified, failed], at: attempt)
        XCTAssertEqual(partial.articles.map(\.title), ["Shared"])
        XCTAssertEqual(partial.preferences.lastRefreshAt, attempt)
        XCTAssertEqual(partial.feeds.first { $0.id == first.id }?.etag, "etag")
        XCTAssertEqual(partial.feeds.first { $0.id == first.id }?.lastSuccessAt, attempt)
        XCTAssertEqual(partial.feeds.first { $0.id == second.id }?.lastError, .rateLimited)
        XCTAssertEqual(partial.feeds.first { $0.id == second.id }?.retryNotBefore,
                       attempt.addingTimeInterval(120))
        XCTAssertEqual(partial.feeds.first { $0.id == second.id }?.lastAttemptAt, attempt)
        XCTAssertEqual(partial.feeds.first { $0.id == second.id }?.lastSuccessAt, instant) // editor validation
        let failureOnly = try repo.applyRefresh([outcome(first, .failed(.offline, retryNotBefore: nil))],
                                                at: attempt.addingTimeInterval(1))
        XCTAssertEqual(failureOnly.articles, partial.articles)
        XCTAssertEqual(failureOnly.preferences.lastRefreshAt, attempt)
        XCTAssertEqual(failureOnly.feeds.first { $0.id == first.id }?.etag, "etag")
        XCTAssertEqual(failureOnly.feeds.first { $0.id == first.id }?.lastError, .offline)
        let checkedAt = attempt.addingTimeInterval(2)
        let checked = try repo.applyRefresh([outcome(first, .notModified, at: checkedAt)], at: checkedAt)
        XCTAssertEqual(checked.articles, partial.articles)
        XCTAssertEqual(checked.preferences.lastRefreshAt, checkedAt)
        XCTAssertEqual(checked.feeds.first { $0.id == first.id }?.lastSuccessAt, checkedAt)
        XCTAssertEqual(checked.feeds.first { $0.id == first.id }?.etag, "etag")
        XCTAssertNil(checked.feeds.first { $0.id == first.id }?.lastError)
        let emptyAt = checkedAt.addingTimeInterval(1)
        let empty = try repo.applyRefresh([outcome(first, .modified([], etag: nil, lastModified: nil), at: emptyAt)],
                                          at: emptyAt)
        XCTAssertEqual(empty.articles, partial.articles)
        XCTAssertEqual(empty.preferences.lastRefreshAt, emptyAt)
        XCTAssertNil(empty.feeds.first { $0.id == first.id }?.etag)
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataNewsRepository(container: reopened,
            now: { self.instant.addingTimeInterval(120) }).loadOrInitialize(catalog()), empty)
    }

    func testPartialRefreshKeepsFailedSourcesAndReopenPreservesSharedProvenance() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let primary = try repo.loadOrInitialize(catalog()).feeds[0]
        let draft = draft(enabled: true)
        let secondary = try XCTUnwrap(repo.saveFeed(draft, validation: receipt(draft))
            .feeds.first { $0.id != primary.id })
        let shared = URL(string: "https://news.example.com/shared")!
        let old = URL(string: "https://news.example.com/old")!
        func modified(_ feed: FeedSourceSnapshot, _ entries: [NewsFeedEntry], at date: Date) -> FeedRefreshOutcome {
            FeedRefreshOutcome(feedID: feed.id, configurationRevision: feed.configurationRevision,
                attemptedAt: date, result: .modified(entries, etag: nil, lastModified: nil))
        }
        let first = try repo.applyRefresh([
            modified(secondary, [NewsFeedEntry(title: "Secondary", url: shared, guid: "s",
                publishedAt: nil, summary: nil),
                NewsFeedEntry(title: "Cached", url: old, guid: "old", publishedAt: nil, summary: nil)], at: instant)
        ], at: instant)
        let sharedID = try XCTUnwrap(first.articles.first { $0.url == shared }?.id)
        let later = instant.addingTimeInterval(90)
        let partial = try repo.applyRefresh([
            modified(primary, [NewsFeedEntry(title: "Primary", url: shared, guid: "p",
                publishedAt: nil, summary: nil)], at: later),
            FeedRefreshOutcome(feedID: secondary.id, configurationRevision: secondary.configurationRevision,
                attemptedAt: later, result: .failed(.offline, retryNotBefore: nil))
        ], at: later)
        XCTAssertEqual(partial.articles.count, 2)
        let combined = try XCTUnwrap(partial.articleStates.first { $0.article.id == sharedID })
        XCTAssertEqual(Set(combined.article.sources.map(\.feedID)), [primary.id, secondary.id])
        XCTAssertEqual(combined.aliases[primary.id], ["p"])
        XCTAssertEqual(combined.aliases[secondary.id], ["s"])
        XCTAssertEqual(combined.article.firstFetchedAt, instant)
        XCTAssertEqual(partial.feeds.first { $0.id == secondary.id }?.lastError, .offline)
        XCTAssertEqual(partial.preferences.lastRefreshAt, later)
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataNewsRepository(container: reopened, now: { later })
            .loadOrInitialize(catalog()), partial)
    }

    func testLateRefreshFencesRemovedDisabledAndEditedFeedsAndBoundsRepeatedMerges() throws {
        let (container, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SwiftDataNewsRepository(container: container, now: { self.instant })
        let original = try repo.loadOrInitialize(catalog()).feeds[0]
        let otherDraft = draft(enabled: true)
        let added = try repo.saveFeed(otherDraft, validation: receipt(otherDraft))
        let other = try XCTUnwrap(added.feeds.first { $0.id != original.id })
        func result(_ feed: FeedSourceSnapshot, _ link: String) -> FeedRefreshOutcome {
            FeedRefreshOutcome(feedID: feed.id, configurationRevision: feed.configurationRevision,
                attemptedAt: instant, result: .modified([
                    NewsFeedEntry(title: link, url: URL(string: link)!, guid: link,
                                  publishedAt: nil, summary: nil)
                ], etag: "current", lastModified: nil))
        }
        let old = result(original, "https://news.example.com/stale")
        let removed = try repo.removeFeed(id: other.id, expectedRevision: other.configurationRevision)
        let disabled = try repo.saveFeed(draft(original, url: original.url.absoluteString, enabled: false))
        XCTAssertEqual(try repo.applyRefresh([old, result(other, "https://news.example.com/removed")],
                                             at: instant), disabled)
        XCTAssertEqual(removed.feeds.count, 1)
        let disabledFeed = try XCTUnwrap(disabled.feeds.first)
        let enableDraft = draft(disabledFeed, url: disabledFeed.url.absoluteString, enabled: true)
        let enabled = try repo.saveFeed(enableDraft, validation: receipt(enableDraft))
        let current = try XCTUnwrap(enabled.feeds.first)
        let edited = try repo.saveFeed(draft(current, name: "Edited", url: current.url.absoluteString,
                                             enabled: true))
        XCTAssertEqual(try repo.applyRefresh([result(current, "https://news.example.com/stale")],
                                             at: instant), edited)
        let live = try XCTUnwrap(edited.feeds.first)
        let endpointDraft = draft(live, url: "https://new.example.com/rss", enabled: true)
        let moved = try repo.saveFeed(endpointDraft, validation: receipt(endpointDraft))
        XCTAssertEqual(try repo.applyRefresh([result(live, "https://news.example.com/stale")],
                                             at: instant), moved)
        let currentEndpoint = try XCTUnwrap(moved.feeds.first)
        for _ in 0..<3 {
            let entries = (0..<520).map { index in
                NewsFeedEntry(title: "Story \(index)",
                    url: URL(string: "https://news.example.com/\(index)")!, guid: "id-\(index)",
                    publishedAt: nil, summary: nil)
            }
            let expired = NewsFeedEntry(title: "Expired", url: URL(string: "https://news.example.com/expired")!,
                guid: "expired", publishedAt: instant.addingTimeInterval(-31 * 86_400), summary: nil)
            let batch = FeedRefreshOutcome(feedID: currentEndpoint.id,
                configurationRevision: currentEndpoint.configurationRevision,
                attemptedAt: instant,
                result: .modified(entries + [expired], etag: nil, lastModified: nil))
            let snapshot = try repo.applyRefresh([batch], at: instant)
            XCTAssertEqual(snapshot.articles.count, 500)
            XCTAssertFalse(snapshot.articles.contains { $0.title == "Expired" })
            XCTAssertEqual(snapshot.articleStates.count, 500)
            XCTAssertTrue(snapshot.articleStates.allSatisfy { $0.aliases[currentEndpoint.id]?.count == 1 })
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count, 500)
        }
        XCTAssertEqual(try repo.loadOrInitialize(catalog()).articles.count, 500)
    }

    func testGUIDMoveThenURLReissuePersistsDistinctRowsAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Kontrol.store")
        // Each invocation releases its repository/container before the next disk open.
        func open(at date: Date, path: String? = nil, guid: String? = nil) throws -> NewsSnapshot {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(storeURL))
            let repo = SwiftDataNewsRepository(container: container, now: { date })
            let cached = try repo.loadOrInitialize(catalog())
            let snapshot: NewsSnapshot
            if let path {
                let feed = cached.feeds[0]
                snapshot = try repo.applyRefresh([FeedRefreshOutcome(feedID: feed.id,
                    configurationRevision: feed.configurationRevision, attemptedAt: date,
                    result: .modified([NewsFeedEntry(title: path,
                        url: URL(string: "https://news.example.com/\(path)")!, guid: guid,
                        publishedAt: nil, summary: nil)], etag: nil, lastModified: nil))], at: date)
            } else {
                snapshot = cached
            }
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count,
                snapshot.articles.count, "No UUID upsert may overwrite a distinct row")
            return snapshot
        }
        let original = try open(at: instant, path: "old", guid: "g1")
        let originalID = try XCTUnwrap(original.articles.first?.id)
        let moved = try open(at: instant.addingTimeInterval(60), path: "new", guid: "g1")
        XCTAssertEqual(moved.articles.first?.id, originalID)
        let separate = try open(at: instant.addingTimeInterval(120), path: "old", guid: "g2")
        XCTAssertEqual(separate.articles.count, 2)
        XCTAssertEqual(Set(separate.articles.map(\.id)).count, 2)
        let reissued = try XCTUnwrap(separate.articleStates.first { $0.article.url.path == "/old" })
        let existing = try XCTUnwrap(separate.articleStates.first { $0.article.url.path == "/new" })
        XCTAssertEqual(existing.article.id, originalID)
        XCTAssertEqual(existing.article.firstFetchedAt, instant)
        XCTAssertEqual(existing.aliases[separate.feeds[0].id], ["g1"])
        XCTAssertNotEqual(reissued.article.id, originalID)
        XCTAssertEqual(reissued.article.firstFetchedAt, instant.addingTimeInterval(120))
        XCTAssertEqual(reissued.aliases[separate.feeds[0].id], ["g2"])
        XCTAssertEqual(try open(at: instant.addingTimeInterval(180)), separate)
        let repeated = try open(at: instant.addingTimeInterval(240), path: "old", guid: "g2")
        XCTAssertEqual(repeated.articleStates, separate.articleStates)
        XCTAssertEqual(try open(at: instant.addingTimeInterval(300)), repeated)
    }

    func testFuturePublicationExpiresAtFirstFetchBoundaryAcrossReopenAnd304() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Kontrol.store")
        let publication = instant.addingTimeInterval(20 * 86_400)
        func open(at date: Date, result: FeedRefreshResult? = nil) throws -> NewsSnapshot {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(storeURL))
            let repo = SwiftDataNewsRepository(container: container, now: { date })
            let cached = try repo.loadOrInitialize(catalog())
            let snapshot: NewsSnapshot
            if let result {
                let feed = cached.feeds[0]
                snapshot = try repo.applyRefresh([FeedRefreshOutcome(feedID: feed.id,
                    configurationRevision: feed.configurationRevision, attemptedAt: date,
                    result: result)], at: date)
            } else {
                snapshot = cached
            }
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NewsArticleRecord>()).count,
                snapshot.articles.count)
            return snapshot
        }
        let entry = NewsFeedEntry(title: "Future", url: URL(string: "https://news.example.com/future")!,
            guid: "future", publishedAt: publication, summary: nil)
        let initial = try open(at: instant, result: .modified([entry], etag: "saved", lastModified: nil))
        XCTAssertEqual(initial.articles.count, 1)
        XCTAssertEqual(initial.articles[0].publishedAt, publication)
        XCTAssertEqual(initial.articles[0].firstFetchedAt, instant)
        let day21 = try open(at: instant.addingTimeInterval(21 * 86_400), result: .notModified)
        XCTAssertEqual(day21.articleStates, initial.articleStates)
        let boundary = instant.addingTimeInterval(NewsSelection.maximumAge)
        let day30 = try open(at: boundary, result: .modified([entry], etag: "saved", lastModified: nil))
        XCTAssertEqual(day30.articleStates, initial.articleStates, "Refresh must not reset the retention cap")
        let expired = try open(at: boundary.addingTimeInterval(1))
        XCTAssertTrue(expired.articleStates.isEmpty, "Load must trim even though publication is now past")
        XCTAssertEqual(expired.preferences.lastRefreshAt, boundary)
        let day31 = try open(at: instant.addingTimeInterval(31 * 86_400), result: .notModified)
        XCTAssertTrue(day31.articleStates.isEmpty)
        XCTAssertEqual(day31.feeds[0].etag, "saved")
        XCTAssertEqual(try open(at: instant.addingTimeInterval(32 * 86_400)), day31)
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
