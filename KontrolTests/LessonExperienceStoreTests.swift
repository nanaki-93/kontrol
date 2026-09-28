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

    func testRequestedIDAndAttemptIDGuardResponseEvenAfterAnotherDetailPublishes() throws {
        let (_, graph, drafts, _, first) = try draftFixture()
        let firstAttempt = try XCTUnwrap(first.detail.attempt)
        let otherID = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first {
            $0.lessonID != first.detail.id
        }?.lessonID)
        drafts.edit("  first 🧪\n", attemptID: firstAttempt.id)
        let second = try graph.learningCatalogStore.openLesson(lessonID: otherID)
        drafts.observe(second.detail)
        XCTAssertNil(LessonExperienceView.matchedDetail(graph.learningCatalogStore.detailState,
                                                         lessonID: first.detail.id))
        XCTAssertNil(LessonExperienceView.response(second.detail, drafts: drafts, lessonID: first.detail.id))
        XCTAssertNil(LessonExperienceView.studiedDefinition(second.detail, lessonID: first.detail.id))
        XCTAssertEqual(LessonExperienceView.response(first.detail, drafts: drafts,
                                                      lessonID: first.detail.id)?.text, "  first 🧪\n")
        XCTAssertEqual(LessonExperienceView.response(second.detail, drafts: drafts,
                                                      lessonID: otherID)?.text, "")
    }

    func testEveryFormatKeepsPinnedSectionsAndExactBlankUnicodeIndentedMultilineDraftAcrossReopen() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let definitions = try XCTUnwrap(store.state.snapshot).definitions
        let samples = ["learn": "", "code": "    let x = 1\n\n  🧪\n", "question": "\n漢字\n", "design": "  one\n    two\n"]
        for format in ["learn", "code", "question", "design"] {
            let definition = try XCTUnwrap(definitions.first { $0.format == format })
            let opened = try store.openLesson(lessonID: definition.id)
            let attempt = try XCTUnwrap(opened.detail.attempt)
            XCTAssertEqual(LessonExperienceView.studiedDefinition(opened.detail, lessonID: definition.id), definition)
            graph.lessonDraftStore.observe(opened.detail)
            // Deliberately edit even the empty answer: a blank must be a valid exact response.
            graph.lessonDraftStore.edit(try XCTUnwrap(samples[format]), attemptID: attempt.id)
            let navigation = NavigationStore()
            navigation.attachDrafts(graph.lessonDraftStore)
            navigation.showLesson(id: definition.id)
            navigation.backToChoices()
            XCTAssertEqual(navigation.learningRoute, .choices)
        }
        // Change an installed definition after study; the practice route still reads the pin.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let firstID = try XCTUnwrap(definitions.first { $0.format == "learn" }?.id)
        let installed = try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first { $0.id == firstID })
        installed.explanation = "Replacement catalog explanation"
        try context.save()
        // A fresh app-owned graph reads the saved answer and pinned authored sections offline.
        let reopened = AppDependencies(container: container, catalogRepository: repository)
        reopened.learningCatalogStore.loadIfNeeded()
        for format in ["learn", "code", "question", "design"] {
            let definition = try XCTUnwrap(definitions.first { $0.format == format })
            let detail = try reopened.learningCatalogStore.loadDetail(lessonID: definition.id)
            XCTAssertEqual(LessonExperienceView.studiedDefinition(detail, lessonID: definition.id), definition)
            reopened.lessonDraftStore.observe(detail)
            XCTAssertEqual(LessonExperienceView.response(detail, drafts: reopened.lessonDraftStore,
                                                          lessonID: definition.id)?.text, samples[format])
        }
    }

    func testMissingPinIsUnavailableAndCorruptPinIsAFailedReadNotCurrentCatalog() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<LessonAttempt>()).first { $0.id == attemptID })
        row.pinnedContentData = nil
        try context.save()
        let missing = try store.loadDetail(lessonID: id)
        XCTAssertEqual(missing.content, .unavailable)
        XCTAssertNil(LessonExperienceView.studiedDefinition(missing, lessonID: id))
        row.pinnedContentData = Data("corrupt".utf8)
        try context.save()
        XCTAssertThrowsError(try store.loadDetail(lessonID: id)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        guard case .failed(let requestedID, _) = store.detailState else {
            return XCTFail("Corrupt pin must fail the requested detail read")
        }
        XCTAssertEqual(requestedID, id)
        XCTAssertNil(LessonExperienceView.matchedDetail(store.detailState, lessonID: id))
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

    func testPracticeConflictKeepsComparisonAndLocalDraftWhenReconciliationFails() throws {
        let (repository, graph, drafts, _, opened) = try draftFixture()
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        drafts.edit("  local 🧪\n", attemptID: attemptID)
        _ = try graph.learningCatalogStore.saveAnswer(attemptID: attemptID, expectedRevision: 0, answer: "remote first")
        XCTAssertThrowsError(try drafts.flush(attemptID: attemptID))

        var comparison = LessonExperienceView.ConflictComparisonState()
        comparison.reload(drafts: drafts, attemptID: attemptID)
        XCTAssertEqual(comparison.detail?.attempt?.answerDraft, "remote first")
        XCTAssertNil(comparison.error)
        _ = try graph.learningCatalogStore.saveAnswer(attemptID: attemptID, expectedRevision: 1, answer: "remote newer")
        comparison.reconcile(drafts: drafts, attemptID: attemptID)
        XCTAssertEqual(comparison.detail?.attempt?.answerDraft, "remote first")
        XCTAssertNotNil(comparison.error)
        XCTAssertTrue(try XCTUnwrap(comparison.error).contains("Reload"))
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "  local 🧪\n")
        XCTAssertEqual(drafts.buffers[attemptID]?.expectedRevision, 0)
        XCTAssertEqual(drafts.buffers[attemptID]?.status, .notSaved(.staleRevision))
        XCTAssertThrowsError(try drafts.retry(attemptID: attemptID))
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "remote newer")

        comparison.reload(drafts: drafts, attemptID: attemptID)
        XCTAssertNil(comparison.error)
        XCTAssertEqual(comparison.detail?.attempt?.answerDraft, "remote newer")
        comparison.reconcile(drafts: drafts, attemptID: attemptID)
        XCTAssertNil(comparison.error)
        XCTAssertNil(comparison.detail)
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "  local 🧪\n")
        try drafts.retry(attemptID: attemptID)
        XCTAssertEqual(try repository.loadLesson(lessonID: opened.detail.id).attempt?.answerDraft, "  local 🧪\n")
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

    func testGenerationNoticeDistinguishesRealPartialAndEmptyExhaustion() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let initial = try repository.loadSnapshot()
        let topic = "go"
        let total = initial.definitions.filter { $0.topicID == topic }.count
        XCTAssertEqual(total, 8)
        for step in 0..<(total - 2) {
            let slot = try XCTUnwrap(repository.loadSnapshot().slots.filter { $0.topicID == topic }
                .max { $0.slotIndex < $1.slotIndex })
            _ = try repository.dismiss(lessonID: slot.lessonID, expectedSlot: slot,
                                       now: Date(timeIntervalSince1970: 2_000_000_000 + Double(step)))
        }
        let partial = try repository.loadSnapshot()
        let choices = LearningView.choices(for: topic, in: partial)
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(try repository.loadHistory().filter { $0.topicID == topic }.count, total - 2)
        let notice = LearningView.generationNotice(choiceCount: choices.count)
        XCTAssertTrue(notice.contains("No additional eligible lessons are installed for this topic"))
        XCTAssertTrue(notice.contains("Generate… is unavailable offline"))
        XCTAssertTrue(notice.contains("History or another topic"))
        for (step, slot) in partial.slots.filter({ $0.topicID == topic }).enumerated() {
            _ = try repository.dismiss(lessonID: slot.lessonID, expectedSlot: slot,
                                       now: Date(timeIntervalSince1970: 2_000_000_010 + Double(step)))
        }
        let empty = try repository.loadSnapshot()
        XCTAssertTrue(LearningView.choices(for: topic, in: empty).isEmpty)
        XCTAssertTrue(LearningView.generationNotice(choiceCount: 0)
            .contains("No eligible lessons are installed for this topic"))
        XCTAssertEqual(try repository.loadHistory().filter { $0.topicID == topic }.count, total)
        XCTAssertEqual(empty.slots.filter { $0.topicID != topic }, initial.slots.filter { $0.topicID != topic })
    }

    func testCapturedDismissalCancelAndStaleConfirmationNeverReplaceAnOccupant() throws {
        let (repository, graph, drafts, _, opened) = try draftFixture()
        let lessonID = opened.detail.id
        let attempt = try XCTUnwrap(opened.detail.attempt)
        let before = try XCTUnwrap(graph.learningCatalogStore.state.snapshot)
        let captured = try XCTUnwrap(LearningView.dismissal(for: lessonID, in: before, attemptID: attempt.id))
        XCTAssertEqual(captured.slot, before.slots.first { $0.lessonID == lessonID })
        XCTAssertEqual(captured.slot.assignedAt, before.slots.first { $0.lessonID == lessonID }?.assignedAt)
        drafts.edit("  unfinished 🧪\n", attemptID: attempt.id)
        // Cancel is presentation-only: no draft flush, progress or slot mutation.
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertEqual(try repository.loadLesson(lessonID: lessonID).attempt?.answerDraft, "")
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attempt.id]).isDirty)

        let replacement = try repository.dismiss(lessonID: lessonID, expectedSlot: captured.slot, now: .distantFuture)
        let replacementID = try XCTUnwrap(replacement.catalog.slots.first { $0.key == captured.slot.key }?.lessonID)
        // Another window replaced the assignment. Its occupant must survive a stale dialog.
        XCTAssertThrowsError(try drafts.dismiss(lessonID: captured.lessonID,
                                                expectedSlot: captured.slot, attemptID: captured.attemptID))
        XCTAssertThrowsError(try graph.learningCatalogStore.dismiss(lessonID: replacementID,
                                                                     expectedSlot: captured.slot)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleSlot)
        }
        XCTAssertEqual(try repository.loadLesson(lessonID: replacementID).progress, nil)
        XCTAssertEqual(try repository.loadSnapshot().slots, replacement.catalog.slots)
        XCTAssertEqual(drafts.buffers[attempt.id]?.text, "  unfinished 🧪\n")
    }

    func testDismissalSaveFailureRetainsAssignmentAndExactDraftForRetry() throws {
        var fail = false
        let (repository, graph, drafts, _, opened) = try draftFixture(beforeSave: {
            if fail { throw Injected.save }
        })
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        let snapshot = try XCTUnwrap(graph.learningCatalogStore.state.snapshot)
        let captured = try XCTUnwrap(LearningView.dismissal(for: opened.detail.id, in: snapshot,
                                                             attemptID: attemptID))
        drafts.edit("  keep 🧪\n", attemptID: attemptID)
        fail = true
        XCTAssertThrowsError(try drafts.dismiss(lessonID: captured.lessonID,
                                                expectedSlot: captured.slot, attemptID: captured.attemptID))
        XCTAssertEqual(try repository.loadSnapshot(), snapshot)
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "  keep 🧪\n")
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        fail = false
        let receipt = try drafts.dismiss(lessonID: captured.lessonID,
                                         expectedSlot: captured.slot, attemptID: captured.attemptID)
        XCTAssertEqual(receipt.detail.attempt?.answerDraft, "  keep 🧪\n")
        XCTAssertEqual(receipt.detail.progress?.status, .dismissed)
    }

    func testConfirmedDismissalRetainsPinnedAnswerAndVacancyWithoutCompletion() throws {
        let (repository, graph, drafts, _, opened) = try draftFixture()
        let id = opened.detail.id
        let attempt = try XCTUnwrap(opened.detail.attempt)
        let snapshot = try XCTUnwrap(graph.learningCatalogStore.state.snapshot)
        let captured = try XCTUnwrap(LearningView.dismissal(for: id, in: snapshot, attemptID: attempt.id))
        drafts.edit("  keep 🧪\n", attemptID: attempt.id)
        let result = try drafts.dismiss(lessonID: captured.lessonID,
                                        expectedSlot: captured.slot, attemptID: captured.attemptID)
        XCTAssertEqual(result.replacedSlot, captured.slot)
        XCTAssertEqual(result.detail.progress?.status, .dismissed)
        XCTAssertNil(result.detail.progress?.completedAt)
        XCTAssertNil(result.detail.attempt?.completedAt)
        XCTAssertEqual(result.detail.attempt?.pinnedContentData, attempt.pinnedContentData)
        XCTAssertEqual(result.detail.attempt?.answerDraft, "  keep 🧪\n")
        XCTAssertEqual(try repository.loadHistory().first?.attempt?.answerDraft, "  keep 🧪\n")
        XCTAssertFalse(result.catalog.slots.contains { $0.lessonID == id })
        XCTAssertEqual(result.catalog.slots.filter { $0.key != captured.slot.key },
                       snapshot.slots.filter { $0.key != captured.slot.key })
        let partial = LearningCatalogSnapshot(topics: result.catalog.topics,
            subtopics: result.catalog.subtopics, concepts: result.catalog.concepts,
            definitions: result.catalog.definitions, progress: result.catalog.progress,
            slots: result.catalog.slots.filter { $0.topicID != captured.slot.topicID })
        XCTAssertTrue(LearningView.choices(for: captured.slot.topicID, in: partial).isEmpty)
        XCTAssertNil(LearningView.dismissal(for: id, in: result.catalog))
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

    func testPracticeGatesAllowSavedBlankAndRequireNewAcknowledgementAfterEdit() throws {
        let (repository, graph, drafts, _, opened) = try draftFixture()
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        let id = opened.detail.id
        func eligible() -> Bool {
            guard let detail = LessonExperienceView.matchedDetail(graph.learningCatalogStore.detailState, lessonID: id),
                  let buffer = LessonExperienceView.response(detail, drafts: drafts, lessonID: id) else { return false }
            return LessonExperienceView.canComplete(detail, buffer: buffer, lessonID: id)
        }
        XCTAssertFalse(eligible())
        drafts.edit("", attemptID: attemptID) // Empty is still a valid saved answer.
        XCTAssertFalse(eligible())
        let revealed = try drafts.revealSolution(attemptID: attemptID) // flush before reveal
        XCTAssertEqual(revealed.detail.attempt?.answerDraft, "")
        XCTAssertEqual(drafts.buffers[attemptID]?.status, .saved)
        XCTAssertFalse(eligible())
        let acknowledged = try drafts.setSelfCheckAcknowledged(attemptID: attemptID, acknowledged: true)
        XCTAssertNotNil(acknowledged.detail.attempt?.selfCheckAcknowledgedAt)
        XCTAssertTrue(eligible())
        let committed = try XCTUnwrap(LessonExperienceView.matchedDetail(graph.learningCatalogStore.detailState, lessonID: id))
        let clean = try XCTUnwrap(drafts.buffers[attemptID])
        XCTAssertFalse(LessonExperienceView.canComplete(committed, buffer: clean, lessonID: "wrong-id"))
        var stale = clean
        stale.expectedRevision -= 1
        XCTAssertFalse(LessonExperienceView.canComplete(committed, buffer: stale, lessonID: id))
        stale = clean
        stale.text = "not the saved text"
        XCTAssertFalse(LessonExperienceView.canComplete(committed, buffer: stale, lessonID: id))
        drafts.edit("  🧪\n", attemptID: attemptID)
        XCTAssertFalse(eligible())
        let saved = try XCTUnwrap(drafts.flush(attemptID: attemptID))
        XCTAssertNil(saved.detail.attempt?.selfCheckAcknowledgedAt)
        XCTAssertFalse(eligible())
        let checkedAgain = try drafts.setSelfCheckAcknowledged(attemptID: attemptID, acknowledged: true)
        XCTAssertEqual(checkedAgain.detail.attempt?.answerDraft, "  🧪\n")
        XCTAssertTrue(eligible())
        let completed = try drafts.complete(attemptID: attemptID)
        XCTAssertEqual(completed.detail.progress?.status, .completed)
        XCTAssertEqual(completed.history.count, 1)
        XCTAssertEqual(completed.history.first?.attempt?.answerDraft, "  🧪\n")
        XCTAssertFalse(eligible())
        let repeated = try drafts.complete(attemptID: attemptID)
        XCTAssertEqual(repeated.outcome, .unchanged)
        XCTAssertEqual(repeated.history, completed.history)
        XCTAssertEqual(repeated.catalog.slots, completed.catalog.slots)
        XCTAssertEqual(try repository.loadHistory(), completed.history)
    }

    func testPracticeGateFailuresKeepRouteAndLocalAnswerWithoutOptimisticReceipt() throws {
        var fail = false
        let (repository, graph, drafts, _, opened) = try draftFixture(beforeSave: {
            if fail { throw Injected.save }
        })
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        let id = opened.detail.id
        let navigation = NavigationStore()
        navigation.attachDrafts(drafts)
        navigation.showLesson(id: id)
        drafts.edit("  keep 🧪\n", attemptID: attemptID)
        fail = true
        XCTAssertThrowsError(try drafts.revealSolution(attemptID: attemptID))
        XCTAssertEqual(navigation.learningRoute, .detail(id))
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "  keep 🧪\n")
        XCTAssertEqual(drafts.buffers[attemptID]?.status, .notSaved(.persistenceFailure))
        XCTAssertNil(try repository.loadLesson(lessonID: id).attempt?.solutionRevealedAt)
        fail = false
        _ = try drafts.revealSolution(attemptID: attemptID)
        fail = true
        XCTAssertThrowsError(try drafts.setSelfCheckAcknowledged(attemptID: attemptID, acknowledged: true))
        XCTAssertNil(try repository.loadLesson(lessonID: id).attempt?.selfCheckAcknowledgedAt)
        fail = false
        _ = try drafts.setSelfCheckAcknowledged(attemptID: attemptID, acknowledged: true)
        let before = graph.learningCatalogStore.projection
        fail = true
        XCTAssertThrowsError(try drafts.complete(attemptID: attemptID))
        XCTAssertEqual(graph.learningCatalogStore.detailState, before.detail)
        XCTAssertEqual(graph.learningCatalogStore.state, before.catalog)
        XCTAssertEqual(graph.learningCatalogStore.historyState, before.history)
        XCTAssertEqual(navigation.learningRoute, .detail(id))
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "  keep 🧪\n")
        XCTAssertEqual(try repository.loadLesson(lessonID: id).progress?.status, .started)
        fail = false
        XCTAssertEqual(try drafts.complete(attemptID: attemptID).detail.progress?.status, .completed)
    }

    func testStaleGateCannotCompleteOrReplaceAnotherWindowsAnswer() throws {
        let (repository, graph, drafts, _, opened) = try draftFixture()
        let id = opened.detail.id
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        _ = try drafts.revealSolution(attemptID: attemptID)
        _ = try drafts.setSelfCheckAcknowledged(attemptID: attemptID, acknowledged: true)
        drafts.edit("local", attemptID: attemptID)
        let revision = try XCTUnwrap(drafts.buffers[attemptID]?.expectedRevision)
        _ = try graph.learningCatalogStore.saveAnswer(attemptID: attemptID, expectedRevision: revision, answer: "remote")
        XCTAssertThrowsError(try drafts.complete(attemptID: attemptID)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleRevision)
        }
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "local")
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        XCTAssertEqual(try repository.loadLesson(lessonID: id).progress?.status, .started)
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "remote")
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
