import Foundation
import SwiftUI

/// Only destination selection is stored in preferences; user records remain in SwiftData.
@MainActor
protocol DestinationPreferences {
    var savedDestination: String? { get set }
}

@MainActor
struct UserDefaultsDestinationPreferences: DestinationPreferences {
    static let key = "com.kontrol.app.selectedDestination"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var savedDestination: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

@MainActor
final class NavigationStore: ObservableObject {
    @Published private(set) var selectedDestination: AppDestination
    private var preferences: any DestinationPreferences

    init(preferences: (any DestinationPreferences)? = nil) {
        let preferences = preferences ?? UserDefaultsDestinationPreferences()
        self.preferences = preferences
        selectedDestination = preferences.savedDestination.flatMap(AppDestination.init(rawValue:)) ?? .today
    }

    func select(_ destination: AppDestination) {
        guard destination != selectedDestination else { return }
        selectedDestination = destination
        preferences.savedDestination = destination.rawValue
    }
}
