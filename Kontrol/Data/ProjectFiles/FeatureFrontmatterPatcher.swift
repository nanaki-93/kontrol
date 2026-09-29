import Foundation

/// Pure, bounded byte patching. The parser supplies root-key token offsets; no YAML
/// serialization or text search is used to choose which fields to edit.
struct FeatureFrontmatterPatcher {
    private let parser = ManifestParser()

    func complete(_ source: ProjectSourceDocument, featureID: String, at instant: Date) throws -> ProjectSourceDocument {
        try completeWithInverse(source, featureID: featureID, at: instant).source
    }

    /// Capture lexical source slices before editing; ranges in the inverse refer to the
    /// completed document, after all preceding edits have shifted their offsets.
    func completeWithInverse(_ source: ProjectSourceDocument, featureID: String, at instant: Date) throws
        -> (source: ProjectSourceDocument, inverse: FeatureInversePatch) {
        do {
            guard case let .supported(before) = try parser.feature(source),
                  before.id == featureID, before.status != .completed else {
                throw FeatureMutationFailure.unpatchableSource
            }
            let locations = try parser.featureFrontmatterLocations(source)
            let bytes = [UInt8](source.bytes)
            guard locations.isBlockMapping, let status = locations.topLevel["status"],
                  let statusRange = status.valueRange,
                  let newline = lineEnding(bytes, through: min(bytes.count, locations.closingDelimiterRange.upperBound +
                      (bytes.dropFirst(locations.closingDelimiterRange.upperBound).first == 0x0d ? 2 : 1))),
                  // Insertion requires a complete preceding line; never consume the delimiter.
                  locations.closingDelimiterRange.lowerBound > 0,
                  bytes[locations.closingDelimiterRange.lowerBound - 1] == 0x0a else {
                throw FeatureMutationFailure.unpatchableSource
            }
            let oldStatus = try token(status, bytes: bytes, yaml: locations.yamlRange)
            let replacement: String
            switch oldStatus {
            case "planned", "ready", "active", "blocked": replacement = "completed"
            case "'planned'", "'ready'", "'active'", "'blocked'": replacement = "'completed'"
            case "\"planned\"", "\"ready\"", "\"active\"", "\"blocked\"": replacement = "\"completed\""
            default: throw FeatureMutationFailure.unpatchableSource
            }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)!
            formatter.formatOptions = [.withInternetDateTime]
            let timestamp = "\"\(formatter.string(from: instant))\""
            var edits: [(Range<Int>, [UInt8])] = [(statusRange, Array(replacement.utf8))]
            if let date = locations.topLevel["completed_at"] {
                let oldDate = try token(date, bytes: bytes, yaml: locations.yamlRange)
                guard let range = date.valueRange,
                      oldDate.isEmpty || oldDate == "null" || oldDate == "Null" ||
                      oldDate == "NULL" || oldDate == "~" ||
                      (oldDate.first == "'" && oldDate.last == "'") ||
                      (oldDate.first == "\"" && oldDate.last == "\"") else {
                    throw FeatureMutationFailure.unpatchableSource
                }
                if oldDate.isEmpty {
                    // libyaml locates an implicit null immediately after the colon.
                    // Keep an existing separator space before the new scalar; if there
                    // is none, supply one without consuming any original bytes.
                    let hasSeparator = range.lowerBound < bytes.count && bytes[range.lowerBound] == 0x20
                    let commentAfterSeparator = hasSeparator && range.lowerBound + 1 < bytes.count &&
                        bytes[range.lowerBound + 1] == 0x23
                    let insertion = hasSeparator && !commentAfterSeparator ? (range.lowerBound + 1) : range.lowerBound
                    edits.append((insertion..<insertion,
                                  Array((hasSeparator && !commentAfterSeparator ? timestamp : " " + timestamp).utf8)))
                } else {
                    edits.append((range, Array(timestamp.utf8)))
                }
            } else {
                edits.append((locations.closingDelimiterRange.lowerBound..<locations.closingDelimiterRange.lowerBound,
                              Array("completed_at: \(timestamp)\(newline)".utf8)))
            }
            let ordered = edits.sorted { $0.0.lowerBound < $1.0.lowerBound }
            var shift = 0
            var previousEnd = 0
            var inverseEdits: [FeatureInverseEdit] = []
            for (range, replacement) in ordered {
                guard range.lowerBound >= previousEnd, range.upperBound <= bytes.count,
                      !replacement.isEmpty else {
                    throw FeatureMutationFailure.unpatchableSource
                }
                let start = range.lowerBound + shift
                inverseEdits.append(FeatureInverseEdit(completedRange: start..<(start + replacement.count),
                                                       originalBytes: Data(bytes[range])))
                shift += replacement.count - range.count
                previousEnd = range.upperBound
            }
            // Descending offsets keep all parser-derived ranges anchored to the original.
            var result = bytes
            for (range, replacement) in ordered.reversed() {
                result.replaceSubrange(range, with: replacement)
            }
            let patched = ProjectSourceDocument(relativePath: source.relativePath, bytes: Data(result))
            guard case let .supported(after) = try parser.feature(patched),
                  after.id == before.id, after.status == .completed,
                  after.completedAt == formatter.date(from: formatter.string(from: instant)),
                  after.title == before.title, after.priority == before.priority,
                  after.effort == before.effort, after.dependsOn == before.dependsOn,
                  after.areas == before.areas, after.body == before.body,
                  after.sourcePath == before.sourcePath else {
                throw FeatureMutationFailure.unpatchableSource
            }
            return (patched, FeatureInversePatch(relativePath: source.relativePath,
                                                 originalSHA256: source.sha256,
                                                 completedSHA256: patched.sha256,
                                                 edits: inverseEdits))
        } catch {
            // Parser errors and source fragments are not exposed across the mutation boundary.
            throw FeatureMutationFailure.unpatchableSource
        }
    }

    /// A revision guard prevents undo from overwriting any subsequent byte change.
    /// The original digest and parser check also reject corrupted inverse payloads.
    func restore(_ completed: ProjectSourceDocument, using inverse: FeatureInversePatch) throws -> ProjectSourceDocument {
        guard completed.relativePath == inverse.relativePath,
              completed.sha256 == inverse.completedSHA256 else {
            throw FeatureMutationFailure.undoConflict
        }
        do {
            guard case let .supported(before) = try parser.feature(completed), before.status == .completed else {
                throw FeatureMutationFailure.unpatchableSource
            }
            var bytes = [UInt8](completed.bytes)
            var previousEnd = 0
            for edit in inverse.edits {
                let range = edit.completedRange
                guard range.lowerBound >= previousEnd, range.upperBound <= bytes.count,
                      range.lowerBound < range.upperBound else {
                    throw FeatureMutationFailure.unpatchableSource
                }
                previousEnd = range.upperBound
            }
            guard !inverse.edits.isEmpty else { throw FeatureMutationFailure.unpatchableSource }
            for edit in inverse.edits.reversed() {
                bytes.replaceSubrange(edit.completedRange, with: edit.originalBytes)
            }
            let restored = ProjectSourceDocument(relativePath: completed.relativePath, bytes: Data(bytes))
            guard restored.sha256 == inverse.originalSHA256,
                  case let .supported(after) = try parser.feature(restored),
                  after.id == before.id, after.status != .completed,
                  after.title == before.title, after.priority == before.priority,
                  after.effort == before.effort, after.dependsOn == before.dependsOn,
                  after.areas == before.areas, after.body == before.body,
                  after.sourcePath == before.sourcePath else {
                throw FeatureMutationFailure.unpatchableSource
            }
            return restored
        } catch {
            throw FeatureMutationFailure.unpatchableSource
        }
    }

    /// Check every line break in the frontmatter, including delimiters. Bare CR and
    /// mixed LF/CRLF have no unambiguous insertion style. Body line breaks are irrelevant.
    private func lineEnding(_ bytes: [UInt8], through end: Int) -> String? {
        var style: Bool?
        for index in 0..<end {
            if bytes[index] == 0x0d && (index + 1 == end || bytes[index + 1] != 0x0a) { return nil }
            if bytes[index] == 0x0a {
                let crlf = index > 0 && bytes[index - 1] == 0x0d
                if let style, style != crlf { return nil }
                style = crlf
            }
        }
        return style == true ? "\r\n" : "\n"
    }

    /// Verify a parser-located scalar occupies just one ordinary block-mapping line.
    /// The colon, padding, and comment stay outside the replacement range. A zero-width
    /// implicit null may occur before padding/comment; never replace the whole line.
    private func token(_ location: FeatureScalarLocation, bytes: [UInt8], yaml: Range<Int>) throws -> String {
        let key = location.keyRange
        guard key.lowerBound >= yaml.lowerBound, key.upperBound < yaml.upperBound,
              let range = location.valueRange,
              range.lowerBound >= key.upperBound + 1, range.upperBound <= yaml.upperBound else {
            throw FeatureMutationFailure.unpatchableSource
        }
        let lineStart = (yaml.lowerBound..<key.lowerBound).last(where: { bytes[$0] == 0x0a }).map { $0 + 1 } ?? yaml.lowerBound
        // Only unindented root entries with a literal colon separator are supported.
        guard lineStart == key.lowerBound else { throw FeatureMutationFailure.unpatchableSource }
        let lineEnd = (key.upperBound..<yaml.upperBound).first(where: { bytes[$0] == 0x0a }) ?? yaml.upperBound
        guard range.upperBound <= lineEnd, bytes[key.upperBound] == 0x3a,
              bytes[(key.upperBound + 1)..<range.lowerBound].allSatisfy({ $0 == 0x20 }),
              !bytes[range].contains(0x0a), !bytes[range].contains(0x0d) else {
            throw FeatureMutationFailure.unpatchableSource
        }
        let suffix = bytes[range.upperBound..<lineEnd].dropLast(bytes[lineEnd - 1] == 0x0d ? 1 : 0)
        let rest = suffix.drop(while: { $0 == 0x20 })
        guard rest.isEmpty || rest.first == 0x23 else { throw FeatureMutationFailure.unpatchableSource }
        return String(decoding: bytes[range], as: UTF8.self)
    }
}
