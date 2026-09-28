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
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(preferences.writes, 0)
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
        XCTAssertEqual(preferences.writes, 1)
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
