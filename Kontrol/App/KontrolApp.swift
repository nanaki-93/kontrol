import SwiftData
import SwiftUI

@main
struct KontrolApp: App {
    static let bootstrapTitle = "Kontrol"
    @StateObject private var launch = LaunchCoordinator()

    var body: some Scene {
        WindowGroup {
            Group {
                if let dependencies = launch.dependencies, launch.state == .ready {
                    Text(Self.bootstrapTitle)
                        .modelContainer(dependencies.container)
                } else if launch.state == .opening {
                    ProgressView("Opening Kontrol")
                } else {
                    // The blocking recovery surface and actions are added in 3.4.
                    Text(Self.bootstrapTitle)
                }
            }
            .frame(minWidth: 600, minHeight: 400)
            .task { await launch.start() }
        }
    }
}
