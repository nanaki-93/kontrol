import Foundation
import SwiftData

/// Created only after the store is open and its bundled catalog is initialized.
/// Both windows and the future Settings scene receive this same app-owned graph.
@MainActor
final class AppDependencies {
    let container: ModelContainer
    let catalogRepository: any CatalogRepository
    let taskStore: TaskStore
    let scheduleStore: ScheduleStore
    let focusService: FocusService

    init(container: ModelContainer, catalogRepository: any CatalogRepository,
         taskRepository: (any TaskRepository)? = nil,
         scheduleRepository: (any ScheduleRepository)? = nil,
         focusRepository: (any FocusRepository)? = nil,
         focusWallClock: @escaping () -> Date = Date.init,
         focusMonotonicClock: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.container = container
        self.catalogRepository = catalogRepository
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
