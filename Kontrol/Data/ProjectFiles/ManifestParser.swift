import Foundation
import CYaml
import Yams

/// No filesystem access: callers supply a bounded, UTF-8 source from the reader.
/// An unsupported schema is not decoded using V1 assumptions.
enum ProjectDocumentResult<Value: Equatable>: Equatable {
    case supported(Value)
    case unsupported(version: Int, rawText: String)
}

struct ProjectParseError: Error, Equatable {
    let code: ProjectDiagnosticCode
    let path: String
    let line: Int?
    let column: Int?
    let field: String
}

struct ManifestParser {
    func project(_ source: ProjectSourceDocument) throws -> ProjectDocumentResult<ProjectManifest> {
        let fields = try mapping(source)
        let version = try schemaVersion(fields, source)
        guard version == 1 else { return .unsupported(version: version, rawText: source.text!) }
        return .supported(ProjectManifest(schemaVersion: version,
                                          id: try requiredString("id", fields, source, nonempty: true),
                                          name: try requiredString("name", fields, source, nonempty: true),
                                          description: try optionalString("description", fields, source),
                                          stack: try optionalStrings("stack", fields, source),
                                          goals: try optionalStrings("goals", fields, source),
                                          currentFocus: try optionalStrings("current_focus", fields, source)))
    }

    func roadmap(_ source: ProjectSourceDocument) throws -> ProjectDocumentResult<ProjectRoadmap> {
        let fields = try mapping(source)
        let version = try schemaVersion(fields, source)
        guard version == 1 else { return .unsupported(version: version, rawText: source.text!) }
        guard let node = fields["milestones"], case let .sequence(items) = node else {
            throw failure(.invalidField, "milestones", source, fields["milestones"])
        }
        var ids = Set<String>()
        let milestones = try items.map { item -> RoadmapMilestone in
            guard case .mapping = item else { throw failure(.invalidField, "milestones", source, item) }
            let entry = try checkedMapping(item, source)
            let id = try requiredString("id", entry, source, nonempty: true)
            guard ids.insert(id).inserted else { throw failure(.duplicateID, "id", source, entry["id"]) }
            return RoadmapMilestone(id: id,
                                    title: try requiredString("title", entry, source, nonempty: true),
                                    status: try requiredString("status", entry, source, nonempty: true))
        }
        return .supported(ProjectRoadmap(schemaVersion: version, milestones: milestones))
    }

    /// Parse only the YAML region; the source and Markdown suffix remain untouched.
    /// Delimiters must occupy complete lines, starting at byte zero (no preamble/BOM).
    func feature(_ source: ProjectSourceDocument) throws -> ProjectDocumentResult<ProjectFeature> {
        guard source.bytes.count <= 1_048_576 else { throw failure(.sizeLimit, "document", source) }
        guard let text = source.text else { throw failure(.invalidUTF8, "document", source) }
        // Foundation's UTF-8 decoder can discard a leading BOM; delimiters are byte-exact.
        guard source.bytes.starts(with: [0x2d, 0x2d, 0x2d, 0x0a]) ||
              source.bytes.starts(with: [0x2d, 0x2d, 0x2d, 0x0d, 0x0a]) else {
            throw failure(.invalidFrontmatter, "opening delimiter", source)
        }
        var cursor = text.startIndex
        guard let opening = nextLine(in: text, from: &cursor), opening.utf8.elementsEqual("---".utf8) else {
            throw failure(.invalidFrontmatter, "opening delimiter", source)
        }
        let yamlStart = cursor
        var yamlEnd: String.Index?
        while cursor < text.endIndex {
            let start = cursor
            guard let line = nextLine(in: text, from: &cursor) else { break }
            if line.utf8.elementsEqual("---".utf8) {
                yamlEnd = start
                break
            }
        }
        guard let yamlEnd else { throw failure(.invalidFrontmatter, "closing delimiter", source) }
        let yaml = ProjectSourceDocument(relativePath: source.relativePath,
                                         bytes: Data(text[yamlStart..<yamlEnd].utf8))
        do {
            let fields = try mapping(yaml)
            // Feature files inherit V1 unless they explicitly declare another schema.
            let version = fields["schema_version"] == nil ? 1 : try schemaVersion(fields, yaml)
            guard version == 1 else { return .unsupported(version: version, rawText: text) }
            let id = try requiredString("id", fields, yaml, nonempty: true)
            let title = try requiredString("title", fields, yaml, nonempty: true)
            let status: ProjectFeatureStatus = try featureEnum("status", fields, yaml)
            let priority: ProjectFeaturePriority = try featureEnum("priority", fields, yaml)
            let effort: ProjectFeatureEffort = try featureEnum("effort", fields, yaml)
            let completedAt = try completionDate(fields, yaml)
            return .supported(ProjectFeature(id: id, title: title, status: status, priority: priority,
                                             effort: effort, dependsOn: try optionalStrings("depends_on", fields, yaml),
                                             areas: try optionalStrings("areas", fields, yaml),
                                             completedAt: completedAt, body: String(text[cursor...]),
                                             sourcePath: source.relativePath))
        } catch let error as ProjectParseError {
            // Yams' marks are zero-based within the extracted YAML, after the opening line.
            throw ProjectParseError(code: error.code, path: source.relativePath,
                                    line: error.line.map { $0 + 1 }, column: error.column, field: error.field)
        }
    }

    /// Returns nil for a final unterminated line, which cannot be an opening delimiter.
    /// A closing delimiter at EOF is handled separately below by the line scanner.
    private func nextLine(in text: String, from cursor: inout String.Index) -> String? {
        let start = cursor
        // String.Character combines CRLF into one grapheme. Inspect Unicode scalars so
        // LF and CRLF have identical delimiter semantics without normalizing the body.
        let scalars = text.unicodeScalars
        if let newline = scalars[cursor...].firstIndex(of: "\n") {
            cursor = scalars.index(after: newline)
            let end = newline > start && scalars[scalars.index(before: newline)] == "\r"
                ? scalars.index(before: newline) : newline
            return String(text[start..<end])
        }
        cursor = text.endIndex
        return start == text.endIndex ? nil : String(text[start...])
    }

    private func featureEnum<T: RawRepresentable>(_ key: String, _ fields: [String: Node],
                                                   _ source: ProjectSourceDocument) throws -> T where T.RawValue == String {
        let value = try requiredString(key, fields, source)
        guard let result = T(rawValue: value) else { throw failure(.invalidField, key, source, fields[key]) }
        return result
    }

    private func completionDate(_ fields: [String: Node], _ source: ProjectSourceDocument) throws -> Date? {
        guard let node = fields["completed_at"] else { return nil }
        if case let .scalar(scalar) = node, node.tag.rawValue == Tag.Name.null.rawValue,
           ["", "null", "Null", "NULL", "~"].contains(scalar.string) { return nil }
        let value = try requiredString("completed_at", fields, source)
        // Require a full, explicit RFC 3339-style ISO 8601 instant (not a date-only value,
        // local time, YAML implicit timestamp, or a formatter-accepted prefix).
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.range == range else {
            throw failure(.invalidField, "completed_at", source, node)
        }
        let ns = value as NSString
        let numbers = (1...6).compactMap { Int(ns.substring(with: match.range(at: $0))) }
        guard numbers.count == 6, numbers[0] >= 1, (0...23).contains(numbers[3]),
              (0...59).contains(numbers[4]), (0...59).contains(numbers[5]) else {
            throw failure(.invalidField, "completed_at", source, node)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
        guard let day = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: day) == parts else {
            throw failure(.invalidField, "completed_at", source, node)
        }
        let zone = ns.substring(with: match.range(at: 7))
        if zone != "Z" {
            let components = zone.dropFirst().split(separator: ":")
            guard components.count == 2, let hours = Int(components[0]), let minutes = Int(components[1]),
                  hours <= 23, minutes <= 59 else { throw failure(.invalidField, "completed_at", source, node) }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw failure(.invalidField, "completed_at", source, node) }
        return date
    }

    private func mapping(_ source: ProjectSourceDocument) throws -> [String: Node] {
        guard source.bytes.count <= 1_048_576 else { throw failure(.sizeLimit, "document", source) }
        guard let text = source.text else { throw failure(.invalidUTF8, "document", source) }
        do {
            // Yams composes recursively. Reject excessive nesting *before* calling singleRoot;
            // a post-composition Node walk cannot protect the composer stack.
            try preflight(source)
            // singleRoot checks the entire stream; compose() alone would only parse the first document.
            let parser = try Parser(yaml: text, encoding: .utf8)
            guard let root = try parser.singleRoot() else {
                throw failure(.malformedYAML, "document", source)
            }
            guard case .mapping = root else { throw failure(.invalidField, "document", source, root) }
            var budget = 0
            try inspect(root, source, depth: 0, budget: &budget)
            return try checkedMapping(root, source)
        } catch let error as ProjectParseError {
            throw error
        } catch YamlError.duplicatedKeysInMapping(let duplicates, _) {
            let key = duplicates.keys.sorted { ($0.mark?.line ?? 0) < ($1.mark?.line ?? 0) }.first
            throw failure(.duplicateKey, key?.scalar?.string ?? "mapping key", source, key)
        } catch {
            // Do not leak project source or unrestricted parser errors into UI/logs.
            throw failure(.malformedYAML, "document", source)
        }
    }

    /// libyaml's event parser is iterative. It shares Yams' YAML grammar, but does not
    /// build Nodes or recursively compose. Count every container and scalar (including
    /// unknown fields) before Yams can recurse. Reject aliases/anchors before expansion.
    private func preflight(_ source: ProjectSourceDocument) throws {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else {
            throw failure(.malformedYAML, "document", source)
        }
        defer { yaml_parser_delete(&parser) }
        var depth = 0
        var nodes = 0
        try source.bytes.withUnsafeBytes { buffer in
            yaml_parser_set_input_string(&parser, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            while true {
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else {
                    throw failure(.malformedYAML, "document", source)
                }
                let type = event.type
                let anchor: UnsafeMutablePointer<UInt8>?
                switch type {
                case YAML_MAPPING_START_EVENT:
                    anchor = event.data.mapping_start.anchor
                    depth += 1
                    nodes += 1
                case YAML_SEQUENCE_START_EVENT:
                    anchor = event.data.sequence_start.anchor
                    depth += 1
                    nodes += 1
                case YAML_SCALAR_EVENT:
                    anchor = event.data.scalar.anchor
                    nodes += 1
                case YAML_ALIAS_EVENT:
                    anchor = nil
                default:
                    anchor = nil
                }
                let unsafeAlias = type == YAML_ALIAS_EVENT || anchor != nil
                if type == YAML_MAPPING_END_EVENT || type == YAML_SEQUENCE_END_EVENT { depth -= 1 }
                yaml_event_delete(&event)
                if unsafeAlias { throw failure(.malformedYAML, "anchor/alias", source) }
                if depth > 64 || nodes > 10_000 { throw failure(.sizeLimit, "document", source) }
                if type == YAML_STREAM_END_EVENT { break }
            }
        }
    }

    /// Check *all* nodes, including unknown fields, before decoding. The post-composition
    /// check also enforces tags, mapping keys and duplicate keys.
    private func inspect(_ node: Node, _ source: ProjectSourceDocument,
                         depth: Int, budget: inout Int) throws {
        budget += 1
        guard depth <= 64, budget <= 10_000 else { throw failure(.sizeLimit, "document", source, node) }
        guard node.anchor == nil else { throw failure(.malformedYAML, "anchor/alias", source, node) }
        switch node {
        case .scalar:
            guard [Tag.Name.str, .int, .float, .bool, .null].map(\.rawValue).contains(node.tag.rawValue) else {
                throw failure(.invalidField, "tag", source, node)
            }
        case let .sequence(items):
            guard node.tag.rawValue == Tag.Name.seq.rawValue else { throw failure(.invalidField, "tag", source, node) }
            for item in items { try inspect(item, source, depth: depth + 1, budget: &budget) }
        case let .mapping(pairs):
            guard node.tag.rawValue == Tag.Name.map.rawValue else { throw failure(.invalidField, "tag", source, node) }
            var keys = Set<String>()
            for (key, value) in pairs {
                guard key.tag.rawValue != Tag.Name.merge.rawValue else {
                    throw failure(.invalidField, "mapping key", source, key)
                }
                try inspect(key, source, depth: depth + 1, budget: &budget)
                guard case let .scalar(scalar) = key, key.tag.rawValue == Tag.Name.str.rawValue,
                      scalar.string != "<<" else { throw failure(.invalidField, "mapping key", source, key) }
                guard keys.insert(scalar.string).inserted else {
                    throw failure(.duplicateKey, scalar.string, source, key)
                }
                try inspect(value, source, depth: depth + 1, budget: &budget)
            }
        case .alias:
            throw failure(.malformedYAML, "alias", source, node)
        }
    }

    private func checkedMapping(_ node: Node, _ source: ProjectSourceDocument) throws -> [String: Node] {
        guard case let .mapping(pairs) = node else { throw failure(.invalidField, "mapping", source, node) }
        // Called only after inspect has checked duplicate and non-string keys recursively.
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.key.scalar!.string, $0.value) })
    }

    private func schemaVersion(_ fields: [String: Node], _ source: ProjectSourceDocument) throws -> Int {
        guard let node = fields["schema_version"], case let .scalar(scalar) = node,
              node.tag.rawValue == Tag.Name.int.rawValue, let version = Int(scalar.string), version >= 1 else {
            throw failure(.invalidField, "schema_version", source, fields["schema_version"])
        }
        return version
    }

    private func requiredString(_ key: String, _ fields: [String: Node],
                                _ source: ProjectSourceDocument, nonempty: Bool = false) throws -> String {
        guard let node = fields[key], case let .scalar(scalar) = node, node.tag.rawValue == Tag.Name.str.rawValue,
              !nonempty || !scalar.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(.invalidField, key, source, fields[key])
        }
        return scalar.string
    }

    private func optionalString(_ key: String, _ fields: [String: Node],
                                _ source: ProjectSourceDocument) throws -> String {
        guard fields[key] != nil else { return "" }
        return try requiredString(key, fields, source)
    }

    private func optionalStrings(_ key: String, _ fields: [String: Node],
                                 _ source: ProjectSourceDocument) throws -> [String] {
        guard let node = fields[key] else { return [] }
        guard case let .sequence(items) = node else { throw failure(.invalidField, key, source, node) }
        return try items.map { item in
            guard case let .scalar(scalar) = item, item.tag.rawValue == Tag.Name.str.rawValue else {
                throw failure(.invalidField, key, source, item)
            }
            return scalar.string
        }
    }

    private func failure(_ code: ProjectDiagnosticCode, _ field: String,
                         _ source: ProjectSourceDocument, _ node: Node? = nil) -> ProjectParseError {
        ProjectParseError(code: code, path: source.relativePath,
                          line: node?.mark?.line,
                          column: node?.mark?.column, field: field)
    }
}
