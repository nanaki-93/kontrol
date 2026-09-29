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
            let studiedCriteria = try XCTUnwrap(baseline.definitions.first { $0.id == ids[0] }).selfCheckCriteria
            XCTAssertFalse(studiedCriteria.isEmpty)
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
            XCTAssertEqual(archived.first?.provenance, .dismissalPin)
            XCTAssertEqual(archived.last?.provenance, .studiedPin)
            XCTAssertEqual(LearningHistoryView.archivedDisplay(try XCTUnwrap(archived.last)),
                           .studied(try XCTUnwrap(baseline.definitions.first { $0.id == last })))
            XCTAssertEqual(archived.last?.contentVersion, archived.last?.attempt?.contentVersion)
            XCTAssertEqual(archived.last?.metadata?.conceptIDs,
                           baseline.definitions.first { $0.id == last }?.conceptIDs.sorted())
            // An installed edit is not permission to rewrite studied History.
            let edit = ModelContext(container)
            for row in try edit.fetch(FetchDescriptor<LessonDefinition>()) where ids.contains(row.id) {
                row.title = "Upgraded"
                row.exercise = "New exercise"
                row.selfCheckCriteria = ["New installed criterion"]
                row.contentVersion += 1
            }
            try edit.save()
            XCTAssertEqual(try writer.loadHistory(), archived)
            guard case .pinned(let dismissedStudy) = try XCTUnwrap(archived.first).content else {
                return XCTFail("Dismissed study must retain its pin")
            }
            XCTAssertEqual(dismissedStudy.selfCheckCriteria, studiedCriteria)
            guard case .pinned(let completedStudy) = try XCTUnwrap(archived.last).content else {
                return XCTFail("Completed study must retain its pin")
            }
            XCTAssertEqual(completedStudy.selfCheckCriteria,
                           baseline.definitions.first { $0.id == last }?.selfCheckCriteria)
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

    func testHistorySelectionIsReadOnlyIDMatchedAndRestoreIsExplicit() throws {
        let (container, repository) = try setup()
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let original = try XCTUnwrap(store.state.snapshot)
        let firstSlot = try XCTUnwrap(original.slots.first)
        let secondSlot = try XCTUnwrap(original.slots.first { $0.lessonID != firstSlot.lessonID })
        XCTAssertEqual(try store.loadHistory(), [])
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertEqual(store.state.snapshot, original)
        let opened = try store.openLesson(lessonID: firstSlot.lessonID, now: first)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        _ = try store.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "  archived 🧪\n")
        _ = try store.dismiss(lessonID: firstSlot.lessonID, expectedSlot: firstSlot, now: later)
        _ = try store.dismiss(lessonID: secondSlot.lessonID, expectedSlot: secondSlot, now: later)
        let history = try store.loadHistory()
        XCTAssertEqual(history.count, 2)
        let entry = try XCTUnwrap(LearningHistoryView.entry(firstSlot.lessonID, in: store.historyState))
        XCTAssertEqual(entry.attempt?.answerDraft, "  archived 🧪\n")
        XCTAssertNil(LearningHistoryView.matchedDetail(entry, state: .current(
            try repository.loadLesson(lessonID: secondSlot.lessonID))))
        var changedDate = try repository.loadLesson(lessonID: firstSlot.lessonID)
        changedDate = LessonDetailSnapshot(id: changedDate.id,
            progress: LessonProgressSnapshot(lessonID: firstSlot.lessonID, status: .dismissed,
                dismissedAt: first), attempt: changedDate.attempt, content: changedDate.content)
        XCTAssertNil(LearningHistoryView.matchedDetail(entry, state: .current(changedDate)))
        let detail = try store.loadDetail(lessonID: firstSlot.lessonID)
        XCTAssertEqual(LearningHistoryView.matchedDetail(entry, state: store.detailState), detail)
        XCTAssertTrue(LearningHistoryView.canRestore(entry, detail: detail))
        XCTAssertEqual(try repository.loadHistory(), history) // selection and detail reads do not restore
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
        let beforeStudy = try XCTUnwrap(LearningHistoryView.entry(secondSlot.lessonID, in: store.historyState))
        XCTAssertEqual(beforeStudy.provenance, .dismissalReference)
        XCTAssertNil(beforeStudy.attempt)
        guard case .current(let reference) = beforeStudy.content else {
            return XCTFail("Expected dismissal-time reference, not studied content")
        }
        XCTAssertEqual(reference.id, secondSlot.lessonID)
        XCTAssertEqual(LearningHistoryView.archivedDisplay(beforeStudy), .reference(reference, recovered: false))
        let upgraded = LessonHistorySnapshot(lessonID: beforeStudy.lessonID, status: beforeStudy.status,
            date: beforeStudy.date, title: beforeStudy.title, topicID: beforeStudy.topicID,
            contentVersion: beforeStudy.contentVersion, provenance: beforeStudy.provenance,
            metadata: beforeStudy.metadata, content: .current(try XCTUnwrap(original.definitions.first {
                $0.id != secondSlot.lessonID
            })), attempt: nil)
        XCTAssertEqual(LearningHistoryView.archivedDisplay(upgraded), .unavailable)
        let recovered = LessonHistorySnapshot(lessonID: beforeStudy.lessonID, status: .dismissed,
            date: beforeStudy.date, title: beforeStudy.title, topicID: beforeStudy.topicID,
            contentVersion: beforeStudy.contentVersion, provenance: .legacyRecoveredReference,
            metadata: beforeStudy.metadata, content: beforeStudy.content, attempt: nil)
        XCTAssertEqual(LearningHistoryView.archivedDisplay(recovered), .reference(reference, recovered: true))
        let missing = LessonHistorySnapshot(lessonID: beforeStudy.lessonID, status: .dismissed,
            date: beforeStudy.date, title: beforeStudy.title, topicID: nil, content: .unavailable, attempt: nil)
        XCTAssertEqual(LearningHistoryView.archivedDisplay(missing), .unavailable)
        let unstudied = try store.loadDetail(lessonID: secondSlot.lessonID)
        XCTAssertNotNil(LearningHistoryView.matchedDetail(beforeStudy, state: .current(unstudied)))
        XCTAssertNil(unstudied.attempt)
        XCTAssertNil(LearningHistoryView.entry(firstSlot.lessonID, in: .failed(stale: history)))
        XCTAssertNil(LearningHistoryView.matchedDetail(entry, state: .failed(lessonID: firstSlot.lessonID, stale: detail)))
        XCTAssertFalse(LearningHistoryView.canRestore(nil, detail: detail))
        let slotsBeforeRestore = try repository.loadSnapshot().slots
        let restored = try store.restoreDismissed(lessonID: firstSlot.lessonID, now: later)
        XCTAssertEqual(restored.detail.attempt?.answerDraft, "  archived 🧪\n")
        XCTAssertNil(LearningHistoryView.entry(firstSlot.lessonID, in: store.historyState))
        XCTAssertEqual(restored.catalog.slots.filter { $0.key != firstSlot.key },
                       slotsBeforeRestore.filter { $0.key != firstSlot.key })
    }

    func testHistoryAndDetailFailuresRequireTheirOwnRetriesBeforeRestore() throws {
        let (container, repository) = try setup()
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let slot = try XCTUnwrap(store.state.snapshot?.slots.first)
        let opened = try store.openLesson(lessonID: slot.lessonID, now: first)
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        _ = try store.dismiss(lessonID: slot.lessonID, expectedSlot: slot, now: later)
        let baseline = try store.loadHistory()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let attempt = try XCTUnwrap(context.fetch(FetchDescriptor<LessonAttempt>()).first { $0.id == attemptID })
        let savedPin = attempt.pinnedContentData
        attempt.pinnedContentData = Data("corrupt".utf8)
        try context.save()
        XCTAssertThrowsError(try store.loadHistory())
        XCTAssertNil(LearningHistoryView.entry(slot.lessonID, in: store.historyState))
        XCTAssertThrowsError(try store.restoreDismissed(lessonID: slot.lessonID))
        XCTAssertEqual(try repository.loadSnapshot().progress.first { $0.lessonID == slot.lessonID }?.status, .dismissed)
        attempt.pinnedContentData = savedPin
        try context.save()
        XCTAssertEqual(try store.retryHistory(), baseline)
        XCTAssertEqual(LearningHistoryView.entry(slot.lessonID, in: store.historyState)?.lessonID, slot.lessonID)
        attempt.pinnedContentData = Data("corrupt".utf8)
        try context.save()
        XCTAssertThrowsError(try store.loadDetail(lessonID: slot.lessonID))
        let entry = try XCTUnwrap(LearningHistoryView.entry(slot.lessonID, in: store.historyState))
        XCTAssertNil(LearningHistoryView.matchedDetail(entry, state: store.detailState))
        XCTAssertThrowsError(try store.restoreDismissed(lessonID: slot.lessonID))
        attempt.pinnedContentData = savedPin
        try context.save()
        let detail = try store.retryDetail(lessonID: slot.lessonID)
        XCTAssertEqual(LearningHistoryView.matchedDetail(entry, state: store.detailState), detail)
        XCTAssertTrue(LearningHistoryView.canRestore(entry, detail: detail))
        XCTAssertEqual(try store.restoreDismissed(lessonID: slot.lessonID).detail.attempt?.id, attemptID)
    }

    func testRestoredStartedFullChoicesOffersSeparateResumeEntry() throws {
        let (_, repository) = try setup()
        let initial = try repository.loadSnapshot()
        let slot = try XCTUnwrap(initial.slots.first)
        let attempt = try XCTUnwrap(repository.openLesson(lessonID: slot.lessonID, now: first).detail.attempt)
        _ = try repository.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "  keep\n")
        let dismissed = try repository.dismiss(lessonID: slot.lessonID, expectedSlot: slot, now: later)
        let restored = try repository.restoreDismissed(lessonID: slot.lessonID, now: later)
        XCTAssertEqual(restored.catalog.slots, dismissed.catalog.slots)
        XCTAssertEqual(LearningView.choices(for: slot.topicID, in: restored.catalog).count, 4)
        XCTAssertEqual(LearningView.restoredUnslotted(for: slot.topicID, in: restored.catalog).map(\.lessonID),
                       [slot.lessonID])
        XCTAssertTrue(LearningView.restoredUnslotted(for: "other", in: restored.catalog).isEmpty)
        XCTAssertEqual(try repository.openLesson(lessonID: slot.lessonID, now: later).detail.attempt?.answerDraft,
                       "  keep\n")
        XCTAssertEqual(try repository.loadSnapshot().slots, dismissed.catalog.slots)
    }

    func testFilteredGroupsKeepDetailIdentityAndNeverWriteLearningRecords() throws {
        let (container, repository) = try setup()
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let choices = try repository.loadSnapshot()
        let one = try XCTUnwrap(choices.slots.first)
        let other = try XCTUnwrap(choices.slots.first { $0.topicID != one.topicID })
        _ = try store.dismiss(lessonID: one.lessonID, expectedSlot: one, now: first)
        let opened = try store.openLesson(lessonID: other.lessonID, now: first)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        _ = try store.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "untouched")
        _ = try store.revealSolution(attemptID: attempt.id, expectedRevision: 1, now: first)
        _ = try store.setSelfCheckAcknowledged(attemptID: attempt.id, expectedRevision: 2,
                                                acknowledged: true, now: first)
        _ = try store.complete(attemptID: attempt.id, expectedRevision: 3, now: later)
        let history = try store.loadHistory()
        let detail = try store.loadDetail(lessonID: one.lessonID)
        let snapshot = try repository.loadSnapshot()
        let attempts = try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>())
            .map { ($0.id, $0.answerDraft, $0.revision) }
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = HistoryLocalDate(later, calendar: calendar, timeZone: zone)
        var filters = LearningHistoryFilters(topic: .topic(one.topicID), status: .dismissed,
                                             date: .custom(start: day, end: day))
        func groups() throws -> [LearningHistoryDayGroup] {
            try LearningHistorySelection.select(history, filters: filters, now: later,
                                                calendar: calendar, timeZone: zone,
                                                locale: Locale(identifier: "en_US")).get()
        }
        let matching = try groups()
        XCTAssertEqual(matching.flatMap(\.rows).map(\.lessonID), [one.lessonID])
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching[0].day.start, calendar.startOfDay(for: later))
        XCTAssertEqual(LearningHistoryView.visibleEntry(one.lessonID, in: store.historyState,
                                                        groups: matching)?.lessonID, one.lessonID)
        XCTAssertEqual(LearningHistoryView.matchedDetail(matching[0].rows.first, state: store.detailState), detail)
        filters.status = .completed
        let empty = try groups()
        XCTAssertTrue(empty.isEmpty) // saved History exists, but this intersection does not match
        XCTAssertNil(LearningHistoryView.visibleEntry(one.lessonID, in: store.historyState, groups: empty))
        filters.topic = .all
        XCTAssertEqual(try groups().flatMap(\.rows).map(\.lessonID), [other.lessonID])
        XCTAssertNil(LearningHistoryView.visibleEntry(one.lessonID, in: store.historyState, groups: try groups()))
        filters.date = .custom(start: HistoryLocalDate(year: day.year + 1, month: day.month, day: day.day), end: day)
        XCTAssertEqual(LearningHistorySelection.select(history, filters: filters, now: later,
            calendar: calendar, timeZone: zone, locale: Locale(identifier: "en_US")),
                       .failure(.reversedCustomRange))
        XCTAssertEqual(try repository.loadHistory(), history)
        XCTAssertEqual(try repository.loadSnapshot(), snapshot)
        let after = try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>())
            .map { ($0.id, $0.answerDraft, $0.revision) }
        XCTAssertEqual(after.map(\.0), attempts.map(\.0))
        XCTAssertEqual(after.map(\.1), attempts.map(\.1))
        XCTAssertEqual(after.map(\.2), attempts.map(\.2))
    }

    func testCompletedCannotRestoreAndMissingHistoryContentIsNotSubstituted() throws {
        let (container, writer) = try setup()
        let slot = try XCTUnwrap(writer.loadSnapshot().slots.first)
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: slot.lessonID, status: .completed, completedAt: first))
        let studied = KontrolSchemaV1.LessonContentSnapshot(title: "Old title", objectiveKey: "old",
            conceptIDs: [], difficulty: "basic", format: "learn", explanation: "old",
            workedExample: "old", exercise: "old", referenceAnswer: "old",
            selfCheckCriteria: ["Archived design rubric", "Saved second criterion"])
        context.insert(LessonAttempt(id: UUID(), lessonID: slot.lessonID, contentVersion: 1,
            completedAt: first, completedContentSnapshot: studied))
        try context.save()
        XCTAssertEqual(try writer.loadHistory().first?.content, .legacyCompleted(studied))
        XCTAssertEqual(try writer.loadHistory().first?.title, "Old title")
        XCTAssertNil(try writer.loadHistory().first?.topicID) // legacy snapshot recorded no taxonomy
        XCTAssertNil(try writer.loadHistory().first?.provenance) // awaiting import backfill
        guard case .legacyCompleted(let archived) = try XCTUnwrap(writer.loadHistory().first).content else {
            return XCTFail("Expected legacy completed snapshot")
        }
        XCTAssertEqual(archived.selfCheckCriteria, ["Archived design rubric", "Saved second criterion"])
        XCTAssertEqual(LearningHistoryView.archivedDisplay(try XCTUnwrap(writer.loadHistory().first)),
                       .legacyCompleted(studied))
        XCTAssertThrowsError(try writer.restoreDismissed(lessonID: slot.lessonID, now: later)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
        }
        let another = try XCTUnwrap(writer.loadSnapshot().slots.first { $0.lessonID != slot.lessonID })
        let dismissal = try writer.dismiss(lessonID: another.lessonID, expectedSlot: another, now: later)
        let entry = try XCTUnwrap(dismissal.history.first { $0.lessonID == another.lessonID })
        XCTAssertEqual(entry.provenance, .dismissalReference)
        XCTAssertEqual(entry.contentVersion, entry.metadata?.dismissalTimeDefinition?.contentVersion)
        XCTAssertEqual(entry.content, .current(try XCTUnwrap(entry.metadata?.dismissalTimeDefinition)))
        XCTAssertNil(entry.attempt)
        XCTAssertEqual(try writer.loadHistory().count, 2)
    }
}
