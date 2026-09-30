import Foundation
import SwiftData
import XCTest
@testable import Kontrol

/// Fixture bytes enter at URLSession's transport boundary, not as pre-parsed outcomes.
/// Every URL is intercepted, including unexpected requests and offline reopen attempts.
private final class NewsIntegrationProtocol: URLProtocol {
    enum Reply {
        case xml(Data, etag: String)
        case offline
    }

    private static let lock = NSLock()
    private static var replies: [URL: Reply] = [:]
    private static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = request.url.flatMap { Self.replies[$0] } ?? .offline
        Self.lock.unlock()
        switch reply {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .xml(let data, let etag):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/xml", "ETag": etag])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Exercise the actual streaming delegate with multiple chunks.
            let midpoint = data.count / 2
            client?.urlProtocol(self, didLoad: Data(data.prefix(midpoint)))
            client?.urlProtocol(self, didLoad: Data(data.dropFirst(midpoint)))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static func configure(_ replies: [URL: Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        requests = []
    }

    static func captured() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

@MainActor
private final class IntegrationNewsBrowser: NewsBrowserOpening {
    var urls: [URL] = []
    func open(_ url: URL) -> Bool { urls.append(url); return true }
}

@MainActor
private final class IntegrationDestinationPreferences: DestinationPreferences {
    var savedDestination: String? = AppDestination.news.rawValue
}

/// Releasing this owner drops the store, repository and writing container. Reopen creates
/// an entirely new graph against the same disk URL, with no in-memory persistence seam.
@MainActor
private final class IntegrationNewsOwner {
    let container: ModelContainer
    let repository: SwiftDataNewsRepository
    let store: NewsStore
    let browser = IntegrationNewsBrowser()

    init(url: URL, catalog: DefaultFeedCatalog, clock: @escaping () -> Date) throws {
        container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
        repository = SwiftDataNewsRepository(container: container, now: clock)
        let service = FeedService(fetcher: FeedFetcher(protocolClasses: [NewsIntegrationProtocol.self]),
                                  clock: clock)
        store = NewsStore(repository: repository, service: service, catalog: catalog,
                          browserOpener: browser, clock: clock)
    }
}

@MainActor
final class NewsIntegrationTests: XCTestCase {
    private let goID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let aiID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let goURL = URL(string: "https://feeds.test/go.xml")!
    private let aiURL = URL(string: "https://feeds.test/ai.xml")!
    private let sharedURL = "https://articles.test/shared"

    private var catalog: DefaultFeedCatalog {
        DefaultFeedCatalog(version: 1,
            topics: [NewsTopic(id: "go", name: "Go"), NewsTopic(id: "ai", name: "AI")],
            initialSelectedTopicIDs: ["go", "ai"], feeds: [
                .init(id: goID, name: "Go fixture", url: goURL, topicIDs: ["go"]),
                .init(id: aiID, name: "AI fixture", url: aiURL, topicIDs: ["ai"])
            ])
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
            withExtension: "xml", subdirectory: "Feeds"))
        return try Data(contentsOf: url)
    }

    private func snapshot(_ owner: IntegrationNewsOwner?) throws -> NewsSnapshot {
        try XCTUnwrap(owner?.store.snapshot)
    }

    private func visible(_ snapshot: NewsSnapshot, filter: String? = nil) -> [NewsSelection.VisibleArticle] {
        NewsSelection.sections(snapshot, filter: filter).flatMap(\.articles)
    }

    private func article(_ snapshot: NewsSnapshot, _ canonicalURL: String) throws -> ArticleMetadata {
        try XCTUnwrap(snapshot.articles.first { $0.canonicalURL == canonicalURL })
    }

    private func assertRequests(_ urls: [URL], etags: [URL: String] = [:],
                                file: StaticString = #filePath, line: UInt = #line) {
        let requests = NewsIntegrationProtocol.captured()
        XCTAssertEqual(requests.count, urls.count, file: file, line: line)
        XCTAssertEqual(Set(requests.compactMap(\.url)), Set(urls), file: file, line: line)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"),
                           request.url.flatMap { etags[$0] }, file: file, line: line)
        }
    }

    func testFixtureRefreshTransportFailureAndOfflineReopen() async throws {
        try await journey(failedReply: .offline, expectedError: .offline)
    }

    func testFixtureRefreshMalformedFeedAndOfflineReopen() async throws {
        try await journey(failedReply: .xml(try fixture("integration-malformed"), etag: "\"broken\""),
                          expectedError: .malformedFeed)
    }

    private func journey(failedReply: NewsIntegrationProtocol.Reply,
                         expectedError: NewsErrorCode) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolNewsIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            NewsIntegrationProtocol.configure([:])
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appendingPathComponent("Kontrol.store")
        let firstRefresh = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-06-15T12:00:00Z"))
        let partialRefresh = firstRefresh.addingTimeInterval(3600)
        let offlineAttempt = partialRefresh.addingTimeInterval(3600)
        var instant = firstRefresh
        let go = try fixture("integration-go"), ai = try fixture("integration-ai")
        let initialReplies: [URL: NewsIntegrationProtocol.Reply] = [
            goURL: .xml(go, etag: "\"go-v1\""), aiURL: .xml(ai, etag: "\"ai-v1\"")
        ]
        NewsIntegrationProtocol.configure(initialReplies)
        var owner: IntegrationNewsOwner? = try IntegrationNewsOwner(url: url, catalog: catalog, clock: { instant })
        weak var writingStore = owner?.store
        weak var writingRepository = owner?.repository
        weak var writingContainer = owner?.container
        XCTAssertNil(owner?.store.snapshot)
        assertRequests([]) // Construction is not launch IO.
        owner?.store.loadIfNeeded()
        XCTAssertTrue(try snapshot(owner).articles.isEmpty)
        XCTAssertNil(try snapshot(owner).preferences.lastRefreshAt)
        assertRequests([]) // Local initialization is also network-free.

        await owner?.store.refresh(.manual)
        assertRequests([goURL, aiURL])
        let initial = try snapshot(owner)
        XCTAssertNil(owner?.store.localFailure)
        XCTAssertEqual(initial.articles.count, 3, "Four feed entries must become three cached articles")
        XCTAssertEqual(visible(initial).count, 3)
        let shared = try article(initial, sharedURL)
        XCTAssertEqual(Set(shared.sources.map(\.feedID)), [goID, aiID])
        XCTAssertEqual(shared.firstFetchedAt, firstRefresh)
        let sharedState = try XCTUnwrap(initial.articleStates.first { $0.article.id == shared.id })
        XCTAssertEqual(sharedState.aliases[goID], ["go-shared"])
        XCTAssertEqual(sharedState.aliases[aiID], ["ai-shared"])
        XCTAssertEqual(Set(sharedState.contributions.keys), [goID, aiID])
        XCTAssertEqual(sharedState.contributions[goID]?.summary, "Shared plain text .")
        XCTAssertEqual(visible(initial).first { $0.article.id == shared.id }?.topicIDs, ["go", "ai"])
        XCTAssertEqual(visible(initial, filter: "go").count, 2)
        XCTAssertEqual(visible(initial, filter: "ai").count, 2)
        let undated = try XCTUnwrap(NewsSelection.sections(initial).first { $0.kind == .dateUnavailable })
        XCTAssertEqual(undated.title, "Date unavailable")
        XCTAssertEqual(undated.articles.map(\.article.canonicalURL), ["https://articles.test/go-only"])
        XCTAssertNil(undated.articles.first?.article.publishedAt)
        XCTAssertEqual(initial.preferences.lastRefreshAt, firstRefresh)
        XCTAssertTrue(initial.feeds.allSatisfy { $0.lastSuccessAt == firstRefresh && $0.lastError == nil })

        // Repeat full bodies: stable IDs, first-fetch age, aliases and provenance, not just a 304.
        NewsIntegrationProtocol.configure(initialReplies)
        await owner?.store.refresh(.manual)
        assertRequests([goURL, aiURL], etags: [goURL: "\"go-v1\"", aiURL: "\"ai-v1\""])
        let repeated = try snapshot(owner)
        XCTAssertEqual(repeated.articleStates, initial.articleStates)
        XCTAssertEqual(repeated.preferences, initial.preferences)

        // The failed source already owns both a shared and a private cached contribution.
        instant = partialRefresh
        NewsIntegrationProtocol.configure([
            goURL: failedReply,
            aiURL: .xml(try fixture("integration-ai-updated"), etag: "\"ai-v2\"")
        ])
        await owner?.store.refresh(.manual)
        assertRequests([goURL, aiURL], etags: [goURL: "\"go-v1\"", aiURL: "\"ai-v1\""])
        let partial = try snapshot(owner)
        XCTAssertTrue(owner?.store.isPartialRefresh == true)
        XCTAssertEqual(owner?.store.refreshFailures, [goID: expectedError])
        XCTAssertNil(owner?.store.localFailure)
        XCTAssertFalse(owner?.store.isRefreshing == true)
        XCTAssertEqual(partial.articles.count, 4)
        XCTAssertEqual(try article(partial, sharedURL).id, shared.id)
        XCTAssertEqual(Set(try article(partial, sharedURL).sources.map(\.feedID)), [goID, aiID])
        let partialSharedState = try XCTUnwrap(partial.articleStates.first { $0.article.id == shared.id })
        XCTAssertEqual(partialSharedState.contributions[goID], sharedState.contributions[goID])
        XCTAssertEqual(partialSharedState.aliases, sharedState.aliases)
        XCTAssertEqual(try article(partial, "https://articles.test/go-only"),
                       try article(initial, "https://articles.test/go-only"))
        XCTAssertEqual(try article(partial, "https://articles.test/ai-only").id,
                       try article(initial, "https://articles.test/ai-only").id,
                       "An item rolled off a successful feed must remain cached")
        XCTAssertEqual(try article(partial, "https://articles.test/ai-new").firstFetchedAt, partialRefresh)
        XCTAssertFalse(partial.articles.contains { $0.canonicalURL == "https://articles.test/uncommitted" })
        XCTAssertEqual(visible(partial, filter: "ai").first { $0.article.id == shared.id }?.article.title,
                       "Renamed shared story from AI")
        XCTAssertEqual(partial.preferences.lastRefreshAt, partialRefresh)
        let failedFeed = try XCTUnwrap(partial.feeds.first { $0.id == goID })
        XCTAssertEqual(failedFeed.lastAttemptAt, partialRefresh)
        XCTAssertEqual(failedFeed.lastSuccessAt, firstRefresh)
        XCTAssertEqual(failedFeed.lastError, expectedError)
        XCTAssertEqual(failedFeed.etag, "\"go-v1\"")
        XCTAssertEqual(partial.feeds.first { $0.id == aiID }?.lastSuccessAt, partialRefresh)
        XCTAssertEqual(partial.feeds.first { $0.id == aiID }?.etag, "\"ai-v2\"")

        let navigation = NavigationStore(preferences: IntegrationDestinationPreferences())
        navigation.select(.today)
        XCTAssertEqual(navigation.selectedDestination, .today, "A feed failure cannot gate other destinations")
        XCTAssertNil(navigation.saveError)
        XCTAssertNil(navigation.pendingTransition)
        navigation.select(.news)
        XCTAssertEqual(navigation.selectedDestination, .news)

        try owner?.store.saveSelectedTopics(["go"])
        let committed = try snapshot(owner)
        XCTAssertEqual(committed.preferences.selectedTopicIDs, ["go"])
        XCTAssertEqual(committed.articleStates, partial.articleStates, "Selection hides cache; it does not delete it")
        XCTAssertEqual(visible(committed).count, 2)
        owner = nil
        XCTAssertNil(writingStore, "The writing owner must actually close before disk reopen")
        XCTAssertNil(writingRepository)
        XCTAssertNil(writingContainer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // There is no network available to the new owner. Cached state must publish before
        // any refresh, including persisted feed errors and per-feed successful timestamps.
        instant = offlineAttempt
        NewsIntegrationProtocol.configure([:])
        owner = try IntegrationNewsOwner(url: url, catalog: catalog, clock: { instant })
        weak var reopenedStore = owner?.store
        XCTAssertNil(owner?.store.snapshot)
        assertRequests([])
        owner?.store.loadIfNeeded()
        let reopened = try snapshot(owner)
        XCTAssertEqual(reopened, committed)
        XCTAssertEqual(reopened.preferences.lastRefreshAt, partialRefresh)
        XCTAssertEqual(visible(reopened).count, 2)
        assertRequests([])
        owner?.store.openArticle(id: shared.id, sourceFeedID: goID)
        XCTAssertEqual(owner?.browser.urls, [try XCTUnwrap(sharedState.contributions[goID]).url])
        XCTAssertNil(owner?.store.browserOpenFailure)
        assertRequests([]) // Reading uses the injected browser, not a feed/article fetch.

        try owner?.store.saveSelectedTopics(["ai"])
        let reselected = try snapshot(owner)
        XCTAssertEqual(reselected.articleStates, committed.articleStates)
        XCTAssertEqual(visible(reselected).count, 3)
        XCTAssertTrue(visible(reselected, filter: "go").isEmpty)
        XCTAssertEqual(visible(reselected).first { $0.article.id == shared.id }?.article.title,
                       "Renamed shared story from AI")
        assertRequests([])
        try owner?.store.saveSelectedTopics(["go", "ai"])
        await owner?.store.refresh(.manual) // Entirely offline: no successful timestamp may advance.
        assertRequests([goURL, aiURL], etags: [goURL: "\"go-v1\"", aiURL: "\"ai-v2\""])
        let offline = try snapshot(owner)
        XCTAssertEqual(owner?.store.refreshFailures, [goID: .offline, aiID: .offline])
        XCTAssertFalse(owner?.store.isPartialRefresh == true)
        XCTAssertNil(owner?.store.localFailure)
        XCTAssertEqual(offline.articleStates, committed.articleStates)
        XCTAssertEqual(offline.preferences.lastRefreshAt, partialRefresh)
        XCTAssertEqual(offline.feeds.first { $0.id == goID }?.lastSuccessAt, firstRefresh)
        XCTAssertEqual(offline.feeds.first { $0.id == aiID }?.lastSuccessAt, partialRefresh)
        XCTAssertTrue(offline.feeds.allSatisfy { $0.lastAttemptAt == offlineAttempt && $0.lastError == .offline })
        XCTAssertEqual(visible(offline).count, 4)
        navigation.select(.projects)
        XCTAssertEqual(navigation.selectedDestination, .projects)
        XCTAssertNil(navigation.pendingTransition)
        owner = nil
        XCTAssertNil(reopenedStore)

        // The second offline reopen proves topic edits and failed attempts were saved to disk.
        NewsIntegrationProtocol.configure([:])
        owner = try IntegrationNewsOwner(url: url, catalog: catalog, clock: { instant })
        owner?.store.loadIfNeeded()
        XCTAssertEqual(try snapshot(owner), offline)
        assertRequests([])
        owner = nil
    }
}
