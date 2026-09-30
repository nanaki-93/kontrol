import Foundation
import SwiftData

@MainActor
protocol ExportRepository {
    func snapshot(exportedAt: Date, appVersion: String) throws -> LocalDataExport
}

/// Captures committed rows from the app-owned container, never a feature owner's
/// context or editor draft. Under the single-process main-actor write contract,
/// this synchronous operation cannot interleave with another owner's save. This
/// is not a cross-process database transaction or a backup/restore boundary.
@MainActor
final class SwiftDataExportRepository: ExportRepository {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func snapshot(exportedAt: Date, appVersion: String) throws -> LocalDataExport {
        // Pure bundled configuration, not News initialization or refresh.
        let catalog = try BundledFeedCatalog.load()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var value = LocalDataExport(exportedAt: try ExportTimestamp(exportedAt), appVersion: appVersion)
        value = try DailyDataExportProjection.project(
            tasks: context.fetch(FetchDescriptor<TaskItem>()),
            blocks: context.fetch(FetchDescriptor<ScheduleBlock>()),
            sessions: context.fetch(FetchDescriptor<FocusSession>()), into: value)
        value = try DailyDataExportProjection.project(
            general: context.fetch(FetchDescriptor<AppPreferencesRecord>()),
            ai: context.fetch(FetchDescriptor<AISettingsRecord>()),
            newsPreferences: context.fetch(FetchDescriptor<NewsPreferencesRecord>()),
            feeds: context.fetch(FetchDescriptor<NewsFeedRecord>()), catalog: catalog, into: value)
        value = try LearningExportProjection.project(
            topics: context.fetch(FetchDescriptor<Topic>()),
            subtopics: context.fetch(FetchDescriptor<Subtopic>()),
            concepts: context.fetch(FetchDescriptor<Concept>()),
            definitions: context.fetch(FetchDescriptor<LessonDefinition>()), into: value)
        value = try LearningExportProjection.project(
            progress: context.fetch(FetchDescriptor<LessonProgress>()),
            attempts: context.fetch(FetchDescriptor<LessonAttempt>()),
            slots: context.fetch(FetchDescriptor<LessonSlot>()),
            terminalRecords: context.fetch(FetchDescriptor<LessonTerminalRecord>()),
            catalogMembership: context.fetch(FetchDescriptor<CatalogMembership>()), into: value)
        try value.validate()
        return value.canonicalized()
    }
}
