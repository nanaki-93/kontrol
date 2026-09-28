import Foundation
import SwiftData
import XCTest
@testable import Kontrol

final class SchemaTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainerFactory().makeContainer(mode: .inMemory)
    }

    func testV1AndV2IdentitiesRemainAndV3AddsOnlyFocusSession() {
        XCTAssertEqual(KontrolSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(KontrolSchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
        XCTAssertEqual(KontrolSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
        XCTAssertEqual(KontrolMigrationPlan.schemas.count, 3)
        XCTAssertTrue(KontrolMigrationPlan.schemas[0] == KontrolSchemaV1.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[1] == KontrolSchemaV2.self)
        XCTAssertTrue(KontrolMigrationPlan.schemas[2] == KontrolSchemaV3.self)
        XCTAssertEqual(KontrolMigrationPlan.stages.count, 2)
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
        XCTAssertEqual(try context.fetch(FetchDescriptor<CatalogImportState>()).first?.lastImportedVersion, 3)

        let snapshot = KontrolSchemaV1.LessonContentSnapshot(
            title: lesson.title, objectiveKey: lesson.objectiveKey, conceptIDs: lesson.conceptIDs,
            difficulty: lesson.difficulty, format: lesson.format,
            explanation: lesson.explanation, workedExample: lesson.workedExample,
            exercise: lesson.exercise, referenceAnswer: lesson.referenceAnswer,
            selfCheckCriteria: lesson.selfCheckCriteria)
        attempt.completedContentSnapshot = snapshot
        attempt.completedAt = Date(timeIntervalSince1970: 2_000)
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
        XCTAssertNotNil(savedAttempt.completedAt)
        XCTAssertEqual(savedProgress.lessonID, lesson.id)
        XCTAssertEqual(savedProgress.status, .available)
        XCTAssertEqual(savedImport.catalogID, "starter")
        XCTAssertEqual(savedImport.lastImportedVersion, 3)
    }
}
