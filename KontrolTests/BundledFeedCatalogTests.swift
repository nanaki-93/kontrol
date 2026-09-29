import Foundation
import XCTest
@testable import Kontrol

final class BundledFeedCatalogTests: XCTestCase {
    private func bundledData() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "default-feeds", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func changed(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bundledData()) as? [String: Any])
        mutation(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func changeFeed(_ index: Int = 0, _ mutation: (inout [String: Any]) -> Void) throws -> Data {
        try changed { object in
            var feeds = object["feeds"] as! [[String: Any]]
            mutation(&feeds[index])
            object["feeds"] = feeds
        }
    }

    private func assertInvalid(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BundledFeedCatalog.decodeAndValidate(data), file: file, line: line) {
            XCTAssertEqual($0 as? BundledFeedCatalogError, .invalidCatalog, file: file, line: line)
        }
    }

    func testCompiledAppResourceHasNineTopicsSevenSelectedAndRealCoverage() throws {
        // No test fixture, source-tree fallback, or live internet: use the compiled host app resource.
        let catalog = try BundledFeedCatalog.load(from: Bundle.main)
        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.topics.map(\.name), ["Go", "Java", "Software Engineering", "Security",
                                                   "System Design", "AI", "Japan", "Gaming", "Anime"])
        XCTAssertEqual(catalog.initialSelectedTopicIDs,
                       Set(["go", "java", "software-engineering", "security", "system-design", "ai", "japan"]))
        XCTAssertFalse(catalog.initialSelectedTopicIDs.contains("gaming"))
        XCTAssertFalse(catalog.initialSelectedTopicIDs.contains("anime"))
        XCTAssertEqual(catalog.feeds.count, 7)
        XCTAssertEqual(Set(catalog.feeds.map(\.id)).count, catalog.feeds.count)
        XCTAssertTrue(catalog.feeds.contains { $0.topicIDs.count > 1 })
        XCTAssertTrue(catalog.initialSelectedTopicIDs.isSubset(of: catalog.feeds.reduce(into: Set<String>()) {
            $0.formUnion($1.topicIDs)
        }))
        for feed in catalog.feeds {
            XCTAssertEqual(feed.url.scheme, "https")
            XCTAssertFalse(feed.url.absoluteString.contains("example.org"))
            XCTAssertEqual(try NewsURLPolicy.feedURL(feed.url.absoluteString), feed.url)
        }
        XCTAssertEqual(try BundledFeedCatalog.decodeAndValidate(bundledData()), catalog)
    }

    func testMissingBundleAndMalformedResourceFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertThrowsError(try BundledFeedCatalog.load(from: bundle)) {
            XCTAssertEqual($0 as? BundledFeedCatalogError, .missingResource)
        }
        assertInvalid(Data("{".utf8))
        assertInvalid(Data(repeating: 0x20, count: 65_537))
        assertInvalid(try changed { $0["version"] = 0 })
    }

    func testRejectsDuplicateAndUnknownTopicIDsOrIncorrectSelection() throws {
        assertInvalid(try changed { object in
            var topics = object["topics"] as! [[String: Any]]
            topics[1]["id"] = "go"
            object["topics"] = topics
        })
        assertInvalid(try changed { $0["initialSelectedTopicIDs"] = ["go", "java", "gaming"] })
        assertInvalid(try changeFeed { $0["topicIDs"] = ["go", "go"] })
        assertInvalid(try changeFeed { $0["topicIDs"] = ["unknown"] })
        assertInvalid(try changeFeed { $0["topicIDs"] = [] })
        assertInvalid(try changed { object in
            var feeds = object["feeds"] as! [[String: Any]]
            feeds.removeLast() // Japan has no remaining coverage.
            object["feeds"] = feeds
        })
    }

    func testRejectsDuplicateIDsAndNormalizedEndpoints() throws {
        assertInvalid(try changeFeed(1) { $0["id"] = "368191B6-FCD2-45EA-ACFB-86BD36FE0847" })
        assertInvalid(try changeFeed { $0["id"] = "not-a-uuid" })
        assertInvalid(try changeFeed { $0["id"] = "00000000-0000-0000-0000-000000000000" })
        assertInvalid(try changeFeed(1) { $0["url"] = "https://GO.DEV:443/blog/feed.atom" })
    }

    func testRejectsUnsafePlaceholderAndDuplicateMappingURLs() throws {
        for endpoint in ["http://go.dev/blog/feed.atom", "file:///tmp/rss", "https://user@go.dev/rss",
                         "https://go.dev:65536/feed", "https://go.dev/rss#fragment",
                         "https://example.org/feed", "https://rss.example.com/feed", "https://localhost/rss"] {
            assertInvalid(try changeFeed { $0["url"] = endpoint })
        }
        assertInvalid(try changeFeed { $0["name"] = "  " })
        assertInvalid(try changeFeed { $0["name"] = " Go Blog " })
        assertInvalid(try changed { object in
            let feeds = object["feeds"] as! [[String: Any]]
            object["feeds"] = Array(repeating: feeds[0], count: 33)
        })
    }
}
