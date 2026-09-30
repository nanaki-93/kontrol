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

/// Session-only IO outcome. The inspection remains the sole source for status and counts.
enum ProjectCompletionState: Equatable {
    case writing(String)
    case undoing(String)
    case refreshing(String)
    case saved(String)
    case undone(String)
    case undoFailed(String, FeatureMutationFailure)
    case savedButRefreshFailed(String, ProjectRefreshFailure)
    case undoneButRefreshFailed(String, ProjectRefreshFailure)
    case failed(String, FeatureMutationFailure)
}

struct ProjectRowState {
    var reference: ProjectReferenceSnapshot
    var inspection: ProjectInspection?
    var completion: ProjectCompletionState?
    var isRefreshing = false
    var isStale = false
    /// True only when a failed or canceled read kept an older inspection for reference.
    /// A newly accepted partial inspection can also be isStale, but is not retained content.
    var isRetainedInspection = false
    var reconnectFeaturePath: String? // Temporary identity hint while a replacement grant is read.
    var lastReadAt: Date? // Last displayed inspection, distinct from lastSuccessfulReadAt.
    var refreshFailure: ProjectRefreshFailure?
    var locationHint: String? // Transient last-seen location; not a saved authorization path.
}

/// Stable feature IDs are unique only within a saved folder reference.
struct ProjectFeatureIdentity: Equatable {
    let projectID: UUID
    let featureID: String
}

enum ProjectFeatureSelectionNoticeReason: Equatable {
    case removed
    case validationExcluded
}

struct ProjectFeatureSelectionNotice: Equatable {
    let projectID: UUID
    let featureID: String
    let reason: ProjectFeatureSelectionNoticeReason
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
    @Published private(set) var selectedFeature: ProjectFeatureIdentity?
    @Published private(set) var selectionNotice: ProjectFeatureSelectionNotice?
    /// The inspection, not a second feature-content cache, owns the displayed fields.
    var selectedFeatureContent: ProjectFeature? {
        guard let selectedFeature, selectedID == selectedFeature.projectID,
              let inspection = rows.first(where: { $0.reference.id == selectedFeature.projectID })?.inspection else {
            return nil
        }
        return inspection.features.first { $0.id == selectedFeature.featureID }
    }
    @Published private(set) var preview: ProjectAddPreview?
    @Published private(set) var addMessage: String?
    @Published private(set) var reconnectMessage: String?
    private var reconnectMessageProjectID: UUID?
    @Published private(set) var loadFailed = false
    private(set) var isLoaded = false
    private var isInspectionAdmitted = false

    private let inspector: any ProjectInspecting
    private let repository: any ProjectReferenceRepository
    private let identifier: any ProjectFolderIdentifying
    private let writer: any FeatureFileWriting
    private let completionClock: () -> Date
    private let completionValidator: @Sendable (ProjectSourceDocument, ProjectFeature) async -> Bool
    private var mutating: Set<UUID> = []
    private var undoTokens: [UUID: ProjectCompletionUndoToken] = [:]
    private var refreshAfterMutation: Set<UUID> = []
    private struct MutationReconciliation {
        let receipt: FeatureMutationReceipt
        let previous: ProjectInspection?
        let continuation: CheckedContinuation<ProjectRefreshFailure?, Never>
    }
    private var reconciliations: [UUID: MutationReconciliation] = [:]
    private var previewGeneration = 0
    private var adding = false
    private var reconnecting: Set<UUID> = []
    private var reconnectGenerations: [UUID: Int] = [:]
    private struct RefreshOperation {
        var generation = 0
        var task: Task<Void, Never>?
        var followUp = false
        var queued = false
        var publicationInvalidated = false
    }
    private var refreshOperations: [UUID: RefreshOperation] = [:]
    private var refreshQueue: [UUID] = []
    private var activeRefreshes = 0
    private let maxConcurrentRefreshes = 3

    init(inspector: any ProjectInspecting, repository: any ProjectReferenceRepository,
         identifier: any ProjectFolderIdentifying = ScopedProjectFolderIdentifier(),
         writer: any FeatureFileWriting = FeatureFileWriter(),
         completionClock: @escaping () -> Date = Date.init,
         completionValidator: @escaping @Sendable (ProjectSourceDocument, ProjectFeature) async -> Bool = { source, feature in
             await Task.detached(priority: .userInitiated) {
                 guard case let .supported(parsed) = try? ManifestParser().feature(source) else { return false }
                 return parsed == feature
             }.value
         }) {
        self.inspector = inspector
        self.repository = repository
        self.identifier = identifier
        self.writer = writer
        self.completionClock = completionClock
        self.completionValidator = completionValidator
    }

    /// Cheap, synchronous view-facing gate. The exact source is parsed off-main after
    /// claiming the project slot; this predicate alone never authorizes a write.
    func canMarkComplete(_ featureID: String, in projectID: UUID) -> Bool {
        completionInput(featureID, in: projectID) != nil
    }

    private func completionInput(_ featureID: String, in projectID: UUID)
        -> (ProjectReferenceSnapshot, ProjectSourceDocument)? {
        guard !mutating.contains(projectID), !reconnecting.contains(projectID),
              let row = rows.first(where: { $0.reference.id == projectID }),
              !row.isRefreshing, refreshOperations[projectID]?.task == nil,
              refreshOperations[projectID]?.queued != true,
              !row.isRetainedInspection, row.refreshFailure == nil,
              let inspection = row.inspection, let manifest = inspection.manifest,
              manifest.schemaVersion == 1, manifest.id == row.reference.manifestID,
              inspection.featureEnumeration == .complete,
              let feature = inspection.features.first(where: { $0.id == featureID }),
              feature.status != .completed,
              let source = inspection.sources.first(where: { $0.relativePath == feature.sourcePath }),
              inspection.sources.filter({ $0.relativePath == feature.sourcePath }).count == 1 else { return nil }
        return (row.reference, source)
    }

    /// The clock is checked on access as well as activation: no timer or persistent
    /// history can keep an expired action alive across a view switch.
    func undoExpiration(in projectID: UUID) -> Date? {
        guard let token = validUndoToken(in: projectID) else { return nil }
        return token.expiresAt
    }

    /// The latest verified completion target, not the most recent attempted feature.
    /// Keep expiry and grant validation in the same place as the Undo gate.
    func undoFeatureID(in projectID: UUID) -> String? {
        validUndoToken(in: projectID)?.receipt.featureID
    }

    func canUndoCompletion(in projectID: UUID) -> Bool {
        guard validUndoToken(in: projectID) != nil,
              !mutating.contains(projectID), !reconnecting.contains(projectID),
              let row = rows.first(where: { $0.reference.id == projectID }),
              !row.isRefreshing, refreshOperations[projectID]?.task == nil,
              refreshOperations[projectID]?.queued != true,
              !row.isRetainedInspection, row.refreshFailure == nil else { return false }
        return true
    }

    private func validUndoToken(in id: UUID) -> ProjectCompletionUndoToken? {
        guard let token = undoTokens[id] else { return nil }
        guard completionClock() < token.expiresAt,
              let reference = rows.first(where: { $0.reference.id == id })?.reference,
              token.matches(reference) else {
            undoTokens.removeValue(forKey: id)
            return nil
        }
        return token
    }

    /// Claim publication ownership before suspending. A verified IO receipt is not
    /// displayed as progress until the bounded inspector has read the saved revision.
    func markComplete(_ featureID: String, in projectID: UUID) async {
        guard let (reference, source) = completionInput(featureID, in: projectID),
              let index = rows.firstIndex(where: { $0.reference.id == projectID }),
              let feature = rows[index].inspection?.features.first(where: { $0.id == featureID }) else { return }
        mutating.insert(projectID) // Before the first suspension, including validation.
        rows[index].completion = .writing(featureID)
        let request = FeatureCompletionRequest(reference: reference, featureID: featureID,
                                               source: source, completedAt: completionClock())
        do {
            guard await completionValidator(source, feature) else {
                throw FeatureMutationFailure.unpatchableSource
            }
            let receipt = try await writer.complete(request)
            guard receipt.projectID == projectID, receipt.featureID == featureID,
                  receipt.grantBookmarkData == reference.bookmarkData,
                  receipt.relativePath == source.relativePath else {
                throw FeatureMutationFailure.unverifiedWrite
            }
            undoTokens[projectID] = ProjectCompletionUndoToken(receipt: receipt,
                manifestID: reference.manifestID, expiresAt: completionClock().addingTimeInterval(30))
            let previous = rows.first(where: { $0.reference.id == projectID })?.inspection
            if let index = rows.firstIndex(where: { $0.reference.id == projectID }) {
                rows[index].completion = .refreshing(featureID)
                rows[index].isStale = true
                rows[index].isRetainedInspection = previous != nil
            }
            let failure = await reconcileSavedWrite(receipt, previous: previous)
            if let index = rows.firstIndex(where: { $0.reference.id == projectID }) {
                if let failure {
                    // The previous snapshot predates a verified disk write. It cannot
                    // provide an actionable count or detail after failed reconciliation.
                    rows[index].inspection = nil
                    rows[index].lastReadAt = nil
                    rows[index].isStale = true
                    rows[index].isRetainedInspection = false
                    rows[index].refreshFailure = failure
                    rows[index].completion = .savedButRefreshFailed(featureID, failure)
                } else {
                    rows[index].completion = .saved(featureID)
                }
            }
        } catch {
            if let index = rows.firstIndex(where: { $0.reference.id == projectID }) {
                let failure = (error as? FeatureMutationFailure) ?? .writeFailed
                if let token = undoTokens[projectID], token.receipt.featureID == featureID,
                   token.receipt.relativePath == source.relativePath,
                   (Self.isTargetConflict(failure) || failure == .unverifiedWrite) {
                    undoTokens.removeValue(forKey: projectID)
                }
                rows[index].completion = .failed(featureID, failure)
                // A conflict or uncertain replacement invalidates the displayed revision.
                // Require an explicit read before this source becomes actionable again.
                switch failure {
                case .conflict, .missingTarget, .changedIdentity, .manifestMismatch,
                     .unsafePath, .unverifiedWrite:
                    rows[index].isStale = true
                    rows[index].isRetainedInspection = true
                default: break
                }
            }
        }
        mutating.remove(projectID)
        // The reconciliation already consumed all refresh requests made during IO.
        // On a failed write, the coalesced request still needs its own inspection.
        if refreshAfterMutation.remove(projectID) != nil,
           case .failed = rows.first(where: { $0.reference.id == projectID })?.completion {
            refresh(projectID)
        }
    }

    /// Undo is bound to the token's original grant and target, never to selection.
    /// The writer compares the completed digest inside coordinated access before IO.
    func undoCompletion(in projectID: UUID) async {
        guard canUndoCompletion(in: projectID), let token = validUndoToken(in: projectID),
              let index = rows.firstIndex(where: { $0.reference.id == projectID }) else { return }
        let reference = rows[index].reference
        let featureID = token.receipt.featureID
        mutating.insert(projectID)
        rows[index].completion = .undoing(featureID)
        do {
            let receipt = try await writer.undo(FeatureUndoRequest(reference: reference, receipt: token.receipt))
            guard receipt.projectID == projectID, receipt.featureID == featureID,
                  receipt.grantBookmarkData == reference.bookmarkData,
                  receipt.relativePath == token.receipt.relativePath,
                  receipt.verifiedSHA256 == token.receipt.inverse.originalSHA256 else {
                throw FeatureMutationFailure.unverifiedWrite
            }
            undoTokens.removeValue(forKey: projectID)
            let previous = rows.first(where: { $0.reference.id == projectID })?.inspection
            if let index = rows.firstIndex(where: { $0.reference.id == projectID }) {
                rows[index].completion = .refreshing(featureID)
                rows[index].isStale = true
                rows[index].isRetainedInspection = previous != nil
            }
            let failure = await reconcileSavedWrite(receipt, previous: previous)
            if let index = rows.firstIndex(where: { $0.reference.id == projectID }) {
                if let failure {
                    rows[index].inspection = nil
                    rows[index].lastReadAt = nil
                    rows[index].isStale = true
                    rows[index].isRetainedInspection = false
                    rows[index].refreshFailure = failure
                    rows[index].completion = .undoneButRefreshFailed(featureID, failure)
                } else {
                    rows[index].completion = .undone(featureID)
                }
            }
        } catch {
            let failure = (error as? FeatureMutationFailure) ?? .writeFailed
            if Self.isTargetConflict(failure) || failure == .unverifiedWrite {
                undoTokens.removeValue(forKey: projectID)
            }
            if let index = rows.firstIndex(where: { $0.reference.id == projectID }) {
                rows[index].completion = .undoFailed(featureID, failure)
                if Self.isTargetConflict(failure) || failure == .unverifiedWrite {
                    rows[index].isStale = true
                    rows[index].isRetainedInspection = true
                }
            }
        }
        mutating.remove(projectID)
        if refreshAfterMutation.remove(projectID) != nil,
           case .undoFailed = rows.first(where: { $0.reference.id == projectID })?.completion {
            refresh(projectID)
        }
    }

    private static func isTargetConflict(_ failure: FeatureMutationFailure) -> Bool {
        switch failure {
        case .conflict, .undoConflict, .missingTarget, .changedIdentity: return true
        default: return false
        }
    }

    private func reconcileSavedWrite(_ receipt: FeatureMutationReceipt,
                                     previous: ProjectInspection?) async -> ProjectRefreshFailure? {
        await withCheckedContinuation { continuation in
            let id = receipt.projectID
            reconciliations[id] = MutationReconciliation(receipt: receipt, previous: previous,
                                                          continuation: continuation)
            var operation = refreshOperations[id] ?? RefreshOperation()
            // A mutation cannot start during a refresh; still fence any old queued
            // follow-up rather than permitting it to publish before this inspection.
            operation.followUp = false
            if !operation.queued {
                operation.queued = true
                refreshQueue.append(id)
            }
            refreshOperations[id] = operation
            if let index = rows.firstIndex(where: { $0.reference.id == id }) {
                rows[index].isRefreshing = true
            }
            drainRefreshQueue()
        }
    }

    /// Settings may list local references without resolving grants or inspecting folders.
    /// Failed fetches remain retryable and never admit external inspection.
    func loadReferencesIfNeeded() throws {
        guard !isLoaded else { return }
        do {
            rows = try repository.fetchAll().map { ProjectRowState(reference: $0, inspection: nil) }
            isLoaded = true
            loadFailed = false
            selectInitialProjectIfNeeded()
        } catch {
            loadFailed = true
            throw error
        }
    }

    /// Explicit local review. Fetch before touching usable state, and never interfere
    /// with an owner that may be committing a grant or reconciling a saved file write.
    /// Changed references lose all session state; identical survivors keep theirs.
    func reloadReferences() throws {
        guard mutating.isEmpty, reconciliations.isEmpty, reconnecting.isEmpty, !adding else {
            throw ProjectStoreError.busy
        }
        let references: [ProjectReferenceSnapshot]
        do {
            references = try repository.fetchAll()
        } catch {
            loadFailed = true
            throw error
        }
        let unchanged = rows.filter { row in references.contains(row.reference) }
        let invalidated = Set(rows.map(\.reference.id)).subtracting(unchanged.map(\.reference.id))
        for id in invalidated {
            // Keep occupied task/generation bookkeeping until finishRefresh releases
            // its slot. Cancellation alone is not a publication fence for readers
            // that ignore it (or a removed identity subsequently reintroduced).
            if var operation = refreshOperations[id] {
                operation.task?.cancel()
                operation.publicationInvalidated = true
                operation.followUp = false
                operation.queued = false
                if operation.task == nil {
                    refreshOperations.removeValue(forKey: id)
                } else {
                    refreshOperations[id] = operation
                }
            }
            undoTokens.removeValue(forKey: id)
            refreshAfterMutation.remove(id)
            reconnectGenerations.removeValue(forKey: id)
        }
        refreshQueue.removeAll { invalidated.contains($0) }
        rows = references.map { reference in
            unchanged.first(where: { $0.reference.id == reference.id }) ??
                ProjectRowState(reference: reference, inspection: nil)
        }
        if let selectedFeature, invalidated.contains(selectedFeature.projectID) {
            self.selectedFeature = nil
        }
        if let selectionNotice, invalidated.contains(selectionNotice.projectID) {
            self.selectionNotice = nil
        }
        selectInitialProjectIfNeeded()
        isLoaded = true
        loadFailed = false
        // No drain here: passive reload cannot initiate external-folder access.
        // Occupied owners finish normally and drain surviving pre-existing work.
    }

    /// Remove only the confirmed local reference. Admission and durable deletion are
    /// synchronous: no transient state is discarded unless the repository commits.
    /// In-flight reads retain their slots until their existing owners finish.
    func disconnect(id: UUID, expectedRevision: UUID) throws {
        guard let reference = rows.first(where: { $0.reference.id == id })?.reference else {
            throw ProjectReferencePersistenceError.notFound
        }
        guard reference.revision == expectedRevision else {
            throw ProjectReferencePersistenceError.staleRevision
        }
        guard !mutating.contains(id), reconciliations[id] == nil, !reconnecting.contains(id) else {
            throw ProjectStoreError.busy
        }
        try repository.remove(id: id, expectedRevision: expectedRevision)

        if var operation = refreshOperations[id] {
            operation.task?.cancel()
            operation.publicationInvalidated = true
            operation.followUp = false
            operation.queued = false
            if operation.task == nil {
                refreshOperations.removeValue(forKey: id)
            } else {
                refreshOperations[id] = operation
            }
        }
        refreshQueue.removeAll { $0 == id }
        refreshAfterMutation.remove(id)
        undoTokens.removeValue(forKey: id)
        reconnectGenerations.removeValue(forKey: id)
        if reconnectMessageProjectID == id {
            reconnectMessage = nil
            reconnectMessageProjectID = nil
        }
        rows.removeAll { $0.reference.id == id }
        if selectedFeature?.projectID == id { selectedFeature = nil }
        if selectionNotice?.projectID == id { selectionNotice = nil }
        selectInitialProjectIfNeeded()
        // No queue drain or inspection admission: disconnect is local-only. Occupied
        // readers finish normally and drain any surviving pre-existing requests.
    }

    /// Projects entry, not local-reference readiness, admits bounded initial inspection.
    func enterProjects() throws {
        try loadReferencesIfNeeded()
        selectInitialProjectIfNeeded()
        guard !isInspectionAdmitted else { return }
        isInspectionAdmitted = true
        refreshAll()
    }

    /// Requests for a waiting row merge; a running row gets just one follow-up.
    /// A failure in one row never prevents other queued rows from starting.
    func refreshAll() {
        for row in rows { refresh(row.reference.id) }
    }

    /// Main-window key events can occur before Projects is opened or from either
    /// main window. Never fetch references on activation; use the same bounded,
    /// per-row queue as manual and initial refresh only after Projects entry.
    func refreshOnMainWindowActivation() {
        guard isInspectionAdmitted else { return }
        refreshAll()
    }

    private func selectInitialProjectIfNeeded() {
        if let selectedID, rows.contains(where: { $0.reference.id == selectedID }) { return }
        let first = rows.map(\.reference).min {
            if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        selectedID = first?.id
    }

    func select(_ id: UUID) {
        guard rows.contains(where: { $0.reference.id == id }) else { return }
        if selectedID != id {
            selectedFeature = nil
            selectionNotice = nil
        }
        selectedID = id
    }

    /// Accept only validated records in the current inspection, including non-candidates.
    /// Invalid requests leave the current project and detail untouched.
    func selectFeature(_ featureID: String, in projectID: UUID) {
        guard let row = rows.first(where: { $0.reference.id == projectID }),
              let inspection = row.inspection, inspection.manifest?.schemaVersion == 1,
              inspection.featureEnumeration == .complete,
              inspection.features.contains(where: { $0.id == featureID }) else { return }
        select(projectID)
        selectedFeature = ProjectFeatureIdentity(projectID: projectID, featureID: featureID)
        selectionNotice = nil
    }

    func closeFeature() {
        selectedFeature = nil
        selectionNotice = nil
    }

    func refresh(_ id: UUID) {
        guard rows.contains(where: { $0.reference.id == id }) else { return }
        if mutating.contains(id) {
            // Never launch a read against the in-flight replacement.
            refreshAfterMutation.insert(id)
            return
        }
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
        // A caller's canceled read must not cancel verification of a saved write.
        guard !mutating.contains(id), var operation = refreshOperations[id] else { return }
        operation.task?.cancel()
        operation.followUp = false
        if operation.queued {
            refreshQueue.removeAll { $0 == id }
            operation.queued = false
        }
        refreshOperations[id] = operation
        if operation.task == nil, let index = rows.firstIndex(where: { $0.reference.id == id }) {
            rows[index].isRefreshing = false
            if rows[index].inspection != nil {
                rows[index].isStale = true
                rows[index].isRetainedInspection = true
            }
        }
    }

    private func drainRefreshQueue() {
        while activeRefreshes < maxConcurrentRefreshes && !refreshQueue.isEmpty {
            let id = refreshQueue.removeFirst()
            guard let index = rows.firstIndex(where: { $0.reference.id == id }),
                  var operation = refreshOperations[id], operation.queued else { continue }
            operation.queued = false
            operation.generation += 1
            operation.publicationInvalidated = false
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
                                   generation: generation, result: result, location: location,
                                   canceled: Task.isCancelled)
            }
            refreshOperations[id] = operation
        }
    }

    private func finishRefresh(id: UUID, revision: UUID, generation: Int,
                               result: Result<ProjectInspection, Error>, location: String?, canceled: Bool) {
        guard var operation = refreshOperations[id], operation.generation == generation,
              operation.task != nil else { return }
        operation.task = nil
        activeRefreshes -= 1
        let reconciliation = reconciliations.removeValue(forKey: id)
        var reconciliationFailure: ProjectRefreshFailure?
        var didPublish = false
        // A replaced bookmark, canceled task, or removed row owns no publication rights.
        if !operation.publicationInvalidated,
           let index = rows.firstIndex(where: { $0.reference.id == id }),
           rows[index].reference.revision == revision,
           (!mutating.contains(id) || reconciliation != nil) {
            didPublish = true
            let priorInspection = reconciliation?.previous ?? rows[index].inspection
            let acceptedResult: Result<ProjectInspection, Error>
            if canceled {
                acceptedResult = .failure(CancellationError())
            } else if let reconciliation, case let .success(inspection) = result,
                      !Self.matchesSavedWrite(inspection, receipt: reconciliation.receipt,
                                              manifestID: rows[index].reference.manifestID) {
                acceptedResult = .failure(ProjectInspectionFailure.inconsistentRead)
            } else {
                acceptedResult = result
            }
            switch acceptedResult {
            case let .success(inspection):
                if let location, !location.isEmpty { rows[index].locationHint = location }
                // A bookmark can still resolve after the selected folder's manifest was
                // replaced. Never publish content belonging to a different project ID.
                if let manifest = inspection.manifest, manifest.id != rows[index].reference.manifestID {
                    retainInspection(at: index)
                    rows[index].refreshFailure = .manifestMismatch
                    reconciliationFailure = .manifestMismatch
                } else if Self.isComplete(inspection), let manifest = inspection.manifest {
                    do {
                        let receipt = try repository.recordSuccessfulRead(id: id,
                            expectedRevision: revision, nameHint: manifest.name, readAt: inspection.readAt)
                        rows[index].reference = receipt
                        invalidateUndoIfTargetChanged(in: inspection, projectID: id)
                        rows[index].inspection = inspection
                        rows[index].lastReadAt = inspection.readAt
                        rows[index].isStale = false
                        rows[index].isRetainedInspection = false
                        rows[index].refreshFailure = nil
                        reconcileFeature(in: inspection, projectID: id, previous: priorInspection)
                        rows[index].reconnectFeaturePath = nil
                    } catch {
                        // Do not claim a fresh successful read when its durable receipt failed.
                        retainInspection(at: index)
                        rows[index].refreshFailure = .persistence
                        reconciliationFailure = .persistence
                    }
                } else {
                    let previous = rows[index].inspection
                    invalidateUndoIfTargetChanged(in: inspection, projectID: id)
                    rows[index].inspection = inspection
                    rows[index].lastReadAt = inspection.readAt
                    rows[index].isStale = true
                    rows[index].isRetainedInspection = false
                    rows[index].refreshFailure = nil
                    reconcileFeature(in: inspection, projectID: id, previous: reconciliation?.previous ?? previous)
                    if inspection.manifest?.schemaVersion == 1,
                       inspection.featureEnumeration == .complete {
                        rows[index].reconnectFeaturePath = nil
                    }
                }
            case let .failure(error):
                retainInspection(at: index)
                if !(error is CancellationError) {
                    rows[index].refreshFailure = .inspection((error as? ProjectInspectionFailure) ?? .unreadableFolder)
                }
                reconciliationFailure = rows[index].refreshFailure ?? .inspection(.inconsistentRead)
            }
            rows[index].isRefreshing = operation.followUp
        }
        if !didPublish, reconciliation != nil {
            reconciliationFailure = .inspection(.inconsistentRead)
            if let index = rows.firstIndex(where: { $0.reference.id == id }) {
                rows[index].isRefreshing = false
            }
        }
        let followUp = operation.followUp && reconciliation == nil
        operation.followUp = false
        refreshOperations[id] = operation
        reconciliation?.continuation.resume(returning: reconciliationFailure)
        if followUp { refresh(id) }
        drainRefreshQueue()
    }

    /// Only a published read can invalidate a token. Neither failed enumeration nor
    /// a failed read of this path proves removal. A different readable source does
    /// prove a conflict, even when validation excludes that source.
    private func invalidateUndoIfTargetChanged(in inspection: ProjectInspection, projectID: UUID) {
        guard let token = undoTokens[projectID] else { return }
        let sources = inspection.sources.filter { $0.relativePath == token.receipt.relativePath }
        let targetReadFailed = inspection.diagnostics.contains {
            $0.relativePath == token.receipt.relativePath && $0.severity == .error
        } || inspection.excludedFeaturePaths.contains(token.receipt.relativePath)
        if sources.contains(where: { $0.sha256 != token.receipt.verifiedSHA256 }) ||
            (sources.isEmpty && inspection.featureEnumeration == .complete && !targetReadFailed) {
            undoTokens.removeValue(forKey: projectID)
        }
    }

    private static func matchesSavedWrite(_ inspection: ProjectInspection,
                                          receipt: FeatureMutationReceipt, manifestID: String) -> Bool {
        guard inspection.manifest?.id == manifestID,
              inspection.manifest?.schemaVersion == 1,
              inspection.featureEnumeration == .complete,
              inspection.sources.contains(where: { $0 == receipt.verifiedSource }),
              case let .supported(expected) = try? ManifestParser().feature(receipt.verifiedSource),
              inspection.features.contains(where: { $0 == expected && $0.id == receipt.featureID &&
                  $0.sourcePath == receipt.relativePath }) else { return false }
        return true
    }

    private func retainInspection(at index: Int) {
        rows[index].isStale = true
        rows[index].isRetainedInspection = rows[index].inspection != nil
    }

    /// Only a completed V1 enumeration can establish that a previously valid ID is gone.
    /// The old source path catches parse/read failures without assuming filenames are IDs.
    /// For moved sources, validator diagnostics identify the excluded record's path.
    /// Dependency diagnostics sort both record and target IDs, so affectedIDs alone
    /// cannot identify which one belongs to that path (or prove a deleted target moved).
    private func reconcileFeature(in inspection: ProjectInspection, projectID: UUID,
                                  previous: ProjectInspection?) {
        guard selectedFeature?.projectID == projectID, let featureID = selectedFeature?.featureID,
              inspection.manifest?.schemaVersion == 1,
              inspection.featureEnumeration == .complete,
              !inspection.features.contains(where: { $0.id == featureID }) else { return }
        let path = previous?.features.first(where: { $0.id == featureID })?.sourcePath ??
            rows.first(where: { $0.reference.id == projectID })?.reconnectFeaturePath
        let excluded = Set(inspection.excludedFeaturePaths)
        let invalid = (path.map { excluded.contains($0) } ?? false) || inspection.diagnostics.contains { diagnostic in
            guard excluded.contains(diagnostic.relativePath), diagnostic.affectedIDs.contains(featureID) else { return false }
            switch diagnostic.code {
            case .duplicateID, .selfDependency, .cyclicDependency:
                return true
            case .missingDependency, .invalidDependency:
                guard let source = inspection.sources.first(where: { $0.relativePath == diagnostic.relativePath }) else {
                    return false
                }
                guard case let .supported(record) = try? ManifestParser().feature(source) else { return false }
                return record.id == featureID
            default:
                return false
            }
        }
        selectedFeature = nil
        selectionNotice = ProjectFeatureSelectionNotice(projectID: projectID, featureID: featureID,
            reason: invalid ? .validationExcluded : .removed)
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
        guard !reconnecting.contains(id), !mutating.contains(id) else { throw ProjectStoreError.busy }
        guard let original = rows.first(where: { $0.reference.id == id })?.reference else {
            throw ProjectStoreError.referenceNotFound
        }
        reconnecting.insert(id)
        let generation = reconnectGenerations[id, default: 0]
        reconnectGenerations[id] = generation
        defer { reconnecting.remove(id) }
        reconnectMessage = nil
        reconnectMessageProjectID = nil
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
            rows[index].reconnectFeaturePath = rows[index].inspection?.features.first {
                $0.id == selectedFeature?.featureID && selectedFeature?.projectID == id
            }?.sourcePath
            undoTokens.removeValue(forKey: id)
            rows[index].reference = receipt
            rows[index].inspection = nil
            rows[index].lastReadAt = nil
            rows[index].locationHint = nil
            rows[index].isStale = false
            rows[index].isRetainedInspection = false
            rows[index].refreshFailure = nil
            reconnectMessage = nil
            reconnectMessageProjectID = nil
            refresh(id)
            return receipt
        } catch {
            if !(error is CancellationError) && reconnectGenerations[id] == generation {
                reconnectMessageProjectID = id
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
            try loadReferencesIfNeeded()
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
                        select(row.reference.id)
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
            select(receipt.id)
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
