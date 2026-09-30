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
    @State private var section: Section = .hub
    @State private var saved = false

    private enum Section { case hub, general, ai, news }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _preferences = ObservedObject(wrappedValue: dependencies.appPreferencesStore)
        _ai = ObservedObject(wrappedValue: dependencies.aiSettingsStore)
        _news = ObservedObject(wrappedValue: dependencies.newsStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            if section == .ai || section == .news {
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
                }
            case .ai:
                AISettingsView(store: ai)
            case .news:
                NewsManagementView(store: news)
                    .padding(AppMetrics.space4)
                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppMetrics.mediumRadius))
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
        .onAppear { news.loadIfNeeded() } // Saved local summaries only; never refresh feeds.
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
                    ActionButton("Retry loading preferences") { preferences.retry() }
                        .accessibilityIdentifier("settings-preferences-retry")
                }
                ActionButton("Edit general & appearance") { saved = false; section = .general }
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
            ActionButton("Configure AI lessons") { section = .ai }
                .accessibilityIdentifier("settings-ai")
            Text(newsSummary)
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-news-summary")
            ActionButton("Manage News topics & feeds") { section = .news }
                .accessibilityIdentifier("settings-news")
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
        ActionButton("Back to Settings", symbol: "chevron.left") { section = .hub }
            .accessibilityIdentifier("settings-back")
    }
}
