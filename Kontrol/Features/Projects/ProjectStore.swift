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

struct ProjectRowState {
    let reference: ProjectReferenceSnapshot
    var inspection: ProjectInspection?
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
    @Published private(set) var loadFailed = false
    private(set) var isLoaded = false

    private let inspector: any ProjectInspecting
    private let repository: any ProjectReferenceRepository
    private let identifier: any ProjectFolderIdentifying
    private var previewGeneration = 0
    private var adding = false

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
        } catch {
            loadFailed = true
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
            guard generation == previewGeneration, ProjectInspector.canAdd(inspection),
                  let manifest = inspection.manifest else { throw ProjectStoreError.invalidPreview }
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
            rows.append(ProjectRowState(reference: receipt, inspection: inspection))
            selectedID = receipt.id
            preview = nil
            addMessage = nil
            return .added(receipt.id)
        } catch {
            // Cancellation/validation is not a persistence success. Keep a valid preview only
            // when it still represents the current selection; the user may reselect/refresh.
            if !(error is CancellationError) && generation == previewGeneration {
                addMessage = "Project not added"
            }
            throw error
        }
    }
}
