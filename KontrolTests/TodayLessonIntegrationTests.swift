import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class TodayLessonIntegrationTests: XCTestCase {
    private enum Injected: Error { case save, read }

    private final class FailingRead: CatalogRepository {
        let base: SwiftDataCatalogRepository
        var fail = false
        var failDetail = false
        init(_ base: SwiftDataCatalogRepository) { self.base = base }
        func loadSnapshot() throws -> LearningCatalogSnapshot {
            if fail { throw Injected.read }
            return try base.loadSnapshot()
        }
        func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult { try base.importIfNeeded(catalog) }
        func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot { try base.reconcileSlots(now: now) }
        func loadLesson(lessonID: String) throws -> LessonDetailSnapshot {
            if failDetail { throw Injected.read }
            return try base.loadLesson(lessonID: lessonID)
        }
        func loadHistory() throws -> [LessonHistorySnapshot] { try base.loadHistory() }
        func openLesson(lessonID: String, now: Date) throws -> LessonMutationResult { try base.openLesson(lessonID: lessonID, now: now) }
        func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult {
            try base.saveAnswer(attemptID: attemptID, expectedRevision: expectedRevision, answer: answer)
        }
        func revealSolution(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
            try base.revealSolution(attemptID: attemptID, expectedRevision: expectedRevision, now: now)
        }
        func setSelfCheckAcknowledged(attemptID: UUID, expectedRevision: Int, acknowledged: Bool, now: Date) throws -> LessonMutationResult {
            try base.setSelfCheckAcknowledged(attemptID: attemptID, expectedRevision: expectedRevision, acknowledged: acknowledged, now: now)
        }
        func complete(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
            try base.complete(attemptID: attemptID, expectedRevision: expectedRevision, now: now)
        }
        func dismiss(lessonID: String, expectedSlot: LessonSlotSnapshot, now: Date) throws -> LessonMutationResult {
            try base.dismiss(lessonID: lessonID, expectedSlot: expectedSlot, now: now)
        }
        func restoreDismissed(lessonID: String, now: Date) throws -> LessonMutationResult {
            try base.restoreDismissed(lessonID: lessonID, now: now)
        }
    }

    private func navigation(_ drafts: LessonDraftStore) -> NavigationStore {
        let nav = NavigationStore(preferences: MemoryPreferences())
        nav.attachDrafts(drafts)
        return nav
    }

    private struct MemoryPreferences: DestinationPreferences {
        var savedDestination: String?
    }

    func testSelectionOrdersStartedThenTopicSlotAndStableIDAndIgnoresDay() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataCatalogRepository(container: container)
        _ = try repo.importIfNeeded(BundledCatalogLoader.load())
        let snapshot = try repo.loadSnapshot()
        let go = try XCTUnwrap(snapshot.slots.first { $0.topicID == "go" && $0.slotIndex == 0 })
        let java = try XCTUnwrap(snapshot.slots.first { $0.topicID == "java" && $0.slotIndex == 0 })
        let started = LessonProgressSnapshot(lessonID: java.lessonID, status: .started)
        let modified = LearningCatalogSnapshot(topics: snapshot.topics, subtopics: snapshot.subtopics,
            concepts: snapshot.concepts, definitions: snapshot.definitions, progress: [started],
            slots: snapshot.slots.reversed())
        let state = LearningCatalogReadState.current(modified)
        XCTAssertEqual(TodayLessonSelection.suggestions(from: state)?.map(\.id), [java.lessonID, go.lessonID])
        var day = TodayDaySelection()
        day.previous(in: TaskTemporalContext(now: Date(), calendar: .current, timeZone: .current))
        XCTAssertFalse(day.followsToday)
        XCTAssertEqual(TodayLessonSelection.suggestions(from: state)?.map(\.id), [java.lessonID, go.lessonID])
        let terminal = LearningCatalogSnapshot(topics: modified.topics, subtopics: modified.subtopics,
            concepts: modified.concepts, definitions: modified.definitions,
            progress: [LessonProgressSnapshot(lessonID: java.lessonID, status: .completed)], slots: modified.slots)
        XCTAssertEqual(TodayLessonSelection.suggestions(from: .current(terminal))?.map(\.id),
                       [go.lessonID, try XCTUnwrap(snapshot.slots.first { $0.topicID == "go" && $0.slotIndex == 1 }).lessonID])
        XCTAssertNil(TodayLessonSelection.suggestions(from: .notLoaded))
        XCTAssertNil(TodayLessonSelection.suggestions(from: .loading))
        XCTAssertNil(TodayLessonSelection.suggestions(from: .failed(stale: modified)))
        XCTAssertEqual(TodayLessonSelection.suggestions(from: .empty(LearningCatalogSnapshot(
            topics: [], subtopics: [], concepts: [], definitions: [], progress: [], slots: [])))?.count, 0)
    }

    func testAddToTodayUsesActualLocalDayAndOnlyExplicitSaveLinksBlock() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataCatalogRepository(container: container)
        _ = try repo.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repo)
        let learning = graph.learningCatalogStore
        learning.loadIfNeeded()
        let schedule = graph.scheduleStore
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8,
                                                                     hour: 14)))
        let temporal = TaskTemporalContext(now: now, calendar: calendar, timeZone: zone)
        var browsed = TodayDaySelection()
        browsed.previous(in: temporal)
        XCTAssertFalse(browsed.followsToday)
        XCTAssertFalse(calendar.isDate(try XCTUnwrap(browsed.selectedDate(in: temporal)), inSameDayAs: now))
        let suggestion = try XCTUnwrap(TodayLessonSelection.suggestions(from: learning.state)?.first)
        let canceled = try TodayView.addToTodayDraft(suggestion, learning: learning,
                                                     temporal: temporal, schedule: schedule)
        XCTAssertTrue(calendar.isDate(canceled.startAt, inSameDayAs: now))
        XCTAssertEqual(calendar.component(.hour, from: canceled.startAt), 9)
        XCTAssertEqual(canceled.endAt.timeIntervalSince(canceled.startAt),
                       Double(suggestion.lesson.estimatedMinutes) * 60)
        XCTAssertEqual(canceled.title, suggestion.lesson.title)
        XCTAssertEqual(canceled.lessonID, suggestion.id)
        XCTAssertTrue(try schedule.repository.fetchAll().isEmpty)
        canceled.cancel()
        canceled.submit { _ in XCTFail("Canceled") }
        XCTAssertTrue(try schedule.repository.fetchAll().isEmpty)

        let draft = try TodayView.addToTodayDraft(suggestion, learning: learning,
                                                  temporal: temporal, schedule: schedule)
        draft.startAt = now
        draft.endAt = now.addingTimeInterval(3_600) // Native picker edits absolute instants.
        let peer = try schedule.create(input: ScheduleInput(title: "Peer", startAt: now,
                                                            endAt: now.addingTimeInterval(3_600)))
        draft.submit { _ in XCTFail("Overlap needs review") }
        XCTAssertEqual(draft.overlapReview?.conflicts.map(\.block.id), [peer.id])
        XCTAssertEqual(try schedule.repository.fetchAll().count, 1)
        draft.keepBoth { saved in
            XCTAssertEqual(saved.lessonID, suggestion.id)
            XCTAssertEqual(saved.linkedTitleSnapshot, suggestion.lesson.title)
            XCTAssertEqual(saved.startAt, now)
            XCTAssertEqual(saved.endAt, now.addingTimeInterval(3_600))
        }
        XCTAssertEqual(try schedule.repository.fetchAll().count, 2)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<FocusSession>()).isEmpty)
    }

    func testStartNowResumesAndCommittedCompletionAndDismissalRefreshSuggestions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataCatalogRepository(container: container)
        _ = try repo.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repo)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let nav = navigation(graph.lessonDraftStore)
        let initial = try XCTUnwrap(TodayLessonSelection.suggestions(from: store.state))
        XCTAssertEqual(initial.count, 2)
        let first = initial[0]
        try TodayView.startNow(first, learning: store, navigation: nav)
        XCTAssertEqual(nav.selectedDestination, .learning)
        XCTAssertEqual(nav.learningRoute, .detail(first.id))
        let attempt = try XCTUnwrap(repo.loadLesson(lessonID: first.id).attempt)
        try TodayView.startNow(try XCTUnwrap(TodayLessonSelection.suggestions(from: store.state)?.first),
                               learning: store, navigation: nav)
        XCTAssertEqual(try repo.loadLesson(lessonID: first.id).attempt?.id, attempt.id)
        XCTAssertEqual(TodayLessonSelection.suggestions(from: store.state)?.first?.id, first.id)
        let revealed = try store.revealSolution(attemptID: attempt.id, expectedRevision: attempt.revision)
        let acknowledged = try store.setSelfCheckAcknowledged(attemptID: attempt.id,
            expectedRevision: try XCTUnwrap(revealed.detail.attempt).revision, acknowledged: true)
        _ = try store.complete(attemptID: attempt.id, expectedRevision: try XCTUnwrap(acknowledged.detail.attempt).revision)
        XCTAssertFalse(try XCTUnwrap(TodayLessonSelection.suggestions(from: store.state)).contains { $0.id == first.id })
        let next = try XCTUnwrap(TodayLessonSelection.suggestions(from: store.state)?.first)
        _ = try store.dismiss(lessonID: next.id, expectedSlot: next.slot)
        XCTAssertFalse(try XCTUnwrap(TodayLessonSelection.suggestions(from: store.state)).contains { $0.id == next.id })
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ScheduleBlock>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<FocusSession>()).isEmpty)
    }

    func testLinkedBlockOpensRotatedLessonByIDAndTerminalIsReadOnly() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataCatalogRepository(container: container)
        _ = try repo.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repo)
        let learning = graph.learningCatalogStore
        learning.loadIfNeeded()
        let nav = navigation(graph.lessonDraftStore)
        let id = try XCTUnwrap(learning.state.snapshot?.slots.first?.lessonID)
        let now = Date()
        let block = try graph.scheduleStore.create(input: ScheduleInput(
            title: "Study block", startAt: now, endAt: now.addingTimeInterval(1800), lessonID: id))
        let captured = try XCTUnwrap(block.linkedTitleSnapshot)
        XCTAssertNil(try repo.loadLesson(lessonID: id).attempt)
        let first = try learning.openLesson(lessonID: id)
        let attempt = try XCTUnwrap(first.detail.attempt)
        let revealed = try learning.revealSolution(attemptID: attempt.id, expectedRevision: attempt.revision)
        let acknowledged = try learning.setSelfCheckAcknowledged(
            attemptID: attempt.id, expectedRevision: try XCTUnwrap(revealed.detail.attempt).revision,
            acknowledged: true)
        _ = try learning.complete(attemptID: attempt.id,
                                  expectedRevision: try XCTUnwrap(acknowledged.detail.attempt).revision)
        XCTAssertFalse(try XCTUnwrap(learning.state.snapshot).slots.contains { $0.lessonID == id })
        let completedAt = try XCTUnwrap(repo.loadLesson(lessonID: id).attempt?.completedAt)
        try TodayView.openLinkedBlock(block, learning: learning, navigation: nav)
        XCTAssertEqual(nav.selectedDestination, .learning)
        XCTAssertEqual(nav.learningRoute, .detail(id))
        XCTAssertEqual(try repo.loadLesson(lessonID: id).attempt?.completedAt, completedAt)
        XCTAssertEqual(try repo.loadLesson(lessonID: id).progress?.status, .completed)
        // A terminal pin remains readable by ID even if the installed definition goes away.
        let context = ModelContext(container)
        context.delete(try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first { $0.id == id }))
        try context.save()
        nav.select(.today)
        try TodayView.openLinkedBlock(block, learning: learning, navigation: nav)
        XCTAssertEqual(nav.learningRoute, .detail(id))
        XCTAssertEqual(try repo.loadLesson(lessonID: id).attempt?.completedAt, completedAt)
        XCTAssertEqual(try graph.scheduleStore.repository.fetchAll().first?.linkedTitleSnapshot, captured)
        XCTAssertEqual(try graph.scheduleStore.repository.fetchAll().first?.lessonID, id)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
    }

    func testMissingLinkAndFailedReadKeepCapturedBlockWithoutAttemptOrPartialRoute() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let base = SwiftDataCatalogRepository(container: container)
        _ = try base.importIfNeeded(BundledCatalogLoader.load())
        let repo = FailingRead(base)
        let graph = AppDependencies(container: container, catalogRepository: repo)
        let learning = graph.learningCatalogStore
        learning.loadIfNeeded()
        let nav = navigation(graph.lessonDraftStore)
        let id = try XCTUnwrap(learning.state.snapshot?.slots.first?.lessonID)
        let now = Date()
        let block = try graph.scheduleStore.create(input: ScheduleInput(
            title: "Study block", startAt: now, endAt: now.addingTimeInterval(1800), lessonID: id))
        repo.failDetail = true
        XCTAssertThrowsError(try TodayView.openLinkedBlock(block, learning: learning, navigation: nav))
        XCTAssertEqual(nav.selectedDestination, .today)
        XCTAssertEqual(nav.learningRoute, .choices)
        XCTAssertNil(try base.loadLesson(lessonID: id).attempt)
        let otherID = try XCTUnwrap(learning.state.snapshot?.slots.first { $0.lessonID != id }?.lessonID)
        XCTAssertThrowsError(try learning.openLesson(lessonID: otherID)) { error in
            XCTAssertEqual(error as? LessonExperienceError, .invalidTransition)
        }
        repo.failDetail = false
        _ = try learning.retryDetail(lessonID: id)
        let context = ModelContext(container)
        let definitions = try context.fetch(FetchDescriptor<LessonDefinition>())
        context.delete(try XCTUnwrap(definitions.first { $0.id == id }))
        try context.save()
        XCTAssertThrowsError(try TodayView.openLinkedBlock(block, learning: learning, navigation: nav)) { error in
            XCTAssertEqual(error as? LessonExperienceError, .lessonNotFound)
        }
        XCTAssertEqual(nav.selectedDestination, .today)
        XCTAssertEqual(nav.learningRoute, .choices)
        XCTAssertEqual(try graph.scheduleStore.repository.fetchAll(), [block])
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        // A permanently missing block target must not poison the shared detail
        // read and prevent an unrelated Start now from committing an attempt.
        if case .failed = learning.detailState { XCTFail("Missing link blocked unrelated lessons") }
        XCTAssertNil(learning.error)
        let other = try XCTUnwrap(TodayLessonSelection.suggestions(from: learning.state)?
            .first { $0.id != id })
        try TodayView.startNow(other, learning: learning, navigation: nav)
        XCTAssertEqual(nav.learningRoute, .detail(other.id))
        XCTAssertEqual(try base.loadLesson(lessonID: other.id).attempt?.lessonID, other.id)
        XCTAssertEqual(try graph.scheduleStore.repository.fetchAll(), [block])
    }

    func testLinkedBlockFlushFailureDoesNotOpenThenRetryEntersExactLesson() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var failSave = false
        let repo = SwiftDataCatalogRepository(container: container, beforeSave: {
            if failSave { throw Injected.save }
        })
        _ = try repo.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repo)
        let learning = graph.learningCatalogStore
        learning.loadIfNeeded()
        let nav = navigation(graph.lessonDraftStore)
        let ids = try XCTUnwrap(learning.state.snapshot?.slots.prefix(2).map(\.lessonID))
        let now = Date()
        let block = try graph.scheduleStore.create(input: ScheduleInput(
            title: "Study", startAt: now, endAt: now.addingTimeInterval(1800), lessonID: ids[1]))
        let opened = try learning.openLesson(lessonID: ids[0])
        let attempt = try XCTUnwrap(opened.detail.attempt)
        graph.lessonDraftStore.observe(opened.detail)
        graph.lessonDraftStore.edit("  keep this 🧪\n", attemptID: attempt.id)
        failSave = true
        XCTAssertThrowsError(try TodayView.openLinkedBlock(block, learning: learning, navigation: nav))
        XCTAssertEqual(nav.selectedDestination, .today)
        XCTAssertEqual(nav.learningRoute, .choices)
        XCTAssertNil(nav.pendingTransition)
        XCTAssertNil(try repo.loadLesson(lessonID: ids[1]).attempt)
        XCTAssertEqual(graph.lessonDraftStore.buffers[attempt.id]?.text, "  keep this 🧪\n")
        XCTAssertEqual(try graph.scheduleStore.repository.fetchAll(), [block])
        failSave = false
        try TodayView.openLinkedBlock(block, learning: learning, navigation: nav)
        XCTAssertEqual(nav.learningRoute, .detail(ids[1]))
        XCTAssertEqual(nav.selectedDestination, .learning)
        XCTAssertNotNil(try repo.loadLesson(lessonID: ids[1]).attempt)
        XCTAssertEqual(try repo.loadLesson(lessonID: ids[0]).attempt?.answerDraft, "  keep this 🧪\n")
    }

    func testFailedReadAndFailedDraftSaveNeverStartOrNavigate() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var failSave = false
        let base = SwiftDataCatalogRepository(container: container, beforeSave: {
            if failSave { throw Injected.save }
        })
        _ = try base.importIfNeeded(BundledCatalogLoader.load())
        let repo = FailingRead(base)
        let graph = AppDependencies(container: container, catalogRepository: repo)
        let store = graph.learningCatalogStore
        let nav = navigation(graph.lessonDraftStore)
        repo.fail = true
        store.loadIfNeeded()
        XCTAssertNil(TodayLessonSelection.suggestions(from: store.state))
        repo.fail = false
        store.retry()
        let first = try XCTUnwrap(TodayLessonSelection.suggestions(from: store.state)?.first)
        repo.fail = true
        store.refresh()
        XCTAssertNil(TodayLessonSelection.suggestions(from: store.state))
        XCTAssertThrowsError(try TodayView.startNow(first, learning: store, navigation: nav))
        XCTAssertEqual(nav.selectedDestination, .today)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        repo.fail = false
        store.retry()
        failSave = true
        XCTAssertThrowsError(try TodayView.startNow(first, learning: store, navigation: nav))
        XCTAssertEqual(nav.selectedDestination, .today)
        XCTAssertNil(try base.loadLesson(lessonID: first.id).attempt)
        failSave = false
        // Create a dirty response on a different lesson while the window stays on Today.
        let other = try XCTUnwrap(store.state.snapshot?.slots.first { $0.lessonID != first.id })
        let opened = try store.openLesson(lessonID: other.lessonID)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        graph.lessonDraftStore.observe(opened.detail)
        graph.lessonDraftStore.edit("  retained 🧪\n", attemptID: attempt.id)
        failSave = true
        XCTAssertThrowsError(try TodayView.startNow(first, learning: store, navigation: nav))
        XCTAssertEqual(nav.selectedDestination, .today)
        XCTAssertEqual(nav.learningRoute, .choices)
        XCTAssertNil(try base.loadLesson(lessonID: first.id).attempt)
        XCTAssertEqual(graph.lessonDraftStore.buffers[attempt.id]?.text, "  retained 🧪\n")
        failSave = false
        try TodayView.startNow(first, learning: store, navigation: nav)
        XCTAssertEqual(nav.learningRoute, .detail(first.id))
        XCTAssertEqual(try base.loadLesson(lessonID: other.lessonID).attempt?.answerDraft, "  retained 🧪\n")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ScheduleBlock>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<FocusSession>()).isEmpty)
    }
}
