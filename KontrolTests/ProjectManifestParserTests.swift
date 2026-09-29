import Foundation
import XCTest
@testable import Kontrol

final class ProjectManifestParserTests: XCTestCase {
    private let parser = ManifestParser()

    private func source(_ text: String, path: String = ".kontrol/project.yaml") -> ProjectSourceDocument {
        ProjectSourceDocument(relativePath: path, bytes: Data(text.utf8))
    }

    private func assertError(_ text: String, _ code: ProjectDiagnosticCode,
                             field: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parser.project(source(text)), file: file, line: line) { error in
            guard let error = error as? ProjectParseError else {
                return XCTFail("Expected classified parser error", file: file, line: line)
            }
            XCTAssertEqual(error.code, code, file: file, line: line)
            if let field = field { XCTAssertEqual(error.field, field, file: file, line: line) }
            XCTAssertEqual(error.path, ".kontrol/project.yaml", file: file, line: line)
        }
    }

    func testSampleFixturesAndDefaults() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../docs/examples/.kontrol").standardizedFileURL
        let projectBytes = try Data(contentsOf: base.appendingPathComponent("project.yaml"))
        let roadmapBytes = try Data(contentsOf: base.appendingPathComponent("roadmap.yaml"))
        let project = ProjectSourceDocument(relativePath: ".kontrol/project.yaml", bytes: projectBytes)
        let roadmap = ProjectSourceDocument(relativePath: ".kontrol/roadmap.yaml", bytes: roadmapBytes)
        guard case let .supported(manifest) = try parser.project(project),
              case let .supported(parsedRoadmap) = try parser.roadmap(roadmap) else {
            return XCTFail("Sample documents must be supported")
        }
        XCTAssertEqual(manifest.id, "kontrol-example")
        XCTAssertEqual(manifest.stack, ["Swift", "SwiftUI", "SwiftData"])
        XCTAssertEqual(parsedRoadmap.milestones.map(\.id), ["foundation", "projects"])
        XCTAssertEqual(project.bytes, projectBytes)
        XCTAssertEqual(try parser.project(source("schema_version: 1\nid: démo\nname: 東京\nextra: value\n")),
                       .supported(ProjectManifest(schemaVersion: 1, id: "démo", name: "東京",
                                                  description: "", stack: [], goals: [], currentFocus: [])))
        let crlf = source("schema_version: 1\r\nid: café\r\nname: Demo\r\n")
        XCTAssertEqual(crlf.text, "schema_version: 1\r\nid: café\r\nname: Demo\r\n")
        guard case let .supported(value) = try parser.project(crlf) else { return XCTFail() }
        XCTAssertEqual(value.id, "café")
    }

    func testRequiredAndOptionalFieldsAreStrictlyTyped() {
        assertError("schema_version: 1\nname: Demo\n", .invalidField, field: "id")
        assertError("schema_version: 1\nid: '  '\nname: Demo\n", .invalidField, field: "id")
        assertError("schema_version: '1'\nid: x\nname: Demo\n", .invalidField, field: "schema_version")
        assertError("schema_version: true\nid: x\nname: Demo\n", .invalidField, field: "schema_version")
        assertError("schema_version: 1\nid: 12\nname: Demo\n", .invalidField, field: "id")
        assertError("schema_version: 1\nid: x\nname: Demo\ndescription: null\n", .invalidField, field: "description")
        assertError("schema_version: 1\nid: x\nname: Demo\nstack: [Swift, 42]\n", .invalidField, field: "stack")
        assertError("schema_version: 1\nid: x\nname: Demo\ngoals: hello\n", .invalidField, field: "goals")
    }

    func testUnsafeOrMalformedYAMLIsRejectedEvenInUnknownFields() {
        let prefix = "schema_version: 1\nid: x\nname: Demo\n"
        assertError(prefix + "id: again\n", .duplicateKey, field: "id")
        XCTAssertThrowsError(try parser.project(source(prefix + "id: again\n"))) {
            XCTAssertEqual(($0 as? ProjectParseError)?.line, 2)
            XCTAssertEqual(($0 as? ProjectParseError)?.column, 1)
        }
        assertError(prefix + "extra: {nested: 1, nested: 2}\n", .duplicateKey, field: "nested")
        assertError(prefix + "---\nid: other\n", .malformedYAML)
        assertError(prefix + "extra: [broken\n", .malformedYAML)
        assertError(prefix + "extra: &value hello\nother: *value\n", .malformedYAML)
        assertError(prefix + "extra: &value {foo: bar}\nother: {<<: *value}\n", .malformedYAML)
        assertError(prefix + "extra: !custom data\n", .invalidField, field: "tag")
        assertError(prefix + "extra: {false: value}\n", .invalidField, field: "mapping key")
        assertError(prefix + "extra: &value [1]\n", .malformedYAML)
        assertError(prefix + "extra: [*undefined]\n", .malformedYAML)
        assertError(prefix + "extra: {<<: {id: x}}\n", .invalidField, field: "mapping key")
        assertError("[]", .invalidField)
        assertError("", .malformedYAML)
    }

    func testDeepNestingIsRejectedBeforeComposition() {
        // Both flow and block collections can exhaust a recursive composer well below 1 MiB.
        let prefix = "schema_version: 1\nid: x\nname: Demo\nextra: "
        let flow = prefix + String(repeating: "[", count: 300) + "value" + String(repeating: "]", count: 300) + "\n"
        assertError(flow, .sizeLimit, field: "document")
        // libyaml itself rejects nesting beyond its own ceiling; neither path composes it.
        let beyondLibraryLimit = prefix + String(repeating: "[", count: 4_000) + "x"
            + String(repeating: "]", count: 4_000) + "\n"
        assertError(beyondLibraryLimit, .malformedYAML, field: "document")
        let block = prefix + "\n" + (0..<300).map { String(repeating: " ", count: $0) + "-" }.joined(separator: "\n") + "\n"
        assertError(block, .sizeLimit, field: "document")
        let roadmap = source("schema_version: 1\nmilestones: " + String(repeating: "[", count: 300)
                             + "x" + String(repeating: "]", count: 300) + "\n", path: ".kontrol/roadmap.yaml")
        XCTAssertThrowsError(try parser.roadmap(roadmap)) {
            XCTAssertEqual(($0 as? ProjectParseError)?.code, .sizeLimit)
        }
        let wide = prefix + "[" + Array(repeating: "x", count: 10_001).joined(separator: ",") + "]\n"
        assertError(wide, .sizeLimit, field: "document")
    }

    func testUnsupportedVersionReturnsOnlySafeOriginalText() throws {
        let raw = "schema_version: 2\r\nid: future\r\nname: New\r\nunknown: 🌙\r\n"
        XCTAssertEqual(try parser.project(source(raw)), .unsupported(version: 2, rawText: raw))
        let roadmap = source("schema_version: 5\nmilestones: [unexpected]\n", path: ".kontrol/roadmap.yaml")
        XCTAssertEqual(try parser.roadmap(roadmap), .unsupported(version: 5, rawText: roadmap.text!))
        assertError("schema_version: 2\nid: x\nname: Demo\nid: y\n", .duplicateKey)
        let oversize = source(String(repeating: " ", count: 1_048_577))
        XCTAssertThrowsError(try parser.project(oversize)) {
            XCTAssertEqual(($0 as? ProjectParseError)?.code, .sizeLimit)
        }
        let invalid = ProjectSourceDocument(relativePath: ".kontrol/project.yaml", bytes: Data([0xff]))
        XCTAssertThrowsError(try parser.project(invalid)) {
            XCTAssertEqual(($0 as? ProjectParseError)?.code, .invalidUTF8)
        }
    }

    private func featureSource(_ text: String, path: String = ".kontrol/features/different-name.md") -> ProjectSourceDocument {
        source(text, path: path)
    }

    private func assertFeatureError(_ text: String, _ code: ProjectDiagnosticCode,
                                    field: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parser.feature(featureSource(text)), "Input: \(String(reflecting: text))", file: file, line: line) { error in
            guard let error = error as? ProjectParseError else {
                return XCTFail("Expected classified feature error", file: file, line: line)
            }
            XCTAssertEqual(error.code, code, file: file, line: line)
            XCTAssertEqual(error.path, ".kontrol/features/different-name.md", file: file, line: line)
            if let field { XCTAssertEqual(error.field, field, file: file, line: line) }
        }
    }

    private let featureYAML = "id: actual-id\ntitle: 東京 🧭\nstatus: ready\npriority: high\neffort: medium\n"

    func testFeatureFixturesAndVerbatimBodyWithBothLineEndings() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../docs/examples/.kontrol/features").standardizedFileURL
        for name in ["foundation", "project-reader", "feature-history"] {
            let bytes = try Data(contentsOf: base.appendingPathComponent("\(name).md"))
            let source = ProjectSourceDocument(relativePath: ".kontrol/features/\(name).md", bytes: bytes)
            guard case let .supported(feature) = try parser.feature(source) else { return XCTFail() }
            XCTAssertEqual(feature.id, name)
            XCTAssertEqual(feature.sourcePath, source.relativePath)
            XCTAssertEqual(source.bytes, bytes)
            XCTAssertTrue(feature.body.contains("Acceptance:") || name == "foundation")
            if name == "foundation" { XCTAssertNotNil(feature.completedAt) }
            else { XCTAssertNil(feature.completedAt) }
        }
        let body = "# Markdown 🌙\r\n\r\n---\r\nkeep  spaces  \r\n"
        let raw = "---\r\n" + featureYAML.replacingOccurrences(of: "\n", with: "\r\n")
            + "unknown: {keep: 'yes'}\r\n---\r\n" + body
        let original = featureSource(raw)
        guard case let .supported(feature) = try parser.feature(original) else { return XCTFail() }
        XCTAssertEqual(feature.id, "actual-id") // The filename is not the ID.
        XCTAssertEqual(feature.body, body)
        XCTAssertEqual(feature.dependsOn, [])
        XCTAssertEqual(feature.areas, [])
        XCTAssertNil(feature.completedAt)
        XCTAssertEqual(original.bytes, Data(raw.utf8))
        XCTAssertEqual(original.text, raw)
        let noTrailingNewline = "---\n" + featureYAML + "---"
        guard case let .supported(emptyBody) = try parser.feature(featureSource(noTrailingNewline)) else {
            return XCTFail("Closing delimiter at EOF is valid")
        }
        XCTAssertEqual(emptyBody.body, "")
    }

    func testFeatureEnumsArraysAndTimestamps() throws {
        for status in ["planned", "ready", "active", "blocked", "completed"] {
            for priority in ["high", "medium", "low"] {
                for effort in ["small", "medium", "large"] {
                    let yaml = "id: x\ntitle: X\nstatus: \(status)\npriority: \(priority)\neffort: \(effort)\n"
                    guard case let .supported(feature) = try parser.feature(featureSource("---\n" + yaml + "---\n")) else {
                        return XCTFail()
                    }
                    XCTAssertEqual(feature.status.rawValue, status)
                    XCTAssertEqual(feature.priority.rawValue, priority)
                    XCTAssertEqual(feature.effort.rawValue, effort)
                    XCTAssertNil(feature.completedAt) // Even completed does not invent a timestamp.
                }
            }
        }
        for timestamp in ["'2026-09-26T10:00:00Z'", "'2024-02-29T23:59:59.123+02:30'"] {
            let raw = "---\n" + featureYAML + "depends_on: [one, two]\nareas: [ui]\ncompleted_at: \(timestamp)\n---\n"
            guard case let .supported(feature) = try parser.feature(featureSource(raw)) else { return XCTFail() }
            XCTAssertNotNil(feature.completedAt)
            XCTAssertEqual(feature.dependsOn, ["one", "two"])
            XCTAssertEqual(feature.areas, ["ui"])
        }
        for null in ["", "null", "~"] {
            let raw = "---\n" + featureYAML + "completed_at: \(null)\n---\n"
            guard case let .supported(feature) = try parser.feature(featureSource(raw)) else { return XCTFail() }
            XCTAssertNil(feature.completedAt)
        }
        for bad in ["'2026-02-30T10:00:00Z'", "'2026-01-01'", "'2026-01-01T10:00:00'",
                    "'2026-01-01T25:00:00Z'", "'2026-01-01T10:00:00+25:00'", "yesterday", "123", "[]"] {
            assertFeatureError("---\n" + featureYAML + "completed_at: \(bad)\n---\n", .invalidField, field: "completed_at")
        }
    }

    func testInvalidFrontmatterFieldsAndDelimiters() {
        for raw in ["", featureYAML + "---\n", " ---\n" + featureYAML + "---\n",
                    "--- suffix\n" + featureYAML + "---\n", "---\n" + featureYAML,
                    "---\n" + featureYAML + " ---\n", "---\n" + featureYAML + "--- trailing\n",
                    "---\r" + featureYAML + "---\r", "\u{FEFF}---\n" + featureYAML + "---\n",
                    "---\n" + featureYAML + "\u{FEFF}---\n"] {
            assertFeatureError(raw, .invalidFrontmatter)
        }
        for yaml in [featureYAML.replacingOccurrences(of: "id: actual-id\n", with: ""),
                     featureYAML.replacingOccurrences(of: "id: actual-id", with: "id: '  '"),
                     featureYAML.replacingOccurrences(of: "title: 東京 🧭", with: "title: 42"),
                     featureYAML.replacingOccurrences(of: "status: ready", with: "status: done"),
                     featureYAML.replacingOccurrences(of: "priority: high", with: "priority: urgent"),
                     featureYAML.replacingOccurrences(of: "effort: medium", with: "effort: huge"),
                     featureYAML + "depends_on: [valid, 12]\n", featureYAML + "areas: null\n"] {
            XCTAssertThrowsError(try parser.feature(featureSource("---\n" + yaml + "---\n"))) {
                XCTAssertEqual(($0 as? ProjectParseError)?.code, .invalidField)
            }
        }
        assertFeatureError("---\n" + featureYAML + "id: duplicate\n---\n", .duplicateKey)
        XCTAssertThrowsError(try parser.feature(featureSource("---\nid: x\nid: y\n---\n"))) {
            XCTAssertEqual(($0 as? ProjectParseError)?.line, 2) // Physical line, zero-based.
        }
        assertFeatureError("---\n" + featureYAML + "unknown: &x abc\n---\n", .malformedYAML)
        assertFeatureError("---\n" + featureYAML + "unknown: !custom foo\n---\n", .invalidField)
        let invalid = ProjectSourceDocument(relativePath: ".kontrol/features/different-name.md", bytes: Data([0xff]))
        XCTAssertThrowsError(try parser.feature(invalid)) { XCTAssertEqual(($0 as? ProjectParseError)?.code, .invalidUTF8) }
        let utf16 = ProjectSourceDocument(relativePath: ".kontrol/features/different-name.md",
                                          bytes: "---\n".data(using: .utf16LittleEndian)!)
        XCTAssertThrowsError(try parser.feature(utf16)) // Delimiters are not decoded via another encoding.
    }

    func testFeatureUnsupportedVersionPreservesRawSourceButRejectsUnsafeYAML() throws {
        let raw = "---\r\nschema_version: 7\r\nunknown: ☀️\r\n ---\r\nbody"
        // An indented delimiter cannot end frontmatter.
        assertFeatureError(raw, .invalidFrontmatter)
        let valid = raw.replacingOccurrences(of: "\r\n ---", with: "\r\n---")
        XCTAssertEqual(try parser.feature(featureSource(valid)), .unsupported(version: 7, rawText: valid))
        assertFeatureError("---\nschema_version: '2'\n" + featureYAML + "---\n", .invalidField, field: "schema_version")
        assertFeatureError("---\nschema_version: 2\nid: x\nid: y\n---\n", .duplicateKey)
        assertFeatureError("---\nschema_version: 2\nunknown: *alias\n---\n", .malformedYAML)
    }

    func testFeatureLocationsAreParserGuidedUTF8ByteOffsets() throws {
        let raw = "---\r\n# status: ignored\r\nid: real\r\ntitle: 東京 🧭\r\n'note': {status: nested}\r\n'status': 'ready' # status: comment\r\npriority: high\r\neffort: medium\r\ncompleted_at: null # preserve\r\n---\r\n# status: Markdown\r\nstatus: body\r\n"
        let document = featureSource(raw)
        let locations = try parser.featureFrontmatterLocations(document)
        let bytes = [UInt8](document.bytes)
        func slice(_ range: Range<Int>?) -> String? {
            range.map { String(decoding: bytes[$0], as: UTF8.self) }
        }
        XCTAssertTrue(locations.isBlockMapping)
        XCTAssertEqual(slice(locations.yamlRange), raw.components(separatedBy: "---\r\n")[1]) // YAML starts after opening CRLF.
        XCTAssertEqual(slice(locations.closingDelimiterRange), "---")
        XCTAssertEqual(Set(locations.topLevel.keys), ["id", "title", "note", "status", "priority", "effort", "completed_at"])
        XCTAssertEqual(slice(locations.topLevel["status"]?.keyRange), "'status'")
        XCTAssertEqual(slice(locations.topLevel["status"]?.valueRange), "'ready'")
        XCTAssertEqual(slice(locations.topLevel["completed_at"]?.valueRange), "null")
        XCTAssertNil(locations.topLevel["note"]?.valueRange) // Nested mapping is not a scalar.
        XCTAssertLessThan(locations.topLevel["status"]!.valueRange!.upperBound, locations.closingDelimiterRange.lowerBound)
        XCTAssertEqual(bytes[locations.yamlRange.lowerBound], UInt8(ascii: "#"))
    }

    func testBlockNestedStatusDoesNotShadowRootScalar() throws {
        let raw = "---\nid: x\ntitle: 🌙\nunknown:\n  status: nested\nstatus: \"active\" # keep\npriority: high\neffort: small\n---\nstatus: Markdown\n"
        let locations = try parser.featureFrontmatterLocations(featureSource(raw))
        XCTAssertEqual(locations.topLevel.keys.filter { $0 == "status" }.count, 1)
        let bytes = [UInt8](raw.utf8)
        XCTAssertEqual(String(decoding: bytes[locations.topLevel["status"]!.valueRange!], as: UTF8.self), "\"active\"")
        XCTAssertNil(locations.topLevel["unknown"]?.valueRange)
        XCTAssertEqual(String(decoding: bytes[locations.closingDelimiterRange], as: UTF8.self), "---")
    }

    func testDetachedMutationContractCarriesExactRevisionAndRelativePath() {
        let source = featureSource("---\nid: x\ntitle: X\nstatus: ready\npriority: high\neffort: small\n---")
        let reference = ProjectReferenceSnapshot(id: UUID(), manifestID: "project", bookmarkData: Data([1, 2]),
                                                 displayOrder: 0, displayNameHint: "Demo", lastSuccessfulReadAt: nil,
                                                 revision: UUID())
        let request = FeatureCompletionRequest(reference: reference, featureID: "x", source: source,
                                               completedAt: Date(timeIntervalSince1970: 0))
        let completed = featureSource("---\nid: x\ntitle: X\nstatus: completed\npriority: high\neffort: small\ncompleted_at: \"1970-01-01T00:00:00Z\"\n---")
        let inverse = FeatureInversePatch(relativePath: source.relativePath, originalSHA256: source.sha256,
                                          completedSHA256: completed.sha256,
                                          edits: [FeatureInverseEdit(completedRange: 5..<14,
                                                                     originalBytes: Data("ready".utf8))])
        let receipt = FeatureMutationReceipt(projectID: reference.id, featureID: request.featureID,
                                             verifiedSource: completed, inverse: inverse)
        let undo = FeatureUndoRequest(reference: reference, receipt: receipt)
        XCTAssertEqual(request.source.bytes, source.bytes)
        XCTAssertEqual(undo.receipt.inverse.originalSHA256, source.sha256)
        XCTAssertEqual(undo.receipt.verifiedSource.bytes, completed.bytes)
        XCTAssertEqual(undo.receipt.verifiedSHA256, completed.sha256)
        XCTAssertEqual(undo.receipt.verifiedSHA256, inverse.completedSHA256)
        XCTAssertEqual(undo.receipt.relativePath, completed.relativePath)
        XCTAssertEqual(undo.receipt.projectID, reference.id)
    }

    func testLocationsRetainReadOnlyValidationAndRejectUnsupportedSources() throws {
        let valid = "---\nid: x\ntitle: X\nstatus: ready\npriority: high\neffort: small\n---"
        let location = try parser.featureFrontmatterLocations(featureSource(valid))
        XCTAssertEqual(location.closingDelimiterRange.upperBound, Data(valid.utf8).count)
        XCTAssertEqual(location.topLevel["status"]?.valueRange.map {
            String(decoding: Array(valid.utf8)[$0], as: UTF8.self)
        }, "ready")
        for raw in [valid.replacingOccurrences(of: "status: ready", with: "status: ready\nstatus: ready"),
                    valid.replacingOccurrences(of: "status: ready", with: "status: *alias"),
                    valid.replacingOccurrences(of: "status: ready", with: "status: wrong"),
                    valid.replacingOccurrences(of: "id: x", with: "schema_version: 2\nid: x")] {
            XCTAssertThrowsError(try parser.featureFrontmatterLocations(featureSource(raw)))
        }
        let invalid = ProjectSourceDocument(relativePath: ".kontrol/features/x.md", bytes: Data([0xff]))
        XCTAssertThrowsError(try parser.featureFrontmatterLocations(invalid))
    }

    func testRoadmapOrderStatusesAndInvalidMilestones() throws {
        let path = ".kontrol/roadmap.yaml"
        let valid = source("schema_version: 1\nmilestones:\n  - id: second\n    title: Étape\n    status: custom-state\n  - id: first\n    title: Start\n    status: active\n", path: path)
        guard case let .supported(roadmap) = try parser.roadmap(valid) else { return XCTFail() }
        XCTAssertEqual(roadmap.milestones.map(\.id), ["second", "first"])
        XCTAssertEqual(roadmap.milestones.map(\.status), ["custom-state", "active"])
        for yaml in ["schema_version: 1\n", "schema_version: 1\nmilestones: {}\n",
                     "schema_version: 1\nmilestones: [text]\n",
                     "schema_version: 1\nmilestones: [{id: a, title: T, status: ''}]\n",
                     "schema_version: 1\nmilestones: [{id: a, title: T, status: ready}, {id: a, title: T, status: done}]\n"] {
            XCTAssertThrowsError(try parser.roadmap(source(yaml, path: path)))
        }
    }
}
