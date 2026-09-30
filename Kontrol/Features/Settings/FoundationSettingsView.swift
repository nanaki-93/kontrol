import SwiftData
import SwiftUI

/// One foundation surface for both the Settings destination and the native scene.
/// The graph is supplied by the app; neither entry point opens a store.
struct FoundationSettingsView: View {
    let dependencies: AppDependencies

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Settings")
            AISettingsView(store: dependencies.aiSettingsStore)
            NewsManagementView(store: dependencies.newsStore)
                .padding(AppMetrics.space4)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppMetrics.mediumRadius))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .background(AppColors.background)
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .modelContainer(dependencies.container)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-content")
    }
}
