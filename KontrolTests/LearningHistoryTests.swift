import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LearningHistoryTests: XCTestCase {
    private let first = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_100)

    private func setup(_ url: URL? = nil) throws -> (ModelContainer, SwiftDataCatalogRepository) {
        let container = try ModelContainerFactory().makeContainer(mode: url.map { .persistent($0) } ?? .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        return (container, repository)
    }

    func testHistoryIsReadOnlyOrderedAndUsesStudiedContentAfterUpgradeAndReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolHistory-\(UUID().uuidString)/Kontrol.store")
        var ids: [String] = []
        var archived: [LessonHistorySnapshot] = []
        try autoreleasepool {
            let (container, writer) = try setup(url)
            ids = Array(try writer.loadSnapshot().slots.prefix(3).map(\.lessonID)).sorted()
            let baseline = try writer.loadSnapshot()
            XCTAssertTrue(try writer.loadHistory().isEmpty)
            XCTAssertEqual(try writer.loadSnapshot(), baseline)
            for id in ids.prefix(2) {
                let opened = try writer.openLesson(lessonID: id, now: first)
                let attempt = try XCTUnwrap(opened.detail.attempt)
                _ = try writer.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "  🧪\n  keep\n")
                let slot = try XCTUnwrap(baseline.slots.first { $0.lessonID == id })
                _ = try writer.dismiss(lessonID: id, expectedSlot: slot, now: later)
            }
            let last = try XCTUnwrap(ids.last)
            let opened = try writer.openLesson(lessonID: last, now: first)
            let attempt = try XCTUnwrap(opened.detail.attempt)
            _ = try writer.revealSolution(attemptID: attempt.id, expectedRevision: 0, now: first)
            _ = try writer.setSelfCheckAcknowledged(attemptID: attempt.id,
                expectedRevision: 1, acknowledged: true, now: later)
            _ = try writer.complete(attemptID: attempt.id, expectedRevision: 2, now: later)
            archived = try writer.loadHistory()
            XCTAssertEqual(archived.map(\.lessonID), ids)
            XCTAssertEqual(archived.map(\.status), ids.map { $0 == last ? .completed : .dismissed })
            XCTAssertEqual(archived.count, 3)
            XCTAssertEqual(archived.first?.attempt?.answerDraft, "  🧪\n  keep\n")
            XCTAssertEqual(archived.first?.title, baseline.definitions.first { $0.id == ids[0] }?.title)
            XCTAssertNotNil(archived.first?.topicID)
            // An installed edit is not permission to rewrite studied History.
            let edit = ModelContext(container)
            for row in try edit.fetch(FetchDescriptor<LessonDefinition>()) where ids.contains(row.id) {
                row.title = "Upgraded"
                row.exercise = "New exercise"
                row.contentVersion += 1
            }
            try edit.save()
            XCTAssertEqual(try writer.loadHistory(), archived)
            XCTAssertEqual(try writer.loadLesson(lessonID: ids[0]).progress?.status, .dismissed)
        }
        try autoreleasepool {
            let (container, writer) = try setup(url)
            XCTAssertEqual(try writer.loadHistory(), archived)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 3)
            XCTAssertEqual(try writer.loadLesson(lessonID: ids[0]).progress?.status, .dismissed)
        }
    }

    func testRestoreStartedWithFullSlotsKeepsDraftUnslottedAndNeverTouchesOtherRecords() throws {
        let (container, writer) = try setup()
        let initial = try writer.loadSnapshot()
        let slot = try XCTUnwrap(initial.slots.first)
        let attempt = try XCTUnwrap(writer.openLesson(lessonID: slot.lessonID, now: first).detail.attempt)
        _ = try writer.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "  exact\n")
        let dismissed = try writer.dismiss(lessonID: slot.lessonID, expectedSlot: slot, now: later)
        let full = dismissed.catalog.slots
        XCTAssertEqual(full.count, initial.slots.count)
        let linkedBlockID = UUID()
        let linkedFocusID = UUID()
        let links = ModelContext(container)
        links.insert(ScheduleBlock(id: linkedBlockID, title: "Scheduled", startAt: first,
            endAt: later, lessonID: slot.lessonID, linkedTitleSnapshot: "Original"))
        links.insert(FocusSession(id: linkedFocusID, state: "completed", plannedSeconds: 60,
            accumulatedActiveSeconds: 60, startedAt: first, endedAt: later,
            checkpointAt: later, linkedLessonID: slot.lessonID, linkedTitleSnapshot: "Original"))
        try links.save()
        let boundary: any CatalogRepository = writer
        let restored = try boundary.restoreDismissed(lessonID: slot.lessonID, now: later)
        XCTAssertEqual(restored.outcome, .changed)
        XCTAssertEqual(restored.detail.progress?.status, .started)
        XCTAssertEqual(restored.detail.progress?.dismissedAt, later)
        XCTAssertEqual(restored.detail.progress?.startedAt, first)
        XCTAssertEqual(restored.detail.attempt, dismissed.detail.attempt)
        XCTAssertEqual(restored.catalog.slots, full)
        XCTAssertTrue(restored.history.isEmpty)
        XCTAssertEqual(try boundary.loadHistory(), [])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
        let schedule = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<ScheduleBlock>()).first)
        let focus = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<FocusSession>()).first)
        XCTAssertEqual(schedule.id, linkedBlockID)
        XCTAssertEqual(schedule.lessonID, slot.lessonID)
        XCTAssertEqual(schedule.linkedTitleSnapshot, "Original")
        XCTAssertEqual(focus.id, linkedFocusID)
        XCTAssertEqual(focus.linkedLessonID, slot.lessonID)
        XCTAssertEqual(focus.linkedTitleSnapshot, "Original")
        enum Injected: Error { case save }
        let noSave = SwiftDataCatalogRepository(container: container, beforeSave: { throw Injected.save })
        let repeatRestore = try noSave.restoreDismissed(lessonID: slot.lessonID, now: .distantFuture)
        XCTAssertEqual(repeatRestore.outcome, .unchanged)
        XCTAssertEqual(repeatRestore.catalog.slots, full)
        XCTAssertEqual(repeatRestore.detail, restored.detail)
        XCTAssertEqual(try writer.openLesson(lessonID: slot.lessonID, now: later).detail.attempt,
                       restored.detail.attempt)
    }

    func testRestoreIntoVacancyOnlyFillsOwnTopicAndUnstartedBecomesAvailable() throws {
        let (container, writer) = try setup()
        let initial = try writer.loadSnapshot()
        let slot = try XCTUnwrap(initial.slots.first)
        let dismissed = try writer.dismiss(lessonID: slot.lessonID, expectedSlot: slot, now: first)
        XCTAssertNil(dismissed.detail.attempt)
        let context = ModelContext(container)
        let replacement = try XCTUnwrap(context.fetch(FetchDescriptor<LessonSlot>()).first { $0.key == slot.key })
        context.delete(replacement)
        let other = try XCTUnwrap(context.fetch(FetchDescriptor<LessonSlot>()).first {
            $0.topicID != slot.topicID
        })
        let otherKey = other.key
        context.delete(other)
        try context.save()
        let before = try writer.loadSnapshot().slots
        let restored = try writer.restoreDismissed(lessonID: slot.lessonID, now: later)
        XCTAssertEqual(restored.detail.progress?.status, .available)
        XCTAssertNil(restored.detail.attempt)
        XCTAssertEqual(restored.detail.progress?.dismissedAt, first)
        XCTAssertEqual(restored.catalog.slots.filter { $0.key != slot.key }, before)
        XCTAssertEqual(restored.catalog.slots.first { $0.key == slot.key }?.lessonID, slot.lessonID)
        XCTAssertNil(restored.catalog.slots.first { $0.key == otherKey })
        XCTAssertEqual(try writer.restoreDismissed(lessonID: slot.lessonID, now: later).outcome, .unchanged)
    }

    func testRestoredStartedWorkFillsOneVacancyWithoutSubstitutingUpgradedContent() throws {
        let (container, writer) = try setup()
        let initial = try writer.loadSnapshot()
        let slot = try XCTUnwrap(initial.slots.first)
        let studied = try XCTUnwrap(initial.definitions.first { $0.id == slot.lessonID })
        let attempt = try XCTUnwrap(writer.openLesson(lessonID: slot.lessonID, now: first).detail.attempt)
        _ = try writer.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "draft\n")
        _ = try writer.dismiss(lessonID: slot.lessonID, expectedSlot: slot, now: first)
        let context = ModelContext(container)
        context.delete(try XCTUnwrap(context.fetch(FetchDescriptor<LessonSlot>()).first { $0.key == slot.key }))
        let installed = try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first { $0.id == slot.lessonID })
        installed.title = "Replacement title"
        installed.contentVersion += 1
        try context.save()
        let before = try writer.loadSnapshot().slots
        let restored = try writer.restoreDismissed(lessonID: slot.lessonID, now: later)
        XCTAssertEqual(restored.detail.content, .pinned(studied))
        XCTAssertEqual(restored.detail.attempt?.answerDraft, "draft\n")
        XCTAssertEqual(restored.detail.attempt?.id, attempt.id)
        XCTAssertEqual(restored.catalog.slots.filter { $0.key != slot.key }, before)
        XCTAssertEqual(restored.catalog.slots.first { $0.key == slot.key }?.lessonID, slot.lessonID)
        XCTAssertEqual(restored.catalog.slots.first { $0.key == slot.key }?.assignedAt, later)
    }

    func testFailedHistoryAndRestoreAreNotMistakenForEmptyOrCommitted() throws {
        let (container, writer) = try setup()
        let slot = try XCTUnwrap(writer.loadSnapshot().slots.first)
        XCTAssertThrowsError(try writer.restoreDismissed(lessonID: slot.lessonID, now: later)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
        }
        _ = try writer.dismiss(lessonID: slot.lessonID, expectedSlot: slot, now: first)
        let before = try writer.loadSnapshot()
        enum Injected: Error { case failure }
        for failBefore in [true, false] {
            let failing = SwiftDataCatalogRepository(container: container,
                beforeSave: { if failBefore { throw Injected.failure } },
                save: { _ in if !failBefore { throw Injected.failure } })
            XCTAssertThrowsError(try failing.restoreDismissed(lessonID: slot.lessonID, now: later)) {
                XCTAssertTrue($0 is Injected)
            }
            XCTAssertEqual(try writer.loadSnapshot(), before)
            XCTAssertEqual(try writer.loadHistory().count, 1)
        }
        let corrupt = ModelContext(container)
        corrupt.insert(LessonProgress(lessonID: "bad", status: .completed, completedAt: later))
        try corrupt.save()
        XCTAssertThrowsError(try writer.loadHistory()) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try writer.restoreDismissed(lessonID: slot.lessonID, now: later)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        let repair = ModelContext(container)
        repair.delete(try XCTUnwrap(repair.fetch(FetchDescriptor<LessonProgress>()).first { $0.lessonID == "bad" }))
        try repair.save()
        XCTAssertEqual(try writer.loadHistory().count, 1)
    }

    func testRestoreSaveFailuresRemainDismissedAfterDiskReopen() throws {
        enum Injected: Error { case failure }
        for failBefore in [true, false] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "KontrolRestoreFailure-\(UUID().uuidString)/Kontrol.store")
            var id = ""
            var baseline: LearningCatalogSnapshot?
            var history: [LessonHistorySnapshot] = []
            try autoreleasepool {
                let (container, writer) = try setup(url)
                let slot = try XCTUnwrap(writer.loadSnapshot().slots.first)
                id = slot.lessonID
                let opened = try writer.openLesson(lessonID: id, now: first)
                _ = try writer.saveAnswer(attemptID: XCTUnwrap(opened.detail.attempt?.id),
                                          expectedRevision: 0, answer: "  keep\n")
                _ = try writer.dismiss(lessonID: id, expectedSlot: slot, now: later)
                baseline = try writer.loadSnapshot()
                history = try writer.loadHistory()
                let failing = SwiftDataCatalogRepository(container: container,
                    beforeSave: { if failBefore { throw Injected.failure } },
                    save: { _ in if !failBefore { throw Injected.failure } })
                XCTAssertThrowsError(try failing.restoreDismissed(lessonID: id, now: later)) {
                    XCTAssertTrue($0 is Injected)
                }
                XCTAssertEqual(try writer.loadHistory(), history)
                XCTAssertEqual(try writer.loadSnapshot(), baseline)
            }
            try autoreleasepool {
                let (_, writer) = try setup(url)
                XCTAssertEqual(try writer.loadHistory(), history)
                XCTAssertEqual(try writer.loadSnapshot(), baseline)
                let restored = try writer.restoreDismissed(lessonID: id, now: later)
                XCTAssertEqual(restored.outcome, .changed)
                XCTAssertEqual(restored.detail.attempt?.answerDraft, "  keep\n")
                XCTAssertEqual(restored.detail.progress?.dismissedAt, later)
            }
        }
    }

    func testCompletedCannotRestoreAndMissingHistoryContentIsNotSubstituted() throws {
        let (container, writer) = try setup()
        let slot = try XCTUnwrap(writer.loadSnapshot().slots.first)
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: slot.lessonID, status: .completed, completedAt: first))
        let studied = KontrolSchemaV1.LessonContentSnapshot(title: "Old title", objectiveKey: "old",
            conceptIDs: [], difficulty: "basic", format: "learn", explanation: "old",
            workedExample: "old", exercise: "old", referenceAnswer: "old", selfCheckCriteria: [])
        context.insert(LessonAttempt(id: UUID(), lessonID: slot.lessonID, contentVersion: 1,
            completedAt: first, completedContentSnapshot: studied))
        try context.save()
        XCTAssertEqual(try writer.loadHistory().first?.content, .legacyCompleted(studied))
        XCTAssertEqual(try writer.loadHistory().first?.title, "Old title")
        XCTAssertThrowsError(try writer.restoreDismissed(lessonID: slot.lessonID, now: later)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
        }
        let another = try XCTUnwrap(writer.loadSnapshot().slots.first { $0.lessonID != slot.lessonID })
        let dismissal = try writer.dismiss(lessonID: another.lessonID, expectedSlot: another, now: later)
        let entry = try XCTUnwrap(dismissal.history.first { $0.lessonID == another.lessonID })
        XCTAssertEqual(entry.content, .unavailable) // no studied attempt exists
        XCTAssertNil(entry.attempt)
        XCTAssertEqual(try writer.loadHistory().count, 2)
    }
}
