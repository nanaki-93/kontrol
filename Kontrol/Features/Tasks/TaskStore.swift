import Combine
import Foundation

/// A read failure is never equivalent to a successfully loaded empty collection.
/// Cached values remain visible only while explicitly marked stale.
enum TaskReadState: Equatable {
    case notLoaded
    case loaded
    case failed(hasStaleRows: Bool)

    var message: String? {
        switch self {
        case .notLoaded, .loaded:
            return nil
        case .failed(hasStaleRows: true):
            return "Could not refresh tasks. Showing previously loaded tasks. Retry to update."
        case .failed(hasStaleRows: false):
            return "Could not load tasks. Retry to update."
        }
    }
}

enum TaskMutationError: Equatable {
    case writeFailed
    case notFound

    var message: String {
        switch self {
        case .writeFailed:
            return "Could not save the task. Please try again."
        case .notFound:
            return "This task is no longer available. Refresh the list and try again."
        }
    }
}

/// One main-actor publication point for committed task values. This store owns
/// no ModelContext: every value is copied before leaving the repository.
@MainActor
final class TaskStore: ObservableObject {
    let repository: any TaskRepository
    @Published private(set) var snapshots: [TaskSnapshot] = []
    @Published private(set) var readState: TaskReadState = .notLoaded
    @Published private(set) var mutationError: TaskMutationError?

    init(repository: any TaskRepository) {
        self.repository = repository
    }

    /// Called on appearance or by an explicit Retry action. No automatic retry
    /// of a write is safe, especially for a destructive operation.
    func refresh() {
        do {
            let values = try repository.fetchAll().map(TaskSnapshot.init)
            snapshots = values
            readState = .loaded
        } catch {
            readState = .failed(hasStaleRows: !snapshots.isEmpty)
        }
    }

    func retryRead() {
        refresh()
    }

    @discardableResult
    func create(input: TaskInput) throws -> TaskSnapshot {
        try perform {
            let committed = try repository.create(input: input)
            publish(committed)
            return committed
        }
    }

    @discardableResult
    func update(id: UUID, input: TaskInput) throws -> TaskSnapshot {
        try perform {
            let committed = try repository.update(id: id, input: input)
            publish(committed)
            return committed
        }
    }

    @discardableResult
    func setCompleted(id: UUID, completed: Bool) throws -> TaskSnapshot {
        try perform {
            let committed = try repository.setCompleted(id: id, completed: completed)
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

    private func publish(_ committed: TaskSnapshot) {
        // The returned value is the commit receipt. Never refetch here: a read
        // error after save must not invite a duplicate creation or conceal success.
        var next = snapshots.filter { $0.id != committed.id }
        next.append(committed)
        next.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        snapshots = next
        updateStaleFlag()
    }

    private func updateStaleFlag() {
        if case .failed = readState {
            readState = .failed(hasStaleRows: !snapshots.isEmpty)
        }
    }

    private func perform<T>(_ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            mutationError = nil
            return result
        } catch {
            if case TaskRepositoryError.notFound = error {
                mutationError = .notFound
                // A missing UUID can mean an external owner removed it. Read
                // again; if that fails, leave cached values marked stale.
                refresh()
            } else {
                mutationError = .writeFailed
            }
            throw error
        }
    }
}
