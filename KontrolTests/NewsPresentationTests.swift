import Foundation
import XCTest
@testable import Kontrol

private actor PresentationService: NewsRefreshing {
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] { [] }
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed { throw CancellationError() }
}

private actor EditorPresentationService: NewsRefreshing {
    private(set) var requests: [FeedDraft] = []
    private var continuation: CheckedContinuation<ValidatedFeed, Error>?
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] { [] }
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        requests.append(draft)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resolve(success: Bool) {
        guard let draft = requests.last else { return }
        if success {
            continuation?.resume(returning: ValidatedFeed(draftRevision: draft.draftRevision,
                url: URL(string: draft.urlText)!, validatedAt: .now, etag: nil, lastModified: nil))
        } else {
            continuation?.resume(throwing: FeedServiceError(code: .malformedFeed, retryNotBefore: nil))
        }
        continuation = nil
    }
    func count() -> Int { requests.count }
}

@MainActor
private final class EditorBrowserSpy: NewsBrowserOpening {
    var urls: [URL] = []
    func open(_ url: URL) -> Bool { urls.append(url); return true }
}

private final class EditorSaveSwitch {
    enum Failure: Error { case injected }
    var fail = false
    var saves = 0
    func beforeSave() throws { saves += 1; if fail { throw Failure.injected } }
}

/// Compiled presentation fixtures; hosted controls and keyboard/AX execution are F13 work.
@MainActor
final class NewsPresentationTests: XCTestCase {
    private let goID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let securityID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let datedID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let undatedID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func feed(_ id: UUID, name: String, topics: Set<String>) -> FeedSourceSnapshot {
        FeedSourceSnapshot(id: id, name: name, url: URL(string: "https://feeds.test/rss")!,
            topicIDs: topics, isEnabled: true, configurationRevision: id,
            etag: nil, lastModified: nil, lastAttemptAt: nil, lastSuccessAt: nil,
            lastError: nil, retryNotBefore: nil)
    }

    private func state(_ id: UUID, date: Date?, sources: [NewsArticleSource], summary: String?) -> NewsSelection.State {
        let article = ArticleMetadata(id: id, url: URL(string: "https://example.com/\(id)")!,
            canonicalURL: "https://example.com/\(id)", title: "A cached headline",
            publishedAt: date, firstFetchedAt: now, summary: summary, sources: sources)
        return NewsSelection.State(article: article, aliases: [:])
    }

    private func fixture(selected: Set<String> = ["go", "security"]) -> NewsSnapshot {
        let go = NewsArticleSource(feedID: goID, feedName: "Go Blog", topicIDs: ["go"], guid: nil)
        let security = NewsArticleSource(feedID: securityID, feedName: "Security Bulletin",
                                         topicIDs: ["security"], guid: nil)
        return NewsSnapshot(topics: [NewsTopic(id: "go", name: "Go"),
                                     NewsTopic(id: "security", name: "Security"),
                                     NewsTopic(id: "gaming", name: "Gaming")],
            feeds: [feed(goID, name: "Go Blog", topics: ["go"]),
                    feed(securityID, name: "Security Bulletin", topics: ["security"])],
            articleStates: [state(datedID, date: now, sources: [go, security], summary: "Plain text"),
                            state(undatedID, date: nil, sources: [security], summary: nil)],
            preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: selected,
                                         revision: UUID(), lastRefreshAt: now))
    }

    func testSharedArticleIsOneRowAndUndatedIsExplicit() throws {
        let snapshot = fixture()
        let sections = NewsView.sections(in: snapshot, filter: nil)
        XCTAssertEqual(NewsView.selectedTopics(in: snapshot).map(\.id), ["go", "security"])
        XCTAssertEqual(sections.map(\.title), ["Dated", "Date unavailable"])
        XCTAssertEqual(sections.flatMap(\.articles).map(\.article.id), [datedID, undatedID])
        XCTAssertEqual(sections[0].articles[0].topicIDs, ["go", "security"])
        XCTAssertEqual(NewsView.readLabel(for: sections[0].articles[0].article),
                       "Read A cached headline from Go Blog in browser")
        XCTAssertEqual(NewsView.readLabel(for: sections[1].articles[0].article),
                       "Read A cached headline from Security Bulletin in browser")
        _ = NewsView(store: try compiledStoreFixture())
    }

    func testTemporaryFilterDoesNotChangePreferencesAndFallsBackToSelectedAll() {
        let snapshot = fixture()
        XCTAssertEqual(NewsView.sections(in: snapshot, filter: "go").flatMap(\.articles).map(\.article.id), [datedID])
        XCTAssertEqual(NewsView.sections(in: snapshot, filter: "security").flatMap(\.articles).map(\.article.id),
                       [datedID, undatedID])
        XCTAssertNil(NewsView.effectiveFilter("gaming", in: snapshot))
        XCTAssertEqual(NewsView.sections(in: snapshot, filter: "gaming"), NewsView.sections(in: snapshot, filter: nil))
        XCTAssertEqual(snapshot.preferences.selectedTopicIDs, ["go", "security"])
        let noTopics = fixture(selected: [])
        XCTAssertTrue(NewsView.sections(in: noTopics, filter: nil).isEmpty)
        XCTAssertTrue(NewsView.selectedTopics(in: noTopics).isEmpty)
    }

    func testStatusProjectionDistinguishesLoadingReadFailureAndEmptyCauses() {
        XCTAssertEqual(NewsView.contentState(snapshot: nil, isLoading: true, localFailure: nil, filter: nil), .loading)
        XCTAssertEqual(NewsView.contentState(snapshot: nil, isLoading: false, localFailure: .read, filter: nil), .readFailure)
        XCTAssertEqual(NewsView.contentState(snapshot: fixture(), isLoading: false, localFailure: .read, filter: nil), .readFailure)
        XCTAssertEqual(NewsView.lastSuccessText(nil), "Refresh history unavailable",
                       "A failed local read cannot establish whether a refresh ever succeeded")
        XCTAssertEqual(NewsView.refreshingText(nil), "Refreshing selected feeds")
        let base = fixture()
        let never = NewsSnapshot(topics: base.topics, feeds: base.feeds, articleStates: [],
            preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: ["go"],
                revision: UUID(), lastRefreshAt: nil))
        XCTAssertEqual(NewsView.lastSuccessText(never), "Never refreshed")
        XCTAssertEqual(NewsView.refreshingText(never),
                       "Refreshing selected feeds · no saved headlines for selected topics yet")
        XCTAssertEqual(NewsView.contentState(snapshot: never, isLoading: false, localFailure: nil, filter: nil), .emptyCache)
        XCTAssertEqual(NewsView.contentState(snapshot: base, isLoading: false, localFailure: nil, filter: "go"), .headlines)
        let noTopics = fixture(selected: [])
        XCTAssertEqual(NewsView.contentState(snapshot: noTopics, isLoading: false, localFailure: nil, filter: nil), .noTopics)
        let noFeeds = NewsSnapshot(topics: base.topics, feeds: [], articleStates: base.articleStates,
                                   preferences: base.preferences)
        XCTAssertEqual(NewsView.contentState(snapshot: noFeeds, isLoading: false, localFailure: nil, filter: nil), .noFeeds)
        let onlyGo = fixture(selected: ["go", "gaming"])
        XCTAssertEqual(NewsView.contentState(snapshot: onlyGo, isLoading: false, localFailure: nil,
                                             filter: "gaming"), .filteredEmpty)
        XCTAssertTrue(NewsView.sections(in: onlyGo, filter: "gaming").isEmpty)
        XCTAssertFalse(NewsView.sections(in: onlyGo, filter: nil).isEmpty)
        XCTAssertEqual(NewsView.refreshingText(onlyGo), "Refreshing · saved headlines remain available",
                       "Filtering out cached rows must not claim the cache is empty while refreshing")
        for code: NewsErrorCode in [.offline, .timeout, .rateLimited, .http, .unsafeURL,
                                    .oversizedResponse, .malformedFeed, .invalidConfiguration] {
            let empty = NewsView.failureText(code, in: never)
            XCTAssertTrue(empty.contains("No saved headlines for selected topics yet."), "\(code)")
            XCTAssertFalse(empty.contains("Saved headlines remain available."), "\(code)")
            XCTAssertTrue(NewsView.failureText(code, in: onlyGo).contains("Saved headlines remain available."),
                          "Other selected topics have cache even when the active filter is empty: \(code)")
        }
        XCTAssertTrue(NewsView.failureText(.rateLimited, in: never).contains("rate-limited"))
    }

    func testManagementCountMappingsAndRevisionCheckedEnableDraft() {
        let snapshot = fixture()
        XCTAssertEqual(NewsManagementView.selectedCountText(snapshot), "2 topics selected")
        XCTAssertEqual(NewsManagementView.selectedCountText(fixture(selected: [])), "0 topics selected")
        XCTAssertEqual(NewsManagementView.selectedCountText(fixture(selected: ["go"])), "1 topic selected")
        let feed = snapshot.feeds[0]
        XCTAssertEqual(NewsManagementView.topicNames(for: feed, in: snapshot), "Go")
        let draft = NewsManagementView.enabledDraft(for: feed, enabled: false)
        XCTAssertEqual(draft.id, feed.id)
        XCTAssertEqual(draft.expectedRevision, feed.configurationRevision)
        XCTAssertEqual(draft.name, feed.name)
        XCTAssertEqual(draft.urlText, feed.url.absoluteString)
        XCTAssertEqual(draft.topicIDs, feed.topicIDs)
        XCTAssertFalse(draft.isEnabled)
        XCTAssertEqual(NewsManagementView.FeedAction.add.title, "Add feed")
        XCTAssertEqual(NewsManagementView.FeedAction.edit(feed).title, "Edit feed")
        XCTAssertEqual(NewsManagementView.FeedAction.remove(feed).title, "Remove feed")
        XCTAssertNotEqual(NewsManagementView.FeedAction.edit(feed).id,
                          NewsManagementView.FeedAction.remove(feed).id)
        XCTAssertTrue(NewsManagementView.errorMessage(NewsRepositoryError.staleRevision).contains("Reload and review"))
    }

    func testManagementEntryPointsObserveOneStoreIncludingZeroStates() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = DefaultFeedCatalog(version: 1, topics: fixture().topics,
            initialSelectedTopicIDs: ["go"], feeds: [
                .init(id: goID, name: "Go Blog", url: URL(string: "https://feeds.test/go")!, topicIDs: ["go"])])
        let store = NewsStore(repository: SwiftDataNewsRepository(container: container),
                              service: PresentationService(), catalog: catalog)
        let newsEntry = NewsManagementSheet(store: store)
        let settingsEntry = NewsManagementView(store: store)
        XCTAssertTrue(newsEntry.store === settingsEntry.store)
        XCTAssertNil(store.snapshot, "Building management must not initialize or fetch feeds")
        store.loadIfNeeded()
        try settingsEntry.store.saveSelectedTopics([])
        XCTAssertEqual(NewsManagementView.selectedCountText(try XCTUnwrap(newsEntry.store.snapshot)), "0 topics selected")
        let feed = try XCTUnwrap(store.snapshot?.feeds.first)
        try await newsEntry.store.saveFeed(NewsManagementView.enabledDraft(for: feed, enabled: false))
        XCTAssertFalse(try XCTUnwrap(settingsEntry.store.snapshot?.feeds.first).isEnabled)
        try settingsEntry.store.saveSelectedTopics(["security"])
        XCTAssertEqual(newsEntry.store.snapshot?.preferences.selectedTopicIDs, ["security"])
        XCTAssertEqual(NewsManagementView.selectedCountText(try XCTUnwrap(newsEntry.store.snapshot)), "1 topic selected")
        let emptyCatalog = DefaultFeedCatalog(version: 1, topics: fixture().topics,
            initialSelectedTopicIDs: [], feeds: [])
        let emptyContainer = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let emptyStore = NewsStore(repository: SwiftDataNewsRepository(container: emptyContainer),
                                  service: PresentationService(), catalog: emptyCatalog)
        emptyStore.loadIfNeeded()
        _ = NewsManagementView(store: emptyStore)
        XCTAssertTrue(try XCTUnwrap(emptyStore.snapshot).feeds.isEmpty)
        try emptyStore.saveSelectedTopics(["go"])
        XCTAssertEqual(emptyStore.snapshot?.preferences.selectedTopicIDs, ["go"])
    }

    func testEditorLocalValidationAndFocusReturnFixtures() throws {
        let snapshot = fixture()
        let feed = snapshot.feeds[0]
        var draft = NewsFeedEditorState.makeDraft(nil)
        XCTAssertTrue(draft.isEnabled)
        XCTAssertNil(draft.expectedRevision)
        XCTAssertEqual(Set(NewsFeedEditorState.localErrors(draft, snapshot: snapshot).keys), ["name", "url", "topics"])
        draft.name = " Offline draft "
        draft.urlText = "https://new.test/rss"
        draft.topicIDs = ["go"]
        draft.isEnabled = false
        XCTAssertTrue(NewsFeedEditorState.localErrors(draft, snapshot: snapshot).isEmpty)
        XCTAssertFalse(NewsFeedEditorState.requiresValidation(draft, snapshot: snapshot))
        draft.isEnabled = true
        XCTAssertTrue(NewsFeedEditorState.requiresValidation(draft, snapshot: snapshot))
        draft.urlText = feed.url.absoluteString
        XCTAssertNotNil(NewsFeedEditorState.localErrors(draft, snapshot: snapshot)["url"])
        draft.urlText = "http://unsafe.test/rss"
        XCTAssertNotNil(NewsFeedEditorState.localErrors(draft, snapshot: snapshot)["url"])
        draft.topicIDs = ["unknown"]
        XCTAssertNotNil(NewsFeedEditorState.localErrors(draft, snapshot: snapshot)["topics"])
        var edit = NewsFeedEditorState.makeDraft(feed)
        edit.name = "Renamed"
        XCTAssertFalse(NewsFeedEditorState.requiresValidation(edit, snapshot: snapshot))
        XCTAssertEqual(edit.expectedRevision, feed.configurationRevision)
        XCTAssertEqual(NewsManagementView.returnFocus(after: .add, snapshot: snapshot), .add)
        XCTAssertEqual(NewsManagementView.returnFocus(after: .edit(feed), snapshot: snapshot), .edit(feed.id))
        XCTAssertEqual(NewsManagementView.returnFocus(after: .remove(feed), snapshot: snapshot), .remove(feed.id))
        let removed = NewsSnapshot(topics: snapshot.topics, feeds: [], articleStates: [], preferences: snapshot.preferences)
        XCTAssertEqual(NewsManagementView.returnFocus(after: .remove(feed), snapshot: removed), .heading)
        XCTAssertEqual(NewsManagementView.returnFocus(after: .edit(feed), snapshot: nil), .heading)
        let full = NewsSnapshot(topics: snapshot.topics, feeds: Array(repeating: feed, count: 32),
                                articleStates: [], preferences: snapshot.preferences)
        XCTAssertEqual(NewsManagementView.returnFocus(after: .add, snapshot: full), .heading)
        XCTAssertNotNil(NewsFeedEditorState.localErrors(draft, snapshot: full)["limit"])
        let store = try compiledStoreFixture()
        _ = NewsFeedEditorView(store: store) {}
        _ = NewsFeedEditorView(store: store, feed: feed) {}
        _ = NewsFeedRemovalView(store: store, feed: feed) {}
    }

    private func editorStore(service: NewsRefreshing, saves: EditorSaveSwitch = EditorSaveSwitch(),
                             browser: NewsBrowserOpening? = nil) throws -> NewsStore {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = DefaultFeedCatalog(version: 1, topics: fixture().topics,
            initialSelectedTopicIDs: ["go"], feeds: [
                .init(id: goID, name: "Go Blog", url: URL(string: "https://feeds.test/go")!, topicIDs: ["go"])])
        let store = NewsStore(repository: SwiftDataNewsRepository(container: container, beforeSave: { try saves.beforeSave() }),
                              service: service, catalog: catalog, browserOpener: browser)
        store.loadIfNeeded()
        return store
    }

    private func waitForEditor(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Editor fixture did not reach expected state")
    }

    func testEditorPendingDuplicateFailureAndCancelRetainCommittedState() async throws {
        let service = EditorPresentationService()
        let saves = EditorSaveSwitch()
        let browser = EditorBrowserSpy()
        let store = try editorStore(service: service, saves: saves, browser: browser)
        let saved = store.snapshot
        let saveCount = saves.saves
        let editor = NewsFeedEditorState()
        editor.draft.name = "A new feed"
        editor.draft.urlText = "https://new.test/rss"
        editor.draft.topicIDs = ["go"]
        let draft = editor.draft
        var dismissed = false
        editor.submit(store: store) { dismissed = true }
        editor.submit(store: store) { dismissed = true }
        XCTAssertTrue(editor.isSubmitting)
        XCTAssertEqual(editor.pendingText, "Checking this feed…")
        await waitForEditor { await service.count() == 1 }
        await service.resolve(success: false)
        await waitForEditor { !editor.isSubmitting }
        XCTAssertFalse(dismissed)
        XCTAssertEqual(editor.draft, draft)
        XCTAssertTrue(editor.errorMessage?.contains("supported RSS or Atom") == true)
        XCTAssertEqual(store.snapshot, saved)
        editor.submit(store: store) { dismissed = true }
        await waitForEditor { await service.count() == 2 }
        editor.cancel(store: store)
        await service.resolve(success: true) // Deliberately ignores transport cancellation.
        await waitForEditor { !editor.isSubmitting }
        XCTAssertFalse(dismissed)
        XCTAssertEqual(store.snapshot, saved)
        XCTAssertEqual(saves.saves, saveCount, "Validation failure and Cancel cannot persist")
        XCTAssertTrue(browser.urls.isEmpty, "Cancel cannot open a browser")
        let immediatelyCanceled = NewsFeedEditorState()
        immediatelyCanceled.draft = draft
        immediatelyCanceled.submit(store: store) { dismissed = true }
        immediatelyCanceled.cancel(store: store) // Before its queued task starts.
        await waitForEditor { !immediatelyCanceled.isSubmitting }
        let requests = await service.count()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(saves.saves, saveCount)
        XCTAssertTrue(browser.urls.isEmpty)
        XCTAssertFalse(dismissed)
    }

    func testEditorSaveFailureStaleRecoveryAndConfirmedRemoval() async throws {
        let saves = EditorSaveSwitch()
        let store = try editorStore(service: PresentationService(), saves: saves)
        let saved = try XCTUnwrap(store.snapshot)
        let feed = try XCTUnwrap(saved.feeds.first)
        let editor = NewsFeedEditorState(feed: feed)
        editor.draft.name = "Retained rename"
        let draft = editor.draft
        var dismissed = false
        saves.fail = true
        editor.submit(store: store) { dismissed = true }
        await waitForEditor { !editor.isSubmitting }
        XCTAssertFalse(dismissed)
        XCTAssertEqual(editor.draft, draft)
        XCTAssertEqual(store.snapshot, saved)
        XCTAssertTrue(editor.errorMessage?.contains("Nothing new was committed") == true)
        XCTAssertThrowsError(try NewsFeedRemovalView.confirm(feed: feed, store: store))
        XCTAssertEqual(store.snapshot, saved)
        saves.fail = false
        var concurrent = NewsFeedEditorState.makeDraft(feed)
        concurrent.name = "Changed in Settings"
        try await store.saveFeed(concurrent)
        editor.submit(store: store) { dismissed = true }
        await waitForEditor { !editor.isSubmitting }
        XCTAssertTrue(editor.needsReload)
        XCTAssertEqual(editor.draft, draft, "Stale rejection does not replace unsaved fields")
        XCTAssertThrowsError(try NewsFeedRemovalView.confirm(feed: feed, store: store)) {
            XCTAssertEqual($0 as? NewsRepositoryError, .staleRevision)
        }
        editor.reloadLatest(store: store)
        XCTAssertFalse(editor.needsReload)
        XCTAssertEqual(editor.draft.name, "Changed in Settings")
        XCTAssertEqual(editor.draft.expectedRevision, store.snapshot?.feeds.first?.configurationRevision)
        editor.draft.name = "Reviewed edit"
        editor.submit(store: store) { dismissed = true }
        await waitForEditor { !editor.isSubmitting }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(store.snapshot?.feeds.first?.name, "Reviewed edit")
        let current = try XCTUnwrap(store.snapshot?.feeds.first)
        try NewsFeedRemovalView.confirm(feed: current, store: store)
        XCTAssertTrue(try XCTUnwrap(store.snapshot).feeds.isEmpty)
        XCTAssertEqual(NewsManagementView.returnFocus(after: .remove(current), snapshot: store.snapshot), .heading)
    }

    private func compiledStoreFixture() throws -> NewsStore {
        // A static fixture compiles the native view without creating a window or a live service.
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        return NewsStore(repository: SwiftDataNewsRepository(container: container),
                         service: PresentationService(), catalog: nil)
    }
}
