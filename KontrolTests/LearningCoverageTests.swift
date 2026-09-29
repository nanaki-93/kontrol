import Foundation
import XCTest
@testable import Kontrol

final class LearningCoverageTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 100)
    private let late = Date(timeIntervalSince1970: 200)

    private func membership(_ ids: [String] = ["a", "b", "c"],
                            subtopics: [String] = ["one", "two"]) -> CatalogMembershipAvailability {
        .available(CurrentCatalogMembership(catalogID: "catalog", catalogVersion: 2,
            topicIDs: ["topic"], subtopicIDs: subtopics, conceptIDs: ids.sorted(), seededLessonIDs: []))
    }

    private var topics: [LearningTopicSnapshot] { [.init(id: "topic", name: "Topic")] }
    private var subtopics: [LearningSubtopicSnapshot] {
        [.init(id: "one", topicID: "topic", name: "One"),
         .init(id: "two", topicID: "topic", name: "Two")]
    }
    private var concepts: [LearningConceptSnapshot] {
        [.init(id: "a", subtopicID: "one", name: "A", prerequisiteConceptIDs: ["b"]),
         .init(id: "b", subtopicID: "one", name: "B", prerequisiteConceptIDs: []),
         .init(id: "c", subtopicID: "two", name: "C", prerequisiteConceptIDs: [])]
    }

    private func completion(_ id: String, _ date: Date?, _ ids: [String]?,
                            _ status: LessonProgressStatus = .completed,
                            _ provenance: TerminalMetadataProvenance = .legacyCompletedPartial) -> CoverageCompletionEvidence {
        let metadata = LessonTerminalMetadata(lessonID: id, provenance: provenance,
            title: nil, topicID: nil, subtopicID: nil, contentVersion: nil,
            objectiveKey: nil, conceptIDs: ids, normalizedContentHash: nil,
            format: nil, dismissalTimeDefinition: nil)
        return CoverageCompletionEvidence(lessonID: id, status: status, completedAt: date, metadata: metadata)
    }

    private func coverage(_ membership: CatalogMembershipAvailability? = nil,
                          _ concepts: [LearningConceptSnapshot]? = nil,
                          _ completions: [CoverageCompletionEvidence] = []) throws -> [SubtopicCoverageSnapshot] {
        let snapshot = try LearningCoverage.aggregate(membership: membership ?? self.membership(),
            topics: topics, subtopics: subtopics, concepts: concepts ?? self.concepts, completions: completions)
        guard case let .available(catalogID, version, rows, _) = snapshot else {
            XCTFail("Expected available membership"); return []
        }
        XCTAssertEqual(catalogID, "catalog")
        XCTAssertEqual(version, 2)
        return rows
    }

    func testDistinctDirectCompletionsAndLatestActualDate() throws {
        let rows = try coverage(nil, nil, [completion("first", early, ["a"]),
            completion("second", late, ["a"]), completion("older", early, ["a"]),
            completion("dismissed", late, ["b"], .dismissed),
            completion("started", late, ["b"], .started),
            completion("available", late, ["b"], .available),
            completion("reference", late, ["b"], .completed, .dismissalReference)])
        XCTAssertEqual(rows.map(\.practicedConceptCount), [1, 0])
        XCTAssertEqual(rows.map(\.topicName), ["Topic", "Topic"])
        XCTAssertEqual(rows.map(\.currentConceptCount), [2, 1])
        XCTAssertEqual(rows[0].concepts.map(\.latestCompletion), [late, nil])
        XCTAssertEqual(rows[0].latestCompletion, late)
        // The reference cannot establish practice even if erroneously labeled completed.
        let snapshot = try LearningCoverage.aggregate(membership: membership(), topics: topics,
            subtopics: subtopics, concepts: concepts,
            completions: [completion("reference", late, ["b"], .completed, .dismissalReference)])
        if case let .available(_, _, _, evidence) = snapshot {
            XCTAssertEqual(evidence, .incomplete(completedLessonIDs: ["reference"]))
        } else { XCTFail("Expected incomplete evidence") }
    }

    func testCurrentMembershipAdditionRemovalRetirementAndReassignment() throws {
        let historical = [completion("historical", early, ["a", "c", "retired"])]
        let original = try coverage(nil, nil, historical)
        XCTAssertEqual(original.map(\.practicedConceptCount), [1, 1])
        let changed = [LearningConceptSnapshot(id: "a", subtopicID: "two", name: "Moved", prerequisiteConceptIDs: []),
                       LearningConceptSnapshot(id: "b", subtopicID: "one", name: "B", prerequisiteConceptIDs: []),
                       LearningConceptSnapshot(id: "added", subtopicID: "one", name: "Added", prerequisiteConceptIDs: ["a"]),
                       LearningConceptSnapshot(id: "c", subtopicID: "two", name: "Retired", prerequisiteConceptIDs: [])]
        let rows = try coverage(membership(["a", "added", "b"]), changed, historical)
        XCTAssertEqual(rows.map(\.currentConceptCount), [2, 1])
        XCTAssertEqual(rows.map(\.practicedConceptCount), [0, 1])
        XCTAssertEqual(rows[1].concepts.first?.latestCompletion, early)
        XCTAssertNil(rows[0].concepts.first?.latestCompletion) // prerequisites do not count
    }

    func testZeroDenominatorAndUnavailableMembershipAreDifferent() throws {
        let zero = try coverage(membership([], subtopics: ["one"]), nil,
                                [completion("old", early, ["a"])])
        XCTAssertEqual(zero[0].currentConceptCount, 0)
        XCTAssertEqual(zero[0].practicedConceptCount, 0)
        XCTAssertEqual(zero[0].concepts, [])
        XCTAssertEqual(try LearningCoverage.aggregate(membership: .unavailable,
            topics: topics, subtopics: subtopics, concepts: concepts, completions: []), .membershipUnavailable)
    }

    func testUnknownLegacyEvidenceIsNotPresentedAsZeroOrInferredFromDefinitions() throws {
        let missing = CoverageCompletionEvidence(lessonID: "unknown", status: .completed,
                                                  completedAt: early, metadata: nil)
        let snapshot = try LearningCoverage.aggregate(membership: membership(), topics: topics,
            subtopics: subtopics, concepts: concepts, completions: [missing,
                completion("partial", late, nil), completion("no-date", nil, ["a"]),
                completion("known", early, ["b"])])
        guard case let .available(_, _, rows, evidence) = snapshot else { return XCTFail("Unavailable") }
        XCTAssertEqual(rows[0].practicedConceptCount, 1)
        XCTAssertNil(rows[0].concepts[0].latestCompletion)
        XCTAssertEqual(evidence, .incomplete(completedLessonIDs: ["no-date", "partial", "unknown"]))
    }

    func testOverviewGroupsCurrentSubtopicsAndDistinguishesKnownFromIncompleteCounts() throws {
        let rows = try coverage(membership([], subtopics: ["one", "two"]))
        XCTAssertEqual(LearningCoverageView.groups(rows).map(\.id), ["topic"])
        XCTAssertEqual(LearningCoverageView.groups(rows)[0].subtopics.map(\.id), ["one", "two"])
        XCTAssertEqual(LearningCoverageView.countLabel(rows[0], evidence: .complete),
                       "0 of 0 concepts practiced")
        XCTAssertEqual(LearningCoverageView.countLabel(rows[0],
            evidence: .incomplete(completedLessonIDs: ["legacy"])),
            "0 of 0 concepts practiced (known evidence only)")
    }

    func testInconsistentCurrentTaxonomyFailsRatherThanProducingFalseZero() {
        XCTAssertThrowsError(try coverage(membership(["missing"]))) { error in
            XCTAssertEqual(error as? LearningEvidenceError, .invalidPayload)
        }
    }
}
