import SwiftData
import SwiftUI

/// One foundation surface for both the Settings destination and the native scene.
/// The graph is supplied by the app; neither entry point opens a store.
struct FoundationSettingsView: View {
    let dependencies: AppDependencies

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FoundationStyle.heading("Settings")
            Text("No settings available yet.")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(FoundationStyle.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FoundationStyle.horizontalInset)
        .padding(.top, 32)
        .background(FoundationStyle.background)
        .foregroundStyle(FoundationStyle.primary)
        .preferredColorScheme(.dark)
        .modelContainer(dependencies.container)
        .accessibilityIdentifier("settings-content")
    }
}
