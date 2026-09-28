import Foundation
import XCTest
@testable import Kontrol

final class LessonExperienceTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_730_000_000)

    private func definition(_ format: String) -> LessonDefinitionSnapshot {
        .init(id: "lesson-\(format)", objectiveKey: "objective-key", objective: "Objective 🧪\nline 2",
              title: "Title \(format)", topicID: "topic", subtopicID: "subtopic",
              conceptIDs: ["concept-b", "concept-a"], difficulty: "intermediate", format: format,
              estimatedMinutes: 27, prerequisiteConceptIDs: ["prereq-2", "prereq-1"],
              explanation: "  Explanation 🧪\n\n", workedExample: "    example\n",
              exercise: "Prompt\n    indent", referenceAnswer: "  reference\n答え\n",
              selfCheckCriteria: [" first ", "second\nline"], contentVersion: 9,
              normalizedContentHash: "hash-\(format)", source: "generated",
              provenance: "author/source 🧪")
    }

    private func attempt(_ format: String = "code") throws -> LessonAttemptSnapshot {
        let definition = definition(format)
        return LessonAttemptSnapshot(id: UUID(), lessonID: definition.id,
                                     contentVersion: definition.contentVersion,
                                     pinnedContentData: try PinnedLessonContent(definition: definition).encoded())
    }

    private func progress(_ attempt: LessonAttemptSnapshot, status: LessonProgressStatus = .started,
                          startedAt: Date? = Date(timeIntervalSince1970: 1_730_000_000)) -> LessonProgressSnapshot {
        .init(lessonID: attempt.lessonID, status: status, startedAt: startedAt)
    }

    func testAllFourFormatsRoundTripCompleteStudiedDefinitionAndLegacyShape() throws {
        for format in ["learn", "code", "question", "design"] {
            let original = definition(format)
            let data = try PinnedLessonContent(definition: original).encoded()
            let pin = try PinnedLessonContent.decode(data, lessonID: original.id,
                                                      contentVersion: original.contentVersion)
            XCTAssertEqual(pin.definition, original)
            XCTAssertEqual(pin.envelopeVersion, 1)
            let a = try attempt(format)
            XCTAssertEqual(try LessonExperience.studiedContent(a), .pinned(original))
            let completed = try LessonExperience.complete(
                LessonExperience.acknowledge(
                    LessonExperience.reveal(a, status: .started, expectedRevision: 0, now: time),
                    status: .started, expectedRevision: 1, acknowledged: true, now: time),
                progress: progress(a), expectedRevision: 2, now: time)
            XCTAssertEqual(completed.completedContentSnapshot, pin.completedSnapshot)
            XCTAssertEqual(try LessonExperience.studiedContent(completed), .pinned(original))
            XCTAssertEqual(try LessonExperience.complete(completed,
                                                         progress: progress(a, status: .completed),
                                                         expectedRevision: 0, now: time), completed)
            XCTAssertEqual(try LessonExperience.studiedContent(completed), .pinned(original))
            // The released V1 Codable representation has no V5 metadata.
            let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pin.completedSnapshot)) as? [String: Any])
            XCTAssertEqual(Set(keys.keys), Set(["title", "objectiveKey", "conceptIDs", "difficulty", "format",
                                                "explanation", "workedExample", "exercise", "referenceAnswer",
                                                "selfCheckCriteria"]))
        }
    }

    func testInvalidMissingAndMismatchedPinsFailWithoutCurrentCatalogFallback() throws {
        let a = try attempt()
        XCTAssertThrowsError(try PinnedLessonContent.decode(a.pinnedContentData, lessonID: "other", contentVersion: 9)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try PinnedLessonContent.decode(a.pinnedContentData, lessonID: a.lessonID, contentVersion: 10)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        for data in [Data("not json".utf8), Data("{}".utf8), Data("{\"envelopeVersion\":2,\"definition\":{}}".utf8)] {
            XCTAssertThrowsError(try PinnedLessonContent.decode(data, lessonID: a.lessonID, contentVersion: 9)) {
                XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
            }
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: a.pinnedContentData!) as? [String: Any])
        var future = object
        future["envelopeVersion"] = 2
        XCTAssertThrowsError(try PinnedLessonContent.decode(JSONSerialization.data(withJSONObject: future),
                                                             lessonID: a.lessonID, contentVersion: 9)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        var unexpected = object
        unexpected["futureField"] = "cannot ignore"
        XCTAssertThrowsError(try PinnedLessonContent.decode(JSONSerialization.data(withJSONObject: unexpected),
                                                             lessonID: a.lessonID, contentVersion: 9)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        var incomplete = object
        var fields = try XCTUnwrap(incomplete["definition"] as? [String: Any])
        fields.removeValue(forKey: "provenance")
        incomplete["definition"] = fields
        XCTAssertThrowsError(try PinnedLessonContent.decode(JSONSerialization.data(withJSONObject: incomplete),
                                                             lessonID: a.lessonID, contentVersion: 9)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try PinnedLessonContent.decode(nil, lessonID: a.lessonID, contentVersion: 9)) {
            XCTAssertEqual($0 as? LessonExperienceError, .contentUnavailable)
        }
        let missing = LessonAttemptSnapshot(id: a.id, lessonID: a.lessonID,
                                            contentVersion: a.contentVersion, answerDraft: "retain")
        XCTAssertEqual(try LessonExperience.studiedContent(missing), .unavailable)
        XCTAssertThrowsError(try LessonExperience.complete(missing, progress: progress(missing),
                                                            expectedRevision: 0, now: time))
        let corrupt = LessonAttemptSnapshot(id: a.id, lessonID: "other", contentVersion: 9,
                                            pinnedContentData: a.pinnedContentData)
        XCTAssertThrowsError(try LessonExperience.studiedContent(corrupt)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try LessonExperience.reveal(corrupt, status: .started,
                                                          expectedRevision: 0, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try LessonExperience.edit(missing, status: .started,
                                                        expectedRevision: 0, answer: "new")) {
            XCTAssertEqual($0 as? LessonExperienceError, .contentUnavailable)
        }
        let archived = LessonAttemptSnapshot(id: a.id, lessonID: a.lessonID, contentVersion: 9,
                                              answerDraft: "historical", completedAt: time,
                                              completedContentSnapshot: PinnedLessonContent(definition: definition("code")).completedSnapshot)
        XCTAssertEqual(try LessonExperience.studiedContent(archived),
                       .legacyCompleted(PinnedLessonContent(definition: definition("code")).completedSnapshot))
        XCTAssertEqual(try LessonExperience.complete(archived, progress: progress(a, status: .completed),
                                                      expectedRevision: -1, now: time), archived)
        let corruptArchive = LessonAttemptSnapshot(id: a.id, lessonID: a.lessonID, contentVersion: 9,
                                                    completedAt: time,
                                                    completedContentSnapshot: archived.completedContentSnapshot,
                                                    pinnedContentData: Data("bad pin".utf8))
        XCTAssertThrowsError(try LessonExperience.complete(corruptArchive,
                                                            progress: progress(a, status: .completed),
                                                            expectedRevision: 0, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
    }

    func testGatesExactEmptyAnswerIdempotenceAndEditAfterAcknowledgement() throws {
        let a = try attempt()
        XCTAssertThrowsError(try LessonExperience.complete(a, progress: progress(a),
                                                            expectedRevision: 0, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .completionRequirementsMissing)
        }
        XCTAssertThrowsError(try LessonExperience.acknowledge(a, status: .started,
                                                               expectedRevision: 0, acknowledged: true, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
        }
        let revealed = try LessonExperience.reveal(a, status: .started, expectedRevision: 0, now: time)
        XCTAssertEqual(revealed.revision, 1)
        XCTAssertEqual(try LessonExperience.reveal(revealed, status: .started,
                                                   expectedRevision: 0, now: time.addingTimeInterval(5)), revealed)
        XCTAssertEqual(revealed.solutionRevealedAt, time)
        XCTAssertThrowsError(try LessonExperience.complete(revealed, progress: progress(a),
                                                            expectedRevision: 1, now: time))
        let checked = try LessonExperience.acknowledge(revealed, status: .started,
                                                       expectedRevision: 1, acknowledged: true, now: time)
        XCTAssertEqual(try LessonExperience.acknowledge(checked, status: .started,
                                                       expectedRevision: 0, acknowledged: true,
                                                       now: time.addingTimeInterval(5)), checked)
        XCTAssertEqual(checked.selfCheckAcknowledgedAt, time)
        XCTAssertEqual(try LessonExperience.edit(checked, status: .started,
                                                 expectedRevision: 2, answer: ""), checked)
        let completed = try LessonExperience.complete(checked, progress: progress(a),
                                                      expectedRevision: 2, now: time)
        XCTAssertEqual(completed.answerDraft, "")
        XCTAssertEqual(completed.selfCheckAcknowledgedAt, time)
        XCTAssertEqual(try LessonExperience.complete(completed, progress: progress(a, status: .completed),
                                                      expectedRevision: 0, now: time.addingTimeInterval(5)), completed)
        XCTAssertThrowsError(try LessonExperience.edit(completed, status: .completed,
                                                       expectedRevision: 3, answer: "late"))
        let edited = try LessonExperience.edit(checked, status: .started,
                                               expectedRevision: 2, answer: "  🧪\n    code\n\n")
        XCTAssertEqual(edited.answerDraft, "  🧪\n    code\n\n")
        XCTAssertNil(edited.selfCheckAcknowledgedAt)
        XCTAssertEqual(edited.solutionRevealedAt, time)
        XCTAssertThrowsError(try LessonExperience.complete(edited, progress: progress(a),
                                                            expectedRevision: 3, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .completionRequirementsMissing)
        }
        XCTAssertThrowsError(try LessonExperience.edit(edited, status: .started,
                                                       expectedRevision: 2, answer: "stale")) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleRevision)
        }
        XCTAssertThrowsError(try LessonExperience.edit(edited, status: .dismissed,
                                                       expectedRevision: 3, answer: "late")) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
        }
        let rechecked = try LessonExperience.acknowledge(edited, status: .started,
                                                         expectedRevision: 3, acknowledged: true, now: time)
        let cleared = try LessonExperience.acknowledge(rechecked, status: .started,
                                                       expectedRevision: 4, acknowledged: false, now: time)
        XCTAssertNil(cleared.selfCheckAcknowledgedAt)
        XCTAssertEqual(try LessonExperience.acknowledge(cleared, status: .started,
                                                        expectedRevision: 0, acknowledged: false, now: time), cleared)
        XCTAssertThrowsError(try LessonExperience.complete(rechecked,
                                                            progress: progress(a, startedAt: nil),
                                                            expectedRevision: 4, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .completionRequirementsMissing)
        }
    }

    func testRepeatedTransitionsStillValidateActiveStateAndPinBeforeIdempotence() throws {
        let a = try attempt()
        let revealed = try LessonExperience.reveal(a, status: .started, expectedRevision: 0, now: time)
        let checked = try LessonExperience.acknowledge(revealed, status: .started,
                                                       expectedRevision: 1, acknowledged: true, now: time)
        for status in [LessonProgressStatus.dismissed, .completed] {
            XCTAssertThrowsError(try LessonExperience.reveal(revealed, status: status,
                                                              expectedRevision: 0, now: time)) {
                XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
            }
            XCTAssertThrowsError(try LessonExperience.acknowledge(checked, status: status,
                                                                   expectedRevision: 0,
                                                                   acknowledged: true, now: time)) {
                XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
            }
        }
        let corrupt = LessonAttemptSnapshot(id: a.id, lessonID: a.lessonID, contentVersion: a.contentVersion,
                                            solutionRevealedAt: time, selfCheckAcknowledgedAt: time,
                                            pinnedContentData: Data("corrupt".utf8), revision: 2)
        XCTAssertThrowsError(try LessonExperience.reveal(corrupt, status: .started,
                                                          expectedRevision: 0, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try LessonExperience.acknowledge(corrupt, status: .started,
                                                               expectedRevision: 0, acknowledged: true, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try LessonExperience.acknowledge(revealed, status: .started,
                                                               expectedRevision: 0, acknowledged: true, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleRevision)
        }
        XCTAssertThrowsError(try LessonExperience.acknowledge(checked, status: .started,
                                                               expectedRevision: 1, acknowledged: false, now: time)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleRevision)
        }
    }
}
