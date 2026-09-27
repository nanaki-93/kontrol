import SwiftData
import SwiftUI

@main
struct KontrolApp: App {
    static let bootstrapTitle = "Kontrol"
    @StateObject private var launch = LaunchCoordinator()
    @StateObject private var navigation = NavigationStore()

    var body: some Scene {
        WindowGroup {
            MainWindowContent(launch: launch, navigation: navigation)
                .frame(minWidth: 1000, minHeight: 700)
        }
        Settings {
            SettingsSceneContent(launch: launch)
        }
    }
}

/// Both scene entry points share the app-scoped coordinator. Reopening the main
/// window only asks an already-ready coordinator to start (a no-op).
struct MainWindowContent: View {
    @ObservedObject var launch: LaunchCoordinator
    @ObservedObject var navigation: NavigationStore

    var body: some View {
        Group {
            if let dependencies = launch.dependencies, launch.state == .ready {
                AppShell(navigation: navigation, dependencies: dependencies)
                    .modelContainer(dependencies.container)
            } else if launch.state == .opening {
                ProgressView("Opening Kontrol")
            } else {
                // The blocking recovery surface and actions are added in 3.4.
                Text(KontrolApp.bootstrapTitle)
            }
        }
        .task { await launch.start() }
    }
}

struct SettingsSceneContent: View {
    @ObservedObject var launch: LaunchCoordinator

    var body: some View {
        Group {
            if let dependencies = launch.dependencies, launch.state == .ready {
                FoundationSettingsView(dependencies: dependencies)
            } else if launch.state == .opening || launch.state == .idle {
                ProgressView("Opening Kontrol")
            } else {
                Text("Settings are unavailable until Kontrol opens.")
            }
        }
        .frame(width: 520, height: 340)
        .task { await launch.start() }
    }
}
