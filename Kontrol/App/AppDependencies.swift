import Foundation
import SwiftData

/// Created only after the store is open and its bundled catalog is initialized.
/// Both windows and the future Settings scene receive this same app-owned graph.
@MainActor
final class AppDependencies {
    let container: ModelContainer
    let catalogRepository: any CatalogRepository
    let learningCatalogStore: LearningCatalogStore
    let aiSettingsStore: AISettingsStore
    let credentialStore: any CredentialStore
    let lessonGenerationStore: LessonGenerationStore
    let lessonDraftStore: LessonDraftStore
    let taskStore: TaskStore
    let scheduleStore: ScheduleStore
    let focusService: FocusService
    let projectStore: ProjectStore
    let newsStore: NewsStore

    init(container: ModelContainer, catalogRepository: any CatalogRepository,
         taskRepository: (any TaskRepository)? = nil,
         scheduleRepository: (any ScheduleRepository)? = nil,
         focusRepository: (any FocusRepository)? = nil,
         projectInspector: any ProjectInspecting = ProjectInspector(),
         projectRepository: (any ProjectReferenceRepository)? = nil,
         projectIdentifier: any ProjectFolderIdentifying = ScopedProjectFolderIdentifier(),
         projectWriter: any FeatureFileWriting = FeatureFileWriter(),
         projectCompletionClock: @escaping () -> Date = Date.init,
         focusWallClock: @escaping () -> Date = Date.init,
         focusMonotonicClock: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
         draftClock: @escaping () -> Date = Date.init,
         draftScheduler: LessonDraftStore.Scheduler? = nil,
         aiSettingsRepository: (any AISettingsRepository)? = nil,
         credentialStore: (any CredentialStore)? = nil,
         aiGenerator: ((String, String, any CredentialStore) -> any LessonGenerator)? = nil,
         aiConnectionTester: ((String, String, any CredentialStore) -> any OpenAIConnectionTesting)? = nil,
         newsRepository: (any NewsRepository)? = nil,
         newsService: any NewsRefreshing = FeedService(),
         newsCatalog: DefaultFeedCatalog? = nil,
         newsCatalogLoader: () throws -> DefaultFeedCatalog = { try BundledFeedCatalog.load() }) {
        self.container = container
        self.catalogRepository = catalogRepository
        // LaunchCoordinator validates the required resource before publishing this graph.
        // Directly constructed graphs also surface a catalog failure on the News route
        // rather than trapping or treating a missing resource as an empty feed.
        // Neither construction nor catalog loading starts a feed request.
        let loadedCatalog: DefaultFeedCatalog?
        if let newsCatalog {
            loadedCatalog = newsCatalog
        } else {
            loadedCatalog = try? newsCatalogLoader()
        }
        newsStore = NewsStore(repository: newsRepository ?? SwiftDataNewsRepository(container: container),
                              service: newsService, catalog: loadedCatalog)
        // Assemble the project boundary without fetching references or resolving grants.
        // SwiftData stays on the main actor; only detached snapshots cross into IO.
        projectStore = ProjectStore(inspector: projectInspector,
            repository: projectRepository ?? SwiftDataProjectReferenceRepository(container: container),
            identifier: projectIdentifier, writer: projectWriter,
            completionClock: projectCompletionClock)
        learningCatalogStore = LearningCatalogStore(repository: catalogRepository)
        let credentials = credentialStore ?? KeychainCredentialStore()
        self.credentialStore = credentials
        aiSettingsStore = AISettingsStore(repository: aiSettingsRepository ?? SwiftDataAISettingsRepository(container: container),
            credentials: credentials, connectionTester: { model, reference in
                if let aiConnectionTester { return aiConnectionTester(model, reference, credentials) }
                return OpenAILessonGenerator(model: model, credentialReference: reference, credentials: credentials)
            })
        lessonGenerationStore = LessonGenerationStore(settings: aiSettingsStore, repository: catalogRepository,
            learning: learningCatalogStore, generator: { model, reference in
                if let aiGenerator { return aiGenerator(model, reference, credentials) }
                return OpenAILessonGenerator(model: model, credentialReference: reference, credentials: credentials)
            })
        if let draftScheduler {
            lessonDraftStore = LessonDraftStore(learning: learningCatalogStore, clock: draftClock,
                                                schedule: draftScheduler)
        } else {
            lessonDraftStore = LessonDraftStore(learning: learningCatalogStore, clock: draftClock)
        }
        taskStore = TaskStore(repository: taskRepository ?? SwiftDataTaskRepository(container: container))
        scheduleStore = ScheduleStore(repository: scheduleRepository ?? SwiftDataScheduleRepository(container: container))
        focusService = FocusService(repository: focusRepository ?? SwiftDataFocusRepository(container: container),
                                    wallClock: focusWallClock, monotonicClock: focusMonotonicClock)
        taskStore.didDeleteTask = { [weak focusService] id in
            focusService?.taskWasDeleted(id: id)
        }
        focusService.loadIfNeeded()
    }
}
