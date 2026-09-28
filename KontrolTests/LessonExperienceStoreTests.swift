import Combine
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LessonExperienceStoreTests: XCTestCase {
    private enum Injected: Error { case save }

    private final class ManualScheduler {
        var now = Date(timeIntervalSince1970: 1_000)
        struct Job {
            let deadline: Date
            let callback: () -> Void
            var cancelled = false
        }
        var jobs: [Job] = []
        func schedule(_ deadline: Date, _ callback: @escaping () -> Void) -> () -> Void {
            let index = jobs.count
            jobs.append(Job(deadline: deadline, callback: callback))
            return { [weak self] in self?.jobs[index].cancelled = true }
        }
        func advance(by seconds: TimeInterval) {
            now.addTimeInterval(seconds)
            let due = jobs.indices.filter { jobs[$0].deadline <= now && !jobs[$0].cancelled }
            for index in due { jobs[index].callback() }
        }
    }

    private func draftFixture(beforeSave: @escaping () throws -> Void = {}) throws ->
        (SwiftDataCatalogRepository, AppDependencies, LessonDraftStore, ManualScheduler, LessonMutationResult) {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: beforeSave)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let scheduler = ManualScheduler()
        let graph = AppDependencies(container: container, catalogRepository: repository,
                                    draftClock: { scheduler.now }, draftScheduler: scheduler.schedule)
        graph.learningCatalogStore.loadIfNeeded()
        let id = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: id)
        graph.lessonDraftStore.observe(opened.detail)
        return (repository, graph, graph.lessonDraftStore, scheduler, opened)
    }

    func testExplicitChoiceEntryPinsOnceAndBrowsingRemainsReadOnly() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let snapshot = try XCTUnwrap(store.state.snapshot)
        let first = try XCTUnwrap(LearningView.choices(for: "go", in: snapshot).first)
        XCTAssertEqual(LearningView.choices(for: "go", in: snapshot).count, 4)
        _ = LearningView.orderedTopics(in: snapshot)
        _ = LearningView.choices(for: "java", in: snapshot)
        let partial = LearningCatalogSnapshot(topics: snapshot.topics, subtopics: snapshot.subtopics,
            concepts: snapshot.concepts, definitions: snapshot.definitions, progress: snapshot.progress,
            slots: Array(snapshot.slots.filter { $0.topicID == "go" }.prefix(2)))
        XCTAssertEqual(LearningView.choices(for: "go", in: partial).count, 2)
        XCTAssertTrue(LearningView.choices(for: "java", in: partial).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)

        let suite = "LessonChoiceEntry.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        navigation.attachDrafts(graph.lessonDraftStore)
        let opened = try store.openLesson(lessonID: first.id)
        graph.lessonDraftStore.observe(opened.detail)
        navigation.enterLesson(id: first.id)
        XCTAssertEqual(navigation.selectedDestination, .learning)
        XCTAssertEqual(navigation.learningRoute, .detail(first.id))
        let attempt = try XCTUnwrap(opened.detail.attempt)
        XCTAssertNotNil(attempt.pinnedContentData)
        XCTAssertEqual(opened.detail.content, .pinned(first))
        XCTAssertEqual(opened.detail.progress?.status, .started)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)

        graph.lessonDraftStore.edit("  🧪\nresumed\n", attemptID: attempt.id)
        navigation.backToChoices() // guarded save before leaving
        XCTAssertEqual(try repository.loadLesson(lessonID: first.id).attempt?.answerDraft, "  🧪\nresumed\n")
        let resumed = try store.openLesson(lessonID: first.id)
        graph.lessonDraftStore.observe(resumed.detail)
        navigation.enterLesson(id: first.id)
        XCTAssertEqual(resumed.detail.attempt?.id, attempt.id)
        XCTAssertEqual(resumed.detail.attempt?.pinnedContentData, attempt.pinnedContentData)
        XCTAssertEqual(resumed.detail.attempt?.answerDraft, "  🧪\nresumed\n")
        XCTAssertEqual(LearningView.choices(for: "go", in: try XCTUnwrap(store.state.snapshot)).map(\.id),
                       LearningView.choices(for: "go", in: snapshot).map(\.id))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
    }

    func testDebounceLatestEditAtExactlyFiveHundredMillisecondsAndSharedWindows() throws {
        let (repository, graph, drafts, scheduler, opened) = try draftFixture()
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        let firstWindow = graph.lessonDraftStore
        let secondWindow = graph.lessonDraftStore
        XCTAssertTrue(firstWindow === secondWindow)
        XCTAssertTrue(firstWindow === drafts)
        firstWindow.edit("old", attemptID: id)
        scheduler.advance(by: 0.4)
        secondWindow.edit("  🧪\n  exact\n", attemptID: id)
        scheduler.advance(by: 0.1)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.revision, 0)
        XCTAssertEqual(firstWindow.buffers[id]?.status, .saving)
        scheduler.advance(by: 0.4)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "  🧪\n  exact\n")
        XCTAssertEqual(firstWindow.buffers[id]?.status, .saved)
        XCTAssertEqual(secondWindow.buffers[id]?.expectedRevision, 1)
        XCTAssertFalse(try XCTUnwrap(secondWindow.buffers[id]).isDirty)
        // A cancelled callback delivered late cannot overwrite the new edit.
        secondWindow.edit("newer", attemptID: id)
        scheduler.jobs[0].callback()
        XCTAssertEqual(firstWindow.buffers[id]?.text, "newer")
        XCTAssertEqual(firstWindow.buffers[id]?.status, .saving)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.revision, 1)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "newer")
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.revision, 2)
    }

    func testFailedSaveRetryAndManualFlushInvalidateDelayedCallbacks() throws {
        var fail = false
        let (repository, _, drafts, scheduler, opened) = try draftFixture(beforeSave: {
            if fail { throw Injected.save }
        })
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        drafts.edit("\n  exact 🍃\n", attemptID: id)
        fail = true
        scheduler.advance(by: 0.5)
        XCTAssertEqual(drafts.buffers[id]?.status, .notSaved(.persistenceFailure))
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[id]).isDirty)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "")
        fail = false
        try drafts.retry(attemptID: id)
        XCTAssertEqual(drafts.buffers[id]?.status, .saved)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "\n  exact 🍃\n")
        drafts.edit("next", attemptID: id)
        let late = scheduler.jobs.last!.callback
        try drafts.flush(attemptID: id)
        drafts.edit("latest", attemptID: id)
        late()
        XCTAssertEqual(drafts.buffers[id]?.status, .saving)
        XCTAssertEqual(drafts.buffers[id]?.text, "latest")
        scheduler.advance(by: 0.5)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "latest")
    }

    func testStaleRevisionRetainsLocalTextUntilExplicitReloadAndReconciliation() throws {
        let (repository, graph, drafts, _, opened) = try draftFixture()
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        drafts.edit("my local answer", attemptID: id)
        _ = try graph.learningCatalogStore.saveAnswer(attemptID: id, expectedRevision: 0, answer: "other window")
        XCTAssertThrowsError(try drafts.flush(attemptID: id)) { error in
            XCTAssertEqual(error as? LessonExperienceError, .staleRevision)
        }
        XCTAssertEqual(drafts.buffers[id]?.status, .notSaved(.staleRevision))
        XCTAssertThrowsError(try drafts.retry(attemptID: id))
        let latest = try drafts.reload(attemptID: id)
        XCTAssertEqual(latest.attempt?.answerDraft, "other window")
        XCTAssertEqual(drafts.buffers[id]?.text, "my local answer")
        XCTAssertEqual(drafts.buffers[id]?.expectedRevision, 0)
        try drafts.reconcileForRetry(attemptID: id, with: latest)
        try drafts.retry(attemptID: id)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "my local answer")
        XCTAssertEqual(drafts.buffers[id]?.status, .saved)
    }

    func testStaleReloadDoesNotAdoptRevisionOrOverwriteExactDirtyTextWithoutReconciliation() throws {
        let (repository, graph, drafts, scheduler, opened) = try draftFixture()
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        for local in ["", "  🧪\n  漢字\n", "\nline one\n\nline two\n"] {
            drafts.edit(local, attemptID: id)
            let delayed = scheduler.jobs.last!.callback
            let baseline = try XCTUnwrap(drafts.buffers[id]?.expectedRevision)
            _ = try graph.learningCatalogStore.saveAnswer(attemptID: id, expectedRevision: baseline,
                                                          answer: "remote \(baseline)")
            XCTAssertThrowsError(try drafts.flush(attemptID: id)) { error in
                XCTAssertEqual(error as? LessonExperienceError, .staleRevision)
            }
            XCTAssertThrowsError(try drafts.retry(attemptID: id))
            let latest = try drafts.reload(attemptID: id)
            drafts.observe(latest) // receipt observation cannot silently adopt a dirty baseline
            delayed() // cancelled debounce must not save or clear a newer dirty edit
            XCTAssertEqual(drafts.buffers[id]?.text, local)
            XCTAssertEqual(drafts.buffers[id]?.expectedRevision, baseline)
            XCTAssertEqual(drafts.buffers[id]?.status, .notSaved(.staleRevision))
            XCTAssertTrue(try XCTUnwrap(drafts.buffers[id]).isDirty)
            XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft,
                           "remote \(baseline)")
            try drafts.reconcileForRetry(attemptID: id, with: latest)
            try drafts.retry(attemptID: id)
            XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, local)
        }
    }

    func testReconciliationRequiresExplicitReloadAndLatestMatchingDetail() throws {
        let (repository, graph, drafts, _, opened) = try draftFixture()
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        drafts.edit("keep local", attemptID: id)
        let remote = try graph.learningCatalogStore.saveAnswer(attemptID: id, expectedRevision: 0, answer: "remote")
        XCTAssertThrowsError(try drafts.reconcileForRetry(attemptID: id, with: remote.detail))
        XCTAssertThrowsError(try drafts.flush(attemptID: id))
        let loaded = try drafts.reload(attemptID: id)
        // A different committed receipt must invalidate the previously loaded projection.
        _ = try graph.learningCatalogStore.saveAnswer(attemptID: id, expectedRevision: 1, answer: "newer remote")
        XCTAssertThrowsError(try drafts.reconcileForRetry(attemptID: id, with: loaded))
        XCTAssertEqual(drafts.buffers[id]?.text, "keep local")
        XCTAssertEqual(drafts.buffers[id]?.expectedRevision, 0)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "newer remote")
        let latest = try drafts.reload(attemptID: id)
        try drafts.reconcileForRetry(attemptID: id, with: latest)
        try drafts.retry(attemptID: id)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "keep local")
    }

    func testCleanReceiptObservationAdvancesRevealAndAcknowledgementButNotDirtyText() throws {
        let (_, graph, drafts, _, opened) = try draftFixture()
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        let revealed = try graph.learningCatalogStore.revealSolution(attemptID: id, expectedRevision: 0)
        drafts.observe(revealed.detail)
        XCTAssertEqual(drafts.buffers[id]?.expectedRevision, 1)
        XCTAssertEqual(drafts.buffers[id]?.status, .saved)
        let acknowledged = try graph.learningCatalogStore.setSelfCheckAcknowledged(
            attemptID: id, expectedRevision: 1, acknowledged: true)
        drafts.observe(acknowledged.detail)
        XCTAssertEqual(drafts.buffers[id]?.expectedRevision, 2)
        drafts.edit("\n  local 🧪\n", attemptID: id)
        let changed = try graph.learningCatalogStore.saveAnswer(attemptID: id, expectedRevision: 2, answer: "remote")
        drafts.observe(changed.detail)
        XCTAssertEqual(drafts.buffers[id]?.text, "\n  local 🧪\n")
        XCTAssertEqual(drafts.buffers[id]?.expectedRevision, 2)
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[id]).isDirty)
        XCTAssertThrowsError(try drafts.retry(attemptID: id)) { error in
            XCTAssertEqual(error as? LessonExperienceError, .staleRevision)
        }
    }

    func testIndependentAttemptBuffersAndFlushAllBarrier() throws {
        let (repository, graph, drafts, scheduler, opened) = try draftFixture()
        let firstID = try XCTUnwrap(opened.detail.attempt?.id)
        let nextID = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first {
            $0.lessonID != opened.detail.id
        }?.lessonID)
        let other = try graph.learningCatalogStore.openLesson(lessonID: nextID)
        let secondID = try XCTUnwrap(other.detail.attempt?.id)
        drafts.observe(other.detail)
        drafts.edit("first", attemptID: firstID)
        let stale = scheduler.jobs.last!.callback
        drafts.edit("second", attemptID: secondID)
        try drafts.flushAll()
        drafts.edit("still local", attemptID: firstID)
        stale()
        XCTAssertEqual(drafts.buffers[firstID]?.text, "still local")
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[firstID]).isDirty)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "first")
        XCTAssertEqual(try repository.loadLesson(lessonID: nextID).attempt?.answerDraft, "second")
        scheduler.advance(by: 0.5)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "still local")
        // A delayed old detail cannot roll a saved revision back.
        drafts.observe(opened.detail)
        XCTAssertEqual(drafts.buffers[firstID]?.expectedRevision, 2)
    }

    func testDismissFlushesDraftAndCancelledCallbackCannotReviveIt() throws {
        let (repository, graph, drafts, scheduler, opened) = try draftFixture()
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        let slot = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first {
            $0.lessonID == opened.detail.id
        })
        drafts.edit("keep on dismissal", attemptID: id)
        let late = scheduler.jobs.last!.callback
        let dismissed = try drafts.dismiss(lessonID: opened.detail.id, expectedSlot: slot, attemptID: id)
        XCTAssertEqual(dismissed.detail.progress?.status, .dismissed)
        late()
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "keep on dismissal")
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).progress?.status, .dismissed)
        XCTAssertEqual(drafts.buffers[id]?.status, .saved)
    }

    func testRouteChangeCannotRedirectDelayedAnswerToAnotherLesson() throws {
        let (repository, graph, drafts, scheduler, opened) = try draftFixture()
        let firstID = try XCTUnwrap(opened.detail.attempt?.id)
        let nextLessonID = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first {
            $0.lessonID != opened.detail.id
        }?.lessonID)
        let next = try graph.learningCatalogStore.openLesson(lessonID: nextLessonID)
        let nextID = try XCTUnwrap(next.detail.attempt?.id)
        drafts.observe(next.detail)
        let navigation = NavigationStore()
        navigation.attachDrafts(drafts)
        navigation.showLesson(id: opened.detail.id)
        drafts.edit("first answer", attemptID: firstID)
        let delayed = scheduler.jobs.last!.callback
        navigation.showLesson(id: nextLessonID)
        XCTAssertEqual(navigation.learningRoute, .detail(nextLessonID))
        drafts.edit("second answer", attemptID: nextID)
        delayed()
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "first answer")
        XCTAssertEqual(try repository.loadLesson(lessonID: nextLessonID).attempt?.answerDraft, "")
        try drafts.flushAll()
        XCTAssertEqual(try repository.loadLesson(lessonID: nextLessonID).attempt?.answerDraft, "second answer")
    }

    func testLifecycleBarrierRetainsDirtyTextOnFailureAndInvalidatesOldCallbackOnRetry() throws {
        var fail = false
        let (repository, graph, drafts, scheduler, opened) = try draftFixture(beforeSave: {
            if fail { throw Injected.save }
        })
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        let navigation = NavigationStore()
        navigation.attachDrafts(drafts)
        let lifecycle = KontrolLifecycleDelegate()
        lifecycle.navigation = navigation
        navigation.showLesson(id: opened.detail.id)
        drafts.edit("quit draft\n  exact", attemptID: id)
        let delayed = scheduler.jobs.last!.callback
        fail = true
        XCTAssertFalse(lifecycle.flushBeforeTermination()) // quit must be cancelled
        XCTAssertFalse(navigation.flushForLifecycle()) // window close / deactivation
        XCTAssertEqual(navigation.learningRoute, .detail(opened.detail.id))
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertEqual(drafts.buffers[id]?.status, .notSaved(.persistenceFailure))
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "")
        fail = false
        XCTAssertTrue(lifecycle.flushBeforeTermination())
        delayed()
        XCTAssertEqual(drafts.buffers[id]?.status, .saved)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "quit draft\n  exact")
        XCTAssertTrue(graph.lessonDraftStore === drafts)
    }

    func testTransitionFlushesAndFailurePreventsTransition() throws {
        var fail = false
        let (repository, _, drafts, _, opened) = try draftFixture(beforeSave: {
            if fail { throw Injected.save }
        })
        let id = try XCTUnwrap(opened.detail.attempt?.id)
        drafts.edit("before reveal", attemptID: id)
        fail = true
        XCTAssertThrowsError(try drafts.revealSolution(attemptID: id))
        XCTAssertNil(try repository.loadLesson(lessonID: opened.detail.id).attempt?.solutionRevealedAt)
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[id]).isDirty)
        fail = false
        let revealed = try drafts.revealSolution(attemptID: id)
        XCTAssertEqual(revealed.detail.attempt?.answerDraft, "before reveal")
        XCTAssertNotNil(revealed.detail.attempt?.solutionRevealedAt)
        XCTAssertEqual(drafts.buffers[id]?.expectedRevision, revealed.detail.attempt?.revision)
    }

    func testCommittedReceiptsPublishChoicesDetailAndHistoryTogetherToBothConsumers() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let first = graph.learningCatalogStore
        let second = graph.learningCatalogStore
        XCTAssertTrue(first === second)
        first.loadIfNeeded()
        let slot = try XCTUnwrap(first.state.snapshot?.slots.first)
        var publications: [LearningExperienceProjection] = []
        let subscription = second.$projection.sink { publications.append($0) }
        defer { subscription.cancel() }
        let opened = try second.openLesson(lessonID: slot.lessonID, now: .distantPast)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        XCTAssertEqual(first.detailState, .current(opened.detail))
        let edited = try first.saveAnswer(attemptID: attempt.id, expectedRevision: attempt.revision, answer: "  🧪\n  exact\n")
        XCTAssertEqual(edited.detail.attempt?.answerDraft, "  🧪\n  exact\n")
        let revealed = try first.revealSolution(attemptID: attempt.id, expectedRevision: 1)
        XCTAssertNotNil(revealed.detail.attempt?.solutionRevealedAt)
        let acknowledged = try second.setSelfCheckAcknowledged(attemptID: attempt.id, expectedRevision: 2,
                                                                  acknowledged: true)
        XCTAssertNotNil(acknowledged.detail.attempt?.selfCheckAcknowledgedAt)
        let completed = try first.complete(attemptID: attempt.id, expectedRevision: 3)
        XCTAssertEqual(completed.detail.progress?.status, .completed)
        XCTAssertEqual(second.historyState, .current(completed.history))
        XCTAssertEqual(first.state.snapshot, completed.catalog)
        XCTAssertFalse(completed.catalog.slots.contains { $0.lessonID == slot.lessonID })
        XCTAssertEqual(completed.history.first?.attempt?.answerDraft, "  🧪\n  exact\n")
        XCTAssertEqual(publications.last?.detail, .current(completed.detail))
        XCTAssertEqual(publications.last?.history, .current(completed.history))
        XCTAssertEqual(publications.last?.catalog.snapshot, completed.catalog)
        XCTAssertEqual(try repository.loadSnapshot(), completed.catalog)
        XCTAssertEqual(try repository.loadHistory(), completed.history)
        // Reads of the new selection cannot retroactively make an earlier receipt stale.
        let repeated = try second.complete(attemptID: attempt.id, expectedRevision: 0)
        XCTAssertEqual(repeated.outcome, .unchanged)
        XCTAssertEqual(second.state.snapshot?.slots, completed.catalog.slots)
    }

    func testDismissAndRestorePublishOneConsistentProjection() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let slot = try XCTUnwrap(store.state.snapshot?.slots.first)
        let dismissed = try store.dismiss(lessonID: slot.lessonID, expectedSlot: slot)
        XCTAssertEqual(store.projection.catalog.snapshot, dismissed.catalog)
        XCTAssertEqual(store.detailState, .current(dismissed.detail))
        XCTAssertEqual(store.historyState, .current(dismissed.history))
        XCTAssertEqual(dismissed.history.first?.status, .dismissed)
        let restored = try store.restoreDismissed(lessonID: slot.lessonID)
        XCTAssertEqual(store.projection.catalog.snapshot, restored.catalog)
        XCTAssertEqual(store.detailState, .current(restored.detail))
        XCTAssertEqual(store.historyState, .current(restored.history))
        XCTAssertTrue(restored.history.isEmpty)
        XCTAssertEqual(try repository.loadSnapshot(), restored.catalog)
    }

    func testFailedSavePublishesOnlyErrorAndNoSpeculativeProjectionOrPostCommitRead() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        let baseline = store.projection
        let attempt = try XCTUnwrap(opened.detail.attempt)
        fail = true
        XCTAssertThrowsError(try store.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "unsaved"))
        XCTAssertEqual(store.error, .persistenceFailure)
        XCTAssertEqual(store.projection.catalog, baseline.catalog)
        XCTAssertEqual(store.projection.detail, baseline.detail)
        XCTAssertEqual(store.projection.history, baseline.history)
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "")
        fail = false
        let saved = try store.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "saved")
        XCTAssertEqual(store.error, nil)
        XCTAssertEqual(store.detailState, .current(saved.detail))
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "saved")
    }
}
