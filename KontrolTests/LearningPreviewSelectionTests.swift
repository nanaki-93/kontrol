import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LearningPreviewSelectionTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, SwiftDataCatalogRepository, LearningCatalogSnapshot) {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        return (container, repository, try repository.loadSnapshot())
    }

    private func projection(_ topic: String?, _ selection: LearningView.LearningPreviewSelection,
                            _ snapshot: LearningCatalogSnapshot) throws -> LearningView.PreviewProjection {
        try XCTUnwrap(LearningView.preview(for: topic, selection: selection, state: .current(snapshot)))
    }

    func testAcceptedTopicsResolveCurrentSlotIdentityWithoutBrowsingWrites() throws {
        let (container, repository, committed) = try fixture()
        var selected = LearningView.LearningPreviewSelection()
        for topic in ["java", "go", "design"] {
            let result = try projection(topic, selected, committed)
            let expected = committed.slots.filter { $0.topicID == topic }
                .sorted { $0.slotIndex < $1.slotIndex }.map(\.lessonID)
            XCTAssertEqual(result.selection.topicID, topic)
            XCTAssertEqual(result.choices.map(\.id), expected)
            XCTAssertEqual(result.selection.lessonID, expected.first)
            XCTAssertEqual(result.lesson?.id, result.actionLessonID)
            XCTAssertEqual(result.actionLessonID, expected.first)
            selected = result.selection
        }
        XCTAssertEqual(try repository.loadSnapshot(), committed)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
    }

    func testSelectionRetainsEligibleIDAcrossReorderAndFallsBackAfterRotation() throws {
        let (_, _, committed) = try fixture()
        let slots = committed.slots.filter { $0.topicID == "go" }.sorted { $0.slotIndex < $1.slotIndex }
        XCTAssertGreaterThanOrEqual(slots.count, 2)
        let first = try projection("go", .init(), committed)
        let chosenID = slots[1].lessonID
        let selected = first.selection.selecting(chosenID, from: first)
        XCTAssertEqual(try projection("go", selected, committed).actionLessonID, chosenID)
        XCTAssertEqual(selected.selecting("absent", from: first), selected)
        let reordered = LearningCatalogSnapshot(topics: committed.topics, subtopics: committed.subtopics,
            concepts: committed.concepts, definitions: committed.definitions, progress: committed.progress,
            slots: [slots[1], slots[0]] + committed.slots.filter { $0.topicID != "go" })
        // Slot order, rather than snapshot array order, controls the list.
        let retained = try projection("go", selected, reordered)
        XCTAssertEqual(retained.choices.prefix(2).map(\.id), slots.prefix(2).map(\.lessonID))
        XCTAssertEqual(retained.actionLessonID, chosenID)
        let rotated = LearningCatalogSnapshot(topics: committed.topics, subtopics: committed.subtopics,
            concepts: committed.concepts, definitions: committed.definitions, progress: committed.progress,
            slots: committed.slots.filter { $0.lessonID != chosenID })
        let fallback = try projection("go", selected, rotated)
        XCTAssertEqual(fallback.actionLessonID, slots[0].lessonID)
        XCTAssertEqual(fallback.selection.lessonID, fallback.lesson?.id)
        XCTAssertEqual(selected.selecting(chosenID, from: fallback), selected,
                       "A stale item event cannot select the replacement")
        let empty = LearningCatalogSnapshot(topics: committed.topics, subtopics: committed.subtopics,
            concepts: committed.concepts, definitions: committed.definitions, progress: committed.progress,
            slots: committed.slots.filter { $0.topicID != "go" })
        let noChoices = try projection("go", fallback.selection, empty)
        XCTAssertTrue(noChoices.choices.isEmpty)
        XCTAssertNil(noChoices.lesson)
        XCTAssertNil(noChoices.actionLessonID)
    }

    func testBrowsingSelectionDoesNotFlushDirtyDraftOrEnterLesson() throws {
        var saves = 0
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: { saves += 1 })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let snapshot = try XCTUnwrap(graph.learningCatalogStore.state.snapshot)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: XCTUnwrap(snapshot.slots.first?.lessonID))
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        let drafts = LessonDraftStore(learning: graph.learningCatalogStore, schedule: { _, _ in { } })
        drafts.observe(opened.detail)
        drafts.edit("still unsaved", attemptID: attemptID)
        let suite = "LearningPreviewBrowse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        navigation.attachDrafts(drafts)
        let before = try repository.loadSnapshot()
        let saveCount = saves
        var selection = LearningView.LearningPreviewSelection()
        for topic in ["java", "go", "design"] {
            // Adopt the accepted topic before browsing its choices. An uninitialized
            // selection has no topic and intentionally rejects item selection.
            let current = try projection(topic, selection, snapshot)
            selection = current.selection
            XCTAssertEqual(selection.topicID, topic)
            XCTAssertGreaterThan(current.choices.count, 1)
            let last = try XCTUnwrap(current.choices.last)
            XCTAssertNotEqual(last.id, selection.lessonID)
            selection = selection.selecting(last.id, from: current)
            XCTAssertEqual(selection.topicID, topic)
            XCTAssertEqual(selection.lessonID, last.id)
            let browsed = try projection(topic, selection, snapshot)
            XCTAssertEqual(browsed.selection, selection)
            XCTAssertEqual(browsed.lesson?.id, last.id)
            XCTAssertEqual(browsed.actionLessonID, last.id)
        }
        XCTAssertEqual(saves, saveCount)
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertEqual(navigation.learningRoute, .choices)
        XCTAssertNil(navigation.pendingTransition)
        XCTAssertNil(navigation.selectedTopicID)
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).map(\.id), [attemptID],
                       "Browsing must not create another attempt")
    }

    func testFailedReadRetainsRecoveryIdentityButCannotExposeAction() throws {
        let (_, _, snapshot) = try fixture()
        let selected = try projection("java", .init(), snapshot).selection
        XCTAssertNil(LearningView.preview(for: "java", selection: selected, state: .loading))
        XCTAssertNil(LearningView.preview(for: "java", selection: selected, state: .failed(stale: snapshot)))
        XCTAssertNil(LearningView.preview(for: "java", selection: selected, state: .failed(stale: nil)))
        XCTAssertEqual(try projection("java", selected, snapshot).selection, selected)
        let empty = LearningCatalogSnapshot(topics: [], subtopics: [], concepts: [],
                                            definitions: [], progress: [], slots: [])
        XCTAssertNil(LearningView.preview(for: nil, selection: .init(), state: .empty(empty)))
    }

    func testFailedTopicSaveKeepsAcceptedPreviewUntilRetry() throws {
        enum Injected: Error { case save }
        var fail = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let snapshot = try XCTUnwrap(graph.learningCatalogStore.state.snapshot)
        let lessonID = try XCTUnwrap(snapshot.slots.first?.lessonID)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: lessonID)
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        let drafts = LessonDraftStore(learning: graph.learningCatalogStore, schedule: { _, _ in { } })
        drafts.observe(opened.detail)
        let suite = "LearningPreviewSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        navigation.attachDrafts(drafts)
        navigation.selectTopic("java")
        let accepted = try projection(navigation.selectedTopicID, .init(), snapshot).selection
        drafts.edit("unsaved", attemptID: attemptID)
        fail = true
        navigation.selectTopic("go")
        XCTAssertEqual(navigation.selectedTopicID, "java")
        XCTAssertEqual(navigation.pendingTransition, .topic("go"))
        XCTAssertEqual(try projection(navigation.selectedTopicID, accepted, snapshot).selection, accepted)
        navigation.cancelTransition()
        XCTAssertEqual(navigation.selectedTopicID, "java")
        navigation.selectTopic("design")
        XCTAssertEqual(navigation.selectedTopicID, "java")
        fail = false
        navigation.retryTransition()
        XCTAssertEqual(navigation.selectedTopicID, "design")
        let recovered = try projection(navigation.selectedTopicID, accepted,
                                       try XCTUnwrap(graph.learningCatalogStore.state.snapshot))
        XCTAssertEqual(recovered.selection.topicID, "design")
        XCTAssertEqual(recovered.actionLessonID, recovered.choices.first?.id)
        XCTAssertNotEqual(recovered.actionLessonID, accepted.lessonID)
        XCTAssertEqual(try repository.loadSnapshot().slots, snapshot.slots)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
    }
}
