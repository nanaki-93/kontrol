import SwiftData
import XCTest
@testable import Kontrol

@MainActor
private final class ProjectWorkPreferences: DestinationPreferences {
    var savedDestination: String?
}

private final class ProjectWorkInspector: ProjectInspecting {
    private(set) var calls = 0
    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        calls += 1
        throw ProjectInspectionFailure.inconsistentRead
    }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        calls += 1
        throw ProjectInspectionFailure.inconsistentRead
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data {
        calls += 1
        throw ProjectInspectionFailure.inconsistentRead
    }
}

@MainActor
private final class ProjectWorkRepository: ProjectReferenceRepository {
    private(set) var calls = 0
    func fetchAll() throws -> [ProjectReferenceSnapshot] { calls += 1; return [] }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot {
        calls += 1
        throw ProjectReferencePersistenceError.invalidReference
    }
    func remove(id: UUID, expectedRevision: UUID) throws { calls += 1 }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot {
        calls += 1
        throw ProjectReferencePersistenceError.invalidReference
    }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID,
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot {
        calls += 1
        throw ProjectReferencePersistenceError.invalidReference
    }
}

private final class ProjectWorkWriter: FeatureFileWriting {
    private(set) var calls = 0
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        calls += 1
        throw FeatureMutationFailure.writeFailed
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        calls += 1
        throw FeatureMutationFailure.writeFailed
    }
}

@MainActor
final class UIHierarchySupportingStateTests: XCTestCase {
    private enum Injected: Error { case save }

    func testTodayProjectWorkUsesNavigationBarrierAndDoesNotInspectOrMutateProjects() throws {
        var failSave = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = SwiftDataCatalogRepository(container: container, beforeSave: {
            if failSave { throw Injected.save }
        })
        _ = try catalog.importIfNeeded(BundledCatalogLoader.load())
        let inspector = ProjectWorkInspector()
        let projects = ProjectWorkRepository()
        let writer = ProjectWorkWriter()
        let graph = AppDependencies(container: container, catalogRepository: catalog,
                                    projectInspector: inspector, projectRepository: projects,
                                    projectWriter: writer)
        graph.learningCatalogStore.loadIfNeeded()
        let lessonID = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let detail = try graph.learningCatalogStore.openLesson(lessonID: lessonID).detail
        let attemptID = try XCTUnwrap(detail.attempt?.id)
        // No debounce is run; all saves below are synchronous navigation barriers.
        let drafts = LessonDraftStore(learning: graph.learningCatalogStore, schedule: { _, _ in { } })
        drafts.observe(detail)
        let preferences = ProjectWorkPreferences()
        let navigation = NavigationStore(preferences: preferences)
        navigation.attachDrafts(drafts)
        _ = TodayView(store: graph.taskStore, scheduleStore: graph.scheduleStore,
                      learningStore: graph.learningCatalogStore, navigation: navigation)
        // The standalone Today initializer still needs neither navigation nor Learning.
        _ = TodayView(store: graph.taskStore, scheduleStore: graph.scheduleStore)

        TodayView.openProjectWork(navigation: navigation)
        XCTAssertEqual(navigation.selectedDestination, .projects)
        XCTAssertEqual(preferences.savedDestination, AppDestination.projects.rawValue)
        XCTAssertNil(navigation.pendingTransition)
        navigation.select(.today)
        XCTAssertEqual(navigation.selectedDestination, .today)
        drafts.edit("unsaved Project work 🧪", attemptID: attemptID)
        failSave = true
        TodayView.openProjectWork(navigation: navigation)
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(preferences.savedDestination, AppDestination.today.rawValue)
        XCTAssertEqual(navigation.pendingTransition, .destination(.projects))
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "unsaved Project work 🧪")
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        XCTAssertEqual(drafts.buffers[attemptID]?.status, .notSaved(.persistenceFailure))
        navigation.cancelTransition() // Stay here does not discard the failed draft.
        XCTAssertNil(navigation.pendingTransition)
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        TodayView.openProjectWork(navigation: navigation)
        XCTAssertEqual(navigation.pendingTransition, .destination(.projects))
        failSave = false
        navigation.retryTransition()
        XCTAssertNil(navigation.pendingTransition)
        XCTAssertNil(navigation.saveError)
        XCTAssertEqual(navigation.selectedDestination, .projects)
        XCTAssertEqual(preferences.savedDestination, AppDestination.projects.rawValue)
        XCTAssertEqual(drafts.buffers[attemptID]?.status, .saved)
        XCTAssertFalse(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        XCTAssertEqual(try catalog.loadLesson(lessonID: lessonID).attempt?.answerDraft, "unsaved Project work 🧪")
        XCTAssertEqual(inspector.calls, 0)
        XCTAssertEqual(projects.calls, 0)
        XCTAssertEqual(writer.calls, 0)
        XCTAssertFalse(graph.projectStore.isLoaded)
        XCTAssertTrue(graph.projectStore.rows.isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ProjectReference>()).isEmpty)
    }
}
