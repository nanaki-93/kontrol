import Darwin
import Foundation

/// A single policy for untrusted feed endpoints, parsed article links and persisted Read URLs.
/// This performs no network requests. Revalidate `articleURL` immediately before opening it.
enum NewsURLPolicy {
    static let maximumLength = 4_096 // UTF-8 bytes, both input and resulting URL.

    enum InvalidURL: Error, Equatable {
        case unsafe
    }

    static func feedURL(_ text: String) throws -> URL {
        try validated(text, isFeed: true).url
    }

    static func articleURL(_ text: String) throws -> URL {
        try validated(text, isFeed: false).url
    }

    static func articleURL(_ url: URL) throws -> URL {
        try articleURL(url.absoluteString)
    }

    /// Identity only: never replace the navigable source URL with a guessed remote canonical page.
    static func normalizedArticleURL(_ text: String) throws -> String {
        var components = try validated(text, isFeed: false).components
        components.fragment = nil
        if let items = components.percentEncodedQueryItems {
            let retained = items.filter { item in
                let key = item.name.removingPercentEncoding?.lowercased() ?? item.name.lowercased()
                return !key.hasPrefix("utm_") && key != "gclid" && key != "fbclid"
            }
            if retained.count != items.count {
                // Preserve a trailing empty '?' if it existed and no keys were dropped only.
                components.percentEncodedQueryItems = retained.isEmpty ? nil : retained
            }
        }
        guard let url = components.url, url.absoluteString.utf8.count <= maximumLength else {
            throw InvalidURL.unsafe
        }
        return url.absoluteString
    }

    /// Endpoint identity for configuration uniqueness (no tracking-key removal on feeds).
    static func normalizedFeedURL(_ text: String) throws -> String {
        try validated(text, isFeed: true).url.absoluteString
    }

    private static func validated(_ text: String, isFeed: Bool) throws -> (url: URL, components: URLComponents) {
        guard !text.isEmpty, text.utf8.count <= maximumLength,
              text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7f && $0 != "\\" }),
              validEscapes(text),
              let schemeEnd = text.range(of: "://"),
              text[..<schemeEnd.lowerBound].lowercased() == "https" else { throw InvalidURL.unsafe }

        let remainder = text[schemeEnd.upperBound...]
        let authority = String(remainder.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains("%") else {
            throw InvalidURL.unsafe
        }
        let host: String
        let portText: String?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw InvalidURL.unsafe }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let suffix = authority[authority.index(after: close)...]
            guard suffix.isEmpty || suffix.first == ":" else { throw InvalidURL.unsafe }
            portText = suffix.isEmpty ? nil : String(suffix.dropFirst())
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw InvalidURL.unsafe
            }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw InvalidURL.unsafe }
            host = String(parts[0])
            portText = parts.count == 2 ? String(parts[1]) : nil
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, host.utf8.count <= 253, labels.allSatisfy({ label in
                label.utf8.count <= 63 && !label.isEmpty && label.first != "-" && label.last != "-" &&
                    label.utf8.allSatisfy { byte in
                        (65...90).contains(byte) || (97...122).contains(byte) ||
                            (48...57).contains(byte) || byte == 45
                    }
            }) else { throw InvalidURL.unsafe }
            // A numeric dotted authority is an IPv4 literal, not a DNS name. Do not
            // let the resolver reinterpret malformed or abbreviated address forms.
            if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
                var address = in_addr()
                guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
                    throw InvalidURL.unsafe
                }
            }
        }
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(portText), (1...65_535).contains(port) else { throw InvalidURL.unsafe }
        }
        guard var components = URLComponents(string: text),
              components.scheme?.lowercased() == "https", components.user == nil,
              components.password == nil, components.host != nil,
              (!isFeed || components.fragment == nil) else { throw InvalidURL.unsafe }
        // URLComponents parses the authority; compare with our raw validation to avoid
        // accepting a repaired/misinterpreted host or port.
        guard components.host?.lowercased() == (authority.hasPrefix("[") ? "[\(host.lowercased())]" : host.lowercased()),
              components.port == portText.flatMap(Int.init) else { throw InvalidURL.unsafe }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        if components.port == 443 { components.port = nil }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        guard let url = components.url, url.absoluteString.utf8.count <= maximumLength else {
            throw InvalidURL.unsafe
        }
        return (url, components)
    }

    private static func validEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        for index in bytes.indices where bytes[index] == 37 { // '%'
            guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else {
                return false
            }
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
