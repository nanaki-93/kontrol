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

    init(container: ModelContainer, catalogRepository: any CatalogRepository,
         taskRepository: (any TaskRepository)? = nil,
         scheduleRepository: (any ScheduleRepository)? = nil,
         focusRepository: (any FocusRepository)? = nil,
         focusWallClock: @escaping () -> Date = Date.init,
         focusMonotonicClock: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
         draftClock: @escaping () -> Date = Date.init,
         draftScheduler: LessonDraftStore.Scheduler? = nil,
         aiSettingsRepository: (any AISettingsRepository)? = nil,
         credentialStore: (any CredentialStore)? = nil,
         aiGenerator: ((String, String, any CredentialStore) -> any LessonGenerator)? = nil,
         aiConnectionTester: ((String, String, any CredentialStore) -> any OpenAIConnectionTesting)? = nil) {
        self.container = container
        self.catalogRepository = catalogRepository
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
