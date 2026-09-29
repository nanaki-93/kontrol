import Darwin
import Foundation

/// Folder identity is deliberately separate from the manifest ID and opaque bookmark bytes.
/// No path or file contents are persisted by the store.
struct ProjectFolderIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

protocol ProjectFolderIdentifying {
    func selected(_ folder: URL) async throws -> ProjectFolderIdentity
    func bookmarked(_ data: Data) async throws -> ProjectFolderIdentity
    func location(bookmarked data: Data) async throws -> String
}

extension ProjectFolderIdentifying {
    // Test identifiers that do not resolve a display location still support identity checks.
    func location(bookmarked data: Data) async throws -> String { "" }
}

struct ScopedProjectFolderIdentifier: ProjectFolderIdentifying {
    private let access: ProjectFolderAccess

    init(access: ProjectFolderAccess = ProjectFolderAccess()) { self.access = access }

    func selected(_ folder: URL) async throws -> ProjectFolderIdentity {
        try await access.withSelectedFolder(folder) { try Self.identity($0) }
    }

    func bookmarked(_ data: Data) async throws -> ProjectFolderIdentity {
        try await access.withBookmark(data) { try Self.identity($0) }
    }

    func location(bookmarked data: Data) async throws -> String {
        // A transient display hint only, resolved inside a valid grant; never persisted.
        try await access.withBookmark(data) { $0.path }
    }

    private static func identity(_ folder: URL) throws -> ProjectFolderIdentity {
        try Task.checkCancellation()
        var info = stat()
        guard folder.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return Darwin.lstat(path, &info) == 0
        }), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ProjectFolderAccessError.invalidFolder
        }
        return ProjectFolderIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

/// Inspection, identity, and local persistence failures require different explanations.
/// All are retryable via refresh(id); only grant failures direct the user to Reconnect.
enum ProjectRefreshFailure: Equatable {
    case inspection(ProjectInspectionFailure)
    case manifestMismatch
    case persistence

    var recovery: ProjectRecovery {
        switch self {
        case let .inspection(failure): return failure.recovery
        case .manifestMismatch, .persistence: return .refresh
        }
    }
}

struct ProjectRowState {
    var reference: ProjectReferenceSnapshot
    var inspection: ProjectInspection?
    var isRefreshing = false
    var isStale = false
    var lastReadAt: Date? // Last displayed inspection, distinct from lastSuccessfulReadAt.
    var refreshFailure: ProjectRefreshFailure?
    var locationHint: String? // Transient last-seen location; not a saved authorization path.
}

struct ProjectAddPreview {
    let folder: URL // Ephemeral picker selection only; never written to SwiftData.
    let inspection: ProjectInspection
    let canAdd: Bool
}

enum ProjectAddResult: Equatable {
    case added(UUID)
    case selectedExisting(UUID)
}

enum ProjectStoreError: Error, Equatable {
    case invalidPreview
    case projectNotAdded
    case projectNotReconnected
    case invalidReconnect
    case manifestMismatch
    case referenceNotFound
    case busy
}

/// Created by the app dependency graph later; construction does not fetch rows or touch disk.
/// The only durable project state is a committed repository receipt.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var rows: [ProjectRowState] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var preview: ProjectAddPreview?
    @Published private(set) var addMessage: String?
    @Published private(set) var reconnectMessage: String?
    @Published private(set) var loadFailed = false
    private(set) var isLoaded = false

    private let inspector: any ProjectInspecting
    private let repository: any ProjectReferenceRepository
    private let identifier: any ProjectFolderIdentifying
    private var previewGeneration = 0
    private var adding = false
    private var reconnecting: Set<UUID> = []
    private var reconnectGenerations: [UUID: Int] = [:]
    private struct RefreshOperation {
        var generation = 0
        var task: Task<Void, Never>?
        var followUp = false
        var queued = false
    }
    private var refreshOperations: [UUID: RefreshOperation] = [:]
    private var refreshQueue: [UUID] = []
    private var activeRefreshes = 0
    private let maxConcurrentRefreshes = 3

    init(inspector: any ProjectInspecting, repository: any ProjectReferenceRepository,
         identifier: any ProjectFolderIdentifying = ScopedProjectFolderIdentifier()) {
        self.inspector = inspector
        self.repository = repository
        self.identifier = identifier
    }

    /// Call on entry to Projects, not at launch. Failed fetches may be retried on next entry.
    func enterProjects() throws {
        guard !isLoaded else { return }
        do {
            rows = try repository.fetchAll().map { ProjectRowState(reference: $0, inspection: nil) }
            isLoaded = true
            loadFailed = false
            refreshAll()
        } catch {
            loadFailed = true
            throw error
        }
    }

    /// Requests for a waiting row merge; a running row gets just one follow-up.
    /// A failure in one row never prevents other queued rows from starting.
    func refreshAll() {
        for row in rows { refresh(row.reference.id) }
    }

    func select(_ id: UUID) {
        guard rows.contains(where: { $0.reference.id == id }) else { return }
        selectedID = id
    }

    func refresh(_ id: UUID) {
        guard rows.contains(where: { $0.reference.id == id }) else { return }
        var operation = refreshOperations[id] ?? RefreshOperation()
        if operation.task != nil {
            operation.followUp = true
        } else if !operation.queued {
            operation.queued = true
            refreshQueue.append(id)
            if let index = rows.firstIndex(where: { $0.reference.id == id }) {
                rows[index].isRefreshing = true
            }
        }
        refreshOperations[id] = operation
        drainRefreshQueue()
    }

    /// Cancel without freeing a slot until the underlying IO actually finishes. A reader
    /// that ignores cancellation still cannot publish its result or start extra work.
    func cancelRefresh(_ id: UUID) {
        guard var operation = refreshOperations[id] else { return }
        operation.task?.cancel()
        operation.followUp = false
        if operation.queued {
            refreshQueue.removeAll { $0 == id }
            operation.queued = false
        }
        refreshOperations[id] = operation
        if operation.task == nil, let index = rows.firstIndex(where: { $0.reference.id == id }) {
            rows[index].isRefreshing = false
        }
    }

    private func drainRefreshQueue() {
        while activeRefreshes < maxConcurrentRefreshes && !refreshQueue.isEmpty {
            let id = refreshQueue.removeFirst()
            guard let index = rows.firstIndex(where: { $0.reference.id == id }),
                  var operation = refreshOperations[id], operation.queued else { continue }
            operation.queued = false
            operation.generation += 1
            let generation = operation.generation
            let reference = rows[index].reference
            activeRefreshes += 1
            operation.task = Task { [inspector, identifier] in
                let result: Result<ProjectInspection, Error>
                var location: String?
                do {
                    let inspection = try await inspector.inspect(bookmarkData: reference.bookmarkData)
                    try Task.checkCancellation()
                    // Location is optional display metadata, never a prerequisite for inspection.
                    location = try? await identifier.location(bookmarked: reference.bookmarkData)
                    try Task.checkCancellation()
                    result = .success(inspection)
                } catch {
                    result = .failure(error)
                }
                self.finishRefresh(id: id, revision: reference.revision,
                                   generation: generation, result: result, location: location)
            }
            refreshOperations[id] = operation
        }
    }

    private func finishRefresh(id: UUID, revision: UUID, generation: Int,
                               result: Result<ProjectInspection, Error>, location: String?) {
        guard var operation = refreshOperations[id], operation.generation == generation,
              operation.task != nil else { return }
        operation.task = nil
        activeRefreshes -= 1
        // A replaced bookmark, canceled task, or removed row owns no publication rights.
        if let index = rows.firstIndex(where: { $0.reference.id == id }),
           rows[index].reference.revision == revision {
            switch result {
            case let .success(inspection):
                if let location, !location.isEmpty { rows[index].locationHint = location }
                // A bookmark can still resolve after the selected folder's manifest was
                // replaced. Never publish content belonging to a different project ID.
                if let manifest = inspection.manifest, manifest.id != rows[index].reference.manifestID {
                    rows[index].isStale = true
                    rows[index].refreshFailure = .manifestMismatch
                } else if Self.isComplete(inspection), let manifest = inspection.manifest {
                    do {
                        let receipt = try repository.recordSuccessfulRead(id: id,
                            expectedRevision: revision, nameHint: manifest.name, readAt: inspection.readAt)
                        rows[index].reference = receipt
                        rows[index].inspection = inspection
                        rows[index].lastReadAt = inspection.readAt
                        rows[index].isStale = false
                        rows[index].refreshFailure = nil
                    } catch {
                        // Do not claim a fresh successful read when its durable receipt failed.
                        rows[index].isStale = true
                        rows[index].refreshFailure = .persistence
                    }
                } else {
                    rows[index].inspection = inspection
                    rows[index].lastReadAt = inspection.readAt
                    rows[index].isStale = true
                    rows[index].refreshFailure = nil
                }
            case let .failure(error):
                if !(error is CancellationError) {
                    rows[index].isStale = true
                    rows[index].refreshFailure = .inspection((error as? ProjectInspectionFailure) ?? .unreadableFolder)
                }
            }
            rows[index].isRefreshing = operation.followUp
        }
        let followUp = operation.followUp
        operation.followUp = false
        refreshOperations[id] = operation
        if followUp { refresh(id) }
        drainRefreshQueue()
    }

    private static func isComplete(_ inspection: ProjectInspection) -> Bool {
        guard inspection.manifest?.schemaVersion == 1,
              inspection.featureEnumeration == .complete,
              inspection.excludedFeaturePaths.isEmpty,
              !inspection.diagnostics.contains(where: { $0.severity == .error }) else { return false }
        if case .failed = inspection.roadmap { return false }
        if case .failed = inspection.context { return false }
        if case .failed = inspection.rules { return false }
        if case .failed = inspection.history { return false }
        return true
    }

    /// Cancel a pending picker/inspection without changing the saved reference. An IO
    /// operation that does not cooperate with cancellation still loses publication rights.
    func cancelReconnect(_ id: UUID) {
        reconnectGenerations[id, default: 0] += 1
    }

    /// A reconnect is an explicit replacement of a grant, not an Add or a rename.
    /// The repository enforces the stored manifest ID and revision again at commit.
    @discardableResult
    func reconnect(_ id: UUID, to folder: URL) async throws -> ProjectReferenceSnapshot {
        guard !reconnecting.contains(id) else { throw ProjectStoreError.busy }
        guard let original = rows.first(where: { $0.reference.id == id })?.reference else {
            throw ProjectStoreError.referenceNotFound
        }
        reconnecting.insert(id)
        let generation = reconnectGenerations[id, default: 0]
        reconnectGenerations[id] = generation
        defer { reconnecting.remove(id) }
        reconnectMessage = nil
        do {
            let selectedIdentity = try await identifier.selected(folder)
            try Task.checkCancellation()
            guard reconnectGenerations[id] == generation else { throw CancellationError() }
            let inspection = try await inspector.inspect(selectedFolder: folder)
            try Task.checkCancellation()
            guard reconnectGenerations[id] == generation else { throw CancellationError() }
            guard ProjectInspector.canAdd(inspection), let manifest = inspection.manifest else {
                throw ProjectStoreError.invalidReconnect
            }
            guard manifest.id == original.manifestID else { throw ProjectStoreError.manifestMismatch }
            let bookmark = try await inspector.makeBookmark(selectedFolder: folder)
            let bookmarkedIdentity = try await identifier.bookmarked(bookmark)
            try Task.checkCancellation()
            guard reconnectGenerations[id] == generation else { throw CancellationError() }
            guard bookmarkedIdentity == selectedIdentity else { throw ProjectStoreError.invalidReconnect }
            // Reentrant refreshes may have advanced the revision while IO was suspended.
            // Never overwrite a newer reference with a grant validated against old state.
            guard let current = rows.first(where: { $0.reference.id == id })?.reference,
                  current.revision == original.revision else { throw ProjectStoreError.projectNotReconnected }
            let receipt: ProjectReferenceSnapshot
            do {
                receipt = try repository.reconnect(id: id, expectedRevision: original.revision,
                    input: ReconnectedProjectReference(manifestID: manifest.id,
                        bookmarkData: bookmark, displayNameHint: manifest.name))
            } catch {
                throw ProjectStoreError.projectNotReconnected
            }
            // No suspension between commit and publication. Old queued work is removed;
            // an in-flight read retains its concurrency slot but cannot publish by revision.
            cancelRefresh(id)
            guard let index = rows.firstIndex(where: { $0.reference.id == id }) else {
                preconditionFailure("Committed project disappeared from the main-actor store")
            }
            rows[index].reference = receipt
            rows[index].inspection = nil
            rows[index].lastReadAt = nil
            rows[index].locationHint = nil
            rows[index].isStale = false
            rows[index].refreshFailure = nil
            reconnectMessage = nil
            refresh(id)
            return receipt
        } catch {
            if !(error is CancellationError) && reconnectGenerations[id] == generation {
                switch error {
                case ProjectStoreError.manifestMismatch: reconnectMessage = "Different project selected"
                case ProjectStoreError.invalidReconnect: reconnectMessage = "Selected project is not valid"
                default: reconnectMessage = "Project not reconnected"
                }
            }
            throw error
        }
    }

    func cancelAdd() {
        previewGeneration += 1
        preview = nil
        addMessage = nil
    }

    @discardableResult
    func previewFolder(_ folder: URL) async throws -> ProjectAddPreview {
        guard !adding else { throw ProjectStoreError.busy }
        previewGeneration += 1
        let generation = previewGeneration
        preview = nil
        addMessage = nil
        do {
            let inspection = try await inspector.inspect(selectedFolder: folder)
            try Task.checkCancellation()
            guard generation == previewGeneration else { throw CancellationError() }
            let value = ProjectAddPreview(folder: folder, inspection: inspection,
                                          canAdd: ProjectInspector.canAdd(inspection))
            preview = value
            return value
        } catch {
            if generation == previewGeneration { preview = nil }
            throw error
        }
    }

    /// Always reinspect, including after a previously eligible preview. A changed or invalid
    /// manifest cannot be saved using an old preview, and a canceled task cannot insert.
    func addPreviewedProject() async throws -> ProjectAddResult {
        guard !adding else { throw ProjectStoreError.busy }
        guard let candidate = preview, candidate.canAdd else { throw ProjectStoreError.invalidPreview }
        adding = true
        defer { adding = false }
        let generation = previewGeneration
        do {
            try enterProjects()
            let inspection = try await inspector.inspect(selectedFolder: candidate.folder)
            try Task.checkCancellation()
            guard generation == previewGeneration else { throw CancellationError() }
            // A changed disk result replaces the preview before eligibility is checked.
            // Never leave an obsolete Add-enabled preview after failed revalidation.
            preview = ProjectAddPreview(folder: candidate.folder, inspection: inspection,
                                        canAdd: ProjectInspector.canAdd(inspection))
            guard ProjectInspector.canAdd(inspection), let manifest = inspection.manifest else {
                throw ProjectStoreError.invalidPreview
            }
            // Resolve identities only while each grant is active. An inaccessible old reference
            // cannot be treated as a match; it remains available for explicit Reconnect later.
            let selectedIdentity = try await identifier.selected(candidate.folder)
            try Task.checkCancellation()
            guard generation == previewGeneration else { throw CancellationError() }
            for row in rows {
                do {
                    let existingIdentity = try await identifier.bookmarked(row.reference.bookmarkData)
                    try Task.checkCancellation()
                    guard generation == previewGeneration else { throw CancellationError() }
                    if existingIdentity == selectedIdentity {
                        selectedID = row.reference.id
                        preview = nil
                        addMessage = nil
                        return .selectedExisting(row.reference.id)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Revoked/stale references have no accessible identity to compare.
                    continue
                }
            }
            let bookmark = try await inspector.makeBookmark(selectedFolder: candidate.folder)
            // The picker URL must still identify the folder that passed revalidation.
            // In particular, a replacement between inspection and bookmark creation
            // must not associate another folder's bookmark with this manifest.
            let bookmarkedIdentity = try await identifier.bookmarked(bookmark)
            try Task.checkCancellation()
            guard generation == previewGeneration, bookmarkedIdentity == selectedIdentity else {
                throw ProjectStoreError.invalidPreview
            }
            let nextOrder = (rows.map(\.reference.displayOrder).max() ?? -1) + 1
            let receipt = try repository.insert(NewProjectReference(id: UUID(), manifestID: manifest.id,
                bookmarkData: bookmark, displayOrder: nextOrder, displayNameHint: manifest.name))
            rows.append(ProjectRowState(reference: receipt, inspection: inspection,
                                        locationHint: candidate.folder.path))
            selectedID = receipt.id
            preview = nil
            addMessage = nil
            return .added(receipt.id)
        } catch {
            // Cancellation/validation is not a persistence success. Keep a valid preview only
            // when it still represents the current selection; the user may reselect/refresh.
            if generation == previewGeneration {
                if error is ProjectInspectionFailure { preview = nil }
                if !(error is CancellationError) { addMessage = "Project not added" }
            }
            throw error
        }
    }
}
