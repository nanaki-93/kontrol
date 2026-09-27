import SwiftData
import SwiftUI

@main
struct KontrolApp: App {
    static let bootstrapTitle = "Kontrol"
    @StateObject private var launch = LaunchCoordinator()
    @StateObject private var navigation = NavigationStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if let dependencies = launch.dependencies, launch.state == .ready {
                    AppShell(navigation: navigation)
                        .modelContainer(dependencies.container)
                } else if launch.state == .opening {
                    ProgressView("Opening Kontrol")
                } else {
                    // The blocking recovery surface and actions are added in 3.4.
                    Text(Self.bootstrapTitle)
                }
            }
            .frame(minWidth: 1000, minHeight: 700)
            .task { await launch.start() }
        }
    }
}
