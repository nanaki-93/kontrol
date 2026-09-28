import Foundation
import XCTest
@testable import Kontrol

final class LessonSelectorTests: XCTestCase {
    private let early = Date(timeIntervalSinceReferenceDate: 100)
    private let later = Date(timeIntervalSinceReferenceDate: 200)

    private func lesson(_ id: String, topic: String = "go", subtopic: String = "one",
                        format: String = "learn", difficulty: String = "basic",
                        source: String = "seed", concepts: [String] = ["root"],
                        requires: [String] = [], body: String? = nil) -> LessonDefinitionSnapshot {
        LessonDefinitionSnapshot(id: id, objectiveKey: "objective.\(id)", objective: "Learn \(id)",
                                 title: id, topicID: topic, subtopicID: subtopic,
                                 conceptIDs: concepts, difficulty: difficulty, format: format,
                                 estimatedMinutes: 10, prerequisiteConceptIDs: requires,
                                 explanation: body ?? "Explanation \(id)", workedExample: "Example",
                                 exercise: "Exercise", referenceAnswer: "Answer",
                                 selfCheckCriteria: ["Check"], contentVersion: 1,
                                 normalizedContentHash: "hash", source: source, provenance: "test")
    }

    private func slot(_ id: String, _ index: Int, topic: String = "go",
                      date: Date = Date(timeIntervalSinceReferenceDate: 100)) -> LessonSlotSnapshot {
        LessonSlotSnapshot(topicID: topic, slotIndex: index, lessonID: id, assignedAt: date)
    }

    private func select(_ lessons: [LessonDefinitionSnapshot],
                        concepts: [LearningConceptSnapshot] = [],
                        progress: [LessonProgressSnapshot] = [],
                        slots: [LessonSlotSnapshot] = [], now: Date? = nil) throws -> [LessonSlotSnapshot] {
        try LessonSelector.reconcile(definitions: lessons, concepts: concepts,
                                     progress: progress, slots: slots, now: now ?? later)
    }

    func testPackagedCurriculumProducesTwentyDistinctInitialChoices() throws {
        let catalog = try BundledCatalogLoader.load().value
        let definitions = catalog.lessons.map { lesson in
            LessonDefinitionSnapshot(id: lesson.id, objectiveKey: lesson.objectiveKey,
                                     objective: lesson.objective, title: lesson.title,
                                     topicID: lesson.topicID, subtopicID: lesson.subtopicID,
                                     conceptIDs: lesson.conceptIDs, difficulty: lesson.difficulty,
                                     format: lesson.format, estimatedMinutes: lesson.estimatedMinutes,
                                     prerequisiteConceptIDs: lesson.prerequisiteConceptIDs,
                                     explanation: lesson.explanation, workedExample: lesson.workedExample,
                                     exercise: lesson.exercise, referenceAnswer: lesson.referenceAnswer,
                                     selfCheckCriteria: lesson.selfCheckCriteria,
                                     contentVersion: lesson.contentVersion,
                                     normalizedContentHash: lesson.normalizedContentHash,
                                     source: lesson.source, provenance: lesson.provenance)
        }
        let concepts = catalog.concepts.map {
            LearningConceptSnapshot(id: $0.id, subtopicID: $0.subtopicID, name: $0.name,
                                    prerequisiteConceptIDs: $0.prerequisiteConceptIDs)
        }
        let selected = try select(definitions, concepts: concepts)
        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(Set(selected.map(\.lessonID)).count, 20)
        for topic in catalog.topics {
            XCTAssertEqual(selected.filter { $0.topicID == topic.id }.map(\.slotIndex), [0, 1, 2, 3])
        }
        XCTAssertEqual(try select(definitions.reversed(), concepts: concepts.reversed(),
                                  slots: selected, now: early), selected)
    }

    func testStableOrderingAcrossFetchOrderTimeAndLocaleAndIdempotence() throws {
        let lessons = [lesson("z", subtopic: "one", format: "learn"),
                       lesson("a", subtopic: "one", format: "code"),
                       lesson("b", subtopic: "two", format: "learn"),
                       lesson("c", subtopic: "three", format: "design"),
                       lesson("d", subtopic: "four", format: "question"),
                       lesson("j", topic: "java")]
        let expected = try select(lessons)
        XCTAssertEqual(expected.filter { $0.topicID == "go" }.map(\.lessonID), ["a", "b", "c", "d"])
        XCTAssertEqual(expected.map(\.topicID), ["go", "go", "go", "go", "java"])
        XCTAssertEqual(expected.filter { $0.topicID == "go" }.map(\.slotIndex), [0, 1, 2, 3])
        XCTAssertEqual(try select(lessons.reversed(), now: later), expected)
        // A different wall clock changes only timestamps of NEW slots, not identity.
        XCTAssertEqual(try select(lessons.reversed(), now: early).map(\.lessonID),
                       expected.map(\.lessonID))
        for locale in ["tr_TR", "sv_SE", "en_US"] {
            let previous = UserDefaults.standard.array(forKey: "AppleLanguages")
            UserDefaults.standard.set([locale], forKey: "AppleLanguages")
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: "AppleLanguages") }
                else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            }
            XCTAssertEqual(try select(lessons.reversed()).map(\.lessonID), expected.map(\.lessonID))
        }
        XCTAssertEqual(try select(lessons, slots: expected, now: early), expected)
    }

    func testPreservesStartedSlotDespiteNewPrerequisiteAndRecoversUnslottedStartedFirst() throws {
        let lessons = [lesson("held", requires: ["not-practiced"]), lesson("started"),
                       lesson("a"), lesson("b"), lesson("c")]
        let progress = [LessonProgressSnapshot(lessonID: "held", status: .started, startedAt: early),
                        LessonProgressSnapshot(lessonID: "started", status: .started,
                                               startedAt: early)]
        let existing = slot("held", 2, date: early)
        let result = try select(lessons, progress: progress, slots: [existing])
        XCTAssertEqual(result[2], existing)
        XCTAssertEqual(result[0].lessonID, "started")
        XCTAssertEqual(result[0].assignedAt, later)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(progress[1].startedAt, early) // Values are not mutated.
    }

    func testVacatesMissingWrongTopicAndFinishedSlotsWithoutMovingValidOnes() throws {
        let lessons = [lesson("wrong", topic: "java"), lesson("done"), lesson("dismissed"),
                       lesson("kept"), lesson("new"), lesson("reserve")]
        let old = [slot("missing", 0), slot("wrong", 1), slot("done", 2),
                   slot("kept", 3, date: early), slot("dismissed", 0, topic: "java")]
        let progress = [LessonProgressSnapshot(lessonID: "done", status: .completed),
                        LessonProgressSnapshot(lessonID: "dismissed", status: .dismissed)]
        let result = try select(lessons, progress: progress, slots: old)
        XCTAssertEqual(result.filter { $0.topicID == "go" }.map(\.lessonID),
                       ["new", "reserve", "kept"])
        XCTAssertEqual(result.first { $0.lessonID == "kept" }, old[3])
        XCTAssertEqual(result.first { $0.lessonID == "wrong" }?.topicID, "java")
        XCTAssertEqual(result.first { $0.lessonID == "wrong" }?.slotIndex, 0)
    }

    func testCompletedConceptsIncludeTransitivePrerequisitesButNotStartedOrDismissed() throws {
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "s", name: "Root",
                                                prerequisiteConceptIDs: []),
                        LearningConceptSnapshot(id: "middle", subtopicID: "s", name: "Middle",
                                                prerequisiteConceptIDs: ["root"]),
                        LearningConceptSnapshot(id: "top", subtopicID: "s", name: "Top",
                                                prerequisiteConceptIDs: ["middle"])]
        let lessons = [lesson("completed", concepts: ["top"]),
                       lesson("eligible", requires: ["root"]),
                       lesson("blocked", requires: ["other"])]
        XCTAssertEqual(try select(lessons, concepts: concepts,
                                  progress: [.init(lessonID: "completed", status: .completed)])
            .map(\.lessonID), ["eligible"])
        XCTAssertEqual(try select(lessons, concepts: concepts,
                                  progress: [.init(lessonID: "completed", status: .dismissed)])
            .map(\.lessonID), [])
        XCTAssertEqual(try select(lessons, concepts: concepts,
                                  progress: [.init(lessonID: "completed", status: .started)])
            .map(\.lessonID), ["completed"])
    }

    func testExactNFCTrimmedRepeatAndUnsupportedCandidatesAreExcludedOnExhaustion() throws {
        let base = lesson("done", body: " Café ")
        let repeatLesson = lesson("repeat", body: "Cafe\u{301}")
        let active = lesson("active", body: "Active")
        let activeRepeat = lesson("active-repeat", body: "  Active\n")
        let unsupported = [lesson("bad-format", format: "video"),
                           lesson("bad-difficulty", difficulty: "expert"),
                           lesson("bad-source", source: "other")]
        let result = try select([base, repeatLesson, active, activeRepeat] + unsupported,
                                progress: [.init(lessonID: "done", status: .completed)],
                                slots: [slot("active", 2, date: early)])
        XCTAssertEqual(result, [slot("active", 2, date: early)])
        XCTAssertEqual(try select([lesson("a")]).map(\.lessonID), ["a"])
        XCTAssertTrue(try select([base], progress: [.init(lessonID: "done", status: .dismissed)]).isEmpty)
    }

    func testStartedRecoveryHonorsEligibilityAndRepeatExclusion() throws {
        let lessons = [lesson("started-ineligible", requires: ["missing"]),
                       lesson("started-repeat", body: "same"),
                       lesson("finished", body: " same "), lesson("available")]
        let progress = [LessonProgressSnapshot(lessonID: "started-ineligible", status: .started),
                        LessonProgressSnapshot(lessonID: "started-repeat", status: .started),
                        LessonProgressSnapshot(lessonID: "finished", status: .dismissed)]
        XCTAssertEqual(try select(lessons, progress: progress).map(\.lessonID), ["available"])
    }

    func testContradictorySlotsAndDuplicateInputsThrowBeforeVacating() throws {
        let lessons = [lesson("a"), lesson("b")]
        XCTAssertThrowsError(try select(lessons, slots: [slot("a", 0), slot("b", 0)])) {
            XCTAssertEqual($0 as? LessonSelectionError, .duplicateSlotKey)
        }
        XCTAssertThrowsError(try select(lessons, slots: [slot("a", 0), slot("a", 1)])) {
            XCTAssertEqual($0 as? LessonSelectionError, .duplicateSlottedLesson)
        }
        XCTAssertThrowsError(try select(lessons, slots: [slot("a", 4)])) {
            XCTAssertEqual($0 as? LessonSelectionError, .invalidSlotIdentity)
        }
        let corrupt = LessonSlotSnapshot(key: "wrong", topicID: "go", slotIndex: 0,
                                         lessonID: "missing", assignedAt: early)
        XCTAssertThrowsError(try select(lessons, slots: [corrupt])) {
            XCTAssertEqual($0 as? LessonSelectionError, .invalidSlotIdentity)
        }
        XCTAssertThrowsError(try select([lessons[0], lessons[0]])) {
            XCTAssertEqual($0 as? LessonSelectionError, .duplicateDefinition)
        }
        XCTAssertThrowsError(try select(lessons, progress: [.init(lessonID: "a", status: .started),
                                                         .init(lessonID: "a", status: .completed)])) {
            XCTAssertEqual($0 as? LessonSelectionError, .duplicateProgress)
        }
    }
}
