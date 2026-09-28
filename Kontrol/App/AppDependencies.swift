import SwiftData

/// Created only after the store is open and its bundled catalog is initialized.
/// Both windows and the future Settings scene receive this same app-owned graph.
@MainActor
final class AppDependencies {
    let container: ModelContainer
    let catalogRepository: any CatalogRepository
    let taskStore: TaskStore
    let scheduleStore: ScheduleStore

    init(container: ModelContainer, catalogRepository: any CatalogRepository,
         taskRepository: (any TaskRepository)? = nil,
         scheduleRepository: (any ScheduleRepository)? = nil) {
        self.container = container
        self.catalogRepository = catalogRepository
        taskStore = TaskStore(repository: taskRepository ?? SwiftDataTaskRepository(container: container))
        scheduleStore = ScheduleStore(repository: scheduleRepository ?? SwiftDataScheduleRepository(container: container))
    }
}
