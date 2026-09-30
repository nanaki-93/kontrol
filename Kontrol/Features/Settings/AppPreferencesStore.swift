import Combine
import Foundation

enum AppPreferencesReadState: Equatable {
    case loading
    case loaded
    case failed(AppPreferencesError)
}

/// One app-owned publication point. Editors never place unsaved values here.
@MainActor
final class AppPreferencesStore: ObservableObject {
    @Published private(set) var state: AppPreferencesReadState = .loading
    /// Retained on read failure, but not evidence that current storage is readable.
    @Published private(set) var committed: AppPreferencesSnapshot?
    private let repository: any AppPreferencesRepository

    init(repository: any AppPreferencesRepository) {
        self.repository = repository
        retry()
    }

    /// Only a successful read may establish a new editor's baseline. In particular,
    /// an unavailable record is not the same as a successfully read absent record.
    var editableSnapshot: AppPreferencesSnapshot? {
        guard state == .loaded else { return nil }
        return committed
    }

    /// Explicit read/retry; never inserts defaults or retries a failed save.
    func retry() {
        state = .loading
        do {
            committed = try repository.load()
            state = .loaded
        } catch {
            state = .failed(Self.failure(error))
        }
    }

    @discardableResult
    func save(_ draft: AppPreferencesDraft, expectedRevision: UUID?) throws -> AppPreferencesSnapshot {
        // Do not allow a fallback editor to overwrite damaged/unreadable storage.
        guard state == .loaded else {
            if case .failed(let error) = state { throw error }
            throw AppPreferencesError.persistenceFailure
        }
        _ = try draft.validated()
        do {
            let receipt = try repository.save(draft, expectedRevision: expectedRevision)
            // No suspension between durable save and committed publication. Never
            // synthesize a receipt from the proposal or read again after saving.
            committed = receipt
            return receipt
        } catch {
            throw Self.failure(error)
        }
    }

    private static func failure(_ error: Error) -> AppPreferencesError {
        (error as? AppPreferencesError) ?? .persistenceFailure
    }
}
