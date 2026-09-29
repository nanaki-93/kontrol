import AppKit
import Combine
import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
private final class CountingPreferences: DestinationPreferences {
    var writes = 0
    var savedDestination: String? {
        didSet { writes += 1 }
    }
}

@MainActor
final class NavigationStoreTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "KontrolNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDisplayOrderAndStableRawValues() {
        XCTAssertEqual(AppDestination.allCases.map(\.rawValue),
                       ["today", "learning", "projects", "focus", "tasks", "news", "settings"])
    }

    func testMissingValueDefaultsToTodayWithoutWritingPreference() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        XCTAssertEqual(store.selectedDestination, .today)
        XCTAssertNil(defaults.object(forKey: UserDefaultsDestinationPreferences.key))
    }

    func testEveryDestinationSurvivesReconstructionAndOnlyChangedSelectionWrites() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsDestinationPreferences(defaults: defaults)

        for destination in AppDestination.allCases {
            let store = NavigationStore(preferences: preferences)
            store.select(destination)
            if destination == .today {
                // Initial Today isn't a change; missing value is left missing.
                XCTAssertNil(defaults.object(forKey: UserDefaultsDestinationPreferences.key))
                // Select a different destination then Today to exercise its saved value.
                store.select(.learning)
                store.select(.today)
            }
            XCTAssertEqual(defaults.string(forKey: UserDefaultsDestinationPreferences.key), destination.rawValue)
            XCTAssertEqual(NavigationStore(preferences: preferences).selectedDestination, destination)
        }
    }

    func testSelectionWritesOnlyOnChange() {
        let preferences = CountingPreferences()
        let store = NavigationStore(preferences: preferences)
        store.select(.today)
        XCTAssertEqual(preferences.writes, 0)
        store.select(.focus)
        store.select(.focus)
        XCTAssertEqual(preferences.writes, 1)
        XCTAssertEqual(preferences.savedDestination, AppDestination.focus.rawValue)
    }

    func testStableLessonRouteAndFailureRetainsRoutePreferenceAndDraftForRetry() throws {
        enum Injected: Error { case save }
        var fail = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let lessonID = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: lessonID)
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        graph.lessonDraftStore.observe(opened.detail)
        let preferences = CountingPreferences()
        let navigation = NavigationStore(preferences: preferences)
        navigation.attachDrafts(graph.lessonDraftStore)
        navigation.showLesson(id: lessonID)
        XCTAssertEqual(navigation.selectedDestination, .learning)
        XCTAssertEqual(navigation.learningRoute, .detail(lessonID))
        graph.lessonDraftStore.edit("  answer 🧪\n", attemptID: attemptID)
        fail = true
        navigation.showHistory()
        XCTAssertEqual(navigation.learningRoute, .detail(lessonID))
        XCTAssertEqual(navigation.pendingTransition, .learning(.history))
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertEqual(graph.lessonDraftStore.buffers[attemptID]?.text, "  answer 🧪\n")
        XCTAssertTrue(try XCTUnwrap(graph.lessonDraftStore.buffers[attemptID]).isDirty)
        navigation.selectTopic("java")
        XCTAssertNil(navigation.selectedTopicID)
        navigation.showLesson(id: "another-stable-id")
        XCTAssertEqual(navigation.learningRoute, .detail(lessonID))
        navigation.select(.focus)
        XCTAssertEqual(navigation.selectedDestination, .learning)
        XCTAssertEqual(preferences.writes, 1)
        navigation.cancelTransition()
        XCTAssertEqual(navigation.learningRoute, .detail(lessonID))
        navigation.backToChoices()
        XCTAssertEqual(navigation.learningRoute, .detail(lessonID))
        fail = false
        navigation.retryTransition()
        XCTAssertEqual(navigation.learningRoute, .choices)
        XCTAssertEqual(try repository.loadLesson(lessonID: lessonID).attempt?.answerDraft, "  answer 🧪\n")
        XCTAssertEqual(graph.lessonDraftStore.buffers[attemptID]?.status, .saved)
        navigation.showLesson(id: lessonID)
        navigation.selectTopic("java")
        XCTAssertEqual(navigation.selectedTopicID, "java")
        XCTAssertEqual(navigation.learningRoute, .choices)
        navigation.select(.focus)
        XCTAssertEqual(navigation.selectedDestination, .focus)
        XCTAssertEqual(preferences.writes, 2)
    }

    func testCoverageRouteAndSubtopicRemainWindowLocalAndFailedDraftBarrierKeepsPreviousRoute() throws {
        enum Injected: Error { case save }
        var fail = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let id = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: id)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        graph.lessonDraftStore.observe(opened.detail)
        let preferences = CountingPreferences()
        let first = NavigationStore(preferences: preferences)
        let second = NavigationStore(preferences: preferences)
        first.attachDrafts(graph.lessonDraftStore)
        first.select(.learning)
        first.enterLesson(id: id)
        graph.lessonDraftStore.edit("unsaved coverage answer", attemptID: attempt.id)
        fail = true
        first.showCoverage()
        XCTAssertEqual(first.learningRoute, .detail(id))
        XCTAssertEqual(first.pendingTransition, .learning(.coverage(subtopicID: nil)))
        XCTAssertTrue(try XCTUnwrap(graph.lessonDraftStore.buffers[attempt.id]).isDirty)
        XCTAssertEqual(second.learningRoute, .choices)
        fail = false
        first.retryTransition()
        XCTAssertEqual(first.learningRoute, .coverage(subtopicID: nil))
        first.selectCoverageSubtopic("subtopic")
        XCTAssertEqual(first.learningRoute, .coverage(subtopicID: "subtopic"))
        XCTAssertEqual(second.learningRoute, .choices)
        first.selectCoverageSubtopic(nil)
        XCTAssertEqual(first.learningRoute, .coverage(subtopicID: nil))
        graph.lessonDraftStore.edit("second answer", attemptID: attempt.id)
        fail = true
        first.backToChoices()
        XCTAssertEqual(first.learningRoute, .coverage(subtopicID: nil))
        XCTAssertEqual(first.pendingTransition, .learning(.choices))
        fail = false
        first.retryTransition()
        XCTAssertEqual(first.learningRoute, .choices)
        first.selectCoverageSubtopic("ignored")
        XCTAssertEqual(first.learningRoute, .choices)
        XCTAssertEqual(preferences.writes, 1, "Coverage and subtopic routes are not preferences")
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "second answer")
    }

    func testCompletedReferenceRouteIsStableIDGuardedAndDoesNotOpenWork() throws {
        enum Injected: Error { case save }
        var fail = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let slot = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: slot.lessonID)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        graph.lessonDraftStore.observe(opened.detail)
        let navigation = NavigationStore(preferences: CountingPreferences())
        navigation.attachDrafts(graph.lessonDraftStore)
        navigation.showCoverage()
        navigation.selectCoverageSubtopic("subtopic")
        graph.lessonDraftStore.edit("retain answer", attemptID: attempt.id)
        fail = true
        navigation.showCompletedReference(id: "archived-id")
        XCTAssertEqual(navigation.learningRoute, .coverage(subtopicID: "subtopic"))
        XCTAssertEqual(navigation.pendingTransition, .learning(.historyReference("archived-id")))
        XCTAssertTrue(try XCTUnwrap(graph.lessonDraftStore.buffers[attempt.id]).isDirty)
        fail = false
        navigation.retryTransition()
        XCTAssertEqual(navigation.learningRoute, .historyReference("archived-id"))
        XCTAssertEqual(try repository.loadLesson(lessonID: slot.lessonID).attempt?.answerDraft, "retain answer")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1,
                       "Routing to an archive never opens another attempt")
    }

    func testCrossDestinationEntryFailsWithoutPartialRouteThenCancelAndRetryByStableID() throws {
        enum Injected: Error { case save }
        var fail = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let ids = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.prefix(2).map(\.lessonID))
        XCTAssertEqual(ids.count, 2)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: ids[0])
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        graph.lessonDraftStore.observe(opened.detail)
        let preferences = CountingPreferences()
        let navigation = NavigationStore(preferences: preferences)
        navigation.attachDrafts(graph.lessonDraftStore)
        navigation.select(.learning)
        navigation.showHistory()
        navigation.select(.today)
        XCTAssertEqual(navigation.learningRoute, .history)
        XCTAssertEqual(preferences.savedDestination, AppDestination.today.rawValue)
        graph.lessonDraftStore.edit("  Today → schedule 🧪\n", attemptID: attemptID)
        var publishedPending: [NavigationStore.Transition?] = []
        let subscription = navigation.$pendingTransition.dropFirst().sink { publishedPending.append($0) }
        defer { subscription.cancel() }
        fail = true
        navigation.enterLesson(id: ids[1])
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(navigation.learningRoute, .history)
        XCTAssertEqual(navigation.pendingTransition, .lessonEntry(ids[1]))
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertEqual(preferences.savedDestination, AppDestination.today.rawValue)
        XCTAssertEqual(preferences.writes, 2)
        XCTAssertTrue(try XCTUnwrap(graph.lessonDraftStore.buffers[attemptID]).isDirty)
        XCTAssertTrue(AppShell.showsStayHere(for: navigation))
        navigation.cancelTransition()
        XCTAssertEqual(publishedPending, [.lessonEntry(ids[1]), nil], "Cancel must notify the shell")
        XCTAssertFalse(AppShell.showsStayHere(for: navigation), "Stay here disappears on cancellation")
        XCTAssertNil(navigation.pendingTransition)
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertEqual(graph.lessonDraftStore.buffers[attemptID]?.text, "  Today → schedule 🧪\n")
        XCTAssertTrue(try XCTUnwrap(graph.lessonDraftStore.buffers[attemptID]).isDirty)
        XCTAssertEqual(preferences.savedDestination, AppDestination.today.rawValue)
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(navigation.learningRoute, .history)
        navigation.enterLesson(id: ids[1]) // schedule link requests the same stable ID
        XCTAssertEqual(navigation.pendingTransition, .lessonEntry(ids[1]))
        fail = false
        navigation.retryTransition()
        XCTAssertNil(navigation.pendingTransition)
        XCTAssertNil(navigation.saveError)
        XCTAssertEqual(navigation.selectedDestination, .learning)
        XCTAssertEqual(navigation.learningRoute, .detail(ids[1]))
        XCTAssertEqual(preferences.savedDestination, AppDestination.learning.rawValue)
        XCTAssertEqual(preferences.writes, 3)
        XCTAssertEqual(try repository.loadLesson(lessonID: ids[0]).attempt?.answerDraft, "  Today → schedule 🧪\n")
        XCTAssertEqual(graph.lessonDraftStore.buffers[attemptID]?.status, .saved)
        navigation.enterLesson(id: ids[1])
        XCTAssertEqual(preferences.writes, 3)
        // Routing never opens an attempt; the explicit Open/Resume action owns that mutation.
        XCTAssertNil(try repository.loadLesson(lessonID: ids[1]).attempt)
    }

    func testFailedLifecycleFlushKeepsDraftAndErrorVisibleUntilReturnAndQuitRetry() throws {
        enum Injected: Error { case save }
        var fail = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let id = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let attempt = try XCTUnwrap(graph.learningCatalogStore.openLesson(lessonID: id).detail.attempt)
        graph.lessonDraftStore.observe(try repository.loadLesson(lessonID: id))
        let navigation = NavigationStore(preferences: CountingPreferences())
        navigation.attachDrafts(graph.lessonDraftStore)
        navigation.enterLesson(id: id)
        graph.lessonDraftStore.edit("recover me", attemptID: attempt.id)
        let lifecycle = KontrolLifecycleDelegate()
        lifecycle.navigation = navigation
        fail = true
        lifecycle.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertEqual(navigation.learningRoute, .detail(id))
        XCTAssertTrue(try XCTUnwrap(graph.lessonDraftStore.buffers[attempt.id]).isDirty)
        XCTAssertFalse(lifecycle.flushBeforeTermination())
        XCTAssertFalse(WindowCloseGuard(flush: { navigation.flushForLifecycle() }).makeCoordinator().flush())
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        fail = false
        XCTAssertTrue(lifecycle.flushBeforeTermination())
        XCTAssertNil(navigation.saveError)
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "recover me")
    }

    func testGuardedOpenNeverRoutesOnStaleIDOrFailedDraftFlush() throws {
        enum Injected: Error { case save }
        var fail = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let id = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: id)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        graph.lessonDraftStore.observe(opened.detail)
        graph.lessonDraftStore.edit("  keep 🧪\n", attemptID: attempt.id)
        let navigation = NavigationStore(preferences: CountingPreferences())
        navigation.attachDrafts(graph.lessonDraftStore)
        var calls = 0
        fail = true
        XCTAssertThrowsError(try navigation.openLesson(id: "stale-id") {
            calls += 1
            return try graph.learningCatalogStore.openLesson(lessonID: "stale-id")
        })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(navigation.learningRoute, .choices)
        XCTAssertTrue(try XCTUnwrap(graph.lessonDraftStore.buffers[attempt.id]).isDirty)
        fail = false
        XCTAssertThrowsError(try navigation.openLesson(id: "stale-id") {
            calls += 1
            return try graph.learningCatalogStore.openLesson(lessonID: "stale-id")
        })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(navigation.learningRoute, .choices)
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "  keep 🧪\n")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
    }

    func testUnknownValueFallsBackWithoutChangingPreferencesOrSwiftDataStore() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = UserDefaultsDestinationPreferences.key
        defaults.set("future-destination", forKey: key)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolNavigationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kontrol.store")
        let id = UUID()
        func seedAndClose() throws {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let context = ModelContext(container)
            context.insert(try TaskItem(id: id, title: "Existing record", createdAt: Date()))
            try context.save()
        }
        try seedAndClose()

        func storeBytes() throws -> [String: Data] {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil)
            return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        let before = try storeBytes()
        XCTAssertFalse(before.isEmpty)
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(defaults.string(forKey: key), "future-destination")
        XCTAssertEqual(try storeBytes(), before)

        // A fresh owner can still read the existing record.
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
        XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>()).map(\.id), [id])
    }
}
