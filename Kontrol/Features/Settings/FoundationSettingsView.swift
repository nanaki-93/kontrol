import SwiftData
import SwiftUI

/// One Settings hub for both the destination and native scene. Local navigation
/// changes presentation only; every section receives the same app-owned graph.
/// The scene/shell owns the single scroll document. Sections never add a nested
/// scroll view or a pinned action bar that could hide controls in compact windows.
struct FoundationSettingsView: View {
    let dependencies: AppDependencies
    @ObservedObject private var preferences: AppPreferencesStore
    @ObservedObject private var ai: AISettingsStore
    @ObservedObject private var news: NewsStore
    @ObservedObject private var projects: ProjectStore
    @ObservedObject private var export: ExportService
    // Keep a stale-review gate across Back/section changes in this Settings client.
    @StateObject private var foldersManagement: ProjectFoldersSettingsState
    @State private var section: Section = .hub
    @State private var saved = false
    @FocusState private var focusedAction: HubAction?

    private enum Section { case hub, general, ai, news, folders, localData }
    private enum HubAction: Hashable { case general, ai, news, folders, localData, retry, back }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _preferences = ObservedObject(wrappedValue: dependencies.appPreferencesStore)
        _ai = ObservedObject(wrappedValue: dependencies.aiSettingsStore)
        _news = ObservedObject(wrappedValue: dependencies.newsStore)
        _projects = ObservedObject(wrappedValue: dependencies.projectStore)
        _export = ObservedObject(wrappedValue: dependencies.exportService)
        _foldersManagement = StateObject(wrappedValue: ProjectFoldersSettingsState(store: dependencies.projectStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            if section == .ai || section == .news || section == .folders || section == .localData {
                // Shared header moves Back below the title when its ideal width
                // does not fit. Native Settings needs no global destination bar.
                PageHeader("Settings") { backAction }
            } else {
                PageHeader("Settings")
            }
            switch section {
            case .hub:
                hub
            case .general:
                GeneralPreferencesView(store: preferences) { didSave in
                    saved = didSave
                    section = .hub
                    focusedAction = .general
                }
            case .ai:
                AISettingsView(store: ai)
            case .news:
                NewsManagementView(store: news)
                    .padding(AppMetrics.space4)
                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppMetrics.mediumRadius))
            case .folders:
                ProjectFoldersSettingsView(store: projects, management: foldersManagement)
            case .localData:
                LocalDataSettingsView(service: export, onBack: returnToHub)
            }
        }
        // The scroll host proposes an unconstrained height. Keep that natural
        // document size, including lazy News rows, without a viewport-height form.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space4)
        .padding(.bottom, AppMetrics.space4)
        .background(AppColors.background)
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .modelContainer(dependencies.container)
        .onAppear {
            news.loadIfNeeded() // Saved local summaries only; never refresh feeds.
            try? projects.loadReferencesIfNeeded() // No grant resolution or inspection admission.
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-content")
    }

    private var hub: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            if saved {
                StatusPill("Preferences saved", kind: .success)
                    .accessibilityIdentifier("settings-preferences-saved")
            }
            Text("General & appearance").appTypography(.section).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                if let snapshot = preferences.editableSnapshot {
                    Text("Focus default: \(snapshot.preferences.focusDefaultMinutes) minutes")
                        .appTypography(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-focus-summary")
                    Text(GeneralPreferencesView.summary(snapshot.preferences))
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-appearance-summary")
                } else {
                    Label("Saved preferences unavailable · system appearance and 25-minute Focus fallback", systemImage: "exclamationmark.triangle")
                        .appTypography(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-preferences-unavailable")
                    ActionButton("Retry loading preferences") {
                        preferences.retry()
                        // Retry may disappear after a successful read.
                        focusedAction = preferences.editableSnapshot == nil ? .retry : .general
                    }
                    .focused($focusedAction, equals: .retry)
                    .accessibilityIdentifier("settings-preferences-retry")
                }
                ActionButton("Edit general & appearance") { saved = false; section = .general }
                    .focused($focusedAction, equals: .general)
                    .accessibilityIdentifier("settings-general")
                Text("Black / Red Terminal · fixed theme")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Connections").appTypography(.section).accessibilityAddTraits(.isHeader)
            Text(ai.error == .storageFailure || ai.error == .staleRevision
                 ? "AI settings need review"
                 : "AI lessons: \(ai.presentation.enabled ? "On" : "Off") · \(ai.presentation.modelID ?? "Not configured")")
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-ai-summary")
            ActionButton("Configure AI lessons") { section = .ai; focusedAction = .back }
                .focused($focusedAction, equals: .ai)
                .accessibilityIdentifier("settings-ai")
            Text(newsSummary)
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-news-summary")
            ActionButton("Manage News topics & feeds") { section = .news; focusedAction = .back }
                .focused($focusedAction, equals: .news)
                .accessibilityIdentifier("settings-news")
            Text(ProjectFoldersSettingsView.summary(projects))
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-folders-summary")
            ActionButton("Manage project folders") { section = .folders; focusedAction = .back }
                .focused($focusedAction, equals: .folders)
                .accessibilityIdentifier("settings-folders")
            Divider()
            Text("Local data").appTypography(.section).accessibilityAddTraits(.isHeader)
            Text(LocalDataSettingsView.summary(export.state))
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-local-data-summary")
            ActionButton("Manage local data") { section = .localData; focusedAction = .back }
                .focused($focusedAction, equals: .localData)
                .accessibilityIdentifier("settings-local-data")
        }
    }

    private var newsSummary: String {
        guard news.localFailure == nil, let snapshot = news.snapshot else {
            return "News topics & feeds: saved settings unavailable"
        }
        let enabled = snapshot.feeds.filter(\.isEnabled).count
        return "News: \(NewsManagementView.selectedCountText(snapshot)) · \(enabled) of \(snapshot.feeds.count) feeds enabled"
    }

    private var backAction: some View {
        ActionButton("Back to Settings", symbol: "chevron.left", action: returnToHub)
        .focused($focusedAction, equals: .back)
        .accessibilityHint("Return to the Settings hub")
        .accessibilityIdentifier("settings-back")
    }

    private func returnToHub() {
        let origin = section
        section = .hub
        switch origin {
        case .ai: focusedAction = .ai
        case .folders: focusedAction = .folders
        case .localData: focusedAction = .localData
        default: focusedAction = .news
        }
    }
}
