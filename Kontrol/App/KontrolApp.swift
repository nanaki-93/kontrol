import SwiftUI

@main
struct KontrolApp: App {
    static let bootstrapTitle = "Kontrol"

    var body: some Scene {
        WindowGroup {
            Text(Self.bootstrapTitle)
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
