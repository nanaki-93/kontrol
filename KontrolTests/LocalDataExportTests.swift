import Foundation
import SwiftData
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

    @MainActor
    private func daily(tasks: [TaskItem] = [], blocks: [ScheduleBlock] = [],
                       sessions: [FocusSession] = []) throws -> Export {
        try DailyDataExportProjection.project(tasks: tasks, blocks: blocks, sessions: sessions,
            into: Export(exportedAt: instant(), appVersion: "1.0"))
    }

    @MainActor
    private func storedSession(_ state: String = "running", id: UUID? = nil) throws -> FocusSession {
        let start = try instant().date
        let checkpoint = start.addingTimeInterval(60)
        return FocusSession(id: id ?? firstID, state: state, plannedSeconds: 1500,
            accumulatedActiveSeconds: state == "completed" ? 1500 : 12.75,
            activeSegmentStartedAt: state == "running" ? start : nil,
            deadline: state == "running" ? start.addingTimeInterval(1487.25) : nil,
            pausedAt: state == "paused" ? checkpoint : nil, startedAt: start,
            endedAt: ["completed", "ended"].contains(state) ? checkpoint : nil,
            checkpointAt: checkpoint, recoveryRequired: state == "paused",
            linkedTaskID: nil, linkedLessonID: "missing.historical.lesson", linkedTitleSnapshot: authored)
    }

    @MainActor
    func testDailyProjectionMapsEveryTaskAndBlockFieldWithoutAuthoredNormalization() throws {
        let now = try instant()
        let later = try instant("2026-09-30T13:00:00.456Z")
        let task = try TaskItem(id: secondID, title: "Constructor trims", createdAt: now.date,
            notes: authored, dueAt: later.date, plannedDay: .init(calendarIdentifier: "buddhist",
                year: 2569, month: 9, day: 30), plannedTimeZoneID: "Asia/Bangkok", completedAt: later.date)
        task.title = authored // Stored titles need not retain constructor normalization.
        let legacy = try TaskItem(id: firstID, title: "Legacy unplanned", createdAt: now.date)
        let block = ScheduleBlock(id: secondID, title: authored, startAt: now.date, endAt: later.date,
            note: authored, lessonID: "missing.historical.lesson", linkedTitleSnapshot: authored)
        let unlinked = ScheduleBlock(id: firstID, title: "Unlinked", startAt: now.date, endAt: later.date)
        let value = try daily(tasks: [task, legacy], blocks: [block, unlinked])
        XCTAssertEqual(value.tasks, [
            .init(id: firstID, title: "Legacy unplanned", notes: nil, dueAt: nil, plannedDay: nil,
                  createdAt: now, completedAt: nil),
            .init(id: secondID, title: authored, notes: authored, dueAt: later,
                  plannedDay: .init(calendarIdentifier: "buddhist", year: 2569, month: 9, day: 30,
                                    timeZoneID: "Asia/Bangkok"), createdAt: now, completedAt: later)])
        XCTAssertEqual(value.blocks, [
            .init(id: firstID, title: "Unlinked", startAt: now, endAt: later, note: nil,
                  lessonID: nil, linkedTitleSnapshot: nil),
            .init(id: secondID, title: authored, startAt: now, endAt: later, note: authored,
                  lessonID: "missing.historical.lesson", linkedTitleSnapshot: authored)])
        let decoded = try Export.decode(value.encoded())
        XCTAssertEqual(decoded, value)
        for string in [decoded.tasks[1].title, decoded.tasks[1].notes!, decoded.blocks[1].title,
                       decoded.blocks[1].note!, decoded.blocks[1].linkedTitleSnapshot!] {
            XCTAssertEqual(Array(string.utf8), Array(authored.utf8))
        }
        task.notes = ""; block.note = ""
        XCTAssertEqual(try daily(tasks: [task], blocks: [block]).tasks[0].notes, "")
        XCTAssertEqual(try daily(blocks: [block]).blocks[0].note, "")
        block.lessonID = nil // Deletion can leave only a historical title snapshot.
        XCTAssertEqual(try daily(blocks: [block]).blocks[0].linkedTitleSnapshot, authored)
    }

    @MainActor
    func testDailyProjectionMapsEveryFocusStateTimingLinkAndRecoveryFieldWithoutAdvancement() throws {
        let now = try instant()
        let checkpoint = try ExportTimestamp(now.date.addingTimeInterval(60))
        for state in ["running", "paused", "completed", "ended"] {
            let row = try storedSession(state)
            let before = try FocusSessionSnapshot(row)
            let value = try daily(sessions: [row])
            XCTAssertEqual(value.sessions, [.init(id: firstID, state: state, plannedSeconds: 1500,
                accumulatedActiveSeconds: state == "completed" ? 1500 : 12.75,
                activeSegmentStartedAt: state == "running" ? now : nil,
                deadline: state == "running" ? (try ExportTimestamp(now.date.addingTimeInterval(1487.25))) : nil,
                pausedAt: state == "paused" ? checkpoint : nil, startedAt: now,
                endedAt: ["completed", "ended"].contains(state) ? checkpoint : nil,
                checkpointAt: checkpoint, recoveryRequired: state == "paused", linkedTaskID: nil,
                linkedLessonID: "missing.historical.lesson", linkedTitleSnapshot: authored)])
            XCTAssertEqual(try FocusSessionSnapshot(row), before)
            XCTAssertEqual(try Export.decode(value.encoded()), value)
            XCTAssertEqual(Array(value.sessions[0].linkedTitleSnapshot!.utf8), Array(authored.utf8))
            row.linkedLessonID = nil; row.linkedTaskID = secondID
            XCTAssertEqual(try daily(sessions: [row]).sessions[0].linkedTaskID, secondID)
            row.linkedTaskID = nil // Task deletion retains the saved title, no lookup.
            XCTAssertEqual(try daily(sessions: [row]).sessions[0].linkedTitleSnapshot, authored)
            row.linkedTitleSnapshot = nil
            XCTAssertNil(try daily(sessions: [row]).sessions[0].linkedTitleSnapshot)
        }
        // A valid wall-clock rollback anchor is earlier than startedAt and must
        // not be replaced by the later logical concurrency watermark.
        let rollback = try storedSession()
        rollback.activeSegmentStartedAt = now.date.addingTimeInterval(-60)
        rollback.deadline = rollback.activeSegmentStartedAt!.addingTimeInterval(1487.25)
        let value = try daily(sessions: [rollback])
        XCTAssertEqual(value.sessions[0].activeSegmentStartedAt,
                       try ExportTimestamp(now.date.addingTimeInterval(-60)))
        XCTAssertEqual(value.sessions[0].checkpointAt, checkpoint)
        XCTAssertEqual(value.sessions[0].deadline, try ExportTimestamp(rollback.deadline!))
    }

    @MainActor
    func testDailyProjectionSortsByIdentityAndDetachesValuesWithoutReplacingOtherEnvelopeFields() throws {
        let now = try instant().date
        let tasks = try [secondID, firstID].map { try TaskItem(id: $0, title: "Task", createdAt: now) }
        let blocks = [secondID, firstID].map {
            ScheduleBlock(id: $0, title: "Block", startAt: now, endAt: now.addingTimeInterval(60))
        }
        let sessions = try [secondID, firstID].map { try storedSession("ended", id: $0) }
        var envelope = try rich()
        envelope.exportedAt = try instant("2026-10-01T12:00:00.000Z")
        let value = try DailyDataExportProjection.project(tasks: tasks, blocks: blocks,
            sessions: sessions, into: envelope)
        let reversed = try DailyDataExportProjection.project(tasks: tasks.reversed(), blocks: blocks.reversed(),
            sessions: sessions.reversed(), into: envelope)
        XCTAssertEqual(value, reversed)
        XCTAssertEqual(try value.encoded(), try reversed.encoded())
        XCTAssertEqual(value.tasks.map(\.id), [firstID, secondID])
        XCTAssertEqual(value.blocks.map(\.id), [firstID, secondID])
        XCTAssertEqual(value.sessions.map(\.id), [firstID, secondID])
        XCTAssertEqual(value.learning, envelope.canonicalized().learning)
        XCTAssertEqual(value.generalPreferences, envelope.generalPreferences)
        XCTAssertEqual(value.feedPreferences, envelope.canonicalized().feedPreferences)
        XCTAssertEqual(value.exportedAt, envelope.exportedAt)
        XCTAssertEqual(value.appVersion, envelope.appVersion)
        let bytes = try value.encoded()
        tasks[0].title = "Later edit"; blocks[0].note = "Later edit"
        sessions[0].linkedTitleSnapshot = "Later edit"; sessions[0].state = "corrupt"
        XCTAssertEqual(try value.encoded(), bytes)
        XCTAssertEqual(try daily(), try Export(exportedAt: instant(), appVersion: "1.0"))
    }

    @MainActor
    func testDailyProjectionRejectsDamagedTasksIncludingBothOneSidedPlannedDayCases() throws {
        let mutations: [(TaskItem) -> Void] = [
            { $0.title = " \n" }, { $0.createdAt = Date(timeIntervalSince1970: .nan) },
            { $0.dueAt = Date(timeIntervalSince1970: .infinity) },
            { $0.completedAt = Date(timeIntervalSince1970: 253_402_300_800) },
            { $0.plannedTimeZoneID = "Europe/Rome" },
            { $0.plannedDay = .init(calendarIdentifier: "gregorian", year: 2026, month: 9, day: 30) },
            { $0.plannedDay = .init(calendarIdentifier: "gregorian", year: 2026, month: 2, day: 30)
              $0.plannedTimeZoneID = "Europe/Rome" },
            { $0.plannedDay = .init(calendarIdentifier: "unknown", year: 2026, month: 9, day: 30)
              $0.plannedTimeZoneID = "Europe/Rome" },
            { $0.plannedDay = .init(calendarIdentifier: "gregorian", year: 2026, month: 9, day: 30)
              $0.plannedTimeZoneID = "unknown" },
            { $0.plannedDay = .init(calendarIdentifier: "gregorian", year: 0, month: 9, day: 30)
              $0.plannedTimeZoneID = "" }
        ]
        for mutate in mutations {
            let row = try TaskItem(id: firstID, title: "Task", createdAt: instant().date)
            mutate(row)
            XCTAssertThrowsError(try daily(tasks: [row])) {
                XCTAssertNotNil($0 as? LocalDataExportError)
            }
        }
    }

    @MainActor
    func testDailyProjectionRejectsDamagedBlocksAndBoundsCollapsedByMillisecondRounding() throws {
        let mutations: [(ScheduleBlock) -> Void] = [
            { $0.title = " \t" }, { $0.startAt = Date(timeIntervalSince1970: -.infinity) },
            { $0.endAt = Date(timeIntervalSince1970: .nan) }, { $0.endAt = $0.startAt },
            { $0.endAt = $0.startAt.addingTimeInterval(-1) },
            { $0.endAt = $0.startAt.addingTimeInterval(0.0001) },
            { $0.lessonID = " " }, { $0.lessonID = " lesson" }
        ]
        for mutate in mutations {
            let row = ScheduleBlock(id: firstID, title: "Block", startAt: try instant().date,
                endAt: try instant().date.addingTimeInterval(60))
            mutate(row)
            XCTAssertThrowsError(try daily(blocks: [row])) {
                XCTAssertNotNil($0 as? LocalDataExportError)
            }
        }
    }

    @MainActor
    func testDailyProjectionRejectsCorruptFocusRecordsInsteadOfRepairingOrDroppingThem() throws {
        let mutations: [(FocusSession) -> Void] = [
            { $0.state = "ready" }, { $0.state = "unknown" }, { $0.plannedSeconds = 0 },
            { $0.plannedSeconds = -1 }, { $0.accumulatedActiveSeconds = .nan },
            { $0.accumulatedActiveSeconds = .infinity }, { $0.accumulatedActiveSeconds = -1 },
            { $0.accumulatedActiveSeconds = 1501 }, { $0.accumulatedActiveSeconds = 1500 },
            { $0.activeSegmentStartedAt = nil }, { $0.deadline = nil },
            { $0.deadline = $0.activeSegmentStartedAt },
            { $0.deadline = $0.deadline!.addingTimeInterval(1) },
            { $0.pausedAt = $0.startedAt }, { $0.endedAt = $0.startedAt },
            { $0.recoveryRequired = true }, { $0.linkedTaskID = self.secondID },
            { $0.linkedLessonID = " " }, { $0.linkedLessonID = " lesson" },
            { $0.linkedTitleSnapshot = " \n" },
            { $0.checkpointAt = $0.startedAt.addingTimeInterval(-1) }
        ]
        for mutate in mutations {
            let row = try storedSession()
            mutate(row)
            XCTAssertThrowsError(try daily(sessions: [row])) {
                XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
            }
        }
        let dateMutations: [(FocusSession) -> Void] = [
            { $0.activeSegmentStartedAt = Date(timeIntervalSince1970: .nan) },
            { $0.deadline = Date(timeIntervalSince1970: .infinity) },
            { $0.pausedAt = Date(timeIntervalSince1970: -.infinity) },
            { $0.startedAt = Date(timeIntervalSince1970: .nan) },
            { $0.endedAt = Date(timeIntervalSince1970: 253_402_300_800) },
            { $0.checkpointAt = Date(timeIntervalSince1970: -62_135_596_801) }
        ]
        for mutate in dateMutations {
            let row = try storedSession(); mutate(row)
            XCTAssertThrowsError(try daily(sessions: [row])) {
                XCTAssertEqual($0 as? LocalDataExportError, .invalidDate)
            }
        }
        for state in ["paused", "completed", "ended"] {
            let row = try storedSession(state)
            if state == "paused" { row.pausedAt = nil } else { row.endedAt = nil }
            XCTAssertThrowsError(try daily(sessions: [row]))
            let badRecovery = try storedSession(state)
            if state == "paused" { badRecovery.activeSegmentStartedAt = badRecovery.startedAt }
            else { badRecovery.recoveryRequired = true }
            XCTAssertThrowsError(try daily(sessions: [badRecovery]))
        }
    }

    @MainActor
    func testDailyProjectionRejectsDuplicateRecordIDsAndConflictingActiveRows() throws {
        let task = try TaskItem(id: firstID, title: "Task", createdAt: instant().date)
        let block = ScheduleBlock(id: firstID, title: "Block", startAt: try instant().date,
            endAt: try instant().date.addingTimeInterval(60))
        let ended = try storedSession("ended")
        for capture in [
            { try self.daily(tasks: [task, task]) },
            { try self.daily(blocks: [block, block]) },
            { try self.daily(sessions: [ended, ended]) }
        ] {
            XCTAssertThrowsError(try capture()) {
                XCTAssertEqual($0 as? LocalDataExportError, .duplicateIdentity)
            }
        }
        XCTAssertThrowsError(try daily(sessions: [storedSession(), storedSession("paused", id: secondID)])) {
            XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
        }
        // Namespaces are independent; shared UUIDs across collection kinds are valid.
        XCTAssertNoThrow(try daily(tasks: [task], blocks: [block], sessions: [ended]))
    }

    @MainActor
    func testDailyProjectionLeavesPersistedInventoryActiveSessionAndAnotherOwnersDraftUntouched() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        let start = try instant().date
        seed.insert(try TaskItem(id: firstID, title: "Uncompleted", createdAt: start, notes: authored))
        seed.insert(ScheduleBlock(id: firstID, title: "Block", startAt: start,
            endAt: start.addingTimeInterval(60), note: authored))
        seed.insert(try storedSession()) // Old deadline: capture must not reconcile it.
        seed.insert(LessonProgress(lessonID: "missing.historical.lesson", status: .started, startedAt: start))
        try seed.save()
        let draftOwner = ModelContext(container)
        draftOwner.autosaveEnabled = false
        let draftTask = try XCTUnwrap(draftOwner.fetch(FetchDescriptor<TaskItem>()).first)
        draftTask.title = "Unsaved task draft"
        let capture = ModelContext(container)
        capture.autosaveEnabled = false
        let tasks = try capture.fetch(FetchDescriptor<TaskItem>())
        let blocks = try capture.fetch(FetchDescriptor<ScheduleBlock>())
        let sessions = try capture.fetch(FetchDescriptor<FocusSession>())
        let originalSession = try FocusSessionSnapshot(XCTUnwrap(sessions.first))
        XCTAssertFalse(capture.hasChanges)
        let value = try daily(tasks: tasks, blocks: blocks, sessions: sessions)
        XCTAssertFalse(capture.hasChanges)
        XCTAssertEqual(try FocusSessionSnapshot(XCTUnwrap(sessions.first)), originalSession)
        XCTAssertNil(tasks[0].completedAt)
        XCTAssertTrue(draftOwner.hasChanges)
        XCTAssertEqual(draftTask.title, "Unsaved task draft")
        XCTAssertEqual(value.tasks[0].title, "Uncompleted")
        let inspect = ModelContext(container)
        inspect.autosaveEnabled = false
        let persistedTasks = try inspect.fetch(FetchDescriptor<TaskItem>())
        let persistedBlocks = try inspect.fetch(FetchDescriptor<ScheduleBlock>())
        let persistedSessions = try inspect.fetch(FetchDescriptor<FocusSession>())
        XCTAssertEqual([persistedTasks.count, persistedBlocks.count, persistedSessions.count], [1, 1, 1])
        XCTAssertEqual(try daily(tasks: persistedTasks, blocks: persistedBlocks, sessions: persistedSessions), value)
        let progress = try XCTUnwrap(inspect.fetch(FetchDescriptor<LessonProgress>()).first)
        XCTAssertEqual(progress.status, .started)
        XCTAssertEqual(progress.startedAt, start)
        XCTAssertNil(progress.completedAt)
        XCTAssertFalse(inspect.hasChanges)
    }

    @MainActor
    private func configuration(general: [AppPreferencesRecord] = [], ai: [AISettingsRecord] = [],
                               news: [NewsPreferencesRecord] = [], feeds: [NewsFeedRecord] = [],
                               into envelope: Export? = nil) throws -> Export {
        try DailyDataExportProjection.project(general: general, ai: ai, newsPreferences: news,
            feeds: feeds, catalog: BundledFeedCatalog.load(),
            into: envelope ?? Export(exportedAt: instant(), appVersion: "1.0"))
    }

    @MainActor
    private func newsPreference(_ ids: [String] = ["go", "ai"]) throws -> NewsPreferencesRecord {
        NewsPreferencesRecord(catalogVersion: 1, selectedTopicIDsPayload: try NewsRecordPayload.encodeTopics(ids))
    }

    @MainActor
    private func configuredFeed(id: UUID? = nil) throws -> NewsFeedRecord {
        NewsFeedRecord(id: id ?? secondID, name: "API_KEY=sk-not-a-credential 🔐 e\u{301}",
            endpoint: "https://FEEDS.example.test:443/rss?token=keep%20me",
            topicIDsPayload: try NewsRecordPayload.encodeTopics(["go", "ai"]), isEnabled: false,
            etag: "excluded-validator", lastModified: "excluded-header", lastAttemptAt: try instant().date,
            lastSuccessAt: try instant().date, lastErrorCode: "excluded-diagnostic", retryNotBefore: try instant().date)
    }

    @MainActor
    func testConfigurationProjectionMissingRowsUsesBundledEffectiveDefaultsNotEmptyDTO() throws {
        let catalog = try BundledFeedCatalog.load()
        let value = try configuration()
        XCTAssertEqual(value.generalPreferences, Export.GeneralPreferences(
            focusDefaultMinutes: 25, textSize: "system", reduceMotion: "system",
            ai: .init(enabled: false, providerID: "openai", modelID: nil)))
        XCTAssertEqual(value.feedPreferences.selectedTopicIDs, catalog.initialSelectedTopicIDs.sorted())
        XCTAssertFalse(value.feedPreferences.feeds.isEmpty)
        XCTAssertEqual(value.feedPreferences.feeds, catalog.feeds.map {
            Export.Feed(id: $0.id, name: $0.name, endpoint: $0.url.absoluteString,
                topicIDs: $0.topicIDs.sorted(), isEnabled: true)
        }.sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(try Export.decode(value.encoded()), value)
    }

    @MainActor
    func testConfigurationProjectionAllPersistedDefaultCombinationsAndExplicitEmptyNews() throws {
        let general = AppPreferencesRecord(focusDefaultMinutes: 51, textSize: "large", reduceMotion: "reduce")
        let ai = AISettingsRecord(enabled: true, modelID: "gpt-test:1", credentialReference: firstID.uuidString)
        let news = try newsPreference()
        let feed = try configuredFeed()
        for hasGeneral in [false, true] {
            for hasAI in [false, true] {
                for newsState in 0...2 { // absent, explicitly empty, populated
                    let value = try configuration(general: hasGeneral ? [general] : [], ai: hasAI ? [ai] : [],
                        news: newsState == 0 ? [] : [news], feeds: newsState == 2 ? [feed] : [])
                    XCTAssertEqual(value.generalPreferences.focusDefaultMinutes, hasGeneral ? 51 : 25)
                    XCTAssertEqual(value.generalPreferences.textSize, hasGeneral ? "large" : "system")
                    XCTAssertEqual(value.generalPreferences.reduceMotion, hasGeneral ? "reduce" : "system")
                    XCTAssertEqual(value.generalPreferences.ai, .init(enabled: hasAI, providerID: "openai",
                        modelID: hasAI ? "gpt-test:1" : nil))
                    if newsState != 0 {
                        XCTAssertEqual(value.feedPreferences.selectedTopicIDs, ["ai", "go"])
                        XCTAssertEqual(value.feedPreferences.feeds.count, newsState == 2 ? 1 : 0)
                    } else { XCTAssertFalse(value.feedPreferences.feeds.isEmpty) }
                    XCTAssertEqual(try Export.decode(value.encoded()), value)
                }
            }
        }
        let empty = try configuration(news: [newsPreference([])])
        XCTAssertEqual(empty.feedPreferences, .init(selectedTopicIDs: [], feeds: []))
        ai.enabled = false // Retain configured nonsecret model even when disabled.
        ai.credentialReference = nil
        XCTAssertEqual(try configuration(ai: [ai]).generalPreferences.ai,
                       .init(enabled: false, providerID: "openai", modelID: "gpt-test:1"))
        general.focusDefaultMinutes = Int.max / 60
        XCTAssertEqual(try configuration(general: [general]).generalPreferences.focusDefaultMinutes, Int.max / 60)
    }

    @MainActor
    func testConfigurationProjectionMapsAllowlistedFieldsExactlyAndNeverEmitsExcludedMetadata() throws {
        let general = AppPreferencesRecord(focusDefaultMinutes: 15, textSize: "large", reduceMotion: "reduce")
        let ai = AISettingsRecord(enabled: true, modelID: "gpt-test", credentialReference: firstID.uuidString)
        let news = try newsPreference()
        let feed = try configuredFeed()
        let value = try configuration(general: [general], ai: [ai], news: [news], feeds: [feed])
        XCTAssertEqual(value.generalPreferences, .init(focusDefaultMinutes: 15, textSize: "large",
            reduceMotion: "reduce", ai: .init(enabled: true, providerID: "openai", modelID: "gpt-test")))
        XCTAssertEqual(value.feedPreferences, .init(selectedTopicIDs: ["ai", "go"], feeds: [
            .init(id: secondID, name: feed.name, endpoint: feed.endpoint, topicIDs: ["ai", "go"], isEnabled: false)]))
        XCTAssertEqual(Array(value.feedPreferences.feeds[0].name.utf8), Array(feed.name.utf8))
        let json = try object(value)
        let preferences = try XCTUnwrap(json["generalPreferences"] as? [String: Any])
        XCTAssertEqual(Set(preferences.keys), ["schemaVersion", "focusDefaultMinutes", "textSize", "reduceMotion", "ai"])
        XCTAssertEqual(Set(try XCTUnwrap(preferences["ai"] as? [String: Any]).keys), ["enabled", "providerID", "modelID"])
        let feedPreferences = try XCTUnwrap(json["feedPreferences"] as? [String: Any])
        XCTAssertEqual(Set(feedPreferences.keys), ["selectedTopicIDs", "feeds"])
        let projected = try XCTUnwrap((feedPreferences["feeds"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(projected.keys), ["id", "name", "endpoint", "topicIDs", "isEnabled"])
        let bytes = try value.encoded()
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for excluded in [firstID.uuidString, "excluded-validator", "excluded-header", "excluded-diagnostic"] {
            XCTAssertFalse(text.contains(excluded))
        }
        // Damage in excluded transport fields is irrelevant to included configuration.
        news.lastRefreshAt = Date(timeIntervalSince1970: .nan)
        feed.lastAttemptAt = Date(timeIntervalSince1970: .nan)
        feed.lastSuccessAt = Date(timeIntervalSince1970: .infinity)
        feed.retryNotBefore = Date(timeIntervalSince1970: -.infinity)
        feed.etag = String(repeating: "x", count: 5_000)
        XCTAssertEqual(try configuration(general: [general], ai: [ai], news: [news], feeds: [feed]).encoded(), bytes)
    }

    @MainActor
    func testConfigurationProjectionRejectsDamagedGeneralAndAIRowsWithoutFallback() throws {
        let generalMutations: [(AppPreferencesRecord) -> Void] = [
            { $0.payloadVersion = 2 }, { $0.focusDefaultMinutes = 0 }, { $0.focusDefaultMinutes = -1 },
            { $0.focusDefaultMinutes = Int.max }, { $0.textSize = "unknown" }, { $0.reduceMotion = "unknown" }
        ]
        for (index, mutate) in generalMutations.enumerated() {
            let row = AppPreferencesRecord(); mutate(row)
            XCTAssertThrowsError(try configuration(general: [row])) {
                XCTAssertEqual($0 as? LocalDataExportError, index == 0 ? .unsupportedVersion : .invalidValue)
            }
        }
        let aiMutations: [(AISettingsRecord) -> Void] = [
            { $0.payloadVersion = 2 }, { $0.providerID = "other" }, { $0.modelID = "" },
            { $0.modelID = " contains whitespace " }, { $0.modelID = String(repeating: "a", count: 129) },
            { $0.credentialReference = "not-a-uuid" }, { $0.enabled = true },
            { $0.enabled = true; $0.modelID = "gpt-test" },
            { $0.enabled = true; $0.credentialReference = self.firstID.uuidString }
        ]
        for (index, mutate) in aiMutations.enumerated() {
            let row = AISettingsRecord(); mutate(row)
            XCTAssertThrowsError(try configuration(ai: [row])) {
                XCTAssertEqual($0 as? LocalDataExportError, index == 0 ? .unsupportedVersion : .invalidValue)
            }
        }
    }

    @MainActor
    func testConfigurationProjectionRejectsDuplicateAndForeignSingletonsOrOrphanedFeeds() throws {
        let general = AppPreferencesRecord()
        let ai = AISettingsRecord()
        let news = try newsPreference()
        let feed = try configuredFeed()
        for capture in [
            { try self.configuration(general: [general, general]) },
            { try self.configuration(ai: [ai, ai]) },
            { try self.configuration(news: [news, news]) },
            { try self.configuration(news: [news], feeds: [feed, feed]) }
        ] {
            XCTAssertThrowsError(try capture()) { XCTAssertEqual($0 as? LocalDataExportError, .duplicateIdentity) }
        }
        general.key = "foreign"; ai.key = "foreign"; news.key = "foreign"
        for capture in [
            { try self.configuration(general: [general]) }, { try self.configuration(ai: [ai]) },
            { try self.configuration(news: [news]) }
        ] {
            XCTAssertThrowsError(try capture()) { XCTAssertEqual($0 as? LocalDataExportError, .invalidValue) }
        }
        XCTAssertThrowsError(try configuration(feeds: [feed])) {
            XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
        }
    }

    @MainActor
    func testConfigurationProjectionRejectsCorruptUnsupportedOversizedAndDuplicateTopicPayloads() throws {
        let payloads = [Data("not JSON".utf8), Data(#"{"version":2,"value":["go"]}"#.utf8),
            Data(#"{"version":1,"value":["go","go"]}"#.utf8),
            Data(#"{"version":1,"value":[""]}"#.utf8), Data(repeating: 32, count: 4_097)]
        for (index, payload) in payloads.enumerated() {
            let news = try newsPreference(); news.selectedTopicIDsPayload = payload
            let feed = try configuredFeed(); feed.topicIDsPayload = payload
            for capture in [
                { try self.configuration(news: [news]) },
                { try self.configuration(news: [self.newsPreference()], feeds: [feed]) }
            ] {
                XCTAssertThrowsError(try capture()) {
                    XCTAssertEqual($0 as? LocalDataExportError, index == 1 ? .unsupportedVersion : .invalidValue)
                }
            }
        }
        let badVersion = try newsPreference(); badVersion.catalogVersion = 0
        XCTAssertThrowsError(try configuration(news: [badVersion]))
        XCTAssertThrowsError(try configuration(news: [newsPreference(["unknown"])]))
    }

    @MainActor
    func testConfigurationProjectionRejectsInvalidFeedsEndpointsMappingsAndLimits() throws {
        let mutations: [(NewsFeedRecord) -> Void] = [
            { $0.name = "" }, { $0.name = " spaced " }, { $0.name = String(repeating: "a", count: 257) },
            { $0.endpoint = "http://feeds.example.test/rss" },
            { $0.endpoint = "https://user:secret@feeds.example.test/rss" },
            { $0.endpoint = "https://feeds.example.test/rss#fragment" },
            { $0.endpoint = "not a URL" },
            { $0.topicIDsPayload = try! NewsRecordPayload.encodeTopics([]) },
            { $0.topicIDsPayload = try! NewsRecordPayload.encodeTopics(["unknown"]) }
        ]
        for mutate in mutations {
            let feed = try configuredFeed(); mutate(feed)
            XCTAssertThrowsError(try configuration(news: [newsPreference()], feeds: [feed])) {
                XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
            }
        }
        let first = try configuredFeed(id: firstID)
        let second = try configuredFeed()
        second.endpoint = "https://feeds.example.test/rss?token=keep%20me" // Same normalized identity.
        XCTAssertThrowsError(try configuration(news: [newsPreference()], feeds: [first, second])) {
            XCTAssertEqual($0 as? LocalDataExportError, .duplicateIdentity)
        }
        let feeds = try (0..<33).map { index -> NewsFeedRecord in
            let feed = try configuredFeed(id: UUID())
            feed.endpoint = "https://feeds.example.test/\(index)"
            return feed
        }
        XCTAssertThrowsError(try configuration(news: [newsPreference()], feeds: feeds))
    }

    @MainActor
    func testConfigurationProjectionSortsDetachesAndPreservesOtherEnvelopeContent() throws {
        let general = AppPreferencesRecord()
        let ai = AISettingsRecord()
        let news = try newsPreference()
        let second = try configuredFeed()
        let first = try configuredFeed(id: firstID); first.endpoint = "https://feeds.example.test/other"
        let envelope = try rich()
        let value = try configuration(general: [general], ai: [ai], news: [news], feeds: [second, first], into: envelope)
        let reversed = try configuration(general: [general], ai: [ai], news: [news], feeds: [first, second], into: envelope)
        XCTAssertEqual(try value.encoded(), try reversed.encoded())
        XCTAssertEqual(value.feedPreferences.feeds.map(\.id), [firstID, secondID])
        let canonical = envelope.canonicalized()
        XCTAssertEqual(value.tasks, canonical.tasks); XCTAssertEqual(value.blocks, canonical.blocks)
        XCTAssertEqual(value.sessions, canonical.sessions); XCTAssertEqual(value.learning, canonical.learning)
        XCTAssertEqual(value.exportedAt, envelope.exportedAt); XCTAssertEqual(value.appVersion, envelope.appVersion)
        let bytes = try value.encoded()
        general.focusDefaultMinutes = 50; ai.modelID = "later-model"; first.name = "Later edit"
        news.selectedTopicIDsPayload = try NewsRecordPayload.encodeTopics([])
        XCTAssertEqual(try value.encoded(), bytes)
    }

    @MainActor
    func testConfigurationProjectionNeverInsertsDefaultsSavesOrChangesOtherOwnersDrafts() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let capture = ModelContext(container); capture.autosaveEnabled = false
        func projectRows() throws -> Export {
            try configuration(general: capture.fetch(FetchDescriptor<AppPreferencesRecord>()),
                ai: capture.fetch(FetchDescriptor<AISettingsRecord>()),
                news: capture.fetch(FetchDescriptor<NewsPreferencesRecord>()),
                feeds: capture.fetch(FetchDescriptor<NewsFeedRecord>()))
        }
        func counts(_ context: ModelContext) throws -> [Int] {
            try [context.fetchCount(FetchDescriptor<AppPreferencesRecord>()),
                 context.fetchCount(FetchDescriptor<AISettingsRecord>()),
                 context.fetchCount(FetchDescriptor<NewsPreferencesRecord>()),
                 context.fetchCount(FetchDescriptor<NewsFeedRecord>())]
        }
        _ = try projectRows()
        XCTAssertFalse(capture.hasChanges)
        XCTAssertEqual(try counts(ModelContext(container)), [0, 0, 0, 0])
        let seed = ModelContext(container); seed.autosaveEnabled = false
        seed.insert(AppPreferencesRecord()); seed.insert(AISettingsRecord())
        seed.insert(try newsPreference()); seed.insert(try configuredFeed())
        try seed.save()
        let draftOwner = ModelContext(container); draftOwner.autosaveEnabled = false
        let draft = try XCTUnwrap(draftOwner.fetch(FetchDescriptor<NewsFeedRecord>()).first)
        draft.name = "Unsaved feed edit"
        let value = try projectRows()
        XCTAssertFalse(capture.hasChanges)
        XCTAssertTrue(draftOwner.hasChanges)
        XCTAssertEqual(draft.name, "Unsaved feed edit")
        XCTAssertNotEqual(value.feedPreferences.feeds[0].name, draft.name)
        let inspect = ModelContext(container); inspect.autosaveEnabled = false
        XCTAssertEqual(try counts(inspect), [1, 1, 1, 1])
        XCTAssertEqual(try configuration(general: inspect.fetch(FetchDescriptor<AppPreferencesRecord>()),
            ai: inspect.fetch(FetchDescriptor<AISettingsRecord>()),
            news: inspect.fetch(FetchDescriptor<NewsPreferencesRecord>()),
            feeds: inspect.fetch(FetchDescriptor<NewsFeedRecord>())), value)
        XCTAssertFalse(inspect.hasChanges)
    }

    @MainActor
    private func learning(topics: [Topic] = [], subtopics: [Subtopic] = [], concepts: [Concept] = [],
                          definitions: [LessonDefinition] = [], into envelope: Export? = nil) throws -> Export {
        try LearningExportProjection.project(topics: topics, subtopics: subtopics, concepts: concepts,
            definitions: definitions, into: envelope ?? Export(exportedAt: instant(), appVersion: "1.0"))
    }

    @MainActor
    private func storedDefinition(_ value: Export.Definition? = nil, provenance: String? = nil) -> LessonDefinition {
        let value = value ?? definition()
        return LessonDefinition(id: value.id, objectiveKey: value.objectiveKey, title: value.title,
            topicID: value.topicID, subtopicID: value.subtopicID, conceptIDs: value.conceptIDs,
            difficulty: value.difficulty, format: value.format, estimatedMinutes: value.estimatedMinutes,
            prerequisiteConceptIDs: value.prerequisiteConceptIDs, explanation: value.explanation,
            workedExample: value.workedExample, exercise: value.exercise, referenceAnswer: value.referenceAnswer,
            selfCheckCriteria: value.selfCheckCriteria, contentVersion: value.contentVersion,
            normalizedContentHash: value.normalizedContentHash, source: value.source,
            provenance: provenance ?? authored, objective: value.objective)
    }

    @MainActor
    private func acceptedGenerated(returnedModel: String? = nil) throws -> LessonDefinition {
        let catalog = try BundledCatalogLoader.load()
        let value = catalog.value
        let membership = CurrentCatalogMembership(catalogID: value.catalogID, catalogVersion: value.version,
            topicIDs: value.topics.map(\.id).sorted(), subtopicIDs: value.subtopics.map(\.id).sorted(),
            conceptIDs: value.concepts.map(\.id).sorted(), seededLessonIDs: value.lessons.map(\.id).sorted())
        let registry = try GenerationObjectivesLoader.load(catalog: catalog, membership: membership)
        let context = LessonGenerationContext(catalog: catalog, membership: membership,
            completedConceptIDs: ["go.concurrency.cancel-work"], terminal: [], definitions: [], startedPins: [])
        let request = try LessonGenerationRequestBuilder.make(selection: .init(topicID: "go",
            objectiveKey: "expansion.go.concurrency.cancellation-race", format: "code", difficulty: "intermediate"),
            operationID: secondID, context: context, registry: registry)
        let candidate = CandidateLesson(title: authored, objectiveKey: request.objectiveKey, objective: authored,
            topicID: request.topicID, subtopicID: request.subtopicID, conceptIDs: request.conceptIDs,
            difficulty: request.difficulty, format: request.format, estimatedMinutes: 20,
            prerequisiteConceptIDs: request.prerequisiteConceptIDs, explanation: authored,
            workedExample: " example\n", exercise: " exercise\t", referenceAnswer: authored,
            selfCheckCriteria: [" Z check\n", " A check\t", " A check\t"])
        let accepted = try GeneratedLessonValidator.validate(candidate, request: request, context: context,
            registry: registry, requestedModel: "gpt-test", returnedModel: returnedModel, now: instant().date).definition
        let row = storedDefinition()
        row.id = accepted.id; row.objectiveKey = accepted.objectiveKey; row.objective = accepted.objective
        row.topicID = accepted.topicID; row.subtopicID = accepted.subtopicID; row.conceptIDs = accepted.conceptIDs
        row.difficulty = accepted.difficulty; row.estimatedMinutes = accepted.estimatedMinutes
        row.prerequisiteConceptIDs = accepted.prerequisiteConceptIDs; row.contentVersion = accepted.contentVersion
        row.selfCheckCriteria = accepted.selfCheckCriteria; row.normalizedContentHash = accepted.normalizedContentHash
        row.source = accepted.source; row.provenance = accepted.provenance
        return row
    }

    @MainActor
    func testLearningDefinitionsProjectionMapsEveryTaxonomyAndSeedFieldExactly() throws {
        let row = storedDefinition()
        let value = try learning(topics: [Topic(id: "topic", name: authored)],
            subtopics: [Subtopic(id: "subtopic", topicID: "topic", name: authored)],
            concepts: [Concept(id: "concept", subtopicID: "subtopic", name: authored,
                prerequisiteConceptIDs: ["z.prerequisite", "a.prerequisite"])], definitions: [row])
        XCTAssertEqual(value.learning.topics, [.init(id: "topic", name: authored)])
        XCTAssertEqual(value.learning.subtopics, [.init(id: "subtopic", topicID: "topic", name: authored)])
        XCTAssertEqual(value.learning.concepts, [.init(id: "concept", subtopicID: "subtopic", name: authored,
            prerequisiteConceptIDs: ["a.prerequisite", "z.prerequisite"])])
        var expected = Export(exportedAt: try instant(), appVersion: "1.0")
        expected.learning.definitions = [definition()]
        XCTAssertEqual(value.learning.definitions, expected.canonicalized().learning.definitions)
        XCTAssertEqual(try Export.decode(value.encoded()), value)
        let projected = try XCTUnwrap(value.learning.definitions.first)
        for text in [value.learning.topics[0].name, value.learning.subtopics[0].name,
                     value.learning.concepts[0].name, projected.title, projected.objective,
                     projected.explanation, projected.referenceAnswer, projected.provenance!.attribution!] {
            XCTAssertEqual(Array(text.utf8), Array(authored.utf8))
        }
        XCTAssertEqual(projected.workedExample, " example\n")
        XCTAssertEqual(projected.exercise, " exercise\t")
        XCTAssertEqual(projected.selfCheckCriteria, [" Z check\n", " A check\t"])
    }

    @MainActor
    func testLearningDefinitionsProjectionMapsAcceptedGeneratedAllowlistAndNilReturnedModel() throws {
        for returned in [nil, "gpt-returned"] as [String?] {
            let row = try acceptedGenerated(returnedModel: returned)
            let value = try learning(definitions: [row])
            XCTAssertEqual(value.learning.definitions, [.init(id: "generated.\(secondID.uuidString.lowercased())",
                objectiveKey: row.objectiveKey, objective: row.objective, title: authored, topicID: "go",
                subtopicID: row.subtopicID, conceptIDs: row.conceptIDs.sorted(), difficulty: "intermediate",
                format: "code", estimatedMinutes: 20, prerequisiteConceptIDs: row.prerequisiteConceptIDs.sorted(),
                explanation: authored, workedExample: " example\n", exercise: " exercise\t", referenceAnswer: authored,
                selfCheckCriteria: [" Z check\n", " A check\t", " A check\t"], contentVersion: 1,
                normalizedContentHash: row.normalizedContentHash, source: "generated",
                provenance: .init(attribution: nil, generation: .init(provider: "openai", requestedModel: "gpt-test",
                    returnedModel: returned, generatedAt: try instant(), operationID: secondID,
                    requestSchemaVersion: 1, objectiveRegistryVersion: 1)))])
            XCTAssertEqual(try Export.decode(value.encoded()), value)
            let json = try object(value)
            let definitions = try XCTUnwrap((json["learning"] as? [String: Any])?["definitions"] as? [[String: Any]])
            let provenance = try XCTUnwrap(definitions[0]["provenance"] as? [String: Any])
            XCTAssertEqual(Set(provenance.keys), ["schemaVersion", "attribution", "generation"])
            let generation = try XCTUnwrap(provenance["generation"] as? [String: Any])
            XCTAssertEqual(Set(generation.keys), ["provider", "requestedModel", "returnedModel", "generatedAt",
                "operationID", "requestSchemaVersion", "objectiveRegistryVersion"])
            XCTAssertFalse(String(decoding: try value.encoded(), as: UTF8.self).contains("\"version\""))
        }
    }

    @MainActor
    func testLearningDefinitionsProjectionIncludesRetiredSeedTaxonomyWithoutCurrentMembershipFiltering() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let catalog = try BundledCatalogLoader.load()
        _ = try repository.importIfNeeded(catalog)
        let captureBefore = ModelContext(container); captureBefore.autosaveEnabled = false
        let before = try learning(topics: captureBefore.fetch(FetchDescriptor<Topic>()),
            subtopics: captureBefore.fetch(FetchDescriptor<Subtopic>()), concepts: captureBefore.fetch(FetchDescriptor<Concept>()),
            definitions: captureBefore.fetch(FetchDescriptor<LessonDefinition>()))
        var upgrade = catalog.value
        upgrade.version += 1
        let retired = Set(upgrade.subtopics.filter { $0.topicID == "go" }.map(\.id))
        upgrade.topics.removeAll { $0.id == "go" }; upgrade.subtopics.removeAll { retired.contains($0.id) }
        upgrade.concepts.removeAll { retired.contains($0.subtopicID) }; upgrade.lessons.removeAll { $0.topicID == "go" }
        _ = try repository.importIfNeeded(CatalogValidator.validate(upgrade))
        let capture = ModelContext(container); capture.autosaveEnabled = false
        let value = try learning(topics: capture.fetch(FetchDescriptor<Topic>()),
            subtopics: capture.fetch(FetchDescriptor<Subtopic>()), concepts: capture.fetch(FetchDescriptor<Concept>()),
            definitions: capture.fetch(FetchDescriptor<LessonDefinition>()))
        XCTAssertEqual(value, before)
        XCTAssertTrue(value.learning.definitions.contains { $0.topicID == "go" })
        XCTAssertTrue(value.learning.topics.contains { $0.id == "go" })
        XCTAssertFalse(capture.hasChanges)
        let membership = try XCTUnwrap(capture.fetch(FetchDescriptor<CatalogMembership>()).first).membership()
        XCTAssertFalse(membership.topicIDs.contains("go"))
        XCTAssertTrue(value.learning.progress.isEmpty); XCTAssertTrue(value.learning.slots.isEmpty)
    }

    @MainActor
    func testLearningDefinitionsProjectionPreservesLegacyEmptyObjectiveAttributionAndMissingScalarLinks() throws {
        let row = storedDefinition(provenance: "")
        row.objective = ""; row.contentVersion = 7
        row.topicID = "retired.topic"; row.subtopicID = "retired.subtopic"
        let value = try learning(definitions: [row])
        XCTAssertEqual(value.learning.definitions[0].objective, "")
        XCTAssertEqual(value.learning.definitions[0].contentVersion, 7)
        XCTAssertEqual(value.learning.definitions[0].normalizedContentHash, row.normalizedContentHash)
        XCTAssertNil(value.learning.definitions[0].provenance)
        XCTAssertEqual(value.learning.definitions[0].topicID, "retired.topic")
        XCTAssertTrue(value.learning.topics.isEmpty)
        XCTAssertEqual(try Export.decode(value.encoded()), value)
        row.provenance = " \n"
        XCTAssertThrowsError(try learning(definitions: [row])) {
            XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
        }
    }

    @MainActor
    func testLearningDefinitionsProjectionSortsDetachesAndPreservesOtherEnvelopeFields() throws {
        let topic = Topic(id: "topic", name: authored), other = Topic(id: "z.topic", name: "Other")
        let subtopic = Subtopic(id: "subtopic", topicID: "topic", name: authored)
        let otherSubtopic = Subtopic(id: "z.subtopic", topicID: "z.topic", name: "Other")
        let concept = Concept(id: "concept", subtopicID: "subtopic", name: authored,
            prerequisiteConceptIDs: ["z.prerequisite", "a.prerequisite"])
        let otherConcept = Concept(id: "z.concept", subtopicID: "z.subtopic", name: "Other")
        let seed = storedDefinition(), generated = try acceptedGenerated()
        let envelope = try rich()
        let value = try learning(topics: [other, topic], subtopics: [otherSubtopic, subtopic],
            concepts: [otherConcept, concept], definitions: [seed, generated], into: envelope)
        concept.prerequisiteConceptIDs.reverse(); seed.conceptIDs.reverse(); seed.prerequisiteConceptIDs.reverse()
        let reversed = try learning(topics: [topic, other], subtopics: [subtopic, otherSubtopic],
            concepts: [concept, otherConcept], definitions: [generated, seed], into: envelope)
        XCTAssertEqual(try value.encoded(), try reversed.encoded())
        let canonical = envelope.canonicalized()
        XCTAssertEqual(value.exportedAt, canonical.exportedAt); XCTAssertEqual(value.appVersion, canonical.appVersion)
        XCTAssertEqual(value.tasks, canonical.tasks); XCTAssertEqual(value.blocks, canonical.blocks)
        XCTAssertEqual(value.sessions, canonical.sessions); XCTAssertEqual(value.generalPreferences, canonical.generalPreferences)
        XCTAssertEqual(value.feedPreferences, canonical.feedPreferences)
        XCTAssertEqual(value.learning.progress, canonical.learning.progress)
        XCTAssertEqual(value.learning.attempts, canonical.learning.attempts)
        XCTAssertEqual(value.learning.slots, canonical.learning.slots)
        XCTAssertEqual(value.learning.terminalRecords, canonical.learning.terminalRecords)
        XCTAssertEqual(value.learning.catalogMembership, canonical.learning.catalogMembership)
        let bytes = try value.encoded()
        topic.name = "Later edit"; subtopic.topicID = "Later edit"; concept.prerequisiteConceptIDs = []
        seed.explanation = "Later edit"; generated.provenance = "damaged"
        XCTAssertEqual(try value.encoded(), bytes)
        XCTAssertEqual(try learning(), try Export(exportedAt: instant(), appVersion: "1.0"))
    }

    @MainActor
    func testLearningDefinitionsProjectionRejectsDuplicateCollectionsAndReferenceSetsWithoutDeduplication() throws {
        let topic = Topic(id: "topic", name: "Topic")
        let subtopic = Subtopic(id: "subtopic", topicID: "topic", name: "Subtopic")
        let concept = Concept(id: "concept", subtopicID: "subtopic", name: "Concept")
        let row = storedDefinition()
        for capture in [
            { try self.learning(topics: [topic, topic]) }, { try self.learning(subtopics: [subtopic, subtopic]) },
            { try self.learning(concepts: [concept, concept]) }, { try self.learning(definitions: [row, row]) },
            { concept.prerequisiteConceptIDs = ["same", "same"]; return try self.learning(concepts: [concept]) },
            { row.conceptIDs = ["same", "same"]; return try self.learning(definitions: [row]) },
            { row.conceptIDs = ["concept"]; row.prerequisiteConceptIDs = ["same", "same"]
              return try self.learning(definitions: [row]) }
        ] {
            XCTAssertThrowsError(try capture()) { XCTAssertEqual($0 as? LocalDataExportError, .duplicateIdentity) }
        }
    }

    @MainActor
    func testLearningDefinitionsProjectionRejectsDamagedTaxonomyIdentitiesAndNames() throws {
        let topic = Topic(id: "topic", name: "Topic")
        let subtopic = Subtopic(id: "subtopic", topicID: "topic", name: "Subtopic")
        let concept = Concept(id: "concept", subtopicID: "subtopic", name: "Concept")
        for badID in ["", " ", " spaced", "e\u{301}"] {
            topic.id = badID; subtopic.id = badID; concept.id = badID
            for capture in [{ try self.learning(topics: [topic]) }, { try self.learning(subtopics: [subtopic]) },
                            { try self.learning(concepts: [concept]) }] {
                XCTAssertThrowsError(try capture()) { XCTAssertEqual($0 as? LocalDataExportError, .invalidValue) }
            }
        }
        topic.id = "topic"; subtopic.id = "subtopic"; concept.id = "concept"
        topic.name = "\n"; subtopic.topicID = " bad"; concept.subtopicID = ""
        XCTAssertThrowsError(try learning(topics: [topic]))
        XCTAssertThrowsError(try learning(subtopics: [subtopic]))
        XCTAssertThrowsError(try learning(concepts: [concept]))
        subtopic.topicID = "topic"; subtopic.name = "\t"
        concept.subtopicID = "subtopic"; concept.name = " "
        XCTAssertThrowsError(try learning(subtopics: [subtopic]))
        XCTAssertThrowsError(try learning(concepts: [concept]))
        concept.name = "Concept"; concept.prerequisiteConceptIDs = [" spaced"]
        XCTAssertThrowsError(try learning(concepts: [concept]))
    }

    @MainActor
    func testLearningDefinitionsProjectionRejectsCorruptIncludedDefinitionContentWithoutRepair() throws {
        let mutations: [(LessonDefinition) -> Void] = [
            { $0.id = " lesson" }, { $0.id = "e\u{301}" }, { $0.topicID = "e\u{301}" },
            { $0.subtopicID = "e\u{301}" }, { $0.conceptIDs = ["e\u{301}"] },
            { $0.prerequisiteConceptIDs = ["e\u{301}"] },
            { $0.topicID = "" }, { $0.subtopicID = " " }, { $0.title = "\n" },
            { $0.objectiveKey = " " }, { $0.objective = "\t" }, { $0.conceptIDs = [] },
            { $0.conceptIDs = [" noncanonical"] }, { $0.prerequisiteConceptIDs = [""] },
            { $0.difficulty = "unknown" }, { $0.format = "video" }, { $0.source = "bundle" },
            { $0.estimatedMinutes = 0 }, { $0.contentVersion = 0 }, { $0.contentVersion = -1 },
            { $0.normalizedContentHash = "digest" }, { $0.normalizedContentHash = "sha256:" + String(repeating: "0", count: 64) },
            { $0.explanation = " " }, { $0.workedExample = " " }, { $0.exercise = " " }, { $0.referenceAnswer = " " },
            { $0.selfCheckCriteria = [] }, { $0.selfCheckCriteria = [" "] },
            { $0.explanation += "corrupt change" }, { $0.selfCheckCriteria.reverse() }
        ]
        for mutate in mutations {
            let row = storedDefinition(); mutate(row)
            let originalHash = row.normalizedContentHash, originalBody = row.explanation
            XCTAssertThrowsError(try learning(definitions: [row])) {
                XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
            }
            XCTAssertEqual(row.normalizedContentHash, originalHash); XCTAssertEqual(row.explanation, originalBody)
        }
    }

    @MainActor
    func testLearningDefinitionsProjectionRejectsMalformedUnsupportedAndUnknownGeneratedProvenance() throws {
        let row = try acceptedGenerated()
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.provenance.utf8)) as? [String: Any])
        func reject(_ object: [String: Any], _ error: LocalDataExportError = .invalidValue) throws {
            row.provenance = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertThrowsError(try learning(definitions: [row])) { XCTAssertEqual($0 as? LocalDataExportError, error) }
        }
        for key in baseline.keys {
            var missing = baseline; missing.removeValue(forKey: key); try reject(missing)
        }
        for (key, bad): (String, Any) in [("version", 2), ("requestSchemaVersion", 2)] {
            var object = baseline; object[key] = bad; try reject(object, .unsupportedVersion)
        }
        for (key, bad): (String, Any) in [
            ("version", true), ("provider", "other"), ("requestedModel", "bad model"),
            ("returnedModel", "bad model"), ("returnedModel", 42), ("generatedAt", "2026-02-30T00:00:00.000Z"),
            ("objectiveRegistryVersion", 0), ("operationID", "not-a-uuid"), ("requestSchemaVersion", "1"),
            ("credentialReference", "excluded-secret"), ("payload", ["password": "excluded-secret"])
        ] {
            var object = baseline; object[key] = bad
            try reject(object, key == "generatedAt" ? .invalidDate : .invalidValue)
        }
        var mismatch = baseline; mismatch["operationID"] = firstID.uuidString
        try reject(mismatch, .identityMismatch)
        for malformed in ["", " ", "not JSON", "[]", "null", "{}"] {
            row.provenance = malformed
            XCTAssertThrowsError(try learning(definitions: [row])) {
                XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
            }
        }
        var explicitNull = baseline; explicitNull["returnedModel"] = NSNull()
        row.provenance = String(decoding: try JSONSerialization.data(withJSONObject: explicitNull), as: UTF8.self)
        XCTAssertNil(try learning(definitions: [row]).learning.definitions[0].provenance?.generation?.returnedModel)
    }

    @MainActor
    func testLearningDefinitionsProjectionEnforcesGeneratedAcceptanceContentBounds() throws {
        let mutations: [(LessonDefinition) -> Void] = [
            { $0.title = String(repeating: "x", count: 201) }, { $0.objective = String(repeating: "x", count: 1_001) },
            { $0.objective = "" }, { $0.explanation = String(repeating: "x", count: 12_001) },
            { $0.workedExample = String(repeating: "x", count: 12_001) },
            { $0.exercise = String(repeating: "x", count: 12_001) },
            { $0.referenceAnswer = String(repeating: "x", count: 12_001) },
            { $0.selfCheckCriteria = Array(repeating: "Check", count: 11) },
            { $0.selfCheckCriteria = [String(repeating: "x", count: 1_001)] },
            { $0.conceptIDs = (0..<21).map { "concept.\($0)" } },
            { $0.prerequisiteConceptIDs = (0..<21).map { "prerequisite.\($0)" } }, { $0.estimatedMinutes = 121 }
        ]
        for mutate in mutations {
            let row = try acceptedGenerated(); mutate(row)
            row.normalizedContentHash = CatalogValidator.fingerprint(explanation: row.explanation,
                workedExample: row.workedExample, exercise: row.exercise, referenceAnswer: row.referenceAnswer,
                selfCheckCriteria: row.selfCheckCriteria)
            XCTAssertThrowsError(try learning(definitions: [row])) {
                XCTAssertEqual($0 as? LocalDataExportError, .invalidValue)
            }
        }
    }

    @MainActor
    func testLearningDefinitionsProjectionNeverSeedsReconcilesSavesOrChangesAnotherOwnersDraft() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        func capture(_ context: ModelContext) throws -> Export {
            try learning(topics: context.fetch(FetchDescriptor<Topic>()), subtopics: context.fetch(FetchDescriptor<Subtopic>()),
                concepts: context.fetch(FetchDescriptor<Concept>()), definitions: context.fetch(FetchDescriptor<LessonDefinition>()))
        }
        func inventory(_ context: ModelContext) throws -> [Int] {
            try [context.fetchCount(FetchDescriptor<Topic>()), context.fetchCount(FetchDescriptor<Subtopic>()),
                context.fetchCount(FetchDescriptor<Concept>()), context.fetchCount(FetchDescriptor<LessonDefinition>()),
                context.fetchCount(FetchDescriptor<LessonProgress>()), context.fetchCount(FetchDescriptor<LessonAttempt>()),
                context.fetchCount(FetchDescriptor<LessonSlot>()), context.fetchCount(FetchDescriptor<CatalogMembership>()),
                context.fetchCount(FetchDescriptor<LessonTerminalRecord>()), context.fetchCount(FetchDescriptor<CatalogImportState>())]
        }
        let empty = ModelContext(container); empty.autosaveEnabled = false
        XCTAssertEqual(try capture(empty), try learning())
        XCTAssertFalse(empty.hasChanges); XCTAssertEqual(try inventory(ModelContext(container)), Array(repeating: 0, count: 10))
        let seed = ModelContext(container); seed.autosaveEnabled = false
        seed.insert(Topic(id: "topic", name: authored)); seed.insert(Subtopic(id: "subtopic", topicID: "topic", name: authored))
        seed.insert(Concept(id: "concept", subtopicID: "subtopic", name: authored)); seed.insert(storedDefinition())
        seed.insert(try acceptedGenerated()); try seed.save()
        let draftOwner = ModelContext(container); draftOwner.autosaveEnabled = false
        let draft = try XCTUnwrap(draftOwner.fetch(FetchDescriptor<LessonDefinition>()).first { $0.id == "lesson" })
        draft.title = "Unsaved definition edit"
        let read = ModelContext(container); read.autosaveEnabled = false
        let value = try capture(read)
        XCTAssertFalse(read.hasChanges); XCTAssertTrue(draftOwner.hasChanges)
        XCTAssertEqual(draft.title, "Unsaved definition edit")
        XCTAssertEqual(value.learning.definitions.first { $0.id == "lesson" }?.title, authored)
        let inspect = ModelContext(container); inspect.autosaveEnabled = false
        XCTAssertEqual(try capture(inspect), value)
        XCTAssertEqual(try inventory(inspect), [1, 1, 1, 2, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(inspect.hasChanges)
        let damaged = try XCTUnwrap(read.fetch(FetchDescriptor<LessonDefinition>()).first)
        damaged.provenance = "\n"; try read.save()
        let failedCapture = ModelContext(container); failedCapture.autosaveEnabled = false
        XCTAssertThrowsError(try capture(failedCapture))
        XCTAssertFalse(failedCapture.hasChanges)
        XCTAssertEqual(try inventory(ModelContext(container)), [1, 1, 1, 2, 0, 0, 0, 0, 0, 0])
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
