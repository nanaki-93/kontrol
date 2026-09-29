import Foundation
import XCTest
@testable import Kontrol

final class FeatureFrontmatterPatcherTests: XCTestCase {
    private let patcher = FeatureFrontmatterPatcher()
    private let instant = Date(timeIntervalSince1970: 1_780_315_696) // Fixed UTC instant.
    private let path = ".kontrol/features/other-name.md"

    private func document(_ text: String) -> ProjectSourceDocument {
        ProjectSourceDocument(relativePath: path, bytes: Data(text.utf8))
    }

    private func patch(_ text: String) throws -> String {
        let original = document(text)
        let result = try patcher.complete(original, featureID: "work", at: instant)
        XCTAssertEqual(original.bytes, Data(text.utf8))
        XCTAssertEqual(result.relativePath, path)
        XCTAssertNotEqual(result.sha256, original.sha256)
        return try XCTUnwrap(result.text)
    }

    func testLFAndCRLFPreserveAllOtherBytesAndBodyNewlines() throws {
        for newline in ["\n", "\r\n"] {
            let yaml = ["id: work", "title: 東京 🧭", "unknown: {status: nested}",
                        "status: ready # status: comment", "priority: high", "effort: small"]
                .joined(separator: newline)
            let body = "# status: body\nstatus: ready\r\n---\n"
            let input = "---\(newline)\(yaml)\(newline)---\(newline)\(body)"
            let output = try patch(input)
            XCTAssertEqual(output, input.replacingOccurrences(of: "status: ready #", with: "status: completed #")
                .replacingOccurrences(of: "---\(newline)\(body)", with:
                    "completed_at: \"\(stamp)\"\(newline)---\(newline)\(body)"))
        }
    }

    private var stamp: String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: instant)
    }

    func testQuotedKeysValuesCommentsAndExistingDates() throws {
        let prefix = "---\n'id': work\n\"title\": Café 🌙\n'status': 'blocked'   # keep\npriority: low\neffort: medium\n"
        for date in ["", "null", "~", "'2024-02-29T10:00:00Z'", "\"2025-01-01T00:00:00Z\""] {
            let input = prefix + "'completed_at': \(date)  # original\n---"
            let expected = prefix.replacingOccurrences(of: "'blocked'", with: "'completed'")
                + "'completed_at': \"\(stamp)\"  # original\n---"
            XCTAssertEqual(try patch(input), expected)
        }
        let singleSpaceComment = prefix + "completed_at: # original\n---"
        XCTAssertEqual(try patch(singleSpaceComment),
                       prefix.replacingOccurrences(of: "'blocked'", with: "'completed'")
                       + "completed_at: \"\(stamp)\" # original\n---")
        let double = "---\nid: work\ntitle: X\n\"status\": \"active\" # note\npriority: high\neffort: small\n---"
        XCTAssertEqual(try patch(double), double.replacingOccurrences(of: "\"active\"", with: "\"completed\"")
            .replacingOccurrences(of: "effort: small\n---", with: "effort: small\ncompleted_at: \"\(stamp)\"\n---"))
    }

    func testDelimiterAtEOFEmptyBodyAndTrailingNewlineRemainExact() throws {
        for ending in ["", "\n"] {
            let input = "---\nid: work\ntitle: X\nstatus: planned\npriority: high\neffort: small\n---\(ending)"
            let expected = "---\nid: work\ntitle: X\nstatus: completed\npriority: high\neffort: small\ncompleted_at: \"\(stamp)\"\n---\(ending)"
            XCTAssertEqual(try patch(input), expected)
        }
    }

    func testEmptyDateWithoutCommentAndWhitespaceIsNotNormalized() throws {
        let prefix = "---\nid: work\ntitle: X\nstatus: ready\npriority: high\neffort: small\ncompleted_at:"
        for suffix in ["", "   "] {
            let input = prefix + suffix + "\n---"
            let expected = prefix.replacingOccurrences(of: "status: ready", with: "status: completed")
                + (suffix.isEmpty ? " \"\(stamp)\"" : " \"\(stamp)\"  ") + "\n---"
            XCTAssertEqual(try patch(input), expected)
        }
    }

    func testInverseRestoresExactLexicalBytesForExistingAndInsertedDates() throws {
        let cases = [
            "---\nid: work\ntitle: 東京 🧭\nstatus: 'ready'  # leave\npriority: high\neffort: small\n---\n# status: planned\n",
            "---\r\nid: work\r\ntitle: Café\r\n\"status\": \"active\" # note\r\npriority: low\r\neffort: medium\r\n'completed_at': '2024-02-29T10:00:00+02:00' # old\r\n---",
            "---\nid: work\ntitle: X\nstatus: blocked\npriority: high\neffort: small\ncompleted_at: null  # old\n---",
            "---\nid: work\ntitle: X\nstatus: ready\npriority: high\neffort: small\ncompleted_at:   # empty\n---",
            "---\nid: work\ntitle: X\nstatus: ready\npriority: high\neffort: small\ncompleted_at:\n---",
            "---\nid: work\ntitle: X\nstatus: ready\npriority: high\neffort: small\ncompleted_at: ~\n---"
        ]
        for input in cases {
            let original = document(input)
            let (completed, inverse) = try patcher.completeWithInverse(original, featureID: "work", at: instant)
            XCTAssertEqual(inverse.originalSHA256, original.sha256)
            XCTAssertEqual(inverse.completedSHA256, completed.sha256)
            XCTAssertEqual(inverse.relativePath, path)
            XCTAssertEqual(try patcher.restore(completed, using: inverse).bytes, original.bytes, input)
            XCTAssertEqual(original.bytes, Data(input.utf8))
        }
    }

    func testInverseRefusesChangedRevisionOrPathWithoutProducingBytes() throws {
        let original = document("---\nid: work\ntitle: X\nstatus: 'planned'\npriority: high\neffort: small\n---")
        let (completed, inverse) = try patcher.completeWithInverse(original, featureID: "work", at: instant)
        let edited = ProjectSourceDocument(relativePath: path, bytes: completed.bytes + Data("\nexternal edit".utf8))
        XCTAssertThrowsError(try patcher.restore(edited, using: inverse)) {
            XCTAssertEqual($0 as? FeatureMutationFailure, .undoConflict)
        }
        let moved = ProjectSourceDocument(relativePath: ".kontrol/features/moved.md", bytes: completed.bytes)
        XCTAssertThrowsError(try patcher.restore(moved, using: inverse)) {
            XCTAssertEqual($0 as? FeatureMutationFailure, .undoConflict)
        }
        XCTAssertEqual(try patcher.restore(completed, using: inverse).bytes, original.bytes)
    }

    func testUnsafeInputsReturnNoOutput() throws {
        let base = "---\nid: work\ntitle: X\nstatus: ready\npriority: high\neffort: small\n---\n"
        let invalid = [
            base.replacingOccurrences(of: "status: ready", with: "status: ready\nstatus: ready"),
            base.replacingOccurrences(of: "status: ready", with: "status: *missing"),
            base.replacingOccurrences(of: "status: ready", with: "status: &x ready"),
            base.replacingOccurrences(of: "status: ready", with: "status: [ready"),
            base.replacingOccurrences(of: "status: ready", with: "status: >\n  ready"),
            base.replacingOccurrences(of: "status: ready", with: "status: |\n  ready"),
            base.replacingOccurrences(of: "status: ready", with: "status: ready\ncompleted_at: \"2026-01-01T\n  00:00:00Z\""),
            base.replacingOccurrences(of: "status: ready", with: "status: {x: ready}"),
            base.replacingOccurrences(of: "id: work", with: "schema_version: 2\nid: work"),
            base.replacingOccurrences(of: "priority: high", with: "priority: high\nunknown: [unterminated"),
            base.replacingOccurrences(of: "status: ready\n", with: "status: ready\r\n"),
            base.replacingOccurrences(of: "---\n", with: "---\r\n"),
            base.replacingOccurrences(of: "small\n---\n", with: "small\n---\r\n"),
            "---\n{id: work, title: X, status: ready, priority: high, effort: small}\n---",
            base.replacingOccurrences(of: "status: ready", with: "status: completed"),
            base + String(repeating: " ", count: 1_048_577)
        ]
        for input in invalid {
            XCTAssertThrowsError(try patcher.complete(document(input), featureID: "work", at: instant), input.prefix(100).description) {
                XCTAssertEqual($0 as? FeatureMutationFailure, .unpatchableSource)
            }
        }
        XCTAssertThrowsError(try patcher.complete(document(base), featureID: "wrong", at: instant))
        let bad = ProjectSourceDocument(relativePath: path, bytes: Data([0xff]))
        XCTAssertThrowsError(try patcher.complete(bad, featureID: "work", at: instant))
    }
}
