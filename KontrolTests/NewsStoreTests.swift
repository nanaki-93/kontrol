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
    var savedDrafts: [FeedDraft] = []
    var savedReceipts: [ValidatedFeed?] = []

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
    func saveFeed(_ draft: FeedDraft, validation: ValidatedFeed?) throws -> NewsSnapshot {
        if failSave { throw Failure.injected }
        let old = value.feeds.first { $0.id == draft.id }
        if draft.id != nil && (old == nil || old?.configurationRevision != draft.expectedRevision) {
            throw NewsRepositoryError.staleRevision
        }
        let endpoint = try NewsURLPolicy.feedURL(draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        let changedEndpoint = old?.url != endpoint
        let needsValidation = draft.isEnabled && (old == nil || changedEndpoint ||
            (old?.isEnabled == false && old?.lastSuccessAt == nil))
        if needsValidation && (validation?.draftRevision != draft.draftRevision || validation?.url != endpoint) {
            throw NewsRepositoryError.validationRequired
        }
        savedDrafts.append(draft)
        savedReceipts.append(validation)
        let feed = FeedSourceSnapshot(id: old?.id ?? UUID(), name: draft.name, url: endpoint,
            topicIDs: draft.topicIDs, isEnabled: draft.isEnabled, configurationRevision: UUID(),
            etag: changedEndpoint ? nil : old?.etag, lastModified: changedEndpoint ? nil : old?.lastModified,
            lastAttemptAt: changedEndpoint ? nil : old?.lastAttemptAt,
            lastSuccessAt: needsValidation ? validation?.validatedAt : (changedEndpoint ? nil : old?.lastSuccessAt),
            lastError: nil, retryNotBefore: nil)
        value = NewsSnapshot(topics: value.topics, feeds: value.feeds.filter { $0.id != old?.id } + [feed],
            articleStates: value.articleStates, preferences: value.preferences)
        return value
    }
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
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        throw FeedServiceError(code: .offline, retryNotBefore: nil)
    }
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
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        throw FeedServiceError(code: .offline, retryNotBefore: nil)
    }
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

private actor EditorNewsService: NewsRefreshing {
    private(set) var requests: [FeedDraft] = []
    private var pending: [UUID: CheckedContinuation<ValidatedFeed, Error>] = [:]
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] { [] }
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        requests.append(draft)
        return try await withCheckedThrowingContinuation { pending[draft.draftRevision] = $0 }
    }
    func count() -> Int { requests.count }
    func succeed(_ revision: UUID, at date: Date) {
        guard let draft = requests.first(where: { $0.draftRevision == revision }),
              let continuation = pending.removeValue(forKey: revision) else { return }
        continuation.resume(returning: ValidatedFeed(draftRevision: revision,
            url: URL(string: draft.urlText)!, validatedAt: date, etag: nil, lastModified: nil))
    }
    func fail(_ revision: UUID) {
        pending.removeValue(forKey: revision)?.resume(throwing:
            FeedServiceError(code: .malformedFeed, retryNotBefore: nil))
    }
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

    private func waitFor(_ service: EditorNewsService, count: Int,
                         file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if await service.count() == count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) validations", file: file, line: line)
    }

    private func draft(_ feed: FeedSourceSnapshot?, url: String = "https://new.example.com/rss",
                       enabled: Bool = true) -> FeedDraft {
        FeedDraft(id: feed?.id, name: " Edited ", urlText: url, topicIDs: ["go"],
                  isEnabled: enabled, expectedRevision: feed?.configurationRevision, draftRevision: UUID())
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

    func testEditorSkipsNetworkForDisabledDraftAndNameTopicOnlyEdit() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        let disabled = draft(nil, enabled: false)
        try await store.saveFeed(disabled, editorID: UUID())
        XCTAssertEqual(repo.savedReceipts.count, 1)
        XCTAssertNil(repo.savedReceipts[0])
        let unchanged = draft(cached.feeds[0], url: cached.feeds[0].url.absoluteString)
        try await store.saveFeed(unchanged)
        let validations = await service.count()
        XCTAssertEqual(validations, 0)
        XCTAssertEqual(repo.savedDrafts, [disabled, unchanged])
    }

    func testEditorValidatesEnabledEmptyFeedAndUnvalidatedEnable() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        let new = draft(nil)
        let saving = Task { try await store.saveFeed(new, editorID: UUID()) }
        await waitFor(service, count: 1)
        XCTAssertEqual(repo.savedDrafts.count, 0)
        await service.succeed(new.draftRevision, at: now) // empty recognized XML is valid to the service
        try await saving.value
        XCTAssertEqual(repo.savedReceipts[0]?.draftRevision, new.draftRevision)
        let disabled = draft(cached.feeds[0], url: cached.feeds[0].url.absoluteString, enabled: false)
        try await store.saveFeed(disabled)
        let enabling = draft(store.snapshot!.feeds.first { $0.id == firstID }!,
            url: cached.feeds[0].url.absoluteString)
        let second = Task { try await store.saveFeed(enabling) }
        await waitFor(service, count: 2)
        await service.succeed(enabling.draftRevision, at: now)
        try await second.value
        XCTAssertEqual(repo.savedReceipts.last.flatMap { $0 }?.draftRevision, enabling.draftRevision)
    }

    func testEndpointChangesValidateButDisabledChangesAndInvalidDraftsDoNotRequest() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        store.loadIfNeeded()
        let invalid = FeedDraft(id: firstID, name: "  ", urlText: "http://unsafe.example/rss",
            topicIDs: ["go"], isEnabled: true,
            expectedRevision: cached.feeds[0].configurationRevision, draftRevision: UUID())
        do { try await store.saveFeed(invalid); XCTFail("Invalid draft saved") }
        catch { XCTAssertEqual(error as? NewsRepositoryError, .invalidFeed) }
        let disabled = draft(cached.feeds[0], enabled: false)
        try await store.saveFeed(disabled)
        let count = await service.count()
        XCTAssertEqual(count, 0)
        let beforeEnable = store.snapshot
        let changed = draft(store.snapshot!.feeds.first { $0.id == firstID }!)
        let task = Task { try await store.saveFeed(changed) }
        await waitFor(service, count: 1)
        XCTAssertEqual(store.snapshot, beforeEnable)
        await service.succeed(changed.draftRevision, at: now)
        try await task.value
        XCTAssertEqual(repo.savedReceipts.last.flatMap { $0 }?.draftRevision, changed.draftRevision)
        XCTAssertEqual(store.snapshot?.feeds.first { $0.id == firstID }?.url.absoluteString,
                       changed.urlText)
        let endpoint = draft(store.snapshot!.feeds.first { $0.id == firstID }!,
                             url: "https://new.example.com/changed")
        let endpointSave = Task { try await store.saveFeed(endpoint) }
        await waitFor(service, count: 2)
        await service.succeed(endpoint.draftRevision, at: now)
        try await endpointSave.value
        XCTAssertEqual(repo.savedReceipts.last.flatMap { $0 }?.draftRevision, endpoint.draftRevision)
    }

    func testNewFeedEditorSessionCancelAndNewRevisionFence() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        let session = UUID()
        let first = draft(nil)
        // The default path cannot use the changing draft revision as a session key.
        for unkeyed in [first, draft(nil, enabled: false)] {
            do { try await store.saveFeed(unkeyed); XCTFail("Unkeyed new feed saved") }
            catch { XCTAssertEqual(error as? NewsEditorError, .sessionRequired) }
        }
        XCTAssertEqual(repo.savedDrafts.count, 0)
        let validationCount = await service.count()
        XCTAssertEqual(validationCount, 0)
        let prior = Task { try await store.saveFeed(first, editorID: session) }
        await waitFor(service, count: 1)
        let newer = draft(nil, url: "https://new.example.com/other")
        do { try await store.saveFeed(newer); XCTFail("Unkeyed revision saved") }
        catch { XCTAssertEqual(error as? NewsEditorError, .sessionRequired) }
        let latest = Task { try await store.saveFeed(newer, editorID: session) }
        await waitFor(service, count: 2)
        await service.succeed(first.draftRevision, at: now)
        do { try await prior.value; XCTFail("Old new-feed draft saved") }
        catch { XCTAssertTrue(error is CancellationError) }
        store.cancelFeedEdit(id: session)
        await service.succeed(newer.draftRevision, at: now)
        do { try await latest.value; XCTFail("Canceled new-feed editor saved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(repo.savedDrafts.count, 0)
        XCTAssertEqual(store.snapshot, cached)
        let pending = draft(nil, url: "https://new.example.com/failure")
        let failedAfterCancel = Task { try await store.saveFeed(pending, editorID: session) }
        await waitFor(service, count: 3)
        store.cancelFeedEdit(id: session)
        await service.fail(pending.draftRevision)
        do { try await failedAfterCancel.value; XCTFail("Canceled editor surfaced transport failure") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.snapshot, cached)
    }

    func testNewFeedSupersessionUsesStableSessionInsteadOfDraftRevision() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        let session = UUID()
        let first = draft(nil)
        let pending = Task { try await store.saveFeed(first, editorID: session) }
        await waitFor(service, count: 1)
        let newer = draft(nil, url: "https://new.example.com/other")
        // The no-ID overload must not silently create another session for this revision.
        do { try await store.saveFeed(newer); XCTFail("Unkeyed revision saved") }
        catch { XCTAssertEqual(error as? NewsEditorError, .sessionRequired) }
        let latest = Task { try await store.saveFeed(newer, editorID: session) }
        await waitFor(service, count: 2)
        await service.succeed(first.draftRevision, at: now)
        do { try await pending.value; XCTFail("Superseded validation committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(repo.savedDrafts.count, 0)
        XCTAssertEqual(store.snapshot, cached)
        await service.succeed(newer.draftRevision, at: now)
        try await latest.value
        XCTAssertEqual(repo.savedDrafts, [newer])
        XCTAssertEqual(store.snapshot?.feeds.last?.url.absoluteString, newer.urlText)
    }

    func testEditorValidationFailureAndSaveFailurePreserveDraftAndCache() async {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        store.loadIfNeeded()
        let edit = draft(cached.feeds[0])
        let before = store.snapshot
        let failing = Task { try await store.saveFeed(edit) }
        await waitFor(service, count: 1)
        await service.fail(edit.draftRevision)
        do { try await failing.value; XCTFail("Expected validation failure") }
        catch { XCTAssertTrue(error is FeedServiceError) }
        XCTAssertEqual(store.snapshot, before)
        XCTAssertEqual(repo.savedDrafts.count, 0)
        repo.failSave = true
        let retry = Task { try await store.saveFeed(edit) }
        await waitFor(service, count: 2)
        await service.succeed(edit.draftRevision, at: now)
        do { try await retry.value; XCTFail("Expected save failure") }
        catch { XCTAssertTrue(error is StubNewsRepository.Failure) }
        XCTAssertEqual(store.localFailure, .save)
        XCTAssertEqual(store.snapshot, before)
        XCTAssertEqual(repo.value, before)
        XCTAssertEqual(edit.urlText, "https://new.example.com/rss")
    }

    func testCancelAndNewerDraftFenceLateValidation() async throws {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        store.loadIfNeeded()
        let first = draft(cached.feeds[0])
        let canceled = Task { try await store.saveFeed(first) }
        await waitFor(service, count: 1)
        store.cancelFeedEdit(id: firstID)
        await service.succeed(first.draftRevision, at: now)
        do { try await canceled.value; XCTFail("Canceled editor committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.snapshot, cached)
        let previous = draft(cached.feeds[0])
        let earlier = Task { try await store.saveFeed(previous) }
        await waitFor(service, count: 2)
        let newest = draft(cached.feeds[0], url: "https://new.example.com/other")
        let later = Task { try await store.saveFeed(newest) }
        await waitFor(service, count: 3)
        await service.succeed(previous.draftRevision, at: now)
        do { try await earlier.value; XCTFail("Superseded draft committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        await service.succeed(newest.draftRevision, at: now)
        try await later.value
        XCTAssertEqual(repo.savedDrafts, [newest])
        XCTAssertEqual(store.snapshot?.feeds.first { $0.id == firstID }?.url.absoluteString,
                       newest.urlText)
    }

    func testConcurrentEditRejectsStaleValidatedDraftWithoutReplacingCache() async {
        let (catalog, cached) = fixture()
        let repo = StubNewsRepository(cached)
        let service = EditorNewsService()
        let store = NewsStore(repository: repo, service: service, catalog: catalog)
        store.loadIfNeeded()
        let edit = draft(cached.feeds[0])
        let saving = Task { try await store.saveFeed(edit) }
        await waitFor(service, count: 1)
        let other = draft(cached.feeds[0], url: cached.feeds[0].url.absoluteString)
        _ = try? repo.saveFeed(other, validation: nil) // another window's Settings edit
        await service.succeed(edit.draftRevision, at: now)
        do { try await saving.value; XCTFail("Stale edit committed") }
        catch { XCTAssertEqual(error as? NewsRepositoryError, .staleRevision) }
        XCTAssertEqual(repo.savedDrafts, [other])
        XCTAssertEqual(store.snapshot, cached) // editor can reload and review its retained draft
        store.reload()
        XCTAssertEqual(store.snapshot, repo.value)
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
