import Foundation
import XCTest
@testable import Kontrol

final class LessonSelectorTests: XCTestCase {
    private let early = Date(timeIntervalSinceReferenceDate: 100)
    private let later = Date(timeIntervalSinceReferenceDate: 200)

    private func lesson(_ id: String, topic: String = "go", subtopic: String = "one",
                        format: String = "learn", difficulty: String = "basic",
                        source: String = "seed", concepts: [String] = [],
                        requires: [String] = [], body: String? = nil) -> LessonDefinitionSnapshot {
        let subtopicID = topic == "go" ? subtopic : "\(topic)-\(subtopic)"
        let conceptIDs = concepts.isEmpty ? [topic == "go" && subtopic == "one" ? "root" :
                                            "\(topic).\(subtopic).root"] : concepts
        return LessonDefinitionSnapshot(id: id, objectiveKey: "objective.\(id)", objective: "Learn \(id)",
                                 title: id, topicID: topic, subtopicID: subtopicID,
                                 conceptIDs: conceptIDs, difficulty: difficulty, format: format,
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

    private func subtopics(_ lessons: [LessonDefinitionSnapshot],
                           concepts: [LearningConceptSnapshot]) -> [LearningSubtopicSnapshot] {
        let owners = Dictionary(lessons.map { ($0.subtopicID, $0.topicID) },
                                uniquingKeysWith: { first, _ in first })
        return Set(lessons.map(\.subtopicID) + concepts.map(\.subtopicID)).sorted().map {
            LearningSubtopicSnapshot(id: $0, topicID: owners[$0] ?? "go", name: $0)
        }
    }

    private func select(_ lessons: [LessonDefinitionSnapshot],
                        concepts: [LearningConceptSnapshot] = [],
                        progress: [LessonProgressSnapshot] = [],
                        slots: [LessonSlotSnapshot] = [], now: Date? = nil) throws -> [LessonSlotSnapshot] {
        let known = Set(concepts.map(\.id))
        let extras = Set(lessons.flatMap(\.conceptIDs)).subtracting(known).map { id in
            LearningConceptSnapshot(id: id, subtopicID: lessons.first { $0.conceptIDs.contains(id) }!.subtopicID,
                                    name: id, prerequisiteConceptIDs: [])
        }
        let terminal = progress.filter { $0.status == .completed || $0.status == .dismissed }
            .compactMap { row -> TerminalLessonMatch? in
                guard let lesson = lessons.first(where: { $0.id == row.lessonID }) else { return nil }
                return TerminalLessonMatch(status: row.status, metadata: LessonMatchMetadata(lesson))
            }
        return try LessonSelector.reconcile(definitions: lessons, concepts: concepts + extras,
            subtopics: subtopics(lessons, concepts: concepts + extras),
            progress: progress, slots: slots, terminal: terminal,
            completedConceptIDs: Set(progress.filter { $0.status == .completed }
                .flatMap { row in lessons.first(where: { $0.id == row.lessonID })?.conceptIDs ?? [] }),
            now: now ?? later)
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

    func testReconcileRetainedSlotsAgainstEachOtherAfterContentUpgrade() throws {
        let first = slot("first", 0, date: early)
        let duplicate = slot("duplicate", 1, date: early)
        let untouched = slot("untouched", 2, date: early)
        let otherTopic = slot("java", 0, topic: "java", date: early)
        let lessons = [lesson("first", body: "Shared upgraded content"),
                       lesson("duplicate", body: " Shared upgraded content "),
                       lesson("untouched"), lesson("replacement"), lesson("java", topic: "java")]
        for existing in [[duplicate, otherTopic, untouched, first],
                         [first, untouched, otherTopic, duplicate]] {
            let result = try select(lessons, slots: existing)
            XCTAssertTrue(result.contains(first))
            XCTAssertTrue(result.contains(untouched))
            XCTAssertTrue(result.contains(otherTopic))
            XCTAssertFalse(result.contains(duplicate))
            XCTAssertEqual(result.first { $0.key == duplicate.key }?.lessonID, "replacement")
            XCTAssertEqual(result.first { $0.key == duplicate.key }?.assignedAt, later)
            XCTAssertEqual(try select(lessons, slots: result, now: .distantFuture), result)
        }
    }

    func testStartedPinWinsOverConflictingUnstartedSlotOnUpgrade() throws {
        let unstarted = slot("unstarted", 0, date: early)
        let pinned = slot("pinned", 2, date: early)
        let lessons = [lesson("unstarted", body: "Original pinned text"),
                       lesson("pinned", body: "Upgraded installed text"),
                       lesson("fresh", body: "Fresh text")]
        let result = try LessonSelector.reconcile(definitions: lessons,
            concepts: [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root",
                                               prerequisiteConceptIDs: [])],
            subtopics: subtopics(lessons, concepts: []),
            progress: [.init(lessonID: "pinned", status: .started)],
            slots: [unstarted, pinned], activePins: [StartedLessonEvidence(lesson("pinned", body: "Original pinned text"))],
            now: later)
        XCTAssertTrue(result.contains(pinned))
        XCTAssertFalse(result.contains(unstarted))
        XCTAssertEqual(result.first { $0.key == unstarted.key }?.lessonID, "fresh")
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

    private func replace(_ consumed: LessonSlotSnapshot,
                         lessons: [LessonDefinitionSnapshot],
                         concepts: [LearningConceptSnapshot] = [],
                         progress: [LessonProgressSnapshot],
                         slots: [LessonSlotSnapshot],
                         attempts: [LessonAttemptSnapshot] = []) throws -> [LessonSlotSnapshot] {
        let known = Set(concepts.map(\.id))
        let extras = Set(lessons.flatMap(\.conceptIDs)).subtracting(known).map { id in
            LearningConceptSnapshot(id: id, subtopicID: lessons.first { $0.conceptIDs.contains(id) }!.subtopicID,
                                    name: id, prerequisiteConceptIDs: [])
        }
        let terminal = try progress.filter { $0.status == .completed || $0.status == .dismissed }
            .map { row -> TerminalLessonMatch in
                if let attempt = attempts.first(where: { $0.lessonID == row.lessonID }),
                   let data = attempt.pinnedContentData {
                    let pin = try PinnedLessonContent.decode(data, lessonID: row.lessonID,
                                                               contentVersion: attempt.contentVersion)
                    return TerminalLessonMatch(status: row.status, metadata: LessonMatchMetadata(pin.definition))
                }
                let metadata = lessons.first(where: { $0.id == row.lessonID }).map(LessonMatchMetadata.init)
                    ?? LessonMatchMetadata(id: row.lessonID, objectiveKey: nil, conceptIDs: nil, contentHash: nil)
                return TerminalLessonMatch(status: row.status, metadata: metadata)
            }
        return try LessonSelector.replace(consumedSlot: consumed, definitions: lessons,
            concepts: concepts + extras, subtopics: subtopics(lessons, concepts: concepts + extras),
            progress: progress, slots: slots, terminal: terminal,
            completedConceptIDs: Set(progress.filter { $0.status == .completed }
                .flatMap { row in lessons.first(where: { $0.id == row.lessonID })?.conceptIDs ?? [] }),
            now: later)
    }

    func testReplacementTouchesOnlyConsumedKeyAndUsesF05DiversityAndStableOrdering() throws {
        let consumed = slot("done", 1, date: early)
        let other = slot("held", 2, date: early)
        let anotherTopic = slot("java-held", 0, topic: "java", date: early)
        let slots = [consumed, other, anotherTopic] // index 0 is already vacant
        let lessons = [lesson("done"), lesson("held"), lesson("java-held", topic: "java"),
                       lesson("z", subtopic: "new", format: "code"),
                       lesson("a", subtopic: "new", format: "code"),
                       lesson("b", subtopic: "one", format: "design")]
        let progress = [LessonProgressSnapshot(lessonID: "done", status: .completed)]
        let result = try replace(consumed, lessons: lessons, progress: progress, slots: slots)
        XCTAssertEqual(result, [slot("a", 1, date: later), other, anotherTopic])
        XCTAssertFalse(result.contains { $0.topicID == "go" && $0.slotIndex == 0 })
        XCTAssertEqual(try replace(consumed, lessons: lessons.reversed(), progress: progress,
                                   slots: slots.reversed()), result)
    }

    func testReplacementPrioritizesEligibleStartedAndCompletedPrerequisites() throws {
        let consumed = slot("done", 0)
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "s", name: "Root",
                                                prerequisiteConceptIDs: []),
                        LearningConceptSnapshot(id: "top", subtopicID: "s", name: "Top",
                                                prerequisiteConceptIDs: ["root"])]
        let lessons = [lesson("done", concepts: ["top"]), lesson("started", requires: ["root"]),
                       lesson("available", requires: ["root"]), lesson("blocked", requires: ["missing"]),
                       lesson("unsupported", format: "video")]
        let progress = [LessonProgressSnapshot(lessonID: "done", status: .completed),
                        LessonProgressSnapshot(lessonID: "started", status: .started)]
        XCTAssertEqual(try replace(consumed, lessons: lessons, concepts: concepts,
                                   progress: progress, slots: [consumed]),
                       [slot("started", 0, date: later)])
        XCTAssertEqual(try replace(consumed, lessons: lessons, concepts: concepts,
                                   progress: [.init(lessonID: "done", status: .dismissed)],
                                   slots: [consumed]), []) // dismissal unlocks nothing
    }

    func testTerminalPinsBlockStudiedContentAfterCatalogChanges() throws {
        let consumed = slot("done", 0)
        let studied = lesson("done", body: " Café ")
        let changed = lesson("done", body: "New installed exercise")
        let repeatStudied = lesson("repeat-studied", body: "Cafe\u{301}")
        let repeatInstalled = lesson("repeat-installed", body: "New installed exercise")
        let eligible = lesson("fresh")
        let pin = try PinnedLessonContent(definition: studied).encoded()
        let attempt = LessonAttemptSnapshot(id: UUID(), lessonID: "done", contentVersion: 1,
                                            pinnedContentData: pin)
        for status in [LessonProgressStatus.completed, .dismissed] {
            let result = try replace(consumed,
                lessons: [changed, repeatStudied, repeatInstalled, eligible],
                progress: [.init(lessonID: "done", status: status)], slots: [consumed],
                attempts: [attempt])
            XCTAssertEqual(result, [slot("fresh", 0, date: later)])
        }
        XCTAssertThrowsError(try replace(consumed, lessons: [changed, repeatStudied],
            progress: [.init(lessonID: "done", status: .completed)], slots: [consumed],
            attempts: [.init(id: UUID(), lessonID: "done", contentVersion: 2,
                             pinnedContentData: pin)])) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
    }

    func testExhaustionPreservesOtherVacanciesAndActiveExactContentExclusion() throws {
        let consumed = slot("done", 2)
        let held = slot("held", 3, date: early)
        let lessons = [lesson("done"), lesson("held"),
                       lesson("repeat-held", body: " Explanation held "),
                       lesson("repeat-done", body: " Explanation done "),
                       lesson("dismissed", body: "different"),
                       lesson("bad-difficulty", difficulty: "expert", body: "unique")]
        let result = try replace(consumed, lessons: lessons,
            progress: [.init(lessonID: "done", status: .completed),
                       .init(lessonID: "dismissed", status: .dismissed)],
            slots: [consumed, held])
        XCTAssertEqual(result, [held])
    }

    func testAllVacancyPathsUseArchivedOverlapAndCurrentMembership() throws {
        let done = lesson("done", concepts: ["a", "b", "c", "d", "e"], body: "Old text")
        let near = LessonDefinitionSnapshot(id: "near", objectiveKey: done.objectiveKey,
            objective: done.objective, title: "Renamed", topicID: "go", subtopicID: "one",
            conceptIDs: ["a", "b", "c", "d"], difficulty: "basic", format: "learn",
            estimatedMinutes: 10, prerequisiteConceptIDs: [], explanation: "New text",
            workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
            selfCheckCriteria: ["Check"], contentVersion: 1, normalizedContentHash: "hash",
            source: "seed", provenance: "test")
        let retired = lesson("retired", body: "Retired text")
        let fresh = lesson("fresh", body: "Fresh text")
        let definitions = [near, retired, fresh] // the archived definition is no longer installed
        let concepts = ["a", "b", "c", "d", "e", "root"].map {
            LearningConceptSnapshot(id: $0, subtopicID: "one", name: $0, prerequisiteConceptIDs: [])
        }
        let archive = TerminalLessonMatch(status: .completed, metadata: LessonMatchMetadata(done))
        let progress: [LessonProgressSnapshot] = [.init(lessonID: "done", status: .completed)]
        let membership = CatalogMembershipAvailability.available(.init(catalogID: "test",
            catalogVersion: 2, topicIDs: ["go"], subtopicIDs: ["one"],
            conceptIDs: ["a", "b", "c", "d", "e", "root"], seededLessonIDs: ["fresh", "near"]))
        let args = definitions
        XCTAssertEqual(try LessonSelector.reconcile(definitions: args, concepts: concepts,
            subtopics: subtopics(args, concepts: concepts), progress: progress, slots: [], terminal: [archive], membership: membership, now: later)
            .map(\.lessonID), ["fresh"])
        let consumed = slot("done", 0)
        XCTAssertEqual(try LessonSelector.replace(consumedSlot: consumed, definitions: args,
            concepts: concepts, subtopics: subtopics(args, concepts: concepts), progress: progress, slots: [consumed], terminal: [archive],
            membership: membership, now: later).map(\.lessonID), ["fresh"])
        let restored: [LessonProgressSnapshot] = [.init(lessonID: "near", status: .available),
            .init(lessonID: "done", status: .completed)]
        XCTAssertNil(try LessonSelector.restoredVacancy(lessonID: "near", definitions: args,
            concepts: concepts, subtopics: subtopics(args, concepts: concepts), progress: restored, slots: [], terminal: [archive],
            membership: membership, now: later))
        XCTAssertNil(try LessonSelector.restoredVacancy(lessonID: "retired", definitions: args,
            concepts: concepts, subtopics: subtopics(args, concepts: concepts), progress: [.init(lessonID: "retired", status: .available)],
            slots: [], membership: membership, now: later))
    }

    func testRestoreOnlyRemovesOwnDismissalAndInvalidCandidatesCannotFillVacancy() throws {
        let restored = lesson("restored")
        let another = lesson("another", body: " Explanation restored ")
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root",
                                                prerequisiteConceptIDs: [])]
        let available = [LessonProgressSnapshot(lessonID: "restored", status: .available)]
        XCTAssertNotNil(try LessonSelector.restoredVacancy(lessonID: "restored",
            definitions: [restored], concepts: concepts,
            subtopics: subtopics([restored], concepts: concepts),
            progress: available, slots: [], now: later))
        XCTAssertNil(try LessonSelector.restoredVacancy(lessonID: "restored",
            definitions: [restored], concepts: concepts,
            subtopics: subtopics([restored], concepts: concepts),
            progress: available, slots: [], terminal: [TerminalLessonMatch(status: .completed, metadata: LessonMatchMetadata(another))],
            now: later))
        let invalid = lesson("bad", concepts: ["missing"])
        XCTAssertTrue(try LessonSelector.reconcile(definitions: [invalid], concepts: concepts,
            subtopics: subtopics([invalid], concepts: concepts),
            progress: [], slots: [], now: later).isEmpty)
    }

    func testCrossTopicTaxonomyCannotFillAnyVacancy() throws {
        let taxonomy = [LearningSubtopicSnapshot(id: "one", topicID: "go", name: "Go"),
                        LearningSubtopicSnapshot(id: "java-one", topicID: "java", name: "Java")]
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root",
                                                prerequisiteConceptIDs: []),
                        LearningConceptSnapshot(id: "foreign", subtopicID: "java-one", name: "Foreign",
                                                prerequisiteConceptIDs: [])]
        let wrongSubtopic = LessonDefinitionSnapshot(id: "wrong-parent", objectiveKey: "wrong",
            objective: "wrong", title: "wrong", topicID: "go", subtopicID: "java-one",
            conceptIDs: ["root"], difficulty: "basic", format: "learn", estimatedMinutes: 10,
            prerequisiteConceptIDs: [], explanation: "Wrong parent", workedExample: "Example",
            exercise: "Exercise", referenceAnswer: "Answer", selfCheckCriteria: ["Check"],
            contentVersion: 1, normalizedContentHash: "hash", source: "seed", provenance: "test")
        let invalid = [wrongSubtopic, lesson("foreign-taught", concepts: ["foreign"], body: "Foreign taught"),
                       lesson("foreign-required", requires: ["foreign"], body: "Foreign required")]
        let completed: Set<String> = ["foreign"] // history cannot authorize a cross-topic prerequisite
        let consumed = slot("done", 0)
        for candidate in invalid {
            let available = [LessonProgressSnapshot(lessonID: candidate.id, status: .available)]
            XCTAssertTrue(try LessonSelector.reconcile(definitions: [candidate], concepts: concepts,
                subtopics: taxonomy, progress: available, slots: [],
                completedConceptIDs: completed, now: later).isEmpty, candidate.id)
            XCTAssertTrue(try LessonSelector.replace(consumedSlot: consumed, definitions: [candidate],
                concepts: concepts, subtopics: taxonomy,
                progress: available + [.init(lessonID: "done", status: .completed)],
                slots: [consumed], completedConceptIDs: completed, now: later).isEmpty, candidate.id)
            XCTAssertNil(try LessonSelector.restoredVacancy(lessonID: candidate.id,
                definitions: [candidate], concepts: concepts, subtopics: taxonomy,
                progress: available, slots: [], completedConceptIDs: completed, now: later), candidate.id)
        }
    }

    func testUnslottedStartedCandidateMatchesItsPinNotUpgradedDefinitionOnEveryPath() throws {
        let studied = lesson("started", body: "Pinned original")
        let upgraded = lesson("started", body: "Installed upgrade")
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root",
                                                prerequisiteConceptIDs: [])]
        let taxonomy = subtopics([upgraded], concepts: concepts)
        let progress: [LessonProgressSnapshot] = [.init(lessonID: "started", status: .started),
            .init(lessonID: "other", status: .completed),
            .init(lessonID: "done", status: .completed)]
        let pin = StartedLessonEvidence(studied)
        let consumed = slot("done", 0)
        for (terminalBody, shouldOffer) in [("Pinned original", false), ("Installed upgrade", true)] {
            let other = lesson("other", body: terminalBody)
            let history = [TerminalLessonMatch(status: .completed, metadata: LessonMatchMetadata(other))]
            let reconciled = try LessonSelector.reconcile(definitions: [upgraded], concepts: concepts,
                subtopics: taxonomy, progress: progress, slots: [], terminal: history,
                activePins: [pin], now: later)
            XCTAssertEqual(reconciled.map(\.lessonID), shouldOffer ? ["started"] : [], terminalBody)
            let replaced = try LessonSelector.replace(consumedSlot: consumed, definitions: [upgraded],
                concepts: concepts, subtopics: taxonomy, progress: progress, slots: [consumed],
                terminal: history, activePins: [pin], now: later)
            XCTAssertEqual(replaced.map(\.lessonID), shouldOffer ? ["started"] : [], terminalBody)
            let restored = try LessonSelector.restoredVacancy(lessonID: "started", definitions: [upgraded],
                concepts: concepts, subtopics: taxonomy, progress: progress, slots: [],
                terminal: history, activePins: [pin], now: later)
            XCTAssertEqual(restored?.lessonID, shouldOffer ? "started" : nil, terminalBody)
        }
    }

    func testVacancyRanksCurrentDirectPracticeBeforeFormatDifficultyAndID() throws {
        let lessons = [lesson("a-practiced", subtopic: "one", format: "code"),
                       lesson("z-unpracticed", subtopic: "two", format: "learn", difficulty: "advanced"),
                       lesson("history", subtopic: "one", body: "Old completed prose")]
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root", prerequisiteConceptIDs: []),
                        LearningConceptSnapshot(id: "go.two.root", subtopicID: "two", name: "Other", prerequisiteConceptIDs: [])]
        let membership: CatalogMembershipAvailability = .available(.init(catalogID: "test", catalogVersion: 2,
            topicIDs: ["go"], subtopicIDs: ["one", "two"], conceptIDs: ["go.two.root", "root"],
            seededLessonIDs: lessons.map(\.id).sorted()))
        let terminal = [TerminalLessonMatch(status: .completed, metadata: LessonMatchMetadata(lessons[2]),
            topicID: "go", format: "learn", date: early)]
        func chosen(_ definitions: [LessonDefinitionSnapshot], _ concepts: [LearningConceptSnapshot],
                    _ date: Date) throws -> String? {
            try LessonSelector.reconcile(definitions: definitions, concepts: concepts,
                subtopics: subtopics(lessons, concepts: concepts),
                progress: [.init(lessonID: "history", status: .completed)], slots: [],
                terminal: terminal, completedConceptIDs: ["root", "retired", "root"],
                membership: membership, now: date).first?.lessonID
        }
        XCTAssertEqual(try chosen(lessons, concepts, early), "z-unpracticed")
        XCTAssertEqual(try chosen(lessons.reversed(), concepts.reversed(), .distantFuture), "z-unpracticed")
        // The completed prerequisite of "root" does not imply direct practice of the other subtopic.
        let active = slot("z-unpracticed", 3, date: early)
        let retained = try LessonSelector.reconcile(definitions: lessons, concepts: concepts,
            subtopics: subtopics(lessons, concepts: concepts),
            progress: [.init(lessonID: "history", status: .completed)], slots: [active],
            terminal: terminal, completedConceptIDs: ["root"], membership: membership, now: later)
        XCTAssertTrue(retained.contains(active))
        XCTAssertEqual(retained.first { $0.slotIndex == 0 }?.lessonID, "a-practiced")
    }

    func testFormatRecencyFourMostRecentStableTieAndConsumedSlotNotRetained() throws {
        let consumed = slot("consumed", 0, date: early)
        let held = slot("held", 2, date: early)
        let lessons = [lesson("consumed", format: "code"), lesson("held", format: "design"),
                       lesson("a-code", format: "code"), lesson("b-learn", format: "learn"),
                       lesson("c-question", format: "question", difficulty: "advanced")]
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root", prerequisiteConceptIDs: [])]
        func history(_ id: String, _ format: String, _ date: Date) -> TerminalLessonMatch {
            TerminalLessonMatch(status: .dismissed,
                metadata: LessonMatchMetadata(id: id, objectiveKey: nil, conceptIDs: nil, contentHash: nil),
                topicID: "go", format: format, date: date)
        }
        let recent = [history("z", "learn", later), history("a", "question", later),
                      history("b", "learn", early), history("c", "question", early),
                      history("d", "code", .distantPast)]
        func pick(_ evidence: [TerminalLessonMatch]) throws -> [LessonSlotSnapshot] {
            try LessonSelector.replace(consumedSlot: consumed, definitions: lessons, concepts: concepts,
                subtopics: subtopics(lessons, concepts: concepts),
                progress: [.init(lessonID: "consumed", status: .completed)], slots: [held, consumed],
                terminal: evidence, now: later)
        }
        // The fifth record's code format and consumed code assignment do not penalize code.
        XCTAssertEqual(try pick(recent), [slot("a-code", 0, date: later), held])
        XCTAssertEqual(try pick(recent.reversed()), try pick(recent))
        // With code in the most recent four, no format is novel: difficulty then ID wins.
        let shifted = [history("new", "code", .distantFuture)] + recent
        XCTAssertEqual(try pick(shifted).first?.lessonID, "a-code")
        // Exactly equal dates break on stable terminal ID at the fourth-record cutoff.
        let tied = [history("e", "question", later), history("d", "learn", later),
                    history("c", "learn", later), history("b", "learn", later),
                    history("a", "code", later)]
        XCTAssertEqual(try pick(tied).first?.lessonID, "c-question")
        XCTAssertEqual(try pick(tied.reversed()).first?.lessonID, "c-question")
        let undated = TerminalLessonMatch(status: .dismissed,
            metadata: LessonMatchMetadata(id: "unknown-date", objectiveKey: nil,
                                          conceptIDs: nil, contentHash: nil),
            topicID: "go", format: "question")
        XCTAssertEqual(try pick(tied + [undated]).first?.lessonID, "c-question")
        let started = [LessonProgressSnapshot(lessonID: "consumed", status: .completed),
                       LessonProgressSnapshot(lessonID: "c-question", status: .started)]
        XCTAssertEqual(try LessonSelector.replace(consumedSlot: consumed, definitions: lessons,
            concepts: concepts, subtopics: subtopics(lessons, concepts: concepts),
            progress: started, slots: [consumed, held], terminal: recent, now: later).first?.lessonID,
            "c-question")
    }

    func testRetainedStartedPinFormatRanksVacanciesAfterDefinitionChangedOrRemoved() throws {
        let pinned = lesson("held", format: "learn", body: "Original study")
        let held = slot("held", 2, date: early)
        let consumed = slot("consumed", 0, date: early)
        let candidates = [lesson("a-learn", format: "learn"), lesson("b-code", format: "code")]
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root",
                                                prerequisiteConceptIDs: [])]
        let progress: [LessonProgressSnapshot] = [.init(lessonID: "held", status: .started),
            .init(lessonID: "consumed", status: .completed)]
        let pin = StartedLessonEvidence(pinned)
        for definitions in [candidates + [lesson("held", format: "code", body: "Upgraded study")],
                            candidates] {
            let taxonomy = subtopics(definitions, concepts: concepts)
            let replaced = try LessonSelector.replace(consumedSlot: consumed,
                definitions: definitions, concepts: concepts, subtopics: taxonomy,
                progress: progress, slots: [consumed, held], activePins: [pin], now: later)
            XCTAssertEqual(replaced, [slot("b-code", 0, date: later), held])
            let reconciled = try LessonSelector.reconcile(definitions: definitions,
                concepts: concepts, subtopics: taxonomy, progress: progress,
                slots: [held], activePins: [pin], now: later)
            XCTAssertTrue(reconciled.contains(held))
            XCTAssertEqual(reconciled.first { $0.slotIndex == 0 }?.lessonID, "b-code")
            XCTAssertEqual(try LessonSelector.reconcile(definitions: definitions,
                concepts: concepts, subtopics: taxonomy, progress: progress,
                slots: reconciled, activePins: [pin], now: .distantFuture), reconciled)
        }
    }

    func testCompetingUnslottedStartedCandidatesRankByPinnedNotUpgradedFormat() throws {
        // Both installed formats have swapped since the attempts were opened.
        // The recent learn format penalizes a's pin, not b's pin.
        let pinnedA = lesson("a", format: "learn", body: "Original A")
        let pinnedB = lesson("b", format: "code", body: "Original B")
        let installed = [lesson("a", format: "code", body: "Updated A"),
                         lesson("b", format: "learn", body: "Updated B")]
        let pins = [StartedLessonEvidence(pinnedA), StartedLessonEvidence(pinnedB)]
        let concepts = [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root",
                                                prerequisiteConceptIDs: [])]
        let taxonomy = subtopics(installed, concepts: concepts)
        let progress: [LessonProgressSnapshot] = [.init(lessonID: "a", status: .started),
            .init(lessonID: "b", status: .started), .init(lessonID: "done", status: .completed)]
        let recent = TerminalLessonMatch(status: .completed,
            metadata: LessonMatchMetadata(id: "old", objectiveKey: nil, conceptIDs: nil, contentHash: nil),
            topicID: "go", format: "learn", date: early)
        let consumed = slot("done", 0, date: early)
        for (definitions, evidence) in [(installed, pins), (installed.reversed(), pins.reversed())] {
            let replaced = try LessonSelector.replace(consumedSlot: consumed, definitions: definitions,
                concepts: concepts, subtopics: taxonomy, progress: progress, slots: [consumed],
                terminal: [recent], activePins: evidence, now: later)
            XCTAssertEqual(replaced.first?.lessonID, "b")
            let reconciled = try LessonSelector.reconcile(definitions: definitions, concepts: concepts,
                subtopics: taxonomy, progress: progress, slots: [], terminal: [recent],
                activePins: evidence, now: later)
            XCTAssertEqual(reconciled.prefix(2).map(\.lessonID), ["b", "a"])
            XCTAssertEqual(try LessonSelector.reconcile(definitions: definitions, concepts: concepts,
                subtopics: taxonomy, progress: progress, slots: reconciled, terminal: [recent],
                activePins: evidence, now: .distantFuture), reconciled)
        }
    }

    func testDifficultyOrderPrecedesStableIDAndUnslottedTerminalRotatesNothing() throws {
        let lessons = [lesson("a-advanced", difficulty: "advanced"),
                       lesson("b-intermediate", difficulty: "intermediate"),
                       lesson("z-basic", difficulty: "basic")]
        XCTAssertEqual(try select(lessons).first?.lessonID, "z-basic")
        XCTAssertEqual(try select(lessons.reversed()).first?.lessonID, "z-basic")
        let held = slot("z-basic", 2, date: early)
        let terminal: [TerminalLessonMatch] = [.init(status: .completed,
            metadata: LessonMatchMetadata(id: "unslotted", objectiveKey: nil,
                                          conceptIDs: nil, contentHash: nil),
            topicID: "go", format: "learn", date: later)]
        let result = try LessonSelector.reconcile(definitions: lessons,
            concepts: [LearningConceptSnapshot(id: "root", subtopicID: "one", name: "Root", prerequisiteConceptIDs: [])],
            subtopics: subtopics(lessons, concepts: []),
            progress: [.init(lessonID: "unslotted", status: .completed)],
            slots: [held], terminal: terminal, now: later)
        XCTAssertTrue(result.contains(held))
    }

    func testStaleOrNonterminalConsumptionAndInvalidRowsAreRejected() throws {
        let consumed = slot("done", 0, date: early)
        let lessons = [lesson("done"), lesson("new")]
        let progress = [LessonProgressSnapshot(lessonID: "done", status: .completed)]
        XCTAssertThrowsError(try replace(consumed, lessons: lessons, progress: progress,
                                         slots: [slot("done", 0, date: later)])) {
            XCTAssertEqual($0 as? LessonSelectionError, .staleConsumedSlot)
        }
        XCTAssertThrowsError(try replace(consumed, lessons: lessons, progress: [],
                                         slots: [consumed])) {
            XCTAssertEqual($0 as? LessonSelectionError, .consumedLessonNotTerminal)
        }
        XCTAssertThrowsError(try replace(consumed, lessons: lessons, progress: progress,
                                         slots: [consumed, slot("new", 0)])) {
            XCTAssertEqual($0 as? LessonSelectionError, .duplicateSlotKey)
        }
    }
}
