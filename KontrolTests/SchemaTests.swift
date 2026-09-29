import Foundation
import SwiftData
import XCTest
@testable import Kontrol

final class SchemaTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainerFactory().makeContainer(mode: .inMemory)
    }

    func testReleasedIdentitiesRemainAndV7OnlyAddsSettings() {
        XCTAssertEqual(KontrolSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(KontrolSchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
        XCTAssertEqual(KontrolSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
        XCTAssertEqual(KontrolSchemaV4.versionIdentifier, Schema.Version(4, 0, 0))
        XCTAssertEqual(KontrolSchemaV5.versionIdentifier, Schema.Version(5, 0, 0))
        XCTAssertEqual(KontrolSchemaV6.versionIdentifier, Schema.Version(6, 0, 0))
        XCTAssertEqual(KontrolSchemaV7.versionIdentifier, Schema.Version(7, 0, 0))
        XCTAssertEqual(KontrolMigrationPlan.schemas.count, 7)
        XCTAssertTrue(KontrolMigrationPlan.schemas[0] == KontrolSchemaV1.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[1] == KontrolSchemaV2.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[2] == KontrolSchemaV3.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[3] == KontrolSchemaV4.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[4] == KontrolSchemaV5.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[5] == KontrolSchemaV6.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[6] == KontrolSchemaV7.self)
        XCTAssertEqual(KontrolMigrationPlan.stages.count, 6)
        let v1 = KontrolSchemaV1.models
        XCTAssertEqual(Set(v1.map { String(describing: $0) }),
                       Set(["TaskItem", "Topic", "Subtopic", "Concept",
                            "LessonDefinition", "LessonProgress", "LessonAttempt",
                            "CatalogImportState"]))
        let v2 = KontrolSchemaV2.models
        XCTAssertEqual(v2.count, v1.count + 1)
        for (original, retained) in zip(v1, v2) {
            XCTAssertTrue(original == retained)
        }
        XCTAssertTrue(v2.last == ScheduleBlock.self)
        let v3 = KontrolSchemaV3.models
        XCTAssertEqual(v3.count, v2.count + 1)
        for (original, retained) in zip(v2, v3) {
            XCTAssertTrue(original == retained)
        }
        XCTAssertTrue(v3.last == FocusSession.self)
        let v4 = KontrolSchemaV4.models
        XCTAssertEqual(v4.count, v3.count + 1)
        for historical in v3 where historical != KontrolSchemaV1.LessonDefinition.self {
            XCTAssertTrue(v4.contains { $0 == historical })
        }
        XCTAssertFalse(v4.contains { $0 == KontrolSchemaV1.LessonDefinition.self })
        XCTAssertTrue(v4.contains { $0 == LessonDefinition.self })
        XCTAssertTrue(v4.contains { $0 == LessonSlot.self })
        XCTAssertTrue(v4.contains { $0 == KontrolSchemaV1.LessonAttempt.self })
        let v5 = KontrolSchemaV5.models
        XCTAssertEqual(v5.count, v4.count)
        for historical in v4 where historical != KontrolSchemaV1.LessonAttempt.self {
            XCTAssertTrue(v5.contains { $0 == historical })
        }
        XCTAssertFalse(v5.contains { $0 == KontrolSchemaV1.LessonAttempt.self })
        XCTAssertTrue(v5.contains { $0 == LessonAttempt.self })
        let v6 = KontrolSchemaV6.models
        XCTAssertEqual(v6.count, v5.count + 2)
        for (original, retained) in zip(v5, v6) { XCTAssertTrue(original == retained) }
        XCTAssertTrue(v6.contains { $0 == LessonTerminalRecord.self })
        XCTAssertTrue(v6.contains { $0 == CatalogMembership.self })
        let v7 = KontrolSchemaV7.models
        XCTAssertEqual(v7.count, v6.count + 1)
        for (original, retained) in zip(v6, v7) { XCTAssertTrue(original == retained) }
        XCTAssertTrue(v7.last == AISettingsRecord.self)
    }

    func testEvidencePayloadValidationClassificationAndIdentity() throws {
        let metadata = LessonTerminalMetadata(
            lessonID: "lesson", provenance: .legacyCompletedPartial, title: "Original",
            topicID: nil, subtopicID: nil, contentVersion: 1, objectiveKey: "goal",
            conceptIDs: ["a"], normalizedContentHash: nil, format: nil,
            dismissalTimeDefinition: nil)
        let row = try LessonTerminalRecord(metadata: metadata)
        XCTAssertEqual(try row.metadata(), metadata)
        XCTAssertNil(try row.metadata().topicID) // known unknown, not a current definition
        row.lessonID = "different"
        XCTAssertThrowsError(try row.metadata()) { XCTAssertEqual($0 as? LearningEvidenceError, .identityMismatch) }
        row.lessonID = "lesson"
        row.payload = Data(#"{"version":9,"value":{}}"#.utf8)
        XCTAssertThrowsError(try row.metadata()) { XCTAssertEqual($0 as? LearningEvidenceError, .unsupportedVersion(9)) }
        row.payload = Data(#"{"version":1,"value":{}}"#.utf8)
        XCTAssertThrowsError(try row.metadata()) { XCTAssertEqual($0 as? LearningEvidenceError, .corruptPayload) }
        row.payload = Data("garbage".utf8)
        XCTAssertThrowsError(try row.metadata()) { XCTAssertEqual($0 as? LearningEvidenceError, .corruptPayload) }
        XCTAssertThrowsError(try LessonTerminalRecord(metadata: LessonTerminalMetadata(
            lessonID: "lesson", provenance: .studiedPin, title: nil, topicID: nil,
            subtopicID: nil, contentVersion: nil, objectiveKey: nil, conceptIDs: nil,
            normalizedContentHash: nil, format: nil, dismissalTimeDefinition: nil))) {
            XCTAssertEqual($0 as? LearningEvidenceError, .invalidPayload)
        }
        let duplicate = try LessonTerminalRecord(metadata: metadata)
        XCTAssertThrowsError(try EvidenceIdentity.terminalMetadata([row, duplicate])) {
            XCTAssertEqual($0 as? LearningEvidenceError, .duplicateIdentity)
        }
        XCTAssertThrowsError(try EvidenceIdentity.requireUnique(["a", "a"], id: { $0 })) {
            XCTAssertEqual($0 as? LearningEvidenceError, .duplicateIdentity)
        }
    }

    func testFullTerminalMatchingFieldsRejectInvalidWritesAndReads() throws {
        let hash = CatalogValidator.fingerprint(explanation: "Explanation", workedExample: "Example",
            exercise: "Exercise", referenceAnswer: "Answer", selfCheckCriteria: ["Check"])
        func metadata(objective: String = "Goal", concepts: [String] = ["a", "b"],
                      hash: String) -> LessonTerminalMetadata {
            LessonTerminalMetadata(lessonID: "lesson", provenance: .studiedPin,
                title: "Title", topicID: "topic", subtopicID: "subtopic",
                contentVersion: 1, objectiveKey: objective, conceptIDs: concepts,
                normalizedContentHash: hash, format: "learn", dismissalTimeDefinition: nil)
        }
        let valid = metadata(hash: hash)
        XCTAssertEqual(try LessonTerminalRecord(metadata: valid).metadata(), valid)
        let invalid = [
            metadata(objective: " \n ", hash: hash),
            metadata(concepts: [], hash: hash),
            metadata(concepts: ["a", " a"], hash: hash),
            metadata(concepts: ["a", "a"], hash: hash),
            metadata(concepts: ["b", "a"], hash: hash),
            metadata(hash: "sha256:old"),
            metadata(hash: "sha256:" + String(repeating: "G", count: 64)),
            metadata(hash: "sha256:" + String(repeating: "A", count: 64))
        ]
        struct Envelope: Encodable {
            let version: Int
            let value: LessonTerminalMetadata
        }
        for value in invalid {
            XCTAssertThrowsError(try LessonTerminalRecord(metadata: value)) {
                XCTAssertEqual($0 as? LearningEvidenceError, .invalidPayload)
            }
            // A raw persisted payload must be classified on read, too; validation
            // cannot rely on the convenience initializer having run previously.
            let row = LessonTerminalRecord(lessonID: value.lessonID,
                payload: try JSONEncoder().encode(Envelope(version: 1, value: value)))
            XCTAssertThrowsError(try row.metadata()) {
                XCTAssertEqual($0 as? LearningEvidenceError, .invalidPayload)
            }
        }
        XCTAssertThrowsError(try LessonTerminalRecord(metadata: LessonTerminalMetadata(
            lessonID: "lesson", provenance: .legacyCompletedPartial, title: "Old",
            topicID: nil, subtopicID: nil, contentVersion: 1, objectiveKey: nil,
            conceptIDs: [], normalizedContentHash: nil, format: nil,
            dismissalTimeDefinition: nil))) {
            XCTAssertEqual($0 as? LearningEvidenceError, .invalidPayload)
        }
    }

    func testDismissalReferenceIsDetachedAndNotStudiedContent() throws {
        let reference = LessonDefinitionSnapshot(
            id: "lesson", objectiveKey: "goal", objective: "Goal", title: "Dismissed title",
            topicID: "topic", subtopicID: "subtopic", conceptIDs: ["concept"],
            difficulty: "basic", format: "learn", estimatedMinutes: 5,
            prerequisiteConceptIDs: [], explanation: "Old explanation", workedExample: "Old example",
            exercise: "Old exercise", referenceAnswer: "Old answer", selfCheckCriteria: ["Old criterion"],
            contentVersion: 1, normalizedContentHash: CatalogValidator.fingerprint(
                explanation: "Old explanation", workedExample: "Old example", exercise: "Old exercise",
                referenceAnswer: "Old answer", selfCheckCriteria: ["Old criterion"]), source: "seed",
            provenance: "starter")
        let metadata = LessonTerminalMetadata(
            lessonID: "lesson", provenance: .dismissalReference, title: reference.title,
            topicID: reference.topicID, subtopicID: reference.subtopicID,
            contentVersion: reference.contentVersion, objectiveKey: reference.objectiveKey,
            conceptIDs: reference.conceptIDs, normalizedContentHash: reference.normalizedContentHash,
            format: reference.format, dismissalTimeDefinition: reference)
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(try LessonTerminalRecord(metadata: metadata))
        try context.save()
        let reopened = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<LessonTerminalRecord>()).first)
        XCTAssertEqual(try reopened.metadata(), metadata)
        XCTAssertEqual(try reopened.metadata().dismissalTimeDefinition?.explanation, "Old explanation")
        XCTAssertThrowsError(try LessonTerminalRecord(metadata: LessonTerminalMetadata(
            lessonID: "lesson", provenance: .studiedPin, title: reference.title,
            topicID: reference.topicID, subtopicID: reference.subtopicID,
            contentVersion: 1, objectiveKey: reference.objectiveKey, conceptIDs: reference.conceptIDs,
            normalizedContentHash: reference.normalizedContentHash, format: reference.format,
            dismissalTimeDefinition: reference))) {
            XCTAssertEqual($0 as? LearningEvidenceError, .invalidPayload)
        }
    }

    func testMembershipAvailabilityAndVersionedPersistence() throws {
        let container = try makeContainer()
        let membership = CurrentCatalogMembership(catalogID: "starter", catalogVersion: 2,
            topicIDs: ["go"], subtopicIDs: ["go.basic"], conceptIDs: [], seededLessonIDs: [])
        XCTAssertEqual(CatalogMembershipAvailability.unavailable, .unavailable)
        let context = ModelContext(container)
        context.insert(try CatalogMembership(membership: membership))
        try context.save()
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<CatalogMembership>()).first)
        XCTAssertEqual(try saved.membership(), membership)
        XCTAssertEqual(try EvidenceIdentity.membership([saved], catalogID: "starter", installedVersion: 2),
                       .available(membership))
        XCTAssertEqual(try EvidenceIdentity.membership([saved], catalogID: "starter", installedVersion: 1),
                       .unavailable)
        XCTAssertEqual(try EvidenceIdentity.membership([saved], catalogID: "other", installedVersion: 2),
                       .unavailable)
        let duplicate = try CatalogMembership(membership: membership)
        XCTAssertThrowsError(try EvidenceIdentity.membership([saved, duplicate], catalogID: "starter",
                                                          installedVersion: 2)) {
            XCTAssertEqual($0 as? LearningEvidenceError, .duplicateIdentity)
        }
        saved.payload = Data(#"{"version":2,"value":{}}"#.utf8)
        XCTAssertThrowsError(try saved.membership()) { XCTAssertEqual($0 as? LearningEvidenceError, .unsupportedVersion(2)) }
        saved.catalogID = "wrong"
        saved.payload = try CatalogMembership(membership: membership).payload
        XCTAssertThrowsError(try saved.membership()) { XCTAssertEqual($0 as? LearningEvidenceError, .identityMismatch) }
        XCTAssertThrowsError(try CatalogMembership(membership: CurrentCatalogMembership(
            catalogID: "starter", catalogVersion: 2, topicIDs: ["go", "go"],
            subtopicIDs: [], conceptIDs: [], seededLessonIDs: []))) {
            XCTAssertEqual($0 as? LearningEvidenceError, .invalidPayload)
        }
    }

    func testV4SlotScalarKeysAndDefinitionObjectiveSurviveReopen() throws {
        let container = try makeContainer()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ModelContext(container)
        let slot = LessonSlot(topicID: "go:1", slotIndex: 2, lessonID: "go.lesson", assignedAt: at)
        let other = LessonSlot(topicID: "go", slotIndex: 1, lessonID: "go.other", assignedAt: at)
        XCTAssertNotEqual(slot.key, other.key)
        XCTAssertEqual(slot.key, LessonSlot.canonicalKey(topicID: slot.topicID, slotIndex: slot.slotIndex))
        context.insert(slot)
        context.insert(other)
        try context.save()
        let rows = try ModelContext(container).fetch(FetchDescriptor<LessonSlot>())
        XCTAssertEqual(rows.count, 2)
        let stored = try XCTUnwrap(rows.first { $0.lessonID == "go.lesson" })
        XCTAssertEqual(stored.key, "4:go:1:2")
        XCTAssertEqual(stored.topicID, "go:1")
        XCTAssertEqual(stored.slotIndex, 2)
        XCTAssertEqual(stored.assignedAt, at)
    }

    func testFocusSessionScalarFieldsPersistWithoutChangingOtherEntities() throws {
        let container = try makeContainer()
        let id = UUID()
        let taskID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let anchor = start.addingTimeInterval(12.5)
        let deadline = start.addingTimeInterval(1_500)
        let session = FocusSession(id: id, state: "running", plannedSeconds: 1_500,
                                   accumulatedActiveSeconds: 12.5,
                                   activeSegmentStartedAt: anchor, deadline: deadline,
                                   startedAt: start, checkpointAt: anchor,
                                   linkedTaskID: taskID, linkedTitleSnapshot: "Old task title")
        let context = ModelContext(container)
        context.insert(session)
        try context.save()

        let readContext = ModelContext(container)
        let stored = try XCTUnwrap(readContext.fetch(FetchDescriptor<FocusSession>()).first)
        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.state, "running")
        XCTAssertEqual(stored.plannedSeconds, 1_500)
        XCTAssertEqual(stored.accumulatedActiveSeconds, 12.5)
        XCTAssertEqual(stored.activeSegmentStartedAt, anchor)
        XCTAssertEqual(stored.deadline, deadline)
        XCTAssertNil(stored.pausedAt)
        XCTAssertEqual(stored.startedAt, start)
        XCTAssertNil(stored.endedAt)
        XCTAssertEqual(stored.checkpointAt, anchor)
        XCTAssertFalse(stored.recoveryRequired)
        XCTAssertEqual(stored.linkedTaskID, taskID)
        XCTAssertNil(stored.linkedLessonID)
        XCTAssertEqual(stored.linkedTitleSnapshot, "Old task title")

        stored.state = "ended"
        stored.activeSegmentStartedAt = nil
        stored.deadline = nil
        stored.endedAt = anchor
        stored.linkedTaskID = nil
        stored.linkedLessonID = "lesson-1"
        try readContext.save()
        let updated = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<FocusSession>()).first)
        XCTAssertEqual(updated.state, "ended")
        XCTAssertNil(updated.activeSegmentStartedAt)
        XCTAssertNil(updated.deadline)
        XCTAssertNil(updated.pausedAt)
        XCTAssertEqual(updated.endedAt, anchor)
        XCTAssertFalse(updated.recoveryRequired)
        XCTAssertNil(updated.linkedTaskID)
        XCTAssertEqual(updated.linkedLessonID, "lesson-1")
    }

    func testTaskTrimsTitleRejectsBlankAndDerivesCompletionFromTimestamp() throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let task = try TaskItem(id: id, title: "  Review tests \n", createdAt: now)
        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.title, "Review tests")
        XCTAssertNil(task.notes)
        XCTAssertNil(task.dueAt)
        XCTAssertNil(task.plannedDay)
        XCTAssertNil(task.plannedTimeZoneID)
        XCTAssertNil(task.completedAt)
        XCTAssertFalse(task.isCompleted)
        XCTAssertThrowsError(try TaskItem(id: UUID(), title: " \n ", createdAt: now))

        let day = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian", year: 2026, month: 9, day: 27)
        XCTAssertThrowsError(try TaskItem(id: UUID(), title: "X", createdAt: now,
                                          plannedDay: day))
        XCTAssertThrowsError(try TaskItem(id: UUID(), title: "X", createdAt: now,
                                          plannedTimeZoneID: "America/New_York"))
        task.plannedDay = day
        task.plannedTimeZoneID = "America/New_York"
        task.completedAt = now
        XCTAssertTrue(task.isCompleted)
        task.completedAt = nil
        XCTAssertFalse(task.isCompleted)

        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(task)
        try context.save()
        let readContext = ModelContext(container)
        let stored = try XCTUnwrap(readContext.fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.title, "Review tests")
        XCTAssertEqual(stored.plannedDay?.calendarIdentifier, "gregorian")
        XCTAssertEqual(stored.plannedDay?.year, day.year)
        XCTAssertEqual(stored.plannedDay?.month, day.month)
        XCTAssertEqual(stored.plannedDay?.day, day.day)
        XCTAssertEqual(stored.plannedTimeZoneID, "America/New_York")
        XCTAssertFalse(stored.isCompleted)

        let anotherID = UUID()
        let due = now.addingTimeInterval(3_600)
        let withOptionals = try TaskItem(id: anotherID, title: "With notes", createdAt: now,
                                         notes: "details", dueAt: due, plannedDay: day,
                                         plannedTimeZoneID: "America/New_York", completedAt: due)
        context.insert(withOptionals)
        try context.save()
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first(where: { $0.id == anotherID }))
        XCTAssertEqual(saved.notes, "details")
        XCTAssertEqual(saved.dueAt, due)
        XCTAssertEqual(saved.plannedDay, day)
        XCTAssertTrue(saved.isCompleted)
    }

    func testCatalogDefinitionAndPersonalStateAreIndependent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let topic = Topic(id: "go", name: "Go")
        let subtopic = Subtopic(id: "go.concurrency", topicID: topic.id, name: "Concurrency")
        let concept = Concept(id: "go.concurrency.cancel", subtopicID: subtopic.id,
                              name: "Cancellation", prerequisiteConceptIDs: [])
        let lesson = LessonDefinition(
            id: "go.cancel.1", objectiveKey: "go.concurrency.cancel-work",
            title: "Cancel work", topicID: topic.id, subtopicID: subtopic.id,
            conceptIDs: [concept.id], difficulty: "intermediate", format: "learn",
            estimatedMinutes: 12, explanation: "Explain", workedExample: "Example",
            exercise: "Exercise", referenceAnswer: "Answer", selfCheckCriteria: ["Check"],
            contentVersion: 2, normalizedContentHash: "digest", source: "seed",
            provenance: "starter-catalog")
        let progress = LessonProgress(lessonID: lesson.id)
        let attemptID = UUID()
        let attempt = LessonAttempt(id: attemptID, lessonID: lesson.id, contentVersion: 2,
                                    answerDraft: "Personal draft")
        let importState = CatalogImportState(catalogID: "starter", lastImportedVersion: 3)
        context.insert(topic)
        context.insert(subtopic)
        context.insert(concept)
        context.insert(lesson)
        context.insert(progress)
        context.insert(attempt)
        context.insert(importState)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Topic>()).first?.id, topic.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subtopic>()).first?.topicID, topic.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Concept>()).first?.subtopicID, subtopic.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonDefinition>()).first?.conceptIDs, [concept.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonDefinition>()).first?.contentVersion, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonDefinition>()).first?.objective, "")
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonProgress>()).first?.status, .available)
        XCTAssertNil(progress.firstShownAt)
        XCTAssertNil(progress.startedAt)
        XCTAssertNil(progress.completedAt)
        XCTAssertNil(progress.dismissedAt)
        XCTAssertNil(progress.lastOpenedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonAttempt>()).first?.id, attemptID)
        XCTAssertNil(attempt.completedContentSnapshot)
        XCTAssertNil(attempt.solutionRevealedAt)
        XCTAssertNil(attempt.selfCheckAcknowledgedAt)
        XCTAssertNil(attempt.completedAt)
        XCTAssertNil(attempt.pinnedContentData)
        XCTAssertEqual(attempt.revision, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CatalogImportState>()).first?.lastImportedVersion, 3)

        let snapshot = KontrolSchemaV1.LessonContentSnapshot(
            title: lesson.title, objectiveKey: lesson.objectiveKey, conceptIDs: lesson.conceptIDs,
            difficulty: lesson.difficulty, format: lesson.format,
            explanation: lesson.explanation, workedExample: lesson.workedExample,
            exercise: lesson.exercise, referenceAnswer: lesson.referenceAnswer,
            selfCheckCriteria: lesson.selfCheckCriteria)
        attempt.completedContentSnapshot = snapshot
        attempt.completedAt = Date(timeIntervalSince1970: 2_000)
        attempt.pinnedContentData = Data([0, 1, 255])
        attempt.revision = 3
        lesson.title = "Corrected title"
        try context.save()
        let reopened = ModelContext(container)
        let savedLesson = try XCTUnwrap(reopened.fetch(FetchDescriptor<LessonDefinition>()).first)
        let savedProgress = try XCTUnwrap(reopened.fetch(FetchDescriptor<LessonProgress>()).first)
        let savedAttempt = try XCTUnwrap(reopened.fetch(FetchDescriptor<LessonAttempt>()).first)
        let savedImport = try XCTUnwrap(reopened.fetch(FetchDescriptor<CatalogImportState>()).first)
        XCTAssertEqual(savedLesson.id, lesson.id)
        XCTAssertEqual(savedLesson.title, "Corrected title")
        XCTAssertEqual(savedLesson.selfCheckCriteria, ["Check"])
        XCTAssertEqual(savedAttempt.completedContentSnapshot, snapshot)
        XCTAssertEqual(savedAttempt.completedContentSnapshot?.title, "Cancel work")
        XCTAssertEqual(savedAttempt.answerDraft, "Personal draft")
        XCTAssertEqual(savedAttempt.contentVersion, 2)
        XCTAssertEqual(savedAttempt.pinnedContentData, Data([0, 1, 255]))
        XCTAssertEqual(savedAttempt.revision, 3)
        XCTAssertNotNil(savedAttempt.completedAt)
        XCTAssertEqual(savedProgress.lessonID, lesson.id)
        XCTAssertEqual(savedProgress.status, .available)
        XCTAssertEqual(savedImport.catalogID, "starter")
        XCTAssertEqual(savedImport.lastImportedVersion, 3)
    }
}
