import Foundation
import XCTest
@testable import Kontrol

@MainActor
private final class StubNewsRepository: NewsRepository {
    enum Failure: Error { case injected }
    var value: NewsSnapshot
    var loads = 0
    var failRead = false
    var failSave = false
    var applied: [[FeedRefreshOutcome]] = []

    init(_ value: NewsSnapshot) { self.value = value }
    func loadOrInitialize(_ catalog: DefaultFeedCatalog) throws -> NewsSnapshot {
        loads += 1
        if failRead { throw Failure.injected }
        return value
    }
    func savePreferences(_ edit: NewsPreferencesEdit, expectedRevision: UUID) throws -> NewsSnapshot {
        if failSave { throw Failure.injected }
        guard value.preferences.revision == expectedRevision else { throw NewsRepositoryError.staleRevision }
        value = NewsSnapshot(topics: value.topics, feeds: value.feeds, articleStates: value.articleStates,
            preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: edit.selectedTopicIDs,
                revision: UUID(), lastRefreshAt: value.preferences.lastRefreshAt))
        return value
    }
    func saveFeed(_ draft: FeedDraft, validation: ValidatedFeed?) throws -> NewsSnapshot { value }
    func removeFeed(id: UUID, expectedRevision: UUID) throws -> NewsSnapshot {
        if failSave { throw Failure.injected }
        guard value.feeds.contains(where: { $0.id == id && $0.configurationRevision == expectedRevision }) else {
            throw NewsRepositoryError.staleRevision
        }
        value = NewsSnapshot(topics: value.topics, feeds: value.feeds.filter { $0.id != id },
            articleStates: value.articleStates, preferences: value.preferences)
        return value
    }
    func applyRefresh(_ outcomes: [FeedRefreshOutcome], at date: Date) throws -> NewsSnapshot {
        if failSave { throw Failure.injected }
        applied.append(outcomes)
        let current = value.feeds.map { feed -> FeedSourceSnapshot in
            guard let outcome = outcomes.first(where: { $0.feedID == feed.id &&
                $0.configurationRevision == feed.configurationRevision }), feed.isEnabled else { return feed }
            let success: Bool
            let error: NewsErrorCode?
            let retry: Date?
            switch outcome.result {
            case .modified, .notModified: success = true; error = nil; retry = nil
            case .failed(let code, let deadline): success = false; error = code; retry = deadline
            case .canceled, .deferred: return feed
            }
            return FeedSourceSnapshot(id: feed.id, name: feed.name, url: feed.url, topicIDs: feed.topicIDs,
                isEnabled: feed.isEnabled, configurationRevision: feed.configurationRevision,
                etag: feed.etag, lastModified: feed.lastModified,
                lastAttemptAt: outcome.attemptedAt ?? feed.lastAttemptAt,
                lastSuccessAt: success ? date : feed.lastSuccessAt,
                lastError: error, retryNotBefore: retry)
        }
        let success = current.contains { feed in
            outcomes.contains { outcome in
                guard outcome.feedID == feed.id && outcome.configurationRevision == feed.configurationRevision else { return false }
                switch outcome.result { case .modified, .notModified: return true; default: return false }
            }
        }
        value = NewsSnapshot(topics: value.topics, feeds: current, articleStates: value.articleStates,
            preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: value.preferences.selectedTopicIDs,
                revision: value.preferences.revision, lastRefreshAt: success ? date : value.preferences.lastRefreshAt))
        return value
    }
}

private actor HeldNewsService: NewsRefreshing {
    private(set) var requests: [FeedSourceSnapshot] = []
    private var pending: [UUID: CheckedContinuation<[FeedRefreshOutcome], Never>] = [:]
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] {
        precondition(feeds.count == 1)
        let feed = feeds[0]
        requests.append(feed)
        return await withCheckedContinuation { pending[feed.id] = $0 }
    }
    func finish(_ outcomes: [FeedRefreshOutcome]) {
        for outcome in outcomes {
            pending.removeValue(forKey: outcome.feedID)?.resume(returning: [outcome])
        }
    }
    func count() -> Int { requests.count }
    func lastIDs(_ count: Int) -> Set<UUID> { Set(requests.suffix(count).map(\.id)) }
}

/// Unlike HeldNewsService, this seam actually terminates obsolete requests on cancellation.
private actor CancelingNewsService: NewsRefreshing {
    private var pending: [UUID: CheckedContinuation<[FeedRefreshOutcome], Never>] = [:]
    private(set) var requested = Set<UUID>()
    private(set) var canceled = Set<UUID>()

    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] {
        precondition(feeds.count == 1)
        let feed = feeds[0]
        requested.insert(feed.id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    canceled.insert(feed.id)
                    continuation.resume(returning: [Self.canceledOutcome(feed)])
                } else {
                    pending[feed.id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(feed) }
        }
    }

    private static func canceledOutcome(_ feed: FeedSourceSnapshot) -> FeedRefreshOutcome {
        FeedRefreshOutcome(feedID: feed.id, configurationRevision: feed.configurationRevision,
                           attemptedAt: nil, result: .canceled)
    }

    private func cancel(_ feed: FeedSourceSnapshot) {
        if let continuation = pending.removeValue(forKey: feed.id) {
            canceled.insert(feed.id)
            continuation.resume(returning: [Self.canceledOutcome(feed)])
        }
    }

    func finish(_ outcome: FeedRefreshOutcome) {
        pending.removeValue(forKey: outcome.feedID)?.resume(returning: [outcome])
    }
    func requestedIDs() -> Set<UUID> { requested }
    func canceledIDs() -> Set<UUID> { canceled }
}

@MainActor
final class NewsStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private func fixture(_ attempts: [Date?] = [nil, nil], retry: Date? = nil) -> (DefaultFeedCatalog, NewsSnapshot) {
        let topics = [NewsTopic(id: "go", name: "Go"), NewsTopic(id: "ai", name: "AI")]
        let feeds = [firstID, secondID].enumerated().map { index, id in
            FeedSourceSnapshot(id: id, name: "Feed \(index)", url: URL(string: "https://feeds.example.com/\(index)")!,
                topicIDs: [index == 0 ? "go" : "ai"], isEnabled: true, configurationRevision: UUID(),
                etag: nil, lastModified: nil, lastAttemptAt: attempts[index], lastSuccessAt: nil,
                lastError: nil, retryNotBefore: index == 0 ? retry : nil)
        }
        let catalog = DefaultFeedCatalog(version: 1, topics: topics,
            initialSelectedTopicIDs: ["go", "ai"], feeds: feeds.map {
                .init(id: $0.id, name: $0.name, url: $0.url, topicIDs: $0.topicIDs)
            })
        let article = ArticleMetadata(id: UUID(), url: URL(string: "https://news.example.com/story")!,
            canonicalURL: "https://news.example.com/story", title: "Cached", publishedAt: now,
            firstFetchedAt: now, summary: nil, sources: [])
        let state = NewsSelection.State(article: article, aliases: [:], contributions: [:])
        let snapshot = NewsSnapshot(topics: topics, feeds: feeds, articleStates: [state],
            preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: ["go", "ai"],
                revision: UUID(), lastRefreshAt: nil))
        return (catalog, snapshot)
    }

    private func waitFor(_ service: HeldNewsService, count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if await service.count() == count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) requests", file: file, line: line)
    }

    private func assertCount(_ service: HeldNewsService, _ expected: Int,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let count = await service.count()
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    private func assertIDs(_ service: HeldNewsService, _ expected: Set<UUID>,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let ids = await service.lastIDs(expected.count)
        XCTAssertEqual(ids, expected, file: file, line: line)
    }

    private func outcomes(_ feeds: [FeedSourceSnapshot], _ date: Date) -> [FeedRefreshOutcome] {
        feeds.map { FeedRefreshOutcome(feedID: $0.id, configurationRevision: $0.configurationRevision,
            attemptedAt: date, result: .notModified) }
    }

    func testCacheFirstCoalescesWindowsAndForegroundIsNotKeyWindow() async {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = HeldNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog, clock: { self.now })
        XCTAssertNil(store.snapshot)
        await assertCount(service, 0)
        store.loadIfNeeded()
        XCTAssertEqual(store.snapshot?.articles.first?.title, "Cached")
        await assertCount(service, 0)
        let windowA = UUID(), windowB = UUID()
        store.setVisible(true, windowID: windowA)
        store.setVisible(true, windowID: windowB)
        store.setAppActive(true)
        await waitFor(service, count: 2)
        XCTAssertTrue(store.isRefreshing)
        await assertIDs(service, [firstID, secondID])
        let manual = Task { await store.refresh(.manual) }
        await Task.yield()
        await assertCount(service, 2)
        await service.finish(outcomes(cached.feeds, now))
        await manual.value
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.snapshot?.preferences.lastRefreshAt, now)
        XCTAssertEqual(repo.applied.count, 1)
    }

    func testEligibilityManualOverrideRetryDeadlineAndNextScheduledCheck() async {
        var instant = now
        let (catalog, cached) = fixture([now.addingTimeInterval(-120), now.addingTimeInterval(-1900)],
                                         retry: now.addingTimeInterval(3600))
        let repo = StubNewsRepository(cached)
        let service = HeldNewsService()
        var wake: CheckedContinuation<Void, Error>?
        var intervals: [TimeInterval] = []
        let store = NewsStore(repository: repo, service: service, catalog: catalog,
            clock: { instant }, sleep: { interval in
                intervals.append(interval)
                try await withCheckedThrowingContinuation { wake = $0 }
            })
        store.setVisible(true, windowID: UUID())
        store.setAppActive(true)
        await waitFor(service, count: 1)
        await assertIDs(service, [secondID])
        await service.finish(outcomes([cached.feeds[1]], instant))
        for _ in 0..<10_000 where store.isRefreshing { await Task.yield() }
        XCTAssertFalse(store.isRefreshing)
        for _ in 0..<10_000 where intervals.isEmpty { await Task.yield() }
        XCTAssertFalse(intervals.isEmpty)
        let manual = Task { await store.refresh(.manual) }
        await waitFor(service, count: 2)
        await assertIDs(service, [secondID]) // retry deadline still gates first
        instant = now.addingTimeInterval(3700)
        await service.finish(outcomes([cached.feeds[1]], instant))
        await manual.value
        // Scheduled checks stop when app deactivates even though this window remains visible.
        store.setAppActive(false)
        let oldCount = await service.count()
        wake?.resume()
        await Task.yield()
        await assertCount(service, oldCount)
    }

    func testPartialFailureSaveAndReadFailuresDoNotFabricateCache() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = HeldNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog, clock: { self.now })
        store.loadIfNeeded()
        let pending = Task { await store.refresh(.manual) }
        await waitFor(service, count: 2)
        let results = [outcomes([cached.feeds[0]], now)[0],
            FeedRefreshOutcome(feedID: secondID, configurationRevision: cached.feeds[1].configurationRevision,
                attemptedAt: now, result: .failed(.rateLimited, retryNotBefore: now.addingTimeInterval(120)))]
        await service.finish(results)
        await pending.value
        XCTAssertTrue(store.isPartialRefresh)
        XCTAssertEqual(store.refreshFailures[secondID], .rateLimited)
        XCTAssertEqual(store.snapshot?.preferences.lastRefreshAt, now)
        repo.failSave = true
        let old = store.snapshot
        let next = Task { await store.refresh(.manual) }
        await waitFor(service, count: 3)
        await assertIDs(service, [firstID]) // manual retry cannot bypass the second feed's deadline
        await service.finish(outcomes([cached.feeds[0]], now))
        await next.value
        XCTAssertEqual(store.localFailure, .save)
        XCTAssertEqual(store.snapshot, old)
        repo.failSave = false
        repo.failRead = true
        store.reload()
        XCTAssertEqual(store.localFailure, .read)
        XCTAssertEqual(store.snapshot, old)
        let fresh = NewsStore(repository: repo, service: service, catalog: catalog)
        fresh.loadIfNeeded()
        XCTAssertNil(fresh.snapshot)
        XCTAssertEqual(fresh.localFailure, .read)
        await fresh.refresh(.manual)
        await assertCount(service, 3)
    }

    func testScheduledCheckRunsWhenForegroundAndBecomesEligible() async {
        var instant = now
        let (catalog, cached) = fixture([now, now])
        let repo = StubNewsRepository(cached)
        let service = HeldNewsService()
        var wake: CheckedContinuation<Void, Error>?
        var delay: TimeInterval?
        let store = NewsStore(repository: repo, service: service, catalog: catalog,
            clock: { instant }, sleep: { seconds in
                delay = seconds
                try await withCheckedThrowingContinuation { wake = $0 }
            })
        store.setVisible(true, windowID: UUID())
        store.setAppActive(true)
        for _ in 0..<10_000 where wake == nil { await Task.yield() }
        XCTAssertEqual(delay, 1800)
        await assertCount(service, 0)
        instant = now.addingTimeInterval(1800)
        wake?.resume()
        await waitFor(service, count: 2)
        await assertIDs(service, [firstID, secondID])
        await service.finish(outcomes(cached.feeds, instant))
        for _ in 0..<10_000 where store.isRefreshing { await Task.yield() }
        XCTAssertEqual(store.snapshot?.preferences.lastRefreshAt, instant)
    }

    func testForegroundRespectsPerFeedThirtyMinutesAndHiddenWindowsDoNotRefresh() async {
        let (catalog, cached) = fixture([now.addingTimeInterval(-1799), now.addingTimeInterval(-1800)])
        let repo = StubNewsRepository(cached)
        let service = HeldNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog, clock: { self.now })
        let window = UUID()
        store.setVisible(true, windowID: window)
        store.setAppActive(true)
        await waitFor(service, count: 1)
        await assertIDs(service, [secondID])
        store.setVisible(false, windowID: window)
        await service.finish(outcomes([cached.feeds[1]], now))
        for _ in 0..<10_000 where store.isRefreshing { await Task.yield() }
        await assertCount(service, 1)
        XCTAssertFalse(store.isVisibleAndActive)
        XCTAssertNil(store.localFailure)
    }

    func testReloadCancelsChangedEndpointAndDisabledFeedWithoutLosingOtherSuccess() async {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = HeldNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog, clock: { self.now })
        let pending = Task { await store.refresh(.manual) }
        await waitFor(service, count: 2)
        let changed = cached.feeds.map { feed -> FeedSourceSnapshot in
            FeedSourceSnapshot(id: feed.id, name: feed.name,
                url: feed.id == firstID ? URL(string: "https://new.example.com/rss")! : feed.url,
                topicIDs: feed.topicIDs, isEnabled: feed.id != firstID,
                configurationRevision: feed.id == firstID ? UUID() : feed.configurationRevision,
                etag: nil, lastModified: nil, lastAttemptAt: feed.lastAttemptAt,
                lastSuccessAt: feed.lastSuccessAt, lastError: nil, retryNotBefore: nil)
        }
        repo.value = NewsSnapshot(topics: cached.topics, feeds: changed,
            articleStates: cached.articleStates, preferences: cached.preferences)
        store.reload()
        await service.finish(outcomes(cached.feeds, now))
        await pending.value
        XCTAssertEqual(store.snapshot?.feeds.first, changed.first)
        XCTAssertEqual(store.snapshot?.feeds.last?.lastSuccessAt, now)
        XCTAssertEqual(store.snapshot?.preferences.lastRefreshAt, now)
        XCTAssertNil(store.localFailure)
        await assertCount(service, 2)
    }

    func testCancellationAwareMixedRefreshPreservesUnchangedSuccess() async throws {
        for change in ["remove", "disable", "endpoint"] {
            for completedBeforeEdit in [false, true] {
                let (catalog, cached) = fixture()
                let repo = StubNewsRepository(cached)
                let service = CancelingNewsService()
                let store = NewsStore(repository: repo, service: service, catalog: catalog,
                                      clock: { self.now })
                let refresh = Task { await store.refresh(.manual) }
                for _ in 0..<10_000 {
                    if await service.requestedIDs() == Set([firstID, secondID]) { break }
                    await Task.yield()
                }
                let requested = await service.requestedIDs()
                XCTAssertEqual(requested, Set([firstID, secondID]))
                let healthy = outcomes([cached.feeds[1]], now)[0]
                if completedBeforeEdit { await service.finish(healthy) }
                if change == "remove" {
                    try store.removeFeed(id: firstID)
                } else {
                    let updated = cached.feeds.map { feed -> FeedSourceSnapshot in
                        FeedSourceSnapshot(id: feed.id, name: feed.name,
                            url: feed.id == firstID && change == "endpoint"
                                ? URL(string: "https://new.example.com/rss")! : feed.url,
                            topicIDs: feed.topicIDs,
                            isEnabled: feed.id != firstID || change != "disable",
                            configurationRevision: feed.id == firstID ? UUID() : feed.configurationRevision,
                            etag: nil, lastModified: nil, lastAttemptAt: nil,
                            lastSuccessAt: nil, lastError: nil, retryNotBefore: nil)
                    }
                    repo.value = NewsSnapshot(topics: cached.topics, feeds: updated,
                        articleStates: cached.articleStates, preferences: cached.preferences)
                    store.reload()
                }
                if !completedBeforeEdit { await service.finish(healthy) }
                await refresh.value
                let canceled = await service.canceledIDs()
                XCTAssertEqual(canceled, Set([firstID]), change)
                XCTAssertEqual(store.snapshot?.feeds.first(where: { $0.id == secondID })?.lastSuccessAt, now)
                XCTAssertEqual(store.snapshot?.preferences.lastRefreshAt, now)
                XCTAssertNil(store.localFailure)
                XCTAssertTrue(store.refreshFailures.isEmpty)
                XCTAssertEqual(repo.applied.count, 1)
                XCTAssertEqual(repo.applied[0].first(where: { $0.feedID == firstID })?.result, .canceled)
                XCTAssertEqual(repo.applied[0].first(where: { $0.feedID == secondID })?.result, .notModified)
            }
        }
    }

    func testRemovalCancelsObsoleteWorkAndKeepsCommittedOtherFeed() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = HeldNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog, clock: { self.now })
        let pending = Task { await store.refresh(.manual) }
        await waitFor(service, count: 2)
        try store.removeFeed(id: firstID)
        XCTAssertEqual(store.snapshot?.feeds.count, 1)
        await service.finish(outcomes(cached.feeds, now)) // transport ignored cancellation
        await pending.value
        XCTAssertEqual(store.snapshot?.feeds.map(\.id), [secondID])
        XCTAssertEqual(store.snapshot?.preferences.lastRefreshAt, now)
        XCTAssertNil(store.refreshFailures[firstID])
        await assertCount(service, 2)
    }
}
