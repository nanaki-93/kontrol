import Foundation
import XCTest
@testable import Kontrol

final class LocalDataExportTests: XCTestCase {
    private typealias Export = LocalDataExport
    private let authored = " \tAPI_KEY=sk-not-a-credential\r\n password: keep me 🔐 e\u{301}\n "
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func instant(_ value: String = "2026-09-30T12:00:00.123Z") throws -> ExportTimestamp {
        try ExportTimestamp(value: value)
    }

    private func definition() -> Export.Definition {
        .init(id: "lesson", objectiveKey: "objective.key", objective: authored, title: authored,
              topicID: "topic", subtopicID: "subtopic", conceptIDs: ["z.concept", "concept"],
              difficulty: "basic", format: "code", estimatedMinutes: 25,
              prerequisiteConceptIDs: ["z.prerequisite", "a.prerequisite"], explanation: authored,
              workedExample: " example\n", exercise: " exercise\t", referenceAnswer: authored,
              selfCheckCriteria: [" Z check\n", " A check\t"], contentVersion: 2,
              normalizedContentHash: CatalogValidator.fingerprint(explanation: authored,
                  workedExample: " example\n", exercise: " exercise\t", referenceAnswer: authored,
                  selfCheckCriteria: [" Z check\n", " A check\t"]), source: "seed",
              provenance: .init(attribution: authored, generation: nil))
    }

    private func rich() throws -> Export {
        let now = try instant()
        let later = try instant("2026-09-30T13:00:00.456Z")
        var value = Export(exportedAt: now, appVersion: "1.0")
        value.tasks = [.init(id: secondID, title: authored, notes: authored, dueAt: later,
                             plannedDay: .init(calendarIdentifier: "gregorian", year: 2026, month: 9,
                                               day: 30, timeZoneID: "Europe/Rome"),
                             createdAt: now, completedAt: later),
                       .init(id: firstID, title: "legacy", notes: nil, dueAt: nil, plannedDay: nil,
                             createdAt: now, completedAt: nil)]
        value.blocks = [.init(id: secondID, title: authored, startAt: now, endAt: later, note: authored,
                             lessonID: "missing.historical.lesson", linkedTitleSnapshot: authored)]
        value.sessions = [.init(id: firstID, state: "running", plannedSeconds: 1500,
                               accumulatedActiveSeconds: 12.75, activeSegmentStartedAt: now,
                               deadline: later, pausedAt: nil, startedAt: now, endedAt: nil,
                               checkpointAt: now, recoveryRequired: true, linkedTaskID: nil,
                               linkedLessonID: "lesson", linkedTitleSnapshot: authored)]
        value.feedPreferences = .init(selectedTopicIDs: ["z.news", "a.news"], feeds: [
            .init(id: secondID, name: authored, endpoint: "https://example.test/feed.xml",
                  topicIDs: ["z.news", "a.news"], isEnabled: false)])
        value.generalPreferences = .init(focusDefaultMinutes: 50, textSize: "large", reduceMotion: "reduce",
                                        ai: .init(enabled: true, providerID: "openai", modelID: "gpt-test"))
        var generated = definition()
        generated.id = "generated.lesson"
        generated.source = "generated"
        generated.provenance = .init(attribution: nil, generation: .init(provider: "openai",
            requestedModel: "gpt-test", returnedModel: nil, generatedAt: now, operationID: secondID,
            requestSchemaVersion: 1, objectiveRegistryVersion: 2))
        value.learning = .init(
            topics: [.init(id: "z.topic", name: authored), .init(id: "topic", name: authored)],
            subtopics: [.init(id: "subtopic", topicID: "topic", name: authored)],
            concepts: [.init(id: "concept", subtopicID: "subtopic", name: authored,
                             prerequisiteConceptIDs: ["z.prerequisite", "a.prerequisite"])],
            definitions: [definition(), generated],
            progress: [.init(lessonID: "lesson", status: "completed", firstShownAt: now,
                             startedAt: now, completedAt: later, dismissedAt: nil, lastOpenedAt: later)],
            attempts: [.init(id: secondID, lessonID: "lesson", contentVersion: 2, answerDraft: authored,
                             revision: 8, solutionRevealedAt: now, selfCheckAcknowledgedAt: later,
                             completedAt: later, pinnedContent: .init(definition: definition()),
                             completedContentSnapshot: .init(title: authored, objectiveKey: "objective.key",
                                conceptIDs: ["z.concept", "concept"], difficulty: "basic", format: "code",
                                explanation: authored, workedExample: authored, exercise: authored,
                                referenceAnswer: authored, selfCheckCriteria: [" Z check", " A check"])),
                       .init(id: firstID, lessonID: "absent.legacy", contentVersion: 1, answerDraft: authored,
                             revision: 0, solutionRevealedAt: nil, selfCheckAcknowledgedAt: nil,
                             completedAt: nil, pinnedContent: nil, completedContentSnapshot: nil)],
            slots: [.init(key: "5:topic:0", topicID: "topic", slotIndex: 0, lessonID: "lesson", assignedAt: now)],
            terminalRecords: [.init(lessonID: "lesson", provenance: "dismissalReference", title: authored,
                topicID: "topic", subtopicID: "subtopic", contentVersion: 2, objectiveKey: "objective.key",
                conceptIDs: ["z.concept", "concept"], normalizedContentHash: definition().normalizedContentHash,
                format: "code", dismissalTimeDefinition: definition()),
                .init(lessonID: "absent.legacy", provenance: "legacyCompletedPartial", title: nil, topicID: nil,
                      subtopicID: nil, contentVersion: nil, objectiveKey: nil, conceptIDs: nil,
                      normalizedContentHash: nil, format: nil, dismissalTimeDefinition: nil)],
            catalogMembership: [.init(catalogID: "starter", catalogVersion: 4, topicIDs: ["z.topic", "topic"],
                subtopicIDs: ["subtopic"], conceptIDs: ["z.concept", "concept"], seededLessonIDs: ["lesson"])])
        return value
    }

    private func object(_ value: Export) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
    }

    private func assertRejected(_ value: Export, error: LocalDataExportError? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try value.encoded(), file: file, line: line) { actual in
            if let error { XCTAssertEqual(actual as? LocalDataExportError, error, file: file, line: line) }
        }
    }

    func testEmptyRoundTripEmitsRequiredEnvelopeNineCollectionsAndDefaults() throws {
        let value = Export(exportedAt: try instant(), appVersion: "1.0")
        XCTAssertEqual(try Export.decode(value.encoded()), value)
        let json = try object(value)
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "exportedAt", "appVersion", "tasks", "blocks",
                                       "learning", "sessions", "feedPreferences", "generalPreferences"])
        for key in ["tasks", "blocks", "sessions"] { XCTAssertEqual((json[key] as? [Any])?.count, 0) }
        let learning = try XCTUnwrap(json["learning"] as? [String: Any])
        XCTAssertEqual(Set(learning.keys), ["topics", "subtopics", "concepts", "definitions", "progress",
                                            "attempts", "slots", "terminalRecords", "catalogMembership"])
        for collection in learning.values { XCTAssertEqual((collection as? [Any])?.count, 0) }
        let feeds = try XCTUnwrap(json["feedPreferences"] as? [String: Any])
        XCTAssertEqual((feeds["selectedTopicIDs"] as? [Any])?.count, 0)
        XCTAssertEqual((feeds["feeds"] as? [Any])?.count, 0)
        let general = try XCTUnwrap(json["generalPreferences"] as? [String: Any])
        XCTAssertEqual(general["focusDefaultMinutes"] as? Int, 25)
        XCTAssertEqual(general["textSize"] as? String, "system")
        XCTAssertEqual(general["reduceMotion"] as? String, "system")
        let ai = try XCTUnwrap(general["ai"] as? [String: Any])
        XCTAssertEqual(ai["enabled"] as? Bool, false)
        XCTAssertEqual(ai["providerID"] as? String, "openai")
        XCTAssertTrue(ai["modelID"] is NSNull)
    }

    func testRichRoundTripPreservesEveryFieldAsDetachedSendableValues() throws {
        let value = try rich()
        let decoded = try Export.decode(value.encoded())
        XCTAssertEqual(decoded, value.canonicalized())
        XCTAssertEqual(try decoded.encoded(), try value.encoded())
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(value)
        XCTAssertEqual(decoded.sessions.first?.recoveryRequired, true)
        XCTAssertEqual(decoded.sessions.first?.state, "running")
        XCTAssertEqual(decoded.learning.definitions.first?.provenance?.generation?.objectiveRegistryVersion, 2)
    }

    func testAllNullableFieldsEmitExplicitNullAndRequireTheirKeys() throws {
        let value = try rich()
        var json = try object(value)
        let tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        for key in ["notes", "dueAt", "plannedDay", "completedAt"] { XCTAssertTrue(tasks[0][key] is NSNull) }
        let learning = try XCTUnwrap(json["learning"] as? [String: Any])
        let attempts = try XCTUnwrap(learning["attempts"] as? [[String: Any]])
        for key in ["solutionRevealedAt", "selfCheckAcknowledgedAt", "completedAt", "pinnedContent", "completedContentSnapshot"] {
            XCTAssertTrue(attempts[0][key] is NSNull)
        }
        let terminal = try XCTUnwrap(learning["terminalRecords"] as? [[String: Any]])
        for key in ["title", "topicID", "subtopicID", "contentVersion", "objectiveKey", "conceptIDs",
                    "normalizedContentHash", "format", "dismissalTimeDefinition"] {
            XCTAssertTrue(terminal[0][key] is NSNull)
        }
        var missing = tasks
        missing[0].removeValue(forKey: "notes")
        json["tasks"] = missing
        XCTAssertThrowsError(try Export.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testRequiredKeysCannotDecodeAsDefaultEmptyCollections() throws {
        let json = try object(Export(exportedAt: instant(), appVersion: "1.0"))
        for key in json.keys {
            var missing = json; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try Export.decode(JSONSerialization.data(withJSONObject: missing)), key)
        }
        let learning = try XCTUnwrap(json["learning"] as? [String: Any])
        for key in learning.keys {
            var missing = learning; missing.removeValue(forKey: key)
            var envelope = json; envelope["learning"] = missing
            XCTAssertThrowsError(try Export.decode(JSONSerialization.data(withJSONObject: envelope)), key)
        }
    }

    func testTimestampsUseUTCMillisecondsAndRejectNonfiniteOrOutOfRangeDates() throws {
        let source = Date(timeIntervalSince1970: 1_790_769_600.1236)
        let timestamp = try ExportTimestamp(source)
        XCTAssertEqual(timestamp.value, "2026-09-30T12:00:00.124Z")
        XCTAssertEqual(timestamp.date.timeIntervalSince1970, source.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try ExportTimestamp(value: "0001-01-01T00:00:00.000Z").value, "0001-01-01T00:00:00.000Z")
        XCTAssertEqual(try ExportTimestamp(value: "9999-12-31T23:59:59.999Z").value, "9999-12-31T23:59:59.999Z")
        XCTAssertEqual(try ExportTimestamp(Date(timeIntervalSince1970: -62_135_596_800)).value,
                       "0001-01-01T00:00:00.000Z")
        XCTAssertEqual(try ExportTimestamp(value: "0001-01-01T00:00:00.000Z").date.timeIntervalSince1970,
                       -62_135_596_800)
        // Proleptic Gregorian, not Foundation's default pre-1582 Julian calendar.
        XCTAssertThrowsError(try ExportTimestamp(value: "1500-02-29T00:00:00.000Z"))
        XCTAssertNoThrow(try ExportTimestamp(value: "1582-10-10T00:00:00.000Z"))
        for seconds in [Double.nan, .infinity, -.infinity, -62_135_596_801, 253_402_300_800] {
            XCTAssertThrowsError(try ExportTimestamp(Date(timeIntervalSince1970: seconds)))
        }
    }

    func testMalformedDatesAreRejectedOnDecodeIncludingOptionalAndNestedDates() throws {
        let invalid = ["2026-09-30T12:00:00Z", "2026-09-30T12:00:00.1Z", "2026-09-30T12:00:00.1234Z",
                       "2026-09-30T14:00:00.123+02:00", "2026-02-30T12:00:00.123Z", "2026-09-30T24:00:00.123Z",
                       "2026-09-30T12:00:60.123Z", "0000-01-01T00:00:00.000Z", "not a date", "NaN"]
        for date in invalid {
            XCTAssertThrowsError(try ExportTimestamp(value: date), date)
            var json = try object(rich()); json["exportedAt"] = date
            XCTAssertThrowsError(try Export.decode(JSONSerialization.data(withJSONObject: json)), date)
        }
        let data = try rich().encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let corrupt = text.replacingOccurrences(of: "2026-09-30T13:00:00.456Z", with: "2026-02-30T13:00:00.456Z")
        XCTAssertThrowsError(try Export.decode(Data(corrupt.utf8)))
    }

    func testUnsupportedEnvelopeAndNestedVersionsFailEncodeAndDecode() throws {
        let mutations: [(inout Export) -> Void] = [
            { $0.schemaVersion = 2 }, { $0.generalPreferences.schemaVersion = 2 },
            { $0.learning.attempts[0].pinnedContent?.envelopeVersion = 2 },
            { $0.learning.definitions[0].provenance?.schemaVersion = 2 },
            { $0.learning.terminalRecords[0].schemaVersion = 2 },
            { $0.learning.catalogMembership[0].schemaVersion = 2 },
            { $0.learning.definitions[1].provenance?.generation?.requestSchemaVersion = 2 }
        ]
        for mutate in mutations {
            var value = try rich(); mutate(&value)
            assertRejected(value, error: .unsupportedVersion)
        }
        let text = try XCTUnwrap(String(data: rich().encoded(), encoding: .utf8))
        for key in ["schemaVersion", "envelopeVersion", "requestSchemaVersion"] {
            let corrupt = text.replacingOccurrences(of: "\"\(key)\" : 1", with: "\"\(key)\" : 2")
            XCTAssertNotEqual(corrupt, text)
            XCTAssertThrowsError(try Export.decode(Data(corrupt.utf8)))
        }
    }

    func testDuplicateIdentitiesFailEveryCollectionAndSetRatherThanDeduplicate() throws {
        let mutations: [(inout Export) -> Void] = [
            { $0.tasks.append($0.tasks[0]) }, { $0.blocks.append($0.blocks[0]) },
            { $0.sessions.append($0.sessions[0]) }, { $0.feedPreferences.feeds.append($0.feedPreferences.feeds[0]) },
            { $0.learning.topics.append($0.learning.topics[0]) },
            { $0.learning.subtopics.append($0.learning.subtopics[0]) },
            { $0.learning.concepts.append($0.learning.concepts[0]) },
            { $0.learning.definitions.append($0.learning.definitions[0]) },
            { $0.learning.progress.append($0.learning.progress[0]) },
            { $0.learning.attempts.append($0.learning.attempts[0]) },
            { $0.learning.slots.append($0.learning.slots[0]) },
            { $0.learning.terminalRecords.append($0.learning.terminalRecords[0]) },
            { $0.learning.catalogMembership.append($0.learning.catalogMembership[0]) },
            { $0.feedPreferences.selectedTopicIDs.append($0.feedPreferences.selectedTopicIDs[0]) },
            { $0.feedPreferences.feeds[0].topicIDs.append($0.feedPreferences.feeds[0].topicIDs[0]) },
            { $0.learning.definitions[0].conceptIDs.append($0.learning.definitions[0].conceptIDs[0]) },
            { $0.learning.catalogMembership[0].seededLessonIDs.append("lesson") },
            { var slot = $0.learning.slots[0]; slot.key = "5:topic:1"; slot.slotIndex = 1; $0.learning.slots.append(slot) }
        ]
        for mutate in mutations { var value = try rich(); mutate(&value); assertRejected(value, error: .duplicateIdentity) }
        var json = try object(rich())
        let tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        json["tasks"] = tasks + [tasks[0]]
        XCTAssertThrowsError(try Export.decode(JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? LocalDataExportError, .duplicateIdentity)
        }
    }

    func testMalformedIdentitiesUUIDsAndInternalMismatchesFail() throws {
        let mutations: [(inout Export) -> Void] = [
            { $0.learning.topics[0].id = " " }, { $0.learning.subtopics[0].topicID = " topic" },
            { $0.learning.attempts[0].pinnedContent?.definition.id = "other" },
            { $0.learning.attempts[0].pinnedContent?.definition.contentVersion = 3 },
            { $0.learning.slots[0].key = "wrong" },
            { $0.learning.terminalRecords[0].dismissalTimeDefinition?.id = "other" },
            { $0.learning.terminalRecords[0].contentVersion = 3 },
            { $0.learning.terminalRecords[0].topicID = "other" }
        ]
        for mutate in mutations { var value = try rich(); mutate(&value); assertRejected(value) }
        var json = try object(rich())
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        tasks[0]["id"] = "not-a-uuid"; json["tasks"] = tasks
        XCTAssertThrowsError(try Export.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testPlannedCalendarDayRetainsOriginalZoneAndRejectsInvalidComponents() throws {
        let value = try rich()
        let day = try XCTUnwrap(Export.decode(value.encoded()).tasks[1].plannedDay)
        XCTAssertEqual(day.timeZoneID, "Europe/Rome")
        XCTAssertEqual(day.day, 30)
        for mutate: (inout Export.PlannedDay) -> Void in [
            { $0.calendarIdentifier = "unknown" }, { $0.timeZoneID = "unknown" },
            { $0.month = 2; $0.day = 30 }, { $0.year = 0 }
        ] {
            var invalid = value; mutate(&invalid.tasks[0].plannedDay!)
            assertRejected(invalid, error: .invalidDate)
        }
    }

    func testDeterministicOutputSortsUnorderedCollectionsAndPreservesAuthoredSequence() throws {
        let value = try rich()
        var reversed = value
        reversed.tasks.reverse(); reversed.learning.topics.reverse(); reversed.learning.definitions.reverse()
        reversed.learning.attempts.reverse(); reversed.learning.terminalRecords.reverse()
        reversed.learning.definitions[0].conceptIDs.reverse()
        reversed.learning.definitions[1].prerequisiteConceptIDs.reverse()
        reversed.learning.attempts[1].pinnedContent?.definition.conceptIDs.reverse()
        reversed.learning.terminalRecords[1].dismissalTimeDefinition?.prerequisiteConceptIDs.reverse()
        reversed.learning.catalogMembership[0].topicIDs.reverse()
        reversed.feedPreferences.selectedTopicIDs.reverse(); reversed.feedPreferences.feeds[0].topicIDs.reverse()
        XCTAssertEqual(try value.encoded(), try reversed.encoded())
        let decoded = try Export.decode(value.encoded())
        let stored = try XCTUnwrap(decoded.learning.definitions.first { $0.id == "lesson" })
        XCTAssertEqual(stored.selfCheckCriteria, [" Z check\n", " A check\t"])
        XCTAssertEqual(stored.explanation, authored)
        XCTAssertEqual(stored.workedExample, " example\n")
        XCTAssertEqual(stored.exercise, " exercise\t")
        XCTAssertEqual(stored.referenceAnswer, authored)
    }

    func testDeterminismCoversEveryRecordCollectionNotJustTasksAndDefinitions() throws {
        var value = try rich()
        var block = value.blocks[0]; block.id = firstID; value.blocks.append(block)
        var session = value.sessions[0]; session.id = secondID; value.sessions.append(session)
        var feed = value.feedPreferences.feeds[0]; feed.id = firstID; value.feedPreferences.feeds.append(feed)
        var subtopic = value.learning.subtopics[0]; subtopic.id = "z.subtopic"; value.learning.subtopics.append(subtopic)
        var concept = value.learning.concepts[0]; concept.id = "z.concept"; value.learning.concepts.append(concept)
        var progress = value.learning.progress[0]; progress.lessonID = "z.lesson"; value.learning.progress.append(progress)
        var slot = value.learning.slots[0]; slot.key = "5:topic:1"; slot.slotIndex = 1
        slot.lessonID = "generated.lesson"; value.learning.slots.append(slot)
        var membership = value.learning.catalogMembership[0]; membership.catalogID = "z.starter"
        value.learning.catalogMembership.append(membership)
        var reversed = value
        reversed.tasks.reverse(); reversed.blocks.reverse(); reversed.sessions.reverse()
        reversed.feedPreferences.feeds.reverse()
        reversed.learning.topics.reverse(); reversed.learning.subtopics.reverse(); reversed.learning.concepts.reverse()
        reversed.learning.definitions.reverse(); reversed.learning.progress.reverse(); reversed.learning.attempts.reverse()
        reversed.learning.slots.reverse(); reversed.learning.terminalRecords.reverse(); reversed.learning.catalogMembership.reverse()
        XCTAssertEqual(try value.encoded(), try reversed.encoded())
    }

    func testSlotKeyUsesUTF8LengthAndPreservesColonContainingIdentity() throws {
        var value = try rich()
        value.learning.slots[0].topicID = "t:é"
        value.learning.slots[0].key = "4:t:é:0"
        XCTAssertEqual(try Export.decode(value.encoded()).learning.slots[0].key, "4:t:é:0")
        value.learning.slots[0].key = "3:t:é:0"
        assertRejected(value, error: .identityMismatch)
    }

    func testAuthoredWhitespaceSecretLookingTextAndUnicodeBytesAreNeverRedactedOrNormalized() throws {
        let decoded = try Export.decode(rich().encoded())
        let strings = [decoded.tasks[1].title, decoded.tasks[1].notes!, decoded.blocks[0].note!,
                       decoded.sessions[0].linkedTitleSnapshot!, decoded.learning.attempts[1].answerDraft,
                       decoded.learning.definitions[1].objective, decoded.learning.definitions[1].provenance!.attribution!]
        for string in strings { XCTAssertEqual(Array(string.utf8), Array(authored.utf8)) }
    }

    func testLegacyAbsenceAndEmptyObjectiveAreNotReplacedFromCurrentDefinition() throws {
        var value = try rich()
        value.learning.definitions[0].objective = ""
        value.learning.definitions[0].provenance = nil
        value.learning.attempts[1].lessonID = "lesson" // Same ID as today's definition, still no historical pin.
        let decoded = try Export.decode(value.encoded())
        XCTAssertNil(decoded.learning.attempts[0].pinnedContent)
        XCTAssertNil(decoded.learning.attempts[0].completedContentSnapshot)
        XCTAssertNil(decoded.learning.terminalRecords[0].title)
        XCTAssertEqual(decoded.learning.definitions[1].objective, "")
        XCTAssertNil(decoded.learning.definitions[1].provenance)
    }

    func testInvalidIncludedValuesFailRatherThanDisappear() throws {
        let mutations: [(inout Export) -> Void] = [
            { $0.tasks[0].title = " " }, { $0.blocks[0].endAt = $0.blocks[0].startAt },
            { $0.sessions[0].state = "ready" }, { $0.sessions[0].accumulatedActiveSeconds = .nan },
            { $0.sessions[0].plannedSeconds = 0 }, { $0.sessions[0].linkedTaskID = self.firstID },
            { $0.generalPreferences.focusDefaultMinutes = Int.max }, { $0.generalPreferences.textSize = "unknown" },
            { $0.generalPreferences.reduceMotion = "unknown" }, { $0.learning.definitions[0].contentVersion = 0 },
            { $0.learning.definitions[0].normalizedContentHash = "bad" }, { $0.learning.definitions[0].format = "unknown" },
            { $0.learning.definitions[0].selfCheckCriteria = [] }, { $0.learning.attempts[0].revision = -1 },
            { $0.learning.progress[0].status = "unknown" }, { $0.learning.terminalRecords[0].provenance = "unknown" },
            { $0.learning.terminalRecords[0].title = nil }, { $0.learning.catalogMembership[0].catalogVersion = 0 }
        ]
        for mutate in mutations { var value = try rich(); mutate(&value); assertRejected(value) }
    }

    func testEveryOptionalFieldEmitsNullAndMissingOptionalKeysFailDecode() throws {
        var value = try rich()
        value.blocks[0].note = nil; value.blocks[0].lessonID = nil; value.blocks[0].linkedTitleSnapshot = nil
        value.sessions[0].activeSegmentStartedAt = nil; value.sessions[0].deadline = nil
        value.sessions[0].linkedLessonID = nil; value.sessions[0].linkedTitleSnapshot = nil
        value.learning.definitions[0].provenance = nil
        value.learning.progress[0] = .init(lessonID: "lesson", status: "available", firstShownAt: nil,
            startedAt: nil, completedAt: nil, dismissedAt: nil, lastOpenedAt: nil)
        let json = try object(value)
        func check(_ record: [String: Any], keys: [String]) throws {
            for key in keys { XCTAssertTrue(record[key] is NSNull, key) }
        }
        let blocks = try XCTUnwrap(json["blocks"] as? [[String: Any]])
        try check(blocks[0], keys: ["note", "lessonID", "linkedTitleSnapshot"])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        try check(sessions[0], keys: ["activeSegmentStartedAt", "deadline", "pausedAt", "endedAt",
                                     "linkedTaskID", "linkedLessonID", "linkedTitleSnapshot"])
        let learning = try XCTUnwrap(json["learning"] as? [String: Any])
        let definitions = try XCTUnwrap(learning["definitions"] as? [[String: Any]])
        try check(definitions[1], keys: ["provenance"])
        let progress = try XCTUnwrap(learning["progress"] as? [[String: Any]])
        try check(progress[0], keys: ["firstShownAt", "startedAt", "completedAt", "dismissedAt", "lastOpenedAt"])
        let generated = try XCTUnwrap(definitions[0]["provenance"] as? [String: Any])
        try check(generated, keys: ["attribution"])
        let generation = try XCTUnwrap(generated["generation"] as? [String: Any])
        try check(generation, keys: ["returnedModel"])
        // Every emitted null is a required key, including deeply embedded pins/references.
        func removingNullKeys(_ value: Any) -> [Any] {
            var candidates: [Any] = []
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if child is NSNull {
                        var missing = dictionary; missing.removeValue(forKey: key); candidates.append(missing)
                    } else {
                        for replacement in removingNullKeys(child) {
                            var missing = dictionary; missing[key] = replacement; candidates.append(missing)
                        }
                    }
                }
            } else if let array = value as? [Any] {
                for index in array.indices {
                    for replacement in removingNullKeys(array[index]) {
                        var missing = array; missing[index] = replacement; candidates.append(missing)
                    }
                }
            }
            return candidates
        }
        let candidates = removingNullKeys(json)
        XCTAssertGreaterThan(candidates.count, 30)
        for missing in candidates {
            XCTAssertThrowsError(try Export.decode(JSONSerialization.data(withJSONObject: missing)))
        }
    }

    func testEveryPersistedFocusStateIsRepresentableWithoutLiveTimerMutation() throws {
        var value = try rich()
        for state in ["running", "paused", "completed", "ended"] {
            value.sessions[0].state = state
            let decoded = try Export.decode(value.encoded())
            XCTAssertEqual(decoded.sessions[0], value.sessions[0])
        }
    }

    func testPrivacyFieldAllowlistsHaveNoOpaquePayloadsOrExcludedOwners() throws {
        let json = try object(rich())
        let forbidden: Set<String> = ["credentialReference", "credential", "apiKey", "password", "bookmarkData",
            "projects", "projectReferences", "path", "location", "articles", "etag", "lastModified", "headers",
            "diagnostics", "lastErrorCode", "payload", "pinnedContentData", "selectedTopicIDsPayload", "drafts"]
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                XCTAssertTrue(Set(dictionary.keys).isDisjoint(with: forbidden))
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] { array.forEach(walk) }
        }
        walk(json)
        let learning = try XCTUnwrap(json["learning"] as? [String: Any])
        let definitions = try XCTUnwrap(learning["definitions"] as? [[String: Any]])
        XCTAssertEqual(Set(definitions[0].keys), ["id", "objectiveKey", "objective", "title", "topicID", "subtopicID",
            "conceptIDs", "difficulty", "format", "estimatedMinutes", "prerequisiteConceptIDs", "explanation",
            "workedExample", "exercise", "referenceAnswer", "selfCheckCriteria", "contentVersion",
            "normalizedContentHash", "source", "provenance"])
        let provenance = try XCTUnwrap(definitions[0]["provenance"] as? [String: Any])
        XCTAssertEqual(Set(provenance.keys), ["schemaVersion", "attribution", "generation"])
        let generation = try XCTUnwrap(provenance["generation"] as? [String: Any])
        XCTAssertEqual(Set(generation.keys), ["provider", "requestedModel", "returnedModel", "generatedAt",
            "operationID", "requestSchemaVersion", "objectiveRegistryVersion"])
        let general = try XCTUnwrap(json["generalPreferences"] as? [String: Any])
        XCTAssertEqual(Set((try XCTUnwrap(general["ai"] as? [String: Any])).keys), ["enabled", "providerID", "modelID"])
    }
}
