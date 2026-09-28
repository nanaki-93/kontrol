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
    /// Destination and route publish as one state change. A cross-destination entry
    /// can never expose Learning with the previous lesson (or a placeholder route).
    private struct Location {
        var destination: AppDestination
        var route: LearningRoute
    }
    @Published private var location: Location
    var selectedDestination: AppDestination { location.destination }
    var learningRoute: LearningRoute { location.route }

    /// Window navigation uses identities, never positions in the rotating choice list.
    enum LearningRoute: Equatable {
        case choices
        case detail(String)
        case history
    }

    enum Transition: Equatable {
        case destination(AppDestination)
        case topic(String?)
        case learning(LearningRoute)
        case lessonEntry(String)
    }

    @Published private(set) var selectedTopicID: String?
    @Published private(set) var saveError: LessonExperienceError?
    @Published private(set) var pendingTransition: Transition?
    private weak var drafts: LessonDraftStore?
    private var preferences: any DestinationPreferences

    func attachDrafts(_ drafts: LessonDraftStore) {
        self.drafts = drafts
    }

    init(preferences: (any DestinationPreferences)? = nil) {
        let preferences = preferences ?? UserDefaultsDestinationPreferences()
        self.preferences = preferences
        location = Location(destination: preferences.savedDestination.flatMap(AppDestination.init(rawValue:)) ?? .today,
                            route: .choices)
    }

    func select(_ destination: AppDestination) {
        transition(to: .destination(destination))
    }

    func selectTopic(_ id: String?) {
        transition(to: .topic(id))
    }

    /// Stable-ID entry from Today, a schedule block, or Learning. Flush first;
    /// retry replays the entire destination + route request, never half of it.
    func enterLesson(id: String) {
        transition(to: .lessonEntry(id))
    }

    func showLesson(id: String) {
        enterLesson(id: id)
    }

    func showHistory() {
        transition(to: .learning(.history))
    }

    func backToChoices() {
        transition(to: .learning(.choices))
    }

    func retryTransition() {
        guard let pendingTransition else { return }
        transition(to: pendingTransition)
    }

    func cancelTransition() {
        pendingTransition = nil
        // The failed save is still real; keep Retry visible until it succeeds.
    }

    /// The same barrier is used for deactivation, window closure and quit.
    /// A failure retains all routes and buffers so the user can retry.
    @discardableResult
    func flushForLifecycle() -> Bool {
        do {
            try drafts?.flushAll()
            saveError = nil
            return true
        } catch {
            saveError = (error as? LessonExperienceError) ?? .persistenceFailure
            return false
        }
    }

    private func transition(to next: Transition) {
        let unchanged: Bool
        switch next {
        case .destination(let value): unchanged = value == selectedDestination
        case .topic(let value): unchanged = value == selectedTopicID && learningRoute == .choices
        case .learning(let value): unchanged = value == learningRoute
        case .lessonEntry(let id): unchanged = selectedDestination == .learning && learningRoute == .detail(id)
        }
        guard !unchanged else { return }
        guard flushForLifecycle() else {
            pendingTransition = next
            return
        }
        pendingTransition = nil
        switch next {
        case .destination(let value):
            location.destination = value
            preferences.savedDestination = value.rawValue
        case .topic(let value):
            selectedTopicID = value
            location.route = .choices
        case .learning(let value): location.route = value
        case .lessonEntry(let id):
            // Assign the whole location once so SwiftUI sees one coherent route.
            let changesDestination = selectedDestination != .learning
            location = Location(destination: .learning, route: .detail(id))
            if changesDestination { preferences.savedDestination = AppDestination.learning.rawValue }
        }
    }
}
