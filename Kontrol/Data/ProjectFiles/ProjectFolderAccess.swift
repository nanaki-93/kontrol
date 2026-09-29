import Foundation

/// Only the bookmark bytes may be stored. An absolute URL is never a replacement for a grant.
/// Callers must obtain `selectedFolder` from a user-initiated folder picker; this service does
/// not interpret arbitrary saved paths as authorization. Do not retain the URL past the closure.
enum ProjectFolderAccessError: Error, Equatable {
    case stale
    case unresolved
    case revoked
    case denied
    case invalidFolder
    case bookmarkCreationFailed
}

/// Injectable OS boundary; the production implementation uses app-scoped, read/write bookmarks.
protocol ProjectBookmarkOperations {
    func resolve(_ data: Data) throws -> (folder: URL, isStale: Bool)
    func createBookmark(for selectedFolder: URL) throws -> Data
    func startAccessing(_ folder: URL) -> Bool
    func stopAccessing(_ folder: URL)
}

struct SystemProjectBookmarkOperations: ProjectBookmarkOperations {
    func resolve(_ data: Data) throws -> (folder: URL, isStale: Bool) {
        var stale = false
        let folder = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        return (folder, stale)
    }

    func createBookmark(for selectedFolder: URL) throws -> Data {
        try selectedFolder.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func startAccessing(_ folder: URL) -> Bool { folder.startAccessingSecurityScopedResource() }
    func stopAccessing(_ folder: URL) { folder.stopAccessingSecurityScopedResource() }
}

struct ProjectFolderAccess {
    private let operations: any ProjectBookmarkOperations

    init(operations: any ProjectBookmarkOperations = SystemProjectBookmarkOperations()) {
        self.operations = operations
    }

    /// A picker selection is temporary authorization, not a path to save. Release is guaranteed
    /// even if the operation throws or is canceled. All project IO must remain inside this scope.
    func withSelectedFolder<T>(_ selectedFolder: URL, perform body: (URL) async throws -> T) async throws -> T {
        try await withScope(selectedFolder, deniedAs: .denied, perform: body)
    }

    /// Never retry with a raw URL when resolution, freshness, or access fails.
    func withBookmark<T>(_ data: Data, perform body: (URL) async throws -> T) async throws -> T {
        try await withResolvedBookmark(data, completion: .read, perform: body)
    }

    /// Use only for mutation IO whose body owns its commit-point cancellation policy. A body
    /// that has committed must be able to return its receipt even when cancellation arrives.
    /// Unlike reads, this entry point does not check cancellation after the body returns.
    func withMutationBookmark<T>(_ data: Data, perform body: (URL) async throws -> T) async throws -> T {
        try await withResolvedBookmark(data, completion: .mutation, perform: body)
    }

    private enum CompletionPolicy { case read, mutation }

    private func withResolvedBookmark<T>(_ data: Data, completion: CompletionPolicy,
                                         perform body: (URL) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw ProjectFolderAccessError.unresolved }
        let resolved: (folder: URL, isStale: Bool)
        do {
            resolved = try operations.resolve(data)
        } catch {
            if error is CancellationError { throw error }
            throw Self.resolutionFailure(error)
        }
        try Task.checkCancellation()
        guard !resolved.isStale else { throw ProjectFolderAccessError.stale }
        return try await withScope(resolved.folder, deniedAs: .revoked, completion: completion, perform: body)
    }

    /// Called only after a successful selected-folder inspection and explicit Add/Reconnect.
    /// Returns opaque bookmark bytes, never a URL or a path. F09 does not write project files.
    func makeBookmark(selectedFolder: URL) async throws -> Data {
        try await withSelectedFolder(selectedFolder) { folder in
            do {
                let data = try operations.createBookmark(for: folder)
                guard !data.isEmpty else { throw ProjectFolderAccessError.bookmarkCreationFailed }
                return data
            } catch {
                if error is CancellationError { throw error }
                if let failure = error as? ProjectFolderAccessError { throw failure }
                throw ProjectFolderAccessError.bookmarkCreationFailed
            }
        }
    }

    private func withScope<T>(_ folder: URL, deniedAs failure: ProjectFolderAccessError,
                              completion: CompletionPolicy = .read,
                              perform body: (URL) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard folder.isFileURL else { throw ProjectFolderAccessError.invalidFolder }
        guard operations.startAccessing(folder) else { throw failure }
        defer { operations.stopAccessing(folder) }
        try Task.checkCancellation()
        // Verify only after authorization is active. A missing/replaced folder is not a valid grant.
        let isDirectory: Bool
        do {
            isDirectory = try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            throw failure
        }
        guard isDirectory else { throw ProjectFolderAccessError.invalidFolder }
        // The last scope-level check is before IO. The mutation body must handle cancellation
        // before its commit point and verify the outcome once committing begins.
        try Task.checkCancellation()
        let result = try await body(folder)
        if case .read = completion { try Task.checkCancellation() }
        return result
    }

    private static func resolutionFailure(_ error: Error) -> ProjectFolderAccessError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError { return .revoked }
            if nsError.code == NSFileNoSuchFileError { return .unresolved }
        }
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)) {
            return .revoked
        }
        return .unresolved
    }
}
