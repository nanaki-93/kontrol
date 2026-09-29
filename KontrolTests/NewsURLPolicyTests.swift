import Foundation
import XCTest
@testable import Kontrol

final class NewsURLPolicyTests: XCTestCase {
    func testHTTPSFeedAndArticleURLsRemainUsable() throws {
        XCTAssertEqual(try NewsURLPolicy.feedURL("https://Feeds.Example.com:443/rss?edition=go").absoluteString,
                       "https://feeds.example.com/rss?edition=go")
        XCTAssertEqual(try NewsURLPolicy.articleURL("https://News.Example.com:8443/a#section").absoluteString,
                       "https://news.example.com:8443/a#section")
        XCTAssertEqual(try NewsURLPolicy.normalizedFeedURL("https://FEEDS.example.com:443"),
                       "https://feeds.example.com/")
    }

    func testUnsafeFeedsAndPersistedArticleLinksAreRejected() {
        let invalid = ["http://example.com/rss", "file:///etc/passwd", "javascript:alert(1)",
                       "https://user:pass@example.com/feed", "https://user@example.com/feed",
                       "https://%75ser@example.com/feed", "https://example.com@other.com/rss",
                       "https:///rss", "https://", "https://.example.com/feed",
                       "https://-example.com/feed", "https://example..com/rss",
                       "https://example.com:/rss", "https://example.com:0/rss",
                       "https://example.com:65536/rss", "https://example.com:abc/rss",
                       "https://example.com:443:80/rss", "https://[not-ipv6]/rss",
                       "https://256.0.0.1/rss", "https://127.1/rss",
                       "https://example.com\\@evil.com/rss", "https://example.com/a b",
                       "https://example.com/a%xx", "https://example.com/\nfoo",
                       "https://example.com/" + String(repeating: "a", count: 4_096)]
        for text in invalid {
            XCTAssertThrowsError(try NewsURLPolicy.feedURL(text), text)
            XCTAssertThrowsError(try NewsURLPolicy.articleURL(text), text)
            if let persisted = URL(string: text) {
                // Only check persisted links whose Foundation representation is still unsafe.
                if ["http", "file", "javascript"].contains(persisted.scheme?.lowercased() ?? "") {
                    XCTAssertThrowsError(try NewsURLPolicy.articleURL(persisted), text)
                }
            }
        }
        XCTAssertThrowsError(try NewsURLPolicy.feedURL("https://example.com/rss#fragment"))
        for stored in ["http://example.com/a", "https://name:secret@example.com/a",
                       "https://example.com:65536/a", "https://example.com/" + String(repeating: "a", count: 4_096)] {
            XCTAssertThrowsError(try NewsURLPolicy.articleURL(URL(string: stored)!), stored)
        }
    }

    func testNormalizationRemovesOnlyTrackingKeysFragmentAndDefaultPort() throws {
        let original = "HTTPS://NEWS.Example.com:443/Story/?a=1&utm_source=mail&b=2&GCLID=x&fbclid=y&a=3#read"
        XCTAssertEqual(try NewsURLPolicy.normalizedArticleURL(original),
                       "https://news.example.com/Story/?a=1&b=2&a=3")
        XCTAssertEqual(try NewsURLPolicy.normalizedArticleURL("https://example.com"), "https://example.com/")
        XCTAssertEqual(try NewsURLPolicy.normalizedArticleURL("https://example.com/a?topic=utm_source&x=1"),
                       "https://example.com/a?topic=utm_source&x=1")
        XCTAssertEqual(try NewsURLPolicy.normalizedArticleURL("https://example.com/a?%75tm_medium=x&keep=%2F"),
                       "https://example.com/a?keep=%2F")
    }

    func testMeaningfulPathsPortsAndQueryOrderingRemainDistinct() throws {
        let variants = ["https://example.com/Story?a=1&b=2", "https://example.com/story?a=1&b=2",
                        "https://example.com/Story/?a=1&b=2", "https://example.com/Story?b=2&a=1",
                        "https://example.com:8443/Story?a=1&b=2", "https://example.com/Story?a=2&b=2"]
        XCTAssertEqual(Set(try variants.map(NewsURLPolicy.normalizedArticleURL)).count, variants.count)
        XCTAssertEqual(try NewsURLPolicy.normalizedArticleURL("https://example.com/Story?ref=home&ref=other"),
                       "https://example.com/Story?ref=home&ref=other")
    }

    func testIPv6AndPortBoundary() throws {
        XCTAssertEqual(try NewsURLPolicy.feedURL("https://127.0.0.1/rss").absoluteString,
                       "https://127.0.0.1/rss")
        XCTAssertEqual(try NewsURLPolicy.feedURL("https://[::1]:443/rss").absoluteString,
                       "https://[::1]/rss")
        XCTAssertEqual(try NewsURLPolicy.articleURL("https://[2001:db8::1]:8443/a").absoluteString,
                       "https://[2001:db8::1]:8443/a")
        XCTAssertThrowsError(try NewsURLPolicy.feedURL("https://[::1]:65536/rss"))
        XCTAssertThrowsError(try NewsURLPolicy.feedURL("https://[fe80::1%25en0]/rss"))
    }

    func testRejectsMalformedAuthorityWithoutRequestingRemoteCanonicalURL() throws {
        XCTAssertThrowsError(try NewsURLPolicy.articleURL("https://evil.com%2F@example.com/a"))
        XCTAssertThrowsError(try NewsURLPolicy.articleURL("https://example.com%2f.evil.com/a"))
        XCTAssertEqual(try NewsURLPolicy.normalizedArticleURL("https://example.com/a#b"),
                       "https://example.com/a")
    }
}
