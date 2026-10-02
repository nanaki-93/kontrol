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

    // Pure read-only projections from the shared owners. A retained snapshot is
    // never evidence of a successful current read, even in a second Settings client.
    static func generalSummary(_ store: AppPreferencesStore) -> String {
        switch store.state {
        case .loaded:
            guard let snapshot = store.editableSnapshot else { return "General: saved preferences unavailable · system defaults in use" }
            return "General: \(GeneralPreferencesView.summary(snapshot.preferences))"
        case .loading:
            return "General: loading saved preferences · system defaults in use"
        case .failed:
            return store.committed == nil
                ? "General: saved preferences unavailable · system defaults in use"
                : "General: read failed · previously loaded values retained, not verified · system defaults in use"
        }
    }

    static func aiSummary(_ store: AISettingsStore) -> String {
        if store.error == .storageFailure { return "AI lessons: settings unavailable · review required" }
        if store.error == .staleRevision { return "AI lessons: settings changed · review required" }
        if store.error != nil { return "AI lessons: configuration needs review" }
        let state = store.presentation
        let configuration = "AI lessons: \(state.enabled ? "On" : "Off") · \(state.modelID ?? "Not configured")"
        switch store.credentialStatus {
        case .missing: return configuration + " · saved key missing"
        case .inaccessible: return configuration + " · key unavailable"
        case .notConfigured, .available: return configuration
        }
    }

    static func newsSummary(_ store: NewsStore) -> String {
        if let failure = store.localFailure {
            return failure == .save ? "News: saved changes need review" : "News: saved settings unavailable"
        }
        guard let snapshot = store.snapshot else {
            return store.isLoading ? "News: loading saved settings" : "News: saved settings unavailable"
        }
        let enabled = snapshot.feeds.filter(\.isEnabled).count
        return "News: \(NewsManagementView.selectedCountText(snapshot)) · \(enabled) of \(snapshot.feeds.count) feeds enabled"
    }

    private var hub: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            if saved {
                StatusPill("Preferences saved", kind: .success)
                    .accessibilityIdentifier("settings-preferences-saved")
            }
            hubSection("General", summary: Self.generalSummary(preferences), summaryID: "settings-general-summary",
                       actionID: "settings-general", actionName: "Open General settings", focus: .general) {
                saved = false
                section = .general
            }
            if case .failed = preferences.state {
                Label(preferences.committed == nil ? "Saved preferences unavailable · system appearance and 25-minute Focus fallback"
                      : "Preference read failed · retained values are not verified · system appearance and 25-minute Focus fallback",
                      systemImage: "exclamationmark.triangle")
                    .appTypography(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-preferences-unavailable")
                ActionButton("Retry loading preferences") {
                    preferences.retry()
                    focusedAction = preferences.editableSnapshot == nil ? .retry : .general
                }
                .focused($focusedAction, equals: .retry)
                .accessibilityIdentifier("settings-preferences-retry")
            }
            hubSection("AI lessons", summary: Self.aiSummary(ai), summaryID: "settings-ai-summary",
                       actionID: "settings-ai", actionName: "Open AI lessons settings", focus: .ai) {
                section = .ai; focusedAction = .back
            }
            hubSection("News", summary: Self.newsSummary(news), summaryID: "settings-news-summary",
                       actionID: "settings-news", actionName: "Open News settings", focus: .news) {
                section = .news; focusedAction = .back
            }
            hubSection("Project folders", summary: ProjectFoldersSettingsView.summary(projects),
                       summaryID: "settings-folders-summary", actionID: "settings-folders",
                       actionName: "Open Project folders settings", focus: .folders) {
                section = .folders; focusedAction = .back
            }
            hubSection("Local data", summary: LocalDataSettingsView.summary(export.state),
                       summaryID: "settings-local-data-summary", actionID: "settings-local-data",
                       actionName: "Open Local data settings", focus: .localData) {
                section = .localData; focusedAction = .back
            }
            Text("Black / Red Terminal · fixed theme")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private func hubSection(_ title: String, summary: String, summaryID: String,
                            actionID: String, actionName: String, focus: HubAction,
                            open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            Text(title).appTypography(.section).accessibilityAddTraits(.isHeader)
            Text(summary).appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(summaryID)
            ActionButton("Open", action: open)
                .focused($focusedAction, equals: focus)
                .accessibilityLabel(actionName)
                .accessibilityIdentifier(actionID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppMetrics.space2)
        .accessibilityElement(children: .contain)
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
