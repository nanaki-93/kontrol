import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class TodayLessonIntegrationTests: XCTestCase {
    private enum Injected: Error { case save, read }

    private final class FailingRead: CatalogRepository {
        let base: SwiftDataCatalogRepository
        var fail = false
        init(_ base: SwiftDataCatalogRepository) { self.base = base }
        func loadSnapshot() throws -> LearningCatalogSnapshot {
            if fail { throw Injected.read }
            return try base.loadSnapshot()
        }
        func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult { try base.importIfNeeded(catalog) }
        func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot { try base.reconcileSlots(now: now) }
        func loadLesson(lessonID: String) throws -> LessonDetailSnapshot { try base.loadLesson(lessonID: lessonID) }
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
