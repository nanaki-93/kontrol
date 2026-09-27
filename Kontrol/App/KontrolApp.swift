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
    @State private var recoveryFailure: LaunchFailure?

    var body: some View {
        Group {
            if let dependencies = launch.dependencies, launch.state == .ready {
                AppShell(navigation: navigation, dependencies: dependencies)
                    .modelContainer(dependencies.container)
            } else if case .failed(let failure) = launch.state {
                RecoveryView(failure: failure, launch: launch, onRetry: {
                    recoveryFailure = failure
                    Task { await launch.retry() }
                })
            } else if launch.state == .opening, let recoveryFailure {
                RecoveryView(failure: recoveryFailure, launch: launch)
            } else if launch.state == .opening {
                ProgressView("Opening Kontrol")
            } else {
                Text(KontrolApp.bootstrapTitle)
            }
        }
        .onChange(of: launch.state) { newState in
            if case .failed(let failure) = newState { recoveryFailure = failure }
            if newState == .ready { recoveryFailure = nil }
        }
        .task { await launch.start() }
    }
}

struct SettingsSceneContent: View {
    @ObservedObject var launch: LaunchCoordinator
    @State private var recoveryFailure: LaunchFailure?

    var body: some View {
        Group {
            if let dependencies = launch.dependencies, launch.state == .ready {
                FoundationSettingsView(dependencies: dependencies)
            } else if case .failed(let failure) = launch.state {
                RecoveryView(failure: failure, launch: launch, onRetry: {
                    recoveryFailure = failure
                    Task { await launch.retry() }
                })
            } else if launch.state == .opening, let recoveryFailure {
                RecoveryView(failure: recoveryFailure, launch: launch)
            } else {
                ProgressView("Opening Kontrol")
            }
        }
        .frame(width: 520, height: 340)
        .onChange(of: launch.state) { newState in
            if case .failed(let failure) = newState { recoveryFailure = failure }
            if newState == .ready { recoveryFailure = nil }
        }
        .task { await launch.start() }
    }
}
