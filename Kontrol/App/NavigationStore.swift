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
    }

    @Published private(set) var learningRoute: LearningRoute = .choices
    @Published private(set) var selectedTopicID: String?
    @Published private(set) var saveError: LessonExperienceError?
    private(set) var pendingTransition: Transition?
    private weak var drafts: LessonDraftStore?
    private var preferences: any DestinationPreferences

    func attachDrafts(_ drafts: LessonDraftStore) {
        self.drafts = drafts
    }

    init(preferences: (any DestinationPreferences)? = nil) {
        let preferences = preferences ?? UserDefaultsDestinationPreferences()
        self.preferences = preferences
        selectedDestination = preferences.savedDestination.flatMap(AppDestination.init(rawValue:)) ?? .today
    }

    func select(_ destination: AppDestination) {
        transition(to: .destination(destination))
    }

    func selectTopic(_ id: String?) {
        transition(to: .topic(id))
    }

    func showLesson(id: String) {
        transition(to: .learning(.detail(id)))
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
        }
        guard !unchanged else { return }
        guard flushForLifecycle() else {
            pendingTransition = next
            return
        }
        pendingTransition = nil
        switch next {
        case .destination(let value):
            selectedDestination = value
            preferences.savedDestination = value.rawValue
        case .topic(let value):
            selectedTopicID = value
            learningRoute = .choices
        case .learning(let value): learningRoute = value
        }
    }
}
