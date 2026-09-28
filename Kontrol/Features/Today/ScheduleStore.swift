import AppKit
import Combine
import Foundation

/// A failed read is not an empty day. Any cached rows remain explicitly stale
/// until Retry (or activation) successfully reads the repository again.
enum ScheduleReadState: Equatable {
    case notLoaded
    case loaded
    case failed(hasStaleRows: Bool)

    var message: String? {
        switch self {
        case .notLoaded, .loaded: return nil
        case .failed(hasStaleRows: true):
            return "Could not refresh blocks. Showing previously loaded blocks. Retry to update."
        case .failed(hasStaleRows: false):
            return "Could not load blocks. Retry to update."
        }
    }
}

enum ScheduleMutationError: Equatable {
    case validation(ScheduleValidationError)
    case notFound
    case overlap
    case persistence

    var message: String {
        switch self {
        case .validation: return "Check the block title and times, then try again."
        case .notFound: return "This block is no longer available. Refresh the list and try again."
        case .overlap: return "This time overlaps another block. Review the conflicts before saving."
        case .persistence: return "Could not save the block. Please try again."
        }
    }
}

/// The one app-owned publication point for committed value copies. Never fetch
/// after a successful write: its returned snapshot is the commit receipt.
@MainActor
final class ScheduleStore: ObservableObject {
    let repository: any ScheduleRepository
    @Published private(set) var snapshots: [ScheduleSnapshot] = []
    @Published private(set) var readState: ScheduleReadState = .notLoaded
    @Published private(set) var mutationError: ScheduleMutationError?

    private let notificationCenter: NotificationCenter
    private var activationObserver: NSObjectProtocol?

    init(repository: any ScheduleRepository, notificationCenter: NotificationCenter = .default) {
        self.repository = repository
        self.notificationCenter = notificationCenter
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
    }

    /// Called on appearance, activation or explicit Retry. Writes are never retried automatically.
    func refresh() {
        do {
            snapshots = Self.ordered(try repository.fetchAll())
            readState = .loaded
        } catch {
            readState = .failed(hasStaleRows: !snapshots.isEmpty)
        }
    }

    func retryRead() { refresh() }

    @discardableResult
    func create(input: ScheduleInput, allowOverlap: Bool = false,
                review: ScheduleOverlapReview? = nil) throws -> ScheduleSnapshot {
        try perform {
            let committed = try repository.create(input: input, allowOverlap: allowOverlap, review: review)
            publish(committed)
            return committed
        }
    }

    @discardableResult
    func update(id: UUID, input: ScheduleInput, allowOverlap: Bool = false,
                review: ScheduleOverlapReview? = nil) throws -> ScheduleSnapshot {
        try perform {
            let committed = try repository.update(id: id, input: input,
                                                  allowOverlap: allowOverlap, review: review)
            publish(committed)
            return committed
        }
    }

    func delete(id: UUID) throws {
        try perform {
            try repository.delete(id: id)
            snapshots.removeAll { $0.id == id }
            updateStaleFlag()
        }
    }

    private func publish(_ committed: ScheduleSnapshot) {
        snapshots = Self.ordered(snapshots.filter { $0.id != committed.id } + [committed])
        updateStaleFlag()
    }

    private static func ordered(_ values: [ScheduleSnapshot]) -> [ScheduleSnapshot] {
        values.sorted {
            if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
            if $0.endAt != $1.endAt { return $0.endAt < $1.endAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func updateStaleFlag() {
        if case .failed = readState { readState = .failed(hasStaleRows: !snapshots.isEmpty) }
    }

    private func perform<T>(_ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            mutationError = nil
            return result
        } catch {
            switch error {
            case ScheduleRepositoryError.validation(let reason): mutationError = .validation(reason)
            case ScheduleRepositoryError.overlap: mutationError = .overlap
            case ScheduleRepositoryError.notFound:
                mutationError = .notFound
                // A second owner may have deleted it; failed refresh keeps stale rows.
                refresh()
            default: mutationError = .persistence
            }
            throw error
        }
    }
}
