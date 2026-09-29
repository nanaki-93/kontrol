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
