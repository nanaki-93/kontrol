import Foundation
import XCTest
@testable import Kontrol

final class FeedParserTests: XCTestCase {
    private let base = URL(string: "https://news.test/feed.xml")!
    private func parse(_ xml: String) throws -> ParsedFeed {
        try FeedParser().parse(Data(xml.utf8), baseURL: base)
    }
    private func fixture(_ name: String) throws -> ParsedFeed {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "xml", subdirectory: "Feeds"))
        return try FeedParser().parse(Data(contentsOf: url), baseURL: base)
    }

    func testRSSNamespaceCDATAUnsafeSiblingAndPlainText() throws {
        let entries = try fixture("rss").entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "First &amp; foremost")
        XCTAssertEqual(entries[0].url.absoluteString, "https://news.test/stories/one?x=1")
        XCTAssertEqual(entries[0].guid, "opaque-1")
        XCTAssertEqual(entries[0].summary, "Hello & friends world")
        XCTAssertEqual(entries[0].publishedAt, ISO8601DateFormatter().date(from: "2025-06-10T12:30:00Z"))
        XCTAssertEqual(entries[1].publishedAt, ISO8601DateFormatter().date(from: "2025-06-11T10:00:00Z"))
        XCTAssertEqual(entries[1].summary, "Some safe text")
    }

    func testRDFResourceAndAtomAlternateHTMLBaseAndPublication() throws {
        let rdf = try fixture("rdf").entries
        XCTAssertEqual(rdf.count, 1)
        XCTAssertEqual(rdf[0].url.absoluteString, "https://news.test/rdf/story")
        XCTAssertNotNil(rdf[0].publishedAt)
        let atom = try fixture("atom").entries
        XCTAssertEqual(atom.count, 2)
        XCTAssertEqual(atom[0].url.absoluteString, "https://news.test/posts/story")
        XCTAssertEqual(atom[0].guid, "https://news.test/id-not-a-link")
        XCTAssertNil(atom[0].publishedAt) // updated is not published
        XCTAssertEqual(atom[0].summary, "Hello reader")
        XCTAssertEqual(atom[1].url.absoluteString, "https://news.test/another")
        XCTAssertNotNil(atom[1].publishedAt)
    }

    func testRSSNamedPublicationTimeZonesUseFixedOffsets() throws {
        let dates = ["Tue, 10 Jun 2025 05:30:00 PDT", "Tue, 10 Jun 2025 08:30:00 EDT",
                     "Tue, 10 Jun 2025 12:30:00 GMT", "Tue, 10 Jun 2025 12:30:00 +0000"]
        let items = dates.enumerated().map { index, date in
            "<item><title>Story \(index)</title><link>https://news.test/\(index)</link><pubDate>\(date)</pubDate></item>"
        }.joined()
        let entries = try parse("<rss><channel>\(items)</channel></rss>").entries
        XCTAssertEqual(entries.count, dates.count)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-06-10T12:30:00Z"))
        for entry in entries { XCTAssertEqual(entry.publishedAt, expected, entry.title) }
    }

    func testEmptyAndInvalidItemsDoNotHideSiblings() throws {
        XCTAssertEqual(try parse("<rss><channel/></rss>").entries, [])
        XCTAssertEqual(try parse("<rdf:RDF xmlns:rdf='urn:rdf'/>").entries, [])
        XCTAssertEqual(try parse("<feed xmlns='http://www.w3.org/2005/Atom'/>").entries, [])
        let xml = "<rss><channel><item><title>No link</title><guid>https://news.test/not-a-link</guid></item><item><title>Yes</title><link>https://news.test/yes</link><pubDate>nonsense</pubDate></item></channel></rss>"
        XCTAssertEqual(try parse(xml).entries.map(\.title), ["Yes"])
        XCTAssertNil(try parse(xml).entries.first?.publishedAt)
        XCTAssertThrowsError(try parse("<html/>"))
    }

    func testStructuralFailuresAndEntitiesRejectWholeDocument() throws {
        for xml in ["<rss><channel><item></channel></rss>", "<rss><channel>",
                    "<!DOCTYPE rss><rss><channel/></rss>",
                    "<!DOCTYPE rss [<!ENTITY spy SYSTEM 'file:///etc/passwd'>]><rss><channel><item>&spy;</item></channel></rss>",
                    "<!DOCTYPE rss [<!ENTITY x 'hi'>]><rss><channel/></rss>"] {
            XCTAssertThrowsError(try parse(xml), xml)
        }
    }

    func testDepthEntryAndFieldBounds() throws {
        XCTAssertThrowsError(try parse("<rss><channel>" + String(repeating: "<a>", count: 63) + "</a>".repeated(63) + "</channel></rss>"))
        let item = "<item><title>T</title><link>https://news.test/a</link></item>"
        XCTAssertEqual(try parse("<rss><channel>" + String(repeating: item, count: 1_000) + "</channel></rss>").entries.count, 1_000)
        XCTAssertThrowsError(try parse("<rss><channel>" + String(repeating: item, count: 1_001) + "</channel></rss>"))
        let long = String(repeating: "x", count: 513)
        XCTAssertEqual(try parse("<rss><channel><item><title>\(long)</title><link>https://news.test/a</link></item>\(item)</channel></rss>").entries.count, 1)
        let summary = String(repeating: "s", count: 3_000)
        XCTAssertEqual(try parse("<rss><channel><item><title>T</title><link>https://news.test/a</link><description>\(summary)</description></item></channel></rss>").entries[0].summary?.count, 2_000)
        let longLink = "https://news.test/" + String(repeating: "x", count: 4_097)
        let longGUID = String(repeating: "g", count: 1_025)
        let bounded = try parse("<rss><channel><item><title>Bad</title><link>\(longLink)</link></item><item><title>T</title><link>https://news.test/a</link><guid>\(longGUID)</guid><description>&lt;script&gt;bad&lt;/script&gt;Safe &#65;</description></item></channel></rss>").entries
        XCTAssertEqual(bounded.count, 1)
        XCTAssertNil(bounded[0].guid)
        XCTAssertEqual(bounded[0].summary, "Safe A")
        let unsafeBase = "<feed xml:base='http://bad.test/'><entry><title>Bad</title><link href='relative'/></entry><entry><title>Good</title><link href='https://news.test/ok'/></entry></feed>"
        XCTAssertEqual(try parse(unsafeBase).entries.map(\.title), ["Good"])
    }
}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
