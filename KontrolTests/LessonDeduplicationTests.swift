import Foundation
import XCTest
@testable import Kontrol

final class LessonDeduplicationTests: XCTestCase {
    private let teachingHash = CatalogValidator.fingerprint(explanation: " Explained ",
        workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
        selfCheckCriteria: ["Check"])

    private func metadata(_ id: String = "candidate", _ objective: String? = "Objective",
                          _ concepts: [String]? = ["a", "b", "c", "d"],
                          _ content: String? = nil) -> LessonMatchMetadata {
        LessonMatchMetadata(id: id, objectiveKey: objective, conceptIDs: concepts,
                            contentHash: content ?? teachingHash)
    }

    private func terminal(_ metadata: LessonMatchMetadata,
                          _ status: LessonProgressStatus = .completed) -> TerminalLessonMatch {
        TerminalLessonMatch(status: status, metadata: metadata)
    }

    private var changedHash: String { "sha256:" + String(repeating: "a", count: 64) }

    func testTerminalIDsHavePriorityAndRestoredOrStartedRecordsDoNotExclude() {
        let candidate = metadata()
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate,
            terminal: [terminal(metadata("candidate"), .completed)]), .rejected(.completedID))
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate,
            terminal: [terminal(metadata("candidate"), .dismissed)]), .rejected(.dismissedID))
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate,
            terminal: [terminal(metadata("candidate"), .available)]), .eligible)
    }

    func testTerminalPrecedenceOverMalformedMetadataAndActiveAssignments() {
        let malformed = metadata("shared", nil, [], "untrusted")
        let active = metadata("shared", "other", ["z"], "sha256:" + String(repeating: "b", count: 64))
        XCTAssertEqual(LessonDeduplication.decide(candidate: malformed,
            terminal: [terminal(metadata("shared", nil, nil, nil), .completed)], active: [active]),
            .rejected(.completedID))
        XCTAssertEqual(LessonDeduplication.decide(candidate: malformed,
            terminal: [terminal(metadata("shared", nil, nil, nil), .dismissed)], active: [active]),
            .rejected(.dismissedID))

        // A matching terminal fingerprint outranks an active-ID match, even
        // when the candidate has no usable objective/concept evidence.
        let missingConcepts = metadata("shared", nil, [], teachingHash)
        XCTAssertEqual(LessonDeduplication.decide(candidate: missingConcepts,
            terminal: [terminal(metadata("archived", nil, nil, teachingHash))], active: [active]),
            .rejected(.exactContent))

        let overlapping = metadata("shared", " objective ", ["a", "b", "c", "d"], changedHash)
        XCTAssertEqual(LessonDeduplication.decide(candidate: overlapping,
            terminal: [terminal(metadata("archived", "OBJECTIVE", ["a", "b", "c", "d"], teachingHash))],
            active: [active]), .rejected(.objectiveConceptOverlap))
        XCTAssertEqual(LessonDeduplication.decide(candidate: malformed, terminal: [], active: [active]),
            .rejected(.invalidMetadata))
    }

    func testRenameAndIdenticalTeachingSectionsExcludeRegardlessOfObjective() {
        let candidate = metadata("renamed", "Unrelated", ["z"])
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate,
            terminal: [terminal(metadata("original", "Original", ["a"]))]),
            .rejected(.exactContent))
        // Metadata on a DTO cannot substitute an authored title for the sections.
        XCTAssertEqual(teachingHash, CatalogValidator.fingerprint(explanation: "Explained",
            workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
            selfCheckCriteria: ["Check"]))
    }

    func testChangedProseUsesSharedFingerprintWhileTitleRenameKeepsIt() throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Catalog", withExtension: nil))
        let catalog = try JSONDecoder().decode(CatalogDTO.self,
            from: Data(contentsOf: directory.appendingPathComponent("valid.json")))
        let original = try XCTUnwrap(catalog.lessons.first)
        var renamed = original
        renamed.id = "renamed"
        renamed.title = "A different title"
        XCTAssertEqual(LessonDeduplication.decide(candidate: LessonMatchMetadata(renamed),
            terminal: [terminal(LessonMatchMetadata(original))]), .rejected(.exactContent))
        var edited = renamed
        edited.explanation += " New prose."
        edited.normalizedContentHash = CatalogValidator.fingerprint(for: edited)
        XCTAssertNotEqual(LessonMatchMetadata(edited).contentHash,
                          LessonMatchMetadata(original).contentHash)
        XCTAssertEqual(LessonDeduplication.decide(candidate: LessonMatchMetadata(edited),
            terminal: [terminal(LessonMatchMetadata(original))]), .rejected(.objectiveConceptOverlap))
    }

    func testInclusiveFourFifthsAndImmediatelyLowerOverlap() {
        let candidate = metadata("new", "OBJECTIVE", ["a", "b", "c", "d"] , changedHash)
        let fourOfFive = metadata("old", " objective ", ["e", "a", "b", "c", "d", "a"], teachingHash)
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate,
            terminal: [terminal(fourOfFive)]), .rejected(.objectiveConceptOverlap))
        let threeOfFive = metadata("old", "objective", ["a", "b", "c", "e"], teachingHash)
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate,
            terminal: [terminal(threeOfFive)]), .eligible)
        XCTAssertEqual(LessonDeduplication.decide(candidate: metadata("new", "different", ["a", "b", "c", "d"], changedHash),
            terminal: [terminal(fourOfFive)]), .eligible)
    }

    func testNFCWhitespaceCaseConceptOrderAndLocaleIndependentObjective() {
        let old = metadata("old", "  CAFÉ I  ", ["a", "b", "c", "d", "e"], teachingHash)
        let candidate = metadata("new", "cafe\u{301} i\n", ["e", "d", "c", "b", "a", "a"], changedHash)
        // Turkish locale-specific casing differs; the matcher must use Unicode
        // default casing, not the device's locale-sensitive lowercasing.
        XCTAssertEqual("I".lowercased(with: Locale(identifier: "tr_TR")), "ı")
        XCTAssertEqual("I".lowercased(with: Locale(identifier: "en_US")), "i")
        XCTAssertEqual(LessonDeduplication.normalizedObjective(" I "), "i")
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate,
            terminal: [terminal(old)]), .rejected(.objectiveConceptOverlap))
        XCTAssertEqual(LessonDeduplication.sortedConceptIDs(["b", "a", "b", "A"]), ["A", "a", "b"])
        XCTAssertEqual(LessonDeduplication.decide(candidate: metadata("new", "café i", ["A", "b", "c", "d", "e"], changedHash),
            terminal: [terminal(old)]), .eligible)
    }

    func testActiveAssignmentsOnlySuppressIDAndExactContent() {
        let candidate = metadata("new", "objective", ["a", "b", "c", "d"], changedHash)
        let active = metadata("old", "objective", ["a", "b", "c", "d"], teachingHash)
        XCTAssertEqual(LessonDeduplication.decide(candidate: candidate, terminal: [], active: [active]), .eligible)
        XCTAssertEqual(LessonDeduplication.decide(candidate: metadata("old", "different", ["z"], changedHash),
            terminal: [], active: [active]), .rejected(.activeID))
        XCTAssertEqual(LessonDeduplication.decide(candidate: metadata("new", "different", ["z"]),
            terminal: [], active: [active]), .rejected(.exactContent))
    }

    func testInvalidCandidatesAndPartialTerminalEvidenceHaveFiniteSafeReasons() {
        for candidate in [metadata(" "), metadata("new", "  "),
                          metadata("new", "x", []), metadata("new", "x", [" "]),
                          metadata("new", "x", [" a"]), metadata("new", "x", ["a"], "untrusted") ] {
            XCTAssertEqual(LessonDeduplication.decide(candidate: candidate, terminal: []),
                           .rejected(.invalidMetadata))
        }
        XCTAssertEqual(LessonDeduplication.decide(candidate: metadata("new", "x", ["a"], changedHash),
            terminal: [terminal(metadata("old", nil, nil, teachingHash))]), .eligible)
        XCTAssertEqual(LessonDeduplication.decide(candidate: metadata("new", "x", ["a"]),
            terminal: [terminal(metadata("old", nil, nil, teachingHash))]), .rejected(.exactContent))
        let diagnostic = String(describing: LessonDeduplication.decide(
            candidate: metadata("answer is private", nil, ["a"]), terminal: []))
        XCTAssertFalse(diagnostic.contains("answer is private"))
        XCTAssertTrue(diagnostic.contains("invalidMetadata"))
        XCTAssertFalse(diagnostic.contains("answer"))
    }
}
