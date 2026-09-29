import Foundation

struct ParsedFeed: Equatable {
    let entries: [NewsFeedEntry]
}

enum FeedParserError: Error, Equatable {
    case malformed
    case unsupported
    case limitExceeded
}

/// XMLParser is used only for metadata; no network, stylesheet, or entity resolution is permitted.
struct FeedParser {
    func parse(_ data: Data, baseURL: URL) throws -> ParsedFeed {
        _ = try NewsURLPolicy.feedURL(baseURL.absoluteString)
        // Reject declarations before libxml can expand even internal entities. Also catches empty DTDs.
        let probes = [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian,
                      .utf32LittleEndian, .utf32BigEndian].compactMap { String(data: data, encoding: $0) }
        if probes.contains(where: { $0.range(of: "<!\\s*(?:DOCTYPE|ENTITY)\\b",
                                          options: [.regularExpression, .caseInsensitive]) != nil }) {
            throw FeedParserError.malformed
        }
        let delegate = Collector(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else { throw delegate.failure ?? .malformed }
        if let failure = delegate.failure { throw failure }
        guard delegate.recognized else { throw FeedParserError.unsupported }
        return ParsedFeed(entries: delegate.entries)
    }
}

private final class Collector: NSObject, XMLParserDelegate {
    private struct Element {
        let name: String
        let base: URL
    }
    private struct Item {
        var title = ""
        var link = ""
        var linkBase: URL?
        var guid = ""
        var date = ""
        var summary = ""
        var atomLink: URL?
        var summaryDepth: Int?
        var ignoredDepth: Int?
    }

    private let documentURL: URL
    private var stack: [Element] = []
    private var kind: String?
    private var item: Item?
    private var processed = 0
    private(set) var entries: [NewsFeedEntry] = []
    private(set) var failure: FeedParserError?
    var recognized: Bool { kind != nil }

    init(baseURL: URL) { documentURL = baseURL }

    private func local(_ name: String) -> String { String(name.split(separator: ":").last ?? "").lowercased() }
    private func attribute(_ attributes: [String: String], _ key: String) -> String? {
        attributes.first { local($0.key) == key && (key != "base" || $0.key.lowercased() == "xml:base") }?.value
    }
    private func resolve(_ text: String, base: URL) -> URL? {
        guard text.utf8.count <= NewsURLPolicy.maximumLength,
              let url = URL(string: text, relativeTo: base)?.absoluteURL,
              let safe = try? NewsURLPolicy.articleURL(url) else { return nil }
        return safe
    }
    private func append(_ text: String, to field: inout String, maximum: Int) {
        if field.count > maximum { return }
        let remaining = maximum + 1 - field.count
        field += String(text.prefix(remaining))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = local(elementName)
        if stack.count >= 64 { failure = .limitExceeded; parser.abortParsing(); return }
        let parentBase = stack.last?.base ?? documentURL
        let base = attribute(attributeDict, "base").flatMap { URL(string: $0, relativeTo: parentBase)?.absoluteURL } ?? parentBase
        let parent = stack.last?.name
        stack.append(Element(name: name, base: base))
        if stack.count == 1 {
            if name == "rss" { kind = "rss" }
            else if name == "rdf" { kind = "rdf" }
            else if name == "feed" { kind = "atom" }
            else { failure = .unsupported; parser.abortParsing() }
            return
        }
        if (kind == "rss" && parent == "channel" && name == "item" && stack.count == 3) ||
            (kind == "rdf" && parent == "rdf" && name == "item" && stack.count == 2) ||
            (kind == "atom" && parent == "feed" && name == "entry" && stack.count == 2) {
            processed += 1
            if processed > 1_000 { failure = .limitExceeded; parser.abortParsing(); return }
            item = Item()
            return
        }
        guard var current = item else { return }
        let entryDepth = kind == "rss" ? 3 : 2
        if stack.count == entryDepth + 1 {
            if kind == "atom" && name == "link" {
                let rel = attribute(attributeDict, "rel")?.lowercased() ?? "alternate"
                let type = attribute(attributeDict, "type")?.lowercased() ?? "text/html"
                if rel == "alternate", ["text/html", "application/xhtml+xml"].contains(type),
                   current.atomLink == nil, let href = attribute(attributeDict, "href") {
                    current.atomLink = resolve(href, base: base)
                }
            }
            if kind == "rdf" && name == "link", let resource = attribute(attributeDict, "resource") {
                current.link = resource
                current.linkBase = base
            }
            if ["description", "summary", "content", "encoded"].contains(name) {
                current.summaryDepth = stack.count
            }
        } else if let summaryDepth = current.summaryDepth, stack.count > summaryDepth {
            if current.ignoredDepth == nil && ["script", "style"].contains(name) { current.ignoredDepth = stack.count }
            else if current.ignoredDepth == nil { append(" ", to: &current.summary, maximum: 16_000) }
        }
        item = current
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { collect(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { collect(string) }
    }
    private func collect(_ text: String) {
        guard var current = item, current.ignoredDepth == nil else { return }
        let entryDepth = kind == "rss" ? 3 : 2
        if current.summaryDepth != nil {
            append(text, to: &current.summary, maximum: 16_000)
        } else if stack.count == entryDepth + 1, let name = stack.last?.name {
            switch name {
            case "title": append(text, to: &current.title, maximum: 512)
            case "link" where kind != "atom": append(text, to: &current.link, maximum: 4_096); current.linkBase = stack.last?.base
            case "guid", "id": append(text, to: &current.guid, maximum: 1_024)
            case "pubdate", "published", "date": append(text, to: &current.date, maximum: 128)
            default: break
            }
        }
        item = current
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let top = stack.last else { return }
        if var current = item {
            if current.ignoredDepth == stack.count { current.ignoredDepth = nil }
            if current.summaryDepth == stack.count { current.summaryDepth = nil }
            let entryDepth = kind == "rss" ? 3 : 2
            if stack.count == entryDepth && ["item", "entry"].contains(top.name) {
                let title = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let link = kind == "atom" ? current.atomLink : resolve(current.link.trimmingCharacters(in: .whitespacesAndNewlines), base: current.linkBase ?? top.base)
                if !title.isEmpty, title.count <= 512, current.link.count <= 4_096, let link {
                    let summary = Self.plainText(current.summary)
                    entries.append(NewsFeedEntry(title: title, url: link,
                                                 guid: current.guid.count <= 1_024 ? current.guid.trimmingCharacters(in: .whitespacesAndNewlines).nonempty : nil,
                                                 publishedAt: Self.date(current.date), summary: summary.nonempty))
                }
                item = nil
            } else { item = current }
        }
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = .malformed; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        failure = .malformed; parser.abortParsing()
    }

    private static func plainText(_ input: String) -> String {
        // Escaped HTML in CDATA/text is decoded once, then stripped. Do not render it.
        var text = input
        for (entity, value) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&amp;": "&", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        let numeric = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in numeric.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[valueRange])
            let value = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw, radix: 10)
            let character = value.flatMap(UnicodeScalar.init).map(String.init) ?? " "
            text.replaceSubrange(range, with: character)
        }
        text = text.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: " ", options: .regularExpression)
        // Unclosed dangerous blocks must not leak their bodies into the plain-text preview.
        text = text.replacingOccurrences(of: "(?is)<(?:script|style)\\b[^>]*>.*$", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(2_000))
    }

    private static func date(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 128 else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            iso.formatOptions = options
            if let value = iso.date(from: text) { return value }
        }
        // DateFormatter's `Z` accepts numeric offsets but does not reliably recognize
        // RFC 822's named US zones. Convert only the defined abbreviations to fixed
        // offsets; using the system's abbreviation dictionary can vary by locale/OS.
        let namedOffsets = ["UT": "+0000", "GMT": "+0000", "EST": "-0500", "EDT": "-0400",
                            "CST": "-0600", "CDT": "-0500", "MST": "-0700", "MDT": "-0600",
                            "PST": "-0800", "PDT": "-0700"]
        let parts = text.split(separator: " ")
        let suffix = parts.last.map { String($0).uppercased() } ?? ""
        let normalized = namedOffsets[suffix].map { text.dropLast(suffix.count) + $0 } ?? text
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = format
            if let value = formatter.date(from: normalized) { return value }
        }
        return nil
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
