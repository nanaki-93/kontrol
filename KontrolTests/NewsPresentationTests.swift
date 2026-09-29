import Foundation
import XCTest
@testable import Kontrol

private actor PresentationService: NewsRefreshing {
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] { [] }
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed { throw CancellationError() }
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

    private func compiledStoreFixture() throws -> NewsStore {
        // A static fixture compiles the native view without creating a window or a live service.
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        return NewsStore(repository: SwiftDataNewsRepository(container: container),
                         service: PresentationService(), catalog: nil)
    }
}
