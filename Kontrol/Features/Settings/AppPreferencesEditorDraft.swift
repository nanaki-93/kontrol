import Combine
import Foundation

enum AppPreferencesEditorError: Error, Equatable {
    case preferencesUnavailable
    case preferences(AppPreferencesError)
}

/// Window-local input and revision baseline, deliberately not subscribed to the
/// shared store. Another editor's publication must not silently rebase this one.
@MainActor
final class AppPreferencesEditorDraft: ObservableObject {
    @Published var draft: AppPreferencesDraft
    @Published private(set) var baseline: AppPreferencesSnapshot?
    @Published private(set) var error: AppPreferencesEditorError?

    init(snapshot: AppPreferencesSnapshot?) {
        baseline = snapshot
        draft = AppPreferencesDraft(preferences: snapshot?.preferences ?? .defaults)
    }

    var baselineRevision: UUID? { baseline?.revision }
    var hasChanges: Bool {
        draft != AppPreferencesDraft(preferences: baseline?.preferences ?? .defaults)
    }

    func save(using store: AppPreferencesStore) throws {
        guard let baseline else {
            error = .preferencesUnavailable
            throw AppPreferencesEditorError.preferencesUnavailable
        }
        do {
            let receipt = try store.save(draft, expectedRevision: baseline.revision)
            self.baseline = receipt
            draft = AppPreferencesDraft(preferences: receipt.preferences)
            error = nil
        } catch {
            let failure = Self.failure(error)
            self.error = failure
            throw failure
        }
    }

    /// Explicit stale-edit review accepts the latest *read* baseline while keeping
    /// every unsaved input. Saving still requires a separate user action and checks
    /// this revision again. A failed read cannot rebase from a stale cached value.
    func reviewLatest(using store: AppPreferencesStore) throws {
        store.retry()
        guard let latest = store.editableSnapshot else {
            let failure: AppPreferencesEditorError
            if case .failed(let error) = store.state { failure = .preferences(error) }
            else { failure = .preferencesUnavailable }
            error = failure
            throw failure
        }
        baseline = latest
        error = nil
    }

    /// Cancel discards only this editor's inputs; it never mutates shared state.
    func cancel() {
        draft = AppPreferencesDraft(preferences: baseline?.preferences ?? .defaults)
        error = nil
    }

    private static func failure(_ error: Error) -> AppPreferencesEditorError {
        .preferences((error as? AppPreferencesError) ?? .persistenceFailure)
    }
}
