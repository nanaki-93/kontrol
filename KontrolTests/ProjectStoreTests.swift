import Foundation
import SwiftData
import XCTest
@testable import Kontrol

private final class StubInspector: ProjectInspecting {
    var inspections: [ProjectInspection] = []
    var bookmark = Data([9])
    var bookmarkFails = false
    var inspectionCanceled = false
    var inspectionCount = 0
    var bookmarkedInspectionCount = 0
    var bookmarkCount = 0

    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        inspectionCount += 1
        if inspectionCanceled { throw CancellationError() }
        return inspections.removeFirst()
    }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        bookmarkedInspectionCount += 1
        throw CancellationError()
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data {
        bookmarkCount += 1
        if bookmarkFails { throw ProjectFolderAccessError.bookmarkCreationFailed }
        return bookmark
    }
}

private struct StubIdentity: ProjectFolderIdentifying {
    let selectedIdentity: ProjectFolderIdentity
    let saved: [Data: ProjectFolderIdentity]
    func selected(_ folder: URL) async throws -> ProjectFolderIdentity { selectedIdentity }
    func bookmarked(_ data: Data) async throws -> ProjectFolderIdentity {
        if data == Data([9]) { return selectedIdentity }
        guard let value = saved[data] else { throw ProjectFolderAccessError.stale }
        return value
    }
}

private final class TrackingIdentity: ProjectFolderIdentifying {
    let selectedIdentity: ProjectFolderIdentity
    let saved: [Data: ProjectFolderIdentity]
    var selections = 0
    var bookmarks: [Data] = []
    var locations: [Data] = []

    init(selectedIdentity: ProjectFolderIdentity, saved: [Data: ProjectFolderIdentity] = [:]) {
        self.selectedIdentity = selectedIdentity
        self.saved = saved
    }
    func selected(_ folder: URL) async throws -> ProjectFolderIdentity {
        selections += 1
        return selectedIdentity
    }
    func bookmarked(_ data: Data) async throws -> ProjectFolderIdentity {
        bookmarks.append(data)
        guard let identity = saved[data] else { throw ProjectFolderAccessError.stale }
        return identity
    }
    func location(bookmarked data: Data) async throws -> String {
        locations.append(data)
        return "Transient location"
    }
}

private final class TrackingWriter: FeatureFileWriting {
    var completions = 0
    var undos = 0
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        completions += 1
        throw FeatureMutationFailure.writeFailed
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        undos += 1
        throw FeatureMutationFailure.writeFailed
    }
}

@MainActor
private final class StubRepository: ProjectReferenceRepository {
    var saved: [ProjectReferenceSnapshot] = []
    var fetches = 0
    var failFetch = false
    var inserts = 0
    var failInsert = false
    var failReadSave = false
    var failReconnect = false
    var reconnects = 0
    var successfulReads = 0
    var readAttempts: [UUID] = []
    func fetchAll() throws -> [ProjectReferenceSnapshot] {
        fetches += 1
        if failFetch { throw ProjectReferencePersistenceError.invalidReference }
        return saved
    }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot {
        inserts += 1
        if failInsert { throw ProjectReferencePersistenceError.invalidReference }
        let receipt = ProjectReferenceSnapshot(id: input.id, manifestID: input.manifestID,
            bookmarkData: input.bookmarkData, displayOrder: input.displayOrder,
            displayNameHint: input.displayNameHint, lastSuccessfulReadAt: nil, revision: UUID())
        saved.append(receipt)
        return receipt
    }
    func remove(id: UUID, expectedRevision: UUID) throws {
        guard let index = saved.firstIndex(where: { $0.id == id }) else {
            throw ProjectReferencePersistenceError.notFound
        }
        guard saved[index].revision == expectedRevision else {
            throw ProjectReferencePersistenceError.staleRevision
        }
        saved.remove(at: index)
    }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot {
        guard let index = saved.firstIndex(where: { $0.id == id }) else {
            throw ProjectReferencePersistenceError.notFound
        }
        let old = saved[index]
        guard old.revision == expectedRevision else { throw ProjectReferencePersistenceError.staleRevision }
        guard old.manifestID == input.manifestID else { throw ProjectReferencePersistenceError.manifestMismatch }
        if failReconnect { throw ProjectReferencePersistenceError.invalidReference }
        reconnects += 1
        let receipt = ProjectReferenceSnapshot(id: id, manifestID: old.manifestID,
            bookmarkData: input.bookmarkData, displayOrder: old.displayOrder,
            displayNameHint: input.displayNameHint, lastSuccessfulReadAt: nil, revision: UUID())
        saved[index] = receipt
        return receipt
    }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID, nameHint: String,
                              readAt: Date) throws -> ProjectReferenceSnapshot {
        readAttempts.append(id)
        guard let index = saved.firstIndex(where: { $0.id == id }) else {
            throw ProjectReferencePersistenceError.notFound
        }
        guard saved[index].revision == expectedRevision else {
            throw ProjectReferencePersistenceError.staleRevision
        }
        if failReadSave { throw ProjectReferencePersistenceError.invalidReference }
        successfulReads += 1
        let old = saved[index]
        let receipt = ProjectReferenceSnapshot(id: old.id, manifestID: old.manifestID,
            bookmarkData: old.bookmarkData, displayOrder: old.displayOrder,
            displayNameHint: nameHint, lastSuccessfulReadAt: readAt, revision: UUID())
        saved[index] = receipt
        return receipt
    }
}

/// Each request remains suspended until explicitly released, making scheduling and late
/// publication observable without a sandbox grant or filesystem timing assumptions.
private actor DeferredInspector: ProjectInspecting {
    let selectedInspection: ProjectInspection?
    let newBookmark: Data
    let waitSelected: Bool
    private var selectedWaiter: CheckedContinuation<ProjectInspection, Error>?
    private var selectedStarts = 0
    private var bookmarkCreations = 0
    init(selectedInspection: ProjectInspection? = nil, newBookmark: Data = Data([9]),
         waitSelected: Bool = false) {
        self.selectedInspection = selectedInspection
        self.newBookmark = newBookmark
        self.waitSelected = waitSelected
    }
    private var waiting: [(Data, CheckedContinuation<ProjectInspection, Error>)] = []
    private var started: [Data] = []
    private var active = 0
    private var peak = 0

    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        selectedStarts += 1
        guard let selectedInspection else { throw CancellationError() }
        if waitSelected {
            return try await withCheckedThrowingContinuation { selectedWaiter = $0 }
        }
        return selectedInspection
    }
    func hasSelectedWaiter() -> Bool { selectedWaiter != nil }
    func releaseSelected() {
        selectedWaiter?.resume(returning: selectedInspection!)
        selectedWaiter = nil
    }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        started.append(bookmarkData)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { waiting.append((bookmarkData, $0)) }
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data {
        bookmarkCreations += 1
        return newBookmark
    }
    func selectedCounts() -> (Int, Int) { (selectedStarts, bookmarkCreations) }
    func counts() -> (Int, Int, Int) { (started.count, active, peak) }
    func starts(for data: Data) -> Int { started.filter { $0 == data }.count }
    func release(_ data: Data, result: Result<ProjectInspection, Error>) {
        guard let index = waiting.firstIndex(where: { $0.0 == data }) else { return }
        let continuation = waiting.remove(at: index).1
        continuation.resume(with: result)
    }
}

private actor DeferredLocation: ProjectFolderIdentifying {
    private var waiting: [(Data, CheckedContinuation<String, Error>)] = []
    private var starts = 0
    func selected(_ folder: URL) async throws -> ProjectFolderIdentity { throw CancellationError() }
    func bookmarked(_ data: Data) async throws -> ProjectFolderIdentity { throw CancellationError() }
    func location(bookmarked data: Data) async throws -> String {
        starts += 1
        return try await withCheckedThrowingContinuation { waiting.append((data, $0)) }
    }
    func count() -> Int { starts }
    func pending() -> Int { waiting.count }
    func release(_ data: Data? = nil) {
        guard let index = waiting.firstIndex(where: { data == nil || $0.0 == data }) else { return }
        waiting.remove(at: index).1.resume(returning: "Obsolete location")
    }
}

private actor ReloadMutationWriter: FeatureFileWriting {
    private var completeWaiter: CheckedContinuation<FeatureMutationReceipt, Error>?
    private var undoWaiter: CheckedContinuation<FeatureMutationReceipt, Error>?
    private var completion: FeatureCompletionRequest?
    private var undoRequest: FeatureUndoRequest?
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        completion = request
        return try await withCheckedThrowingContinuation { completeWaiter = $0 }
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        undoRequest = request
        return try await withCheckedThrowingContinuation { undoWaiter = $0 }
    }
    func isCompleting() -> Bool { completeWaiter != nil }
    func isUndoing() -> Bool { undoWaiter != nil }
    func succeed() {
        let request = completion!
        let saved = ProjectSourceDocument(relativePath: request.source.relativePath,
            bytes: Data(String(decoding: request.source.bytes, as: UTF8.self)
                .replacingOccurrences(of: "status: ready", with: "status: completed").utf8))
        completeWaiter?.resume(returning: FeatureMutationReceipt(projectID: request.reference.id,
            grantBookmarkData: request.reference.bookmarkData, featureID: request.featureID,
            verifiedSource: saved, inverse: FeatureInversePatch(relativePath: saved.relativePath,
                originalSHA256: request.source.sha256, completedSHA256: saved.sha256, edits: [])))
        completeWaiter = nil
    }
    func succeedUndo() {
        let request = undoRequest!
        undoWaiter?.resume(returning: FeatureMutationReceipt(projectID: request.reference.id,
            grantBookmarkData: request.reference.bookmarkData, featureID: request.receipt.featureID,
            verifiedSource: completion!.source, inverse: request.receipt.inverse))
        undoWaiter = nil
    }
}

@MainActor
final class ProjectStoreTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/picked-project", isDirectory: true)
    private let identity = ProjectFolderIdentity(device: 1, inode: 2)

    private func inspection(id: String = "shared", valid: Bool = true) -> ProjectInspection {
        ProjectInspection(manifest: valid ? ProjectManifest(schemaVersion: 1, id: id, name: "Name",
            description: "", stack: [], goals: [], currentFocus: []) : nil,
            roadmap: .absent, features: [], excludedFeaturePaths: [], featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())
    }

    private func feature(_ id: String, title: String = "Original", status: ProjectFeatureStatus = .ready) -> ProjectFeature {
        ProjectFeature(id: id, title: title, status: status, priority: .medium, effort: .small,
            dependsOn: [], areas: [], completedAt: nil, body: "Entire body", sourcePath: ".kontrol/features/\(id).md")
    }

    private func inspectionWithFeatures(_ features: [ProjectFeature], excluded: [String] = [],
                                        diagnostics: [ProjectDiagnostic] = [],
                                        sources: [ProjectSourceDocument] = [],
                                        enumeration: ProjectFeatureEnumeration = .complete) -> ProjectInspection {
        let base = inspection()
        return ProjectInspection(manifest: base.manifest, roadmap: base.roadmap,
            features: features, excludedFeaturePaths: excluded, featureEnumeration: enumeration,
            context: base.context, rules: base.rules, history: base.history,
            diagnostics: diagnostics, sources: sources, readAt: Date())
    }

    private func store(_ inspector: StubInspector, _ repository: StubRepository,
                       saved: [Data: ProjectFolderIdentity] = [:]) -> ProjectStore {
        ProjectStore(inspector: inspector, repository: repository,
            identifier: StubIdentity(selectedIdentity: identity, saved: saved))
    }

    private func reference(_ number: UInt8, lastSuccess: Date? = nil) -> ProjectReferenceSnapshot {
        ProjectReferenceSnapshot(id: UUID(), manifestID: "shared", bookmarkData: Data([number]),
            displayOrder: Int(number), displayNameHint: "Old", lastSuccessfulReadAt: lastSuccess,
            revision: UUID())
    }

    private func eventually(_ condition: @escaping () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for refresh", file: file, line: line)
    }

    func testAppDependencyGraphOwnsLazyStoreAndInjectedBoundaries() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let inspector = StubInspector(), repository = StubRepository()
        let graph = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container),
            projectInspector: inspector, projectRepository: repository,
            projectIdentifier: StubIdentity(selectedIdentity: identity, saved: [:]))
        let store = graph.projectStore
        XCTAssertFalse(store.isLoaded)
        XCTAssertEqual(repository.fetches, 0)
        XCTAssertEqual(inspector.inspectionCount, 0)
        XCTAssertTrue(graph.projectStore === store)
        try store.enterProjects()
        XCTAssertEqual(repository.fetches, 1)
        inspector.inspections = [inspection(), inspection()]
        _ = try await store.previewFolder(folder)
        guard case let .added(id) = try await store.addPreviewedProject() else {
            return XCTFail("Expected committed reference")
        }
        XCTAssertEqual(graph.projectStore.rows.map(\.reference.id), [id])
        XCTAssertEqual(repository.saved.map(\.id), [id])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ProjectReference>()).count, 0,
                       "Injected repository owns the reference boundary; no model crosses into inspector")
    }

    func testDefaultProjectRepositoryUsesAppContainerAndReturnsDetachedRows() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let persisted = try SwiftDataProjectReferenceRepository(container: container).insert(
            NewProjectReference(id: UUID(), manifestID: "shared", bookmarkData: Data([4]),
                displayOrder: 0, displayNameHint: "Saved"))
        let graph = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container),
            projectInspector: StubInspector())
        XCTAssertFalse(graph.projectStore.isLoaded)
        XCTAssertTrue(graph.projectStore.rows.isEmpty)
        try graph.projectStore.enterProjects()
        XCTAssertEqual(graph.projectStore.rows.map(\.reference), [persisted])
        XCTAssertEqual(graph.projectStore.selectedID, persisted.id)
        XCTAssertNil(graph.projectStore.selectedFeature)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ProjectReference>()).count, 1)
    }

    func testSettingsFirstListingAndActivationRemainLocalUntilBoundedProjectsEntry() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let refs = (1...5).map { reference(UInt8($0)) }
        repo.saved = refs
        let identifier = TrackingIdentity(selectedIdentity: identity)
        let writer = TrackingWriter()
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier, writer: writer)
        try subject.loadReferencesIfNeeded()
        try subject.loadReferencesIfNeeded()
        for _ in 0..<10 { subject.refreshOnMainWindowActivation() }
        // Give erroneously admitted Tasks an opportunity to start before checking spies.
        try await Task.sleep(nanoseconds: 20_000_000)
        let localCounts = await io.counts()
        XCTAssertEqual(localCounts.0, 0)
        let selectedCounts = await io.selectedCounts()
        XCTAssertEqual(selectedCounts.0, 0)
        XCTAssertEqual(selectedCounts.1, 0)
        XCTAssertTrue(subject.isLoaded)
        XCTAssertFalse(subject.loadFailed)
        XCTAssertEqual(repo.fetches, 1)
        XCTAssertEqual(subject.rows.map(\.reference), refs)
        XCTAssertTrue(subject.rows.allSatisfy { $0.inspection == nil && !$0.isRefreshing && $0.locationHint == nil })
        XCTAssertEqual(identifier.selections, 0)
        XCTAssertTrue(identifier.bookmarks.isEmpty)
        XCTAssertTrue(identifier.locations.isEmpty)
        XCTAssertEqual(writer.completions + writer.undos, 0)
        XCTAssertEqual(repo.inserts + repo.reconnects + repo.successfulReads, 0)

        subject.select(refs[4].id)
        try subject.enterProjects()
        for _ in 0..<10 { try subject.enterProjects(); try subject.loadReferencesIfNeeded() }
        await eventually { await io.counts().0 == 3 }
        XCTAssertEqual(subject.selectedID, refs[4].id)
        for ref in refs.prefix(3) { await io.release(ref.bookmarkData, result: .success(inspection())) }
        await eventually { await io.counts().0 == 5 }
        for ref in refs.suffix(2) { await io.release(ref.bookmarkData, result: .success(inspection())) }
        await eventually { repo.successfulReads == 5 && subject.rows.allSatisfy { !$0.isRefreshing } }
        try subject.enterProjects()
        try await Task.sleep(nanoseconds: 20_000_000)
        let finalCounts = await io.counts()
        XCTAssertEqual(finalCounts.0, 5, "Reentry must not add initial-read follow-ups")
        XCTAssertEqual(finalCounts.2, 3)
        XCTAssertEqual(Set(identifier.locations), Set(refs.map(\.bookmarkData)))
        XCTAssertEqual(identifier.locations.count, 5)
        XCTAssertTrue(identifier.bookmarks.isEmpty)
        XCTAssertEqual(repo.fetches, 1)
        XCTAssertEqual(writer.completions + writer.undos, 0)
    }

    func testFailedLocalLoadAndProjectsEntryCanRetryWithoutPrematureAdmission() async throws {
        let io = StubInspector(), repo = StubRepository(), ref = reference(1)
        repo.saved = [ref]
        repo.failFetch = true
        let identifier = TrackingIdentity(selectedIdentity: identity), writer = TrackingWriter()
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier, writer: writer)
        XCTAssertThrowsError(try subject.loadReferencesIfNeeded())
        XCTAssertThrowsError(try subject.enterProjects())
        subject.refreshOnMainWindowActivation()
        XCTAssertFalse(subject.isLoaded)
        XCTAssertTrue(subject.loadFailed)
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertNil(subject.selectedID)
        repo.failFetch = false
        try subject.loadReferencesIfNeeded()
        subject.refreshOnMainWindowActivation()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(subject.isLoaded)
        XCTAssertFalse(subject.loadFailed)
        XCTAssertEqual(repo.fetches, 3)
        XCTAssertEqual(io.bookmarkedInspectionCount, 0)
        XCTAssertEqual(subject.rows.map(\.reference), [ref])
        XCTAssertEqual(identifier.selections, 0)
        XCTAssertTrue(identifier.bookmarks.isEmpty)
        XCTAssertTrue(identifier.locations.isEmpty)
        XCTAssertEqual(writer.completions + writer.undos, 0)
        try subject.enterProjects()
        await eventually { io.bookmarkedInspectionCount == 1 && !subject.rows[0].isRefreshing }
        try subject.enterProjects()
        XCTAssertEqual(repo.fetches, 3)
    }

    func testSettingsAddRevalidatesAndAuthorizesWithoutInspectingSavedFoldersOrAdmittingActivation() async throws {
        let io = StubInspector(), repo = StubRepository()
        let existing = reference(1), revoked = reference(2)
        repo.saved = [existing, revoked]
        let identifier = TrackingIdentity(selectedIdentity: identity, saved: [
            existing.bookmarkData: ProjectFolderIdentity(device: 1, inode: 3), Data([9]): identity])
        let writer = TrackingWriter()
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier, writer: writer)
        io.inspections = [inspection(), inspection()]
        // Add itself must load references locally even without a prior Settings listing.
        _ = try await subject.previewFolder(folder)
        guard case let .added(id) = try await subject.addPreviewedProject() else { return XCTFail("Expected Add") }
        for _ in 0..<10 { subject.refreshOnMainWindowActivation() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(repo.fetches, 1)
        XCTAssertEqual(repo.inserts, 1)
        XCTAssertEqual(io.inspectionCount, 2, "Preview and final selected-folder reinspection remain required")
        XCTAssertEqual(io.bookmarkCount, 1)
        XCTAssertEqual(io.bookmarkedInspectionCount, 0)
        XCTAssertEqual(identifier.selections, 1)
        XCTAssertEqual(identifier.bookmarks, [existing.bookmarkData, revoked.bookmarkData, Data([9])])
        XCTAssertTrue(identifier.locations.isEmpty)
        XCTAssertEqual(writer.completions + writer.undos, 0)
        XCTAssertEqual(subject.rows.prefix(2).map(\.reference), [existing, revoked])
        XCTAssertTrue(subject.rows.prefix(2).allSatisfy { $0.inspection == nil && !$0.isRefreshing })
        XCTAssertEqual(subject.selectedID, id)
        XCTAssertEqual(subject.rows.last?.inspection?.manifest?.id, "shared")
        XCTAssertEqual(repo.successfulReads, 0)
        try subject.enterProjects()
        await eventually { io.bookmarkedInspectionCount == 3 && subject.rows.allSatisfy { !$0.isRefreshing } }
        try subject.enterProjects()
        XCTAssertEqual(repo.fetches, 1)
    }

    func testSettingsAddRejectsChangedBookmarkIdentityWithoutAdmittingSavedFolderInspection() async throws {
        let io = StubInspector(), repo = StubRepository(), existing = reference(1)
        repo.saved = [existing]
        let otherIdentity = ProjectFolderIdentity(device: 1, inode: 3)
        let identifier = TrackingIdentity(selectedIdentity: identity,
            saved: [existing.bookmarkData: otherIdentity, Data([9]): otherIdentity])
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier)
        io.inspections = [inspection(), inspection()]
        _ = try await subject.previewFolder(folder)
        do { _ = try await subject.addPreviewedProject(); XCTFail("Changed grant must not insert") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidPreview) }
        subject.refreshOnMainWindowActivation()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(subject.rows.map(\.reference), [existing])
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertEqual(repo.saved, [existing])
        XCTAssertEqual(repo.inserts + repo.successfulReads, 0)
        XCTAssertEqual(io.inspectionCount, 2)
        XCTAssertEqual(io.bookmarkCount, 1)
        XCTAssertEqual(io.bookmarkedInspectionCount, 0)
        XCTAssertEqual(identifier.bookmarks, [existing.bookmarkData, Data([9])])
        XCTAssertTrue(identifier.locations.isEmpty)
    }

    func testSettingsAddDuplicateSelectsExistingWithoutAdmittingInspection() async throws {
        let io = StubInspector(), repo = StubRepository(), existing = reference(1)
        repo.saved = [existing]
        let identifier = TrackingIdentity(selectedIdentity: identity, saved: [existing.bookmarkData: identity])
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier)
        try subject.loadReferencesIfNeeded()
        io.inspections = [inspection(), inspection()]
        _ = try await subject.previewFolder(folder)
        let result = try await subject.addPreviewedProject()
        subject.refreshOnMainWindowActivation()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(result, .selectedExisting(existing.id))
        XCTAssertEqual(subject.selectedID, existing.id)
        XCTAssertEqual(subject.rows.map(\.reference), [existing])
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertEqual(io.inspectionCount, 2)
        XCTAssertEqual(io.bookmarkedInspectionCount, 0)
        XCTAssertEqual(io.bookmarkCount, 0)
        XCTAssertEqual(repo.fetches, 1)
        XCTAssertEqual(repo.inserts + repo.successfulReads, 0)
        XCTAssertEqual(identifier.bookmarks, [existing.bookmarkData])
        XCTAssertTrue(identifier.locations.isEmpty)
    }

    func testReloadBeforeEntryIsLocalOnlyAndFailedReloadRetainsRowsForExplicitRetry() async throws {
        let io = StubInspector(), repo = StubRepository(), first = reference(1), second = reference(2)
        let identifier = TrackingIdentity(selectedIdentity: identity), writer = TrackingWriter()
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier, writer: writer)
        repo.failFetch = true
        XCTAssertThrowsError(try subject.reloadReferences())
        XCTAssertFalse(subject.isLoaded)
        XCTAssertTrue(subject.loadFailed)
        repo.failFetch = false
        repo.saved = [first, second]
        try subject.reloadReferences()
        subject.select(second.id)
        repo.failFetch = true
        XCTAssertThrowsError(try subject.reloadReferences())
        XCTAssertEqual(subject.rows.map(\.reference), [first, second])
        XCTAssertEqual(subject.selectedID, second.id)
        XCTAssertTrue(subject.isLoaded)
        XCTAssertTrue(subject.loadFailed)
        repo.failFetch = false
        repo.saved = [second]
        try subject.reloadReferences()
        XCTAssertEqual(subject.rows.map(\.reference), [second])
        XCTAssertFalse(subject.loadFailed)
        subject.refreshOnMainWindowActivation()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(io.inspectionCount + io.bookmarkedInspectionCount + io.bookmarkCount, 0)
        XCTAssertEqual(identifier.selections, 0)
        XCTAssertTrue(identifier.bookmarks.isEmpty && identifier.locations.isEmpty)
        XCTAssertEqual(writer.completions + writer.undos, 0)
        XCTAssertEqual(repo.inserts + repo.reconnects + repo.successfulReads, 0)
        try subject.enterProjects()
        await eventually { io.bookmarkedInspectionCount == 1 && !subject.rows[0].isRefreshing }
    }

    func testReloadPreservesHealthyStateSelectionAndFailedReviewDoesNotCancelRead() async throws {
        let io = DeferredInspector(), repo = StubRepository(), first = reference(1), second = reference(2)
        let identifier = TrackingIdentity(selectedIdentity: identity)
        repo.saved = [first, second]
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 2 }
        let original = inspectionWithFeatures([feature("F1")])
        await io.release(first.bookmarkData, result: .success(original))
        await io.release(second.bookmarkData, result: .success(original))
        await eventually { repo.successfulReads == 2 }
        subject.selectFeature("F1", in: second.id)
        let before = subject.rows[1]
        repo.saved.reverse()
        try subject.reloadReferences()
        XCTAssertEqual(subject.rows[0].reference, before.reference)
        XCTAssertEqual(subject.rows[0].inspection, before.inspection)
        XCTAssertEqual(subject.rows[0].lastReadAt, before.lastReadAt)
        XCTAssertEqual(subject.rows[0].locationHint, before.locationHint)
        XCTAssertFalse(subject.rows[0].isStale)
        XCTAssertEqual(subject.selectedFeatureContent?.title, "Original")
        XCTAssertEqual(subject.selectedID, second.id)
        XCTAssertEqual(identifier.locations.count, 2)
        subject.refresh(second.id)
        await eventually { await io.counts().0 == 3 }
        repo.failFetch = true
        XCTAssertThrowsError(try subject.reloadReferences())
        XCTAssertTrue(subject.rows[0].isRefreshing)
        let fresh = inspectionWithFeatures([feature("F1", title: "Fresh")])
        await io.release(second.bookmarkData, result: .success(fresh))
        await eventually { repo.successfulReads == 3 }
        XCTAssertEqual(subject.selectedFeatureContent?.title, "Fresh", "Failed review must not cancel usable ongoing work")
        repo.failFetch = false
        try subject.reloadReferences()
        XCTAssertFalse(subject.loadFailed)
        XCTAssertEqual(subject.selectedFeatureContent?.title, "Fresh")
        let counts = await io.counts()
        XCTAssertEqual(counts.0, 3)
    }

    func testReloadChangedAndRemovedRowsClearTransientStateAndChooseOrderedSurvivor() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let refs = (1...3).map { reference(UInt8($0)) }
        repo.saved = refs
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: TrackingIdentity(selectedIdentity: identity))
        try subject.enterProjects()
        await eventually { await io.counts().0 == 3 }
        for ref in refs { await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("F1")]))) }
        await eventually { repo.successfulReads == 3 }
        subject.selectFeature("F1", in: refs[0].id)
        subject.refresh(refs[0].id)
        await eventually { await io.counts().0 == 4 }
        await io.release(refs[0].bookmarkData, result: .success(inspectionWithFeatures([])))
        await eventually { subject.selectionNotice != nil }
        repo.saved.removeFirst()
        try subject.reloadReferences()
        XCTAssertNil(subject.selectionNotice)
        XCTAssertEqual(subject.selectedID, refs[1].id)
        subject.selectFeature("F1", in: refs[1].id)
        let old = repo.saved[0]
        repo.saved[0] = ProjectReferenceSnapshot(id: old.id, manifestID: old.manifestID,
            bookmarkData: Data([99]), displayOrder: old.displayOrder, displayNameHint: "Reconnected",
            lastSuccessfulReadAt: nil, revision: UUID())
        try subject.reloadReferences()
        XCTAssertEqual(subject.selectedID, old.id)
        XCTAssertNil(subject.selectedFeature)
        XCTAssertNil(subject.selectedFeatureContent)
        let reset = subject.rows[0]
        XCTAssertNil(reset.inspection)
        XCTAssertNil(reset.lastReadAt)
        XCTAssertNil(reset.locationHint)
        XCTAssertNil(reset.completion)
        XCTAssertNil(reset.reconnectFeaturePath)
        XCTAssertNil(reset.refreshFailure)
        XCTAssertFalse(reset.isStale || reset.isRetainedInspection || reset.isRefreshing)
        XCTAssertNotNil(subject.rows[1].inspection, "Unchanged peer must stay usable")
        repo.saved = []
        try subject.reloadReferences()
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertNil(subject.selectedID)
        XCTAssertFalse(subject.loadFailed, "A successfully fetched empty list is distinct from failure")
    }

    func testReloadFencesNoncooperativeReadsAndRetainsCapacityUntilOwnersFinish() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let refs = (1...5).map { reference(UInt8($0)) }
        repo.saved = refs
        let identifier = TrackingIdentity(selectedIdentity: identity), writer = TrackingWriter()
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier, writer: writer)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 3 }
        subject.refresh(refs[0].id) // Obsolete follow-up must be dropped.
        subject.refresh(refs[1].id)
        let changed = ProjectReferenceSnapshot(id: refs[0].id, manifestID: "shared",
            bookmarkData: Data([99]), displayOrder: 0, displayNameHint: "Replacement",
            lastSuccessfulReadAt: nil, revision: UUID())
        repo.saved = [changed, refs[2], refs[3]] // Remove running and queued rows.
        try subject.reloadReferences()
        try await Task.sleep(nanoseconds: 20_000_000)
        let occupied = await io.counts()
        XCTAssertEqual(occupied.0, 3)
        XCTAssertEqual(occupied.1, 3, "Reload must not release a noncooperative reader's slot early")
        XCTAssertFalse(subject.rows[0].isRefreshing)
        await io.release(refs[0].bookmarkData, result: .success(inspection()))
        await eventually { await io.counts().0 == 4 }
        await io.release(refs[1].bookmarkData, result: .success(inspection()))
        await eventually { await io.counts().1 == 2 }
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertNil(subject.rows[0].locationHint)
        XCTAssertNil(subject.rows[0].reference.lastSuccessfulReadAt)
        XCTAssertEqual(repo.successfulReads, 0)
        XCTAssertTrue(identifier.locations.isEmpty)
        await io.release(refs[2].bookmarkData, result: .success(inspection()))
        await io.release(refs[3].bookmarkData, result: .success(inspection()))
        await eventually { repo.successfulReads == 2 && subject.rows.allSatisfy { !$0.isRefreshing } }
        let final = await io.counts()
        XCTAssertEqual(final.0, 4)
        XCTAssertEqual(final.2, 3)
        let removedQueuedStarts = await io.starts(for: refs[4].bookmarkData)
        XCTAssertEqual(removedQueuedStarts, 0)
        subject.refresh(changed.id) // Explicit new-grant retry remains possible.
        await eventually { await io.starts(for: changed.bookmarkData) == 1 }
        await io.release(changed.bookmarkData, result: .success(inspection()))
        await eventually { repo.successfulReads == 3 && subject.rows[0].inspection != nil }
        XCTAssertEqual(writer.completions + writer.undos, 0)
    }

    func testReloadFencesDelayedLocationEvenWhenIdentityAndRevisionAreReintroduced() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(1)
        let identifier = DeferredLocation()
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 1 }
        await io.release(ref.bookmarkData, result: .success(inspection()))
        await eventually { await identifier.count() == 1 }
        repo.saved = []
        try subject.reloadReferences()
        repo.saved = [ref] // Same revision alone cannot give the old callback ownership.
        try subject.reloadReferences()
        await identifier.release()
        await eventually { await io.counts().1 == 0 }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(subject.rows.map(\.reference), [ref])
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertNil(subject.rows[0].locationHint)
        XCTAssertNil(subject.rows[0].refreshFailure)
        XCTAssertFalse(subject.rows[0].isStale || subject.rows[0].isRefreshing)
        XCTAssertEqual(repo.successfulReads, 0)
    }

    func testDisconnectSaturatedNoncooperativeReadsRecoverExactlyThreeSlotsAndSurvivorsProgress() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let refs = (1...8).map { reference(UInt8($0)) }
        repo.saved = refs
        let identifier = TrackingIdentity(selectedIdentity: identity), writer = TrackingWriter()
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier, writer: writer)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 3 }
        // Coalesced follow-ups and a waiting removal must not survive disconnect.
        for _ in 0..<5 { subject.refresh(refs[0].id); subject.refresh(refs[1].id) }
        for index in [0, 1, 4] {
            try subject.disconnect(id: refs[index].id, expectedRevision: refs[index].revision)
            subject.refresh(refs[index].id)
            subject.cancelRefresh(refs[index].id)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let held = await io.counts()
        XCTAssertEqual(held.0, 3)
        XCTAssertEqual(held.1, 3, "Disconnected noncooperative owners still occupy their slots")
        XCTAssertTrue(repo.readAttempts.isEmpty)
        await io.release(refs[0].bookmarkData, result: .success(inspection()))
        await eventually { await io.starts(for: refs[3].bookmarkData) == 1 }
        let afterOne = await io.counts()
        XCTAssertEqual(afterOne.0, 4, "One completion releases exactly one slot")
        XCTAssertEqual(afterOne.1, 3)
        await io.release(refs[1].bookmarkData, result: .failure(ProjectInspectionFailure.unreadableFolder))
        await eventually { await io.starts(for: refs[5].bookmarkData) == 1 }
        let afterTwo = await io.counts()
        XCTAssertEqual(afterTwo.0, 5)
        XCTAssertEqual(afterTwo.1, 3)
        let survivors = [refs[2], refs[3], refs[5], refs[6], refs[7]]
        for ref in survivors {
            await eventually { await io.starts(for: ref.bookmarkData) == 1 }
            await io.release(ref.bookmarkData, result: .success(inspection()))
        }
        await eventually { repo.successfulReads == 5 && subject.rows.allSatisfy { !$0.isRefreshing } }
        XCTAssertEqual(Set(repo.readAttempts), Set(survivors.map(\.id)))
        XCTAssertEqual(repo.readAttempts.count, 5, "Removed callbacks cannot even attempt metadata persistence")
        XCTAssertEqual(subject.rows.map(\.reference.id), survivors.map(\.id))
        XCTAssertEqual(identifier.locations.count, 5)
        for ref in [refs[0], refs[1], refs[4]] {
            let starts = await io.starts(for: ref.bookmarkData)
            XCTAssertEqual(starts, ref.id == refs[4].id ? 0 : 1)
        }
        // Re-saturate after all old owners finish: a leak gives <3, a double release >3.
        subject.refreshAll()
        await eventually { await io.counts().0 == 10 }
        let secondWave = await io.counts()
        XCTAssertEqual(secondWave.1, 3)
        XCTAssertEqual(secondWave.2, 3)
        for ref in survivors {
            await eventually { await io.starts(for: ref.bookmarkData) == 2 }
            await io.release(ref.bookmarkData, result: .success(inspection()))
        }
        await eventually { repo.successfulReads == 10 && subject.rows.allSatisfy { !$0.isRefreshing } }
        let finished = await io.counts()
        XCTAssertEqual(finished.0, 12)
        XCTAssertEqual(finished.1, 0)
        XCTAssertEqual(finished.2, 3)
        XCTAssertEqual(writer.completions + writer.undos, 0)
        XCTAssertEqual(identifier.selections, 0)
        XCTAssertTrue(identifier.bookmarks.isEmpty)
    }

    func testDisconnectRetainsSaturatedDelayedLocationSlotsUntilEachOwnerReturns() async throws {
        let io = DeferredInspector(), repo = StubRepository(), identifier = DeferredLocation()
        let refs = (1...5).map { reference(UInt8($0)) }
        repo.saved = refs
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier,
                                   writer: TrackingWriter())
        try subject.enterProjects()
        await eventually { await io.counts().0 == 3 }
        for ref in refs.prefix(3) { await io.release(ref.bookmarkData, result: .success(inspection())) }
        await eventually { await identifier.pending() == 3 }
        for _ in 0..<5 { subject.refresh(refs[0].id) }
        try subject.disconnect(id: refs[0].id, expectedRevision: refs[0].revision)
        try await Task.sleep(nanoseconds: 20_000_000)
        let held = await io.counts()
        XCTAssertEqual(held.0, 3, "Finishing inspection does not free a slot occupied by delayed location")
        let locations = await identifier.pending()
        XCTAssertEqual(locations, 3, "Disconnect cannot interrupt noncooperative location IO")
        XCTAssertTrue(repo.readAttempts.isEmpty)
        await identifier.release(refs[0].bookmarkData)
        await eventually { await io.starts(for: refs[3].bookmarkData) == 1 }
        let oneSlot = await io.counts()
        XCTAssertEqual(oneSlot.0, 4, "A returned location frees one slot, not two")
        XCTAssertTrue(repo.readAttempts.isEmpty)
        XCTAssertEqual(subject.rows.map(\.reference.id), refs.dropFirst().map(\.id))
        await identifier.release(refs[1].bookmarkData)
        await eventually { await io.starts(for: refs[4].bookmarkData) == 1 }
        await identifier.release(refs[2].bookmarkData)
        for ref in refs.suffix(2) { await io.release(ref.bookmarkData, result: .success(inspection())) }
        await eventually { await identifier.count() == 5 }
        for ref in refs.suffix(2) { await identifier.release(ref.bookmarkData) }
        await eventually { repo.successfulReads == 4 && subject.rows.allSatisfy { !$0.isRefreshing } }
        XCTAssertEqual(Set(repo.readAttempts), Set(refs.dropFirst().map(\.id)))
        XCTAssertEqual(repo.readAttempts.count, 4)
        let removedStarts = await io.starts(for: refs[0].bookmarkData)
        XCTAssertEqual(removedStarts, 1, "Removed location callback cannot schedule its old follow-up")
        XCTAssertTrue(subject.rows.allSatisfy { $0.inspection != nil && $0.locationHint != nil })
    }

    func testDisconnectDelayedLocationCannotPublishEvenAfterSameReferenceIsReintroduced() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(1), peer = reference(2)
        let identifier = DeferredLocation(), writer = TrackingWriter()
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo, identifier: identifier, writer: writer)
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("F1")])))
        await eventually { await identifier.count() == 1 }
        subject.refresh(ref.id) // Pending follow-up must be discarded.
        try subject.disconnect(id: ref.id, expectedRevision: ref.revision)
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertNil(subject.selectedID)
        repo.saved = [ref, peer] // Deliberately reuse identity AND revision, not just the folder.
        try subject.reloadReferences()
        subject.refresh(peer.id)
        await eventually { await io.starts(for: peer.bookmarkData) == 1 }
        await identifier.release()
        // Finish the peer through the same delayed-location seam to synchronize publication.
        await io.release(peer.bookmarkData, result: .success(inspection()))
        await eventually { await identifier.count() == 2 }
        await identifier.release()
        await eventually { repo.successfulReads == 1 && !subject.rows[1].isRefreshing }
        XCTAssertEqual(repo.readAttempts, [peer.id])
        XCTAssertEqual(subject.rows[0].reference, ref)
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertNil(subject.rows[0].locationHint)
        XCTAssertNil(subject.rows[0].lastReadAt)
        XCTAssertNil(subject.rows[0].refreshFailure)
        XCTAssertFalse(subject.rows[0].isRefreshing || subject.rows[0].isStale)
        XCTAssertNil(subject.selectedFeatureContent)
        let starts = await io.starts(for: ref.bookmarkData)
        XCTAssertEqual(starts, 1, "No removed-row follow-up can run after reintroduction")
        XCTAssertEqual(writer.completions + writer.undos, 0)
    }

    func testReloadRejectsReconnectAndAddWithoutCancelingOrQueuingWork() async throws {
        let io = DeferredInspector(selectedInspection: inspection(), waitSelected: true), repo = StubRepository()
        let ref = reference(1)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: StubIdentity(selectedIdentity: identity, saved: [Data([9]): identity]))
        try subject.loadReferencesIfNeeded()
        let reconnect = Task { try await subject.reconnect(ref.id, to: folder) }
        await eventually { await io.hasSelectedWaiter() }
        XCTAssertThrowsError(try subject.reloadReferences()) { XCTAssertEqual($0 as? ProjectStoreError, .busy) }
        XCTAssertEqual(repo.fetches, 1)
        await io.releaseSelected()
        _ = try await reconnect.value
        await eventually { await io.counts().0 == 1 }
        await io.release(Data([9]), result: .success(inspection()))
        await eventually { repo.successfulReads == 1 }
        let preview = Task { try await subject.previewFolder(folder) }
        await eventually { await io.hasSelectedWaiter() }
        await io.releaseSelected()
        _ = try await preview.value
        let add = Task { try await subject.addPreviewedProject() }
        await eventually { await io.hasSelectedWaiter() }
        XCTAssertThrowsError(try subject.reloadReferences()) { XCTAssertEqual($0 as? ProjectStoreError, .busy) }
        XCTAssertEqual(repo.fetches, 1)
        await io.releaseSelected()
        let result = try await add.value
        XCTAssertEqual(result, .selectedExisting(ref.id))
        XCTAssertEqual(repo.reconnects, 1)
        XCTAssertEqual(repo.inserts, 0)
        try subject.reloadReferences()
        XCTAssertEqual(repo.fetches, 2, "Busy attempts must not queue an automatic review")
    }

    func testReloadRejectsCompletionUndoAndSavedWriteReconciliationAndPreservesUndoOnUnchangedReview() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(1), writer = ReloadMutationWriter()
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo, writer: writer)
        func snapshot(_ status: String) throws -> ProjectInspection {
            let source = ProjectSourceDocument(relativePath: ".kontrol/features/F1.md", bytes: Data(
                "---\nid: F1\ntitle: F1\nstatus: \(status)\npriority: medium\neffort: small\n---\nBody".utf8))
            guard case let .supported(parsed) = try ManifestParser().feature(source) else {
                throw ProjectStoreError.invalidPreview
            }
            return inspectionWithFeatures([parsed], sources: [source])
        }
        let ready = try snapshot("ready"), completed = try snapshot("completed")
        try subject.enterProjects()
        await eventually { await io.counts().0 == 1 }
        await io.release(ref.bookmarkData, result: .success(ready))
        await eventually { repo.successfulReads == 1 }
        let completion = Task { await subject.markComplete("F1", in: ref.id) }
        await eventually { await writer.isCompleting() }
        XCTAssertThrowsError(try subject.reloadReferences()) { XCTAssertEqual($0 as? ProjectStoreError, .busy) }
        await writer.succeed()
        await eventually { await io.counts().0 == 2 }
        XCTAssertEqual(subject.rows[0].completion, .refreshing("F1"))
        XCTAssertThrowsError(try subject.reloadReferences()) { XCTAssertEqual($0 as? ProjectStoreError, .busy) }
        await io.release(ref.bookmarkData, result: .success(completed))
        await completion.value
        XCTAssertEqual(subject.rows[0].completion, .saved("F1"))
        XCTAssertTrue(subject.canUndoCompletion(in: ref.id))
        try subject.reloadReferences()
        XCTAssertEqual(subject.rows[0].completion, .saved("F1"))
        XCTAssertTrue(subject.canUndoCompletion(in: ref.id))
        let undo = Task { await subject.undoCompletion(in: ref.id) }
        await eventually { await writer.isUndoing() }
        XCTAssertThrowsError(try subject.reloadReferences()) { XCTAssertEqual($0 as? ProjectStoreError, .busy) }
        await writer.succeedUndo()
        await eventually { await io.counts().0 == 3 }
        XCTAssertThrowsError(try subject.reloadReferences()) { XCTAssertEqual($0 as? ProjectStoreError, .busy) }
        await io.release(ref.bookmarkData, result: .success(ready))
        await undo.value
        XCTAssertEqual(subject.rows[0].completion, .undone("F1"))
        XCTAssertEqual(repo.fetches, 2)
        XCTAssertEqual(repo.successfulReads, 3)
        // A grant change also removes an otherwise valid Undo token and completion notice.
        let secondCompletion = Task { await subject.markComplete("F1", in: ref.id) }
        await eventually { await writer.isCompleting() }
        await writer.succeed()
        await eventually { await io.counts().0 == 4 }
        await io.release(ref.bookmarkData, result: .success(completed))
        await secondCompletion.value
        XCTAssertTrue(subject.canUndoCompletion(in: ref.id))
        let old = repo.saved[0]
        repo.saved[0] = ProjectReferenceSnapshot(id: old.id, manifestID: old.manifestID,
            bookmarkData: Data([99]), displayOrder: old.displayOrder, displayNameHint: old.displayNameHint,
            lastSuccessfulReadAt: nil, revision: UUID())
        try subject.reloadReferences()
        XCTAssertFalse(subject.canUndoCompletion(in: ref.id))
        XCTAssertNil(subject.undoExpiration(in: ref.id))
        XCTAssertNil(subject.rows[0].completion)
        XCTAssertNil(subject.rows[0].inspection)
    }

    func testInitialRefreshIsBoundedIndependentAndCoalescesRequests() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let refs = (1...5).map { reference(UInt8($0)) }
        repo.saved = refs
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 3 }
        let initialPeak = await io.counts().2
        XCTAssertEqual(initialPeak, 3)
        XCTAssertEqual(subject.selectedID, refs[0].id)
        for _ in 0..<10 { subject.refresh(refs[0].id); subject.refresh(refs[4].id) }
        let initialStarts = await io.counts().0
        XCTAssertEqual(initialStarts, 3) // Waiting requests merge.
        await io.release(refs[0].bookmarkData, result: .failure(ProjectInspectionFailure.access(.staleBookmark)))
        await eventually { await io.counts().0 == 4 }
        XCTAssertTrue(subject.rows[0].isStale)
        XCTAssertEqual(subject.rows[0].refreshFailure, .inspection(.access(.staleBookmark)))
        // The healthy peer completes even while other grants are suspended.
        await io.release(refs[1].bookmarkData, result: .success(inspection(id: "shared")))
        await eventually { repo.successfulReads == 1 }
        XCTAssertNotNil(subject.rows[1].reference.lastSuccessfulReadAt)
        await eventually { await io.counts().0 == 5 }
        await io.release(refs[2].bookmarkData, result: .success(inspection()))
        await eventually { await io.starts(for: refs[0].bookmarkData) == 2 }
        await io.release(refs[0].bookmarkData, result: .success(inspection()))
        await io.release(refs[3].bookmarkData, result: .success(inspection()))
        await io.release(refs[4].bookmarkData, result: .success(inspection()))
        await eventually { repo.successfulReads == 5 }
        await eventually { await io.counts().1 == 0 }
        let firstStarts = await io.starts(for: refs[0].bookmarkData)
        let lastStarts = await io.starts(for: refs[4].bookmarkData)
        let peak = await io.counts().2
        XCTAssertEqual(firstStarts, 2)
        XCTAssertEqual(lastStarts, 1) // Requests merged while queued, before first read.
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(repo.successfulReads, 5)
        XCTAssertFalse(subject.rows[0].isStale)
    }

    func testEntrySelectsFirstDisplayReferenceAndPreservesExistingSelectionOnReentry() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let first = reference(1), tied = reference(1), later = reference(3)
        repo.saved = [later, tied, first] // A repository need not supply sorted rows.
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        let expected = [first, tied].min { $0.id.uuidString < $1.id.uuidString }!.id
        XCTAssertEqual(subject.selectedID, expected)
        XCTAssertNil(subject.selectedFeature)
        subject.select(later.id)
        try subject.enterProjects()
        XCTAssertEqual(subject.selectedID, later.id)
        XCTAssertEqual(repo.fetches, 1)
        subject.select(UUID())
        XCTAssertEqual(subject.selectedID, later.id)
        await eventually { await io.counts().0 == 3 }
        for ref in [later, tied, first] {
            await io.release(ref.bookmarkData, result: .failure(CancellationError()))
        }
    }

    func testFeatureSelectionIsValidatedProjectScopedAndReadOnly() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let first = reference(1), second = reference(2)
        repo.saved = [first, second]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 2 }
        subject.selectFeature("same", in: first.id) // Not yet inspected.
        XCTAssertNil(subject.selectedFeature)
        let original = inspectionWithFeatures([feature("same"), feature("planned", status: .planned)])
        await io.release(first.bookmarkData, result: .success(original))
        await io.release(second.bookmarkData, result: .success(inspectionWithFeatures([feature("same", title: "Other folder")])))
        await eventually { repo.successfulReads == 2 }
        subject.selectFeature("missing", in: first.id)
        subject.selectFeature("same", in: UUID())
        XCTAssertNil(subject.selectedFeature)
        subject.selectFeature("planned", in: first.id) // Not limited to ready candidates.
        XCTAssertEqual(subject.selectedFeature, ProjectFeatureIdentity(projectID: first.id, featureID: "planned"))
        XCTAssertEqual(subject.selectedFeatureContent?.status, .planned)
        subject.selectFeature("missing", in: second.id)
        XCTAssertEqual(subject.selectedID, first.id)
        XCTAssertEqual(subject.selectedFeatureContent?.title, "Original")
        XCTAssertNil(subject.selectionNotice)
        XCTAssertEqual(subject.rows[0].inspection, original)
        XCTAssertEqual(repo.inserts, 0)
        XCTAssertEqual(repo.reconnects, 0)
        XCTAssertEqual(repo.successfulReads, 2, "Selecting features must not write a read receipt")
        subject.selectFeature("same", in: second.id)
        XCTAssertEqual(subject.selectedID, second.id)
        XCTAssertEqual(subject.selectedFeature, ProjectFeatureIdentity(projectID: second.id, featureID: "same"))
        XCTAssertEqual(subject.selectedFeatureContent?.title, "Other folder")
        subject.select(first.id)
        XCTAssertNil(subject.selectedFeature)
        XCTAssertNil(subject.selectedFeatureContent)
        XCTAssertNil(subject.selectionNotice)
        subject.selectFeature("same", in: first.id)
        try subject.enterProjects()
        XCTAssertEqual(subject.selectedFeature, ProjectFeatureIdentity(projectID: first.id, featureID: "same"))
        subject.closeFeature()
        XCTAssertNil(subject.selectedFeature)
        XCTAssertNil(subject.selectedFeatureContent)
        XCTAssertEqual(subject.selectedID, first.id)
        XCTAssertEqual(subject.rows[0].inspection?.features, original.features)
    }

    func testMainWindowActivationsRefreshLoadedReferencesIndependentlyAndCoalesce() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let first = reference(31), second = reference(32)
        repo.saved = [first, second]
        let subject = ProjectStore(inspector: io, repository: repo)
        // Key events in either window before Projects is entered do not fetch or inspect.
        subject.refreshOnMainWindowActivation()
        subject.refreshOnMainWindowActivation()
        XCTAssertFalse(subject.isLoaded)
        XCTAssertEqual(repo.fetches, 0)
        let beforeLoad = await io.counts()
        XCTAssertEqual(beforeLoad.0, 0)

        try subject.enterProjects()
        await eventually { await io.counts().0 == 2 }
        await io.release(first.bookmarkData, result: .success(inspection()))
        await io.release(second.bookmarkData, result: .success(inspection()))
        await eventually { repo.successfulReads == 2 }
        // Two different main windows can both become key while the reads are pending.
        subject.refreshOnMainWindowActivation()
        await eventually { await io.counts().0 == 4 }
        for _ in 0..<20 { subject.refreshOnMainWindowActivation() }
        let coalesced = await io.counts()
        XCTAssertEqual(coalesced.0, 4)
        await io.release(first.bookmarkData, result: .failure(ProjectInspectionFailure.access(.staleBookmark)))
        await eventually { await io.starts(for: first.bookmarkData) == 3 }
        XCTAssertTrue(subject.rows[0].isStale)
        // One failed grant does not block the other window's healthy project.
        await io.release(second.bookmarkData, result: .success(inspection()))
        await eventually { await io.starts(for: second.bookmarkData) == 3 }
        await io.release(first.bookmarkData, result: .success(inspection()))
        await io.release(second.bookmarkData, result: .success(inspection()))
        await eventually { repo.successfulReads == 5 }
        await eventually { await io.counts().1 == 0 }
        let firstStarts = await io.starts(for: first.bookmarkData)
        let secondStarts = await io.starts(for: second.bookmarkData)
        let peak = await io.counts().2
        XCTAssertEqual(firstStarts, 3)
        XCTAssertEqual(secondStarts, 3)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertFalse(subject.rows[0].isStale)
        XCTAssertEqual(repo.fetches, 1)
        XCTAssertEqual(repo.inserts, 0)
        XCTAssertEqual(repo.reconnects, 0)
    }

    func testPartialAndFailedReadsRetainSuccessTimestampAndStaleSnapshot() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let ref = reference(7)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 1 }
        let good = inspection()
        await io.release(ref.bookmarkData, result: .success(good))
        await eventually { repo.successfulReads == 1 }
        let date = subject.rows[0].reference.lastSuccessfulReadAt
        let partial = ProjectInspection(manifest: good.manifest, roadmap: .absent, features: [],
            excludedFeaturePaths: [".kontrol/features/bad.md"], featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())
        subject.refresh(ref.id)
        await eventually { await io.counts().0 == 2 }
        await io.release(ref.bookmarkData, result: .success(partial))
        await eventually { subject.rows[0].inspection?.readAt == partial.readAt }
        XCTAssertTrue(subject.rows[0].isStale)
        XCTAssertEqual(subject.rows[0].reference.lastSuccessfulReadAt, date)
        XCTAssertEqual(repo.successfulReads, 1)
        subject.refresh(ref.id)
        await eventually { await io.counts().0 == 3 }
        await io.release(ref.bookmarkData, result: .failure(ProjectInspectionFailure.inconsistentRead))
        await eventually { subject.rows[0].refreshFailure == .inspection(.inconsistentRead) }
        XCTAssertEqual(subject.rows[0].inspection?.readAt, partial.readAt)
        XCTAssertEqual(subject.rows[0].lastReadAt, partial.readAt)
        XCTAssertEqual(subject.rows[0].reference.lastSuccessfulReadAt, date)
    }

    func testLatePeerResultNeverChangesSelectedProject() async throws {
        let io = DeferredInspector(selectedInspection: inspection()), repo = StubRepository()
        let first = reference(11), second = reference(12)
        repo.saved = [first, second]
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: StubIdentity(selectedIdentity: identity,
                saved: [first.bookmarkData: identity,
                        second.bookmarkData: ProjectFolderIdentity(device: 1, inode: 3)]))
        try subject.enterProjects()
        await eventually { await io.counts().0 == 2 }
        _ = try await subject.previewFolder(folder)
        let selected = try await subject.addPreviewedProject()
        XCTAssertEqual(selected, .selectedExisting(first.id))
        let peerInspection = inspection(id: "shared")
        await io.release(second.bookmarkData, result: .success(peerInspection))
        await eventually { repo.successfulReads == 1 }
        XCTAssertEqual(subject.selectedID, first.id)
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertEqual(subject.rows[1].inspection?.manifest?.id, "shared")
        await io.release(first.bookmarkData, result: .failure(ProjectInspectionFailure.access(.staleBookmark)))
        await eventually { !subject.rows[0].isRefreshing }
        XCTAssertEqual(subject.selectedID, first.id)
        XCTAssertNil(subject.rows[0].inspection)
    }

    func testCanceledRefreshKeepsLastSnapshotAndFollowUpOwnsFinalResult() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let ref = reference(9)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 1 }
        let original = inspection()
        await io.release(ref.bookmarkData, result: .success(original))
        await eventually { repo.successfulReads == 1 }
        subject.refresh(ref.id)
        await eventually { await io.counts().0 == 2 }
        for _ in 0..<20 { subject.refresh(ref.id) }
        await io.release(ref.bookmarkData, result: .failure(CancellationError()))
        await eventually { await io.counts().0 == 3 }
        XCTAssertEqual(subject.rows[0].inspection?.readAt, original.readAt)
        XCTAssertEqual(repo.successfulReads, 1)
        let newer = inspection()
        await io.release(ref.bookmarkData, result: .success(newer))
        await eventually { repo.successfulReads == 2 }
        XCTAssertEqual(subject.rows[0].inspection?.readAt, newer.readAt)
        XCTAssertFalse(subject.rows[0].isStale)
        let starts = await io.starts(for: ref.bookmarkData)
        XCTAssertEqual(starts, 3)
    }

    func testCanceledNoncooperativeInspectionCannotPublishOrEscapeConcurrencyLimit() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let refs = (20...23).map { reference(UInt8($0)) }
        repo.saved = refs
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 3 }
        subject.refresh(refs[0].id)
        subject.cancelRefresh(refs[0].id)
        let tooLate = inspection()
        // This test double returns success even after its caller was canceled.
        await io.release(refs[0].bookmarkData, result: .success(tooLate))
        await eventually { await io.counts().0 == 4 }
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertNil(subject.rows[0].reference.lastSuccessfulReadAt)
        let starts = await io.starts(for: refs[0].bookmarkData)
        XCTAssertEqual(starts, 1)
        await io.release(refs[1].bookmarkData, result: .failure(CancellationError()))
        await io.release(refs[2].bookmarkData, result: .failure(CancellationError()))
        await io.release(refs[3].bookmarkData, result: .failure(CancellationError()))
        await eventually { await io.counts().1 == 0 }
        let peak = await io.counts().2
        XCTAssertEqual(peak, 3)
    }

    func testChangedManifestIdentityRetainsTrustedSnapshotUntilRepairAndRetry() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let ref = reference(6)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 1 }
        let original = inspection()
        await io.release(ref.bookmarkData, result: .success(original))
        await eventually { repo.successfulReads == 1 }
        let receipt = subject.rows[0].reference
        subject.refresh(ref.id)
        await eventually { await io.counts().0 == 2 }
        await io.release(ref.bookmarkData, result: .success(inspection(id: "different")))
        await eventually { !subject.rows[0].isRefreshing }
        XCTAssertEqual(subject.rows[0].refreshFailure, .manifestMismatch)
        XCTAssertEqual(subject.rows[0].refreshFailure?.recovery, .refresh)
        XCTAssertTrue(subject.rows[0].isStale)
        XCTAssertEqual(subject.rows[0].inspection, original)
        XCTAssertEqual(subject.rows[0].lastReadAt, original.readAt)
        XCTAssertEqual(subject.rows[0].reference, receipt)
        XCTAssertEqual(repo.saved[0], receipt)
        XCTAssertEqual(repo.successfulReads, 1)
        subject.refresh(ref.id)
        await eventually { await io.counts().0 == 3 }
        let repaired = inspection()
        await io.release(ref.bookmarkData, result: .success(repaired))
        await eventually { repo.successfulReads == 2 }
        XCTAssertEqual(subject.rows[0].inspection, repaired)
        XCTAssertFalse(subject.rows[0].isStale)
        XCTAssertNil(subject.rows[0].refreshFailure)
    }

    func testReadReceiptFailureIsPersistenceFailureAndRetryDoesNotClaimFreshSuccessEarly() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let ref = reference(8)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 1 }
        let first = inspection()
        await io.release(ref.bookmarkData, result: .success(first))
        await eventually { repo.successfulReads == 1 }
        let receipt = subject.rows[0].reference
        repo.failReadSave = true
        subject.refresh(ref.id)
        await eventually { await io.counts().0 == 2 }
        await io.release(ref.bookmarkData, result: .success(inspection()))
        await eventually { !subject.rows[0].isRefreshing }
        XCTAssertEqual(subject.rows[0].refreshFailure, .persistence)
        XCTAssertEqual(subject.rows[0].refreshFailure?.recovery, .refresh)
        XCTAssertTrue(subject.rows[0].isStale)
        XCTAssertEqual(subject.rows[0].inspection, first)
        XCTAssertEqual(subject.rows[0].lastReadAt, first.readAt)
        XCTAssertEqual(subject.rows[0].reference, receipt)
        XCTAssertEqual(repo.saved[0], receipt)
        XCTAssertEqual(repo.successfulReads, 1)
        repo.failReadSave = false
        subject.refresh(ref.id)
        await eventually { await io.counts().0 == 3 }
        let retried = inspection()
        await io.release(ref.bookmarkData, result: .success(retried))
        await eventually { repo.successfulReads == 2 }
        XCTAssertEqual(subject.rows[0].inspection, retried)
        XCTAssertFalse(subject.rows[0].isStale)
        XCTAssertNil(subject.rows[0].refreshFailure)
        XCTAssertEqual(subject.rows[0].reference.lastSuccessfulReadAt, retried.readAt)
    }

    func testLazyFetchPreviewAndCommittedAddWithRevalidation() async throws {
        let io = StubInspector(), repo = StubRepository()
        io.inspections = [inspection(), inspection()]
        let subject = store(io, repo)
        XCTAssertFalse(subject.isLoaded)
        XCTAssertEqual(repo.fetches, 0)
        try subject.enterProjects()
        try subject.enterProjects()
        XCTAssertEqual(repo.fetches, 1)
        let firstPreview = try await subject.previewFolder(folder)
        XCTAssertTrue(firstPreview.canAdd)
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertEqual(repo.inserts, 0)
        let result = try await subject.addPreviewedProject()
        guard case let .added(id) = result else { return XCTFail("Expected Add") }
        XCTAssertEqual(subject.selectedID, id)
        XCTAssertEqual(subject.rows.map(\.reference.id), [id])
        XCTAssertEqual(repo.saved.map(\.id), [id])
        XCTAssertEqual(io.inspectionCount, 2)
        XCTAssertEqual(io.bookmarkCount, 1)
    }

    func testCancelInvalidPreviewAndChangedManifestNeverInsert() async throws {
        let io = StubInspector(), repo = StubRepository()
        io.inspections = [inspection(), inspection(valid: false), inspection(valid: false)]
        let subject = store(io, repo)
        _ = try await subject.previewFolder(folder)
        subject.cancelAdd()
        do { _ = try await subject.addPreviewedProject(); XCTFail("Canceled") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidPreview) }
        let invalidPreview = try await subject.previewFolder(folder)
        XCTAssertFalse(invalidPreview.canAdd)
        do { _ = try await subject.addPreviewedProject(); XCTFail("Invalid") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidPreview) }
        io.inspections = [inspection(), inspection(valid: false)]
        _ = try await subject.previewFolder(folder)
        do { _ = try await subject.addPreviewedProject(); XCTFail("Changed") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidPreview) }
        XCTAssertEqual(repo.inserts, 0)
        XCTAssertEqual(io.bookmarkCount, 0)
        XCTAssertEqual(subject.preview?.canAdd, false,
                       "A failed final inspection must disable the old Add preview")
        do { _ = try await subject.addPreviewedProject(); XCTFail("Stale Add") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidPreview) }
        XCTAssertEqual(repo.inserts, 0)
    }

    func testUnsupportedPreviewAndCanceledSelectionAreNotDurable() async throws {
        let io = StubInspector(), repo = StubRepository()
        let unsupported = ProjectInspection(manifest: ProjectManifest(schemaVersion: 2, id: "new",
            name: "Future", description: "", stack: [], goals: [], currentFocus: []),
            roadmap: .absent, features: [], excludedFeaturePaths: [], featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())
        io.inspections = [unsupported]
        let subject = store(io, repo)
        let result = try await subject.previewFolder(folder)
        XCTAssertFalse(result.canAdd)
        do { _ = try await subject.addPreviewedProject(); XCTFail("Unsupported") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidPreview) }
        subject.cancelAdd()
        io.inspectionCanceled = true
        do { _ = try await subject.previewFolder(folder); XCTFail("Canceled selection") }
        catch is CancellationError { }
        XCTAssertNil(subject.preview)
        XCTAssertEqual(repo.fetches, 0)
        XCTAssertEqual(repo.inserts, 0)
        XCTAssertEqual(io.bookmarkCount, 0)
    }

    func testBookmarkAndSaveFailuresNeverPublishRow() async throws {
        let io = StubInspector(), repo = StubRepository()
        io.inspections = [inspection(), inspection(), inspection()]
        io.bookmarkFails = true
        let subject = store(io, repo)
        _ = try await subject.previewFolder(folder)
        do { _ = try await subject.addPreviewedProject(); XCTFail("Bookmark") } catch {}
        XCTAssertEqual(subject.addMessage, "Project not added")
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertEqual(repo.inserts, 0)
        io.bookmarkFails = false
        repo.failInsert = true
        do { _ = try await subject.addPreviewedProject(); XCTFail("Save") } catch {}
        XCTAssertEqual(subject.addMessage, "Project not added")
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertTrue(repo.saved.isEmpty)
    }

    func testReconnectRejectsMismatchInvalidSelectionCancellationAndSaveFailure() async throws {
        let io = StubInspector(), repo = StubRepository()
        let old = reference(1, lastSuccess: Date(timeIntervalSince1970: 100))
        repo.saved = [old]
        let subject = store(io, repo)
        try subject.enterProjects()
        // Initial refresh from this stub is canceled; it must not affect the row.
        io.inspections = [inspection(id: "other"), inspection(valid: false), inspection()]
        do { _ = try await subject.reconnect(old.id, to: folder); XCTFail("Mismatch") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .manifestMismatch) }
        XCTAssertEqual(subject.reconnectMessage, "Different project selected")
        do { _ = try await subject.reconnect(old.id, to: folder); XCTFail("Invalid") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidReconnect) }
        XCTAssertEqual(io.bookmarkCount, 0)
        repo.failReconnect = true
        do { _ = try await subject.reconnect(old.id, to: folder); XCTFail("Save") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .projectNotReconnected) }
        XCTAssertEqual(subject.reconnectMessage, "Project not reconnected")
        XCTAssertEqual(repo.saved, [old])
        XCTAssertEqual(subject.rows[0].reference, old)
        XCTAssertEqual(repo.reconnects, 0)
        XCTAssertEqual(io.bookmarkCount, 1)

        // Unsupported manifests are never accepted as the same V1 identity.
        io.inspections = [ProjectInspection(manifest: ProjectManifest(schemaVersion: 2,
            id: "shared", name: "Future", description: "", stack: [], goals: [], currentFocus: []),
            roadmap: .absent, features: [], excludedFeaturePaths: [], featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())]
        do { _ = try await subject.reconnect(old.id, to: folder); XCTFail("Unsupported") }
        catch { XCTAssertEqual(error as? ProjectStoreError, .invalidReconnect) }
        XCTAssertEqual(io.bookmarkCount, 1)
        XCTAssertEqual(repo.saved, [old])

        // A picker cancellation does not call reconnect or create a bookmark.
        subject.cancelReconnect(old.id)
        XCTAssertEqual(repo.saved, [old])
        XCTAssertEqual(repo.reconnects, 0)
    }

    func testCancelInFlightReconnectCannotReplaceGrantEvenWhenInspectorReturnsSuccess() async throws {
        let io = DeferredInspector(selectedInspection: inspection(), waitSelected: true)
        let repo = StubRepository(), old = reference(2)
        repo.saved = [old]
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: StubIdentity(selectedIdentity: identity, saved: [:]))
        try subject.enterProjects()
        let reconnect = Task { try await subject.reconnect(old.id, to: folder) }
        await eventually { await io.hasSelectedWaiter() }
        subject.cancelReconnect(old.id)
        await io.releaseSelected()
        do { _ = try await reconnect.value; XCTFail("Canceled selection") }
        catch is CancellationError { }
        XCTAssertEqual(repo.saved, [old])
        XCTAssertEqual(subject.rows[0].reference, old)
        XCTAssertEqual(repo.reconnects, 0)
        XCTAssertNil(subject.reconnectMessage)
        await eventually { await io.starts(for: old.bookmarkData) == 1 }
        await io.release(old.bookmarkData, result: .failure(CancellationError()))
    }

    func testReconnectPreservesRowAndDiscardsLateOldRead() async throws {
        let io = DeferredInspector(selectedInspection: inspection(), newBookmark: Data([9]))
        let repo = StubRepository(), old = reference(1)
        repo.saved = [old]
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: StubIdentity(selectedIdentity: identity, saved: [:]))
        try subject.enterProjects()
        await eventually { await io.starts(for: old.bookmarkData) == 1 }
        subject.refresh(old.id) // an old follow-up must not survive reconnect
        let receipt = try await subject.reconnect(old.id, to: folder)
        XCTAssertEqual(repo.reconnects, 1)
        XCTAssertEqual(repo.saved.count, 1)
        XCTAssertEqual(receipt.id, old.id)
        XCTAssertEqual(receipt.displayOrder, old.displayOrder)
        XCTAssertEqual(receipt.manifestID, old.manifestID)
        XCTAssertEqual(receipt.bookmarkData, Data([9]))
        XCTAssertNil(receipt.lastSuccessfulReadAt)
        XCTAssertNotEqual(receipt.revision, old.revision)
        XCTAssertNil(subject.rows[0].inspection)
        await io.release(old.bookmarkData, result: .success(inspection(id: "other")))
        await eventually { await io.starts(for: Data([9])) == 1 }
        XCTAssertNil(subject.rows[0].inspection)
        XCTAssertNil(subject.rows[0].refreshFailure)
        XCTAssertEqual(repo.successfulReads, 0)
        let oldStarts = await io.starts(for: old.bookmarkData)
        XCTAssertEqual(oldStarts, 1)
        await io.release(Data([9]), result: .success(inspection()))
        await eventually { repo.successfulReads == 1 }
        XCTAssertEqual(subject.rows[0].reference.id, old.id)
        XCTAssertEqual(repo.saved.count, 1)
        XCTAssertFalse(subject.rows[0].isStale)
    }

    func testRefreshReconcilesContentAndRankingWithoutClosingDetail() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(40)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("open")])))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("open", in: ref.id)
        let updated = ProjectFeature(id: "open", title: "Updated", status: .active,
            priority: .low, effort: .large, dependsOn: ["done"], areas: ["new"],
            completedAt: nil, body: "Updated full body", sourcePath: ".kontrol/features/open.md")
        let replacement = inspectionWithFeatures([feature("done", status: .completed), updated])
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 2 }
        await io.release(ref.bookmarkData, result: .success(replacement))
        await eventually { subject.rows[0].inspection?.readAt == replacement.readAt }
        XCTAssertEqual(subject.selectedFeature, ProjectFeatureIdentity(projectID: ref.id, featureID: "open"))
        XCTAssertEqual(subject.selectedFeatureContent, updated)
        XCTAssertNil(subject.selectionNotice)
        XCTAssertFalse(subject.rows[0].isRetainedInspection)
        // Leaving the candidate top three solely due to ranking is not deletion either.
        let ranked = inspectionWithFeatures([updated] + (0..<4).map { feature("ready\($0)") })
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 3 }
        await io.release(ref.bookmarkData, result: .success(ranked))
        await eventually { subject.rows[0].inspection?.readAt == ranked.readAt }
        XCTAssertEqual(subject.selectedFeatureContent, updated)
        XCTAssertNil(subject.selectionNotice)
    }

    func testAuthoritativeRemovalAndExclusionHaveDistinctProjectScopedNotices() async throws {
        let io = DeferredInspector(), repo = StubRepository()
        let first = reference(41), peer = reference(42)
        repo.saved = [first, peer]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.counts().0 == 2 }
        let original = inspectionWithFeatures([feature("open")])
        await io.release(first.bookmarkData, result: .success(original))
        await io.release(peer.bookmarkData, result: .success(original))
        await eventually { repo.successfulReads == 2 }
        subject.selectFeature("open", in: first.id)
        // An excluded dependent can mention this deleted ID without making the
        // deleted feature itself an excluded record.
        let removed = inspectionWithFeatures([], excluded: [".kontrol/features/dependent.md"],
            diagnostics: [ProjectDiagnostic(code: .invalidDependency, severity: .error,
                relativePath: ".kontrol/features/dependent.md", affectedIDs: ["dependent", "open"],
                recovery: .editSource)])
        subject.refresh(first.id)
        await eventually { await io.starts(for: first.bookmarkData) == 2 }
        await io.release(first.bookmarkData, result: .success(removed))
        await eventually { subject.rows[0].inspection?.readAt == removed.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice, ProjectFeatureSelectionNotice(projectID: first.id,
            featureID: "open", reason: .removed))
        subject.selectFeature("open", in: peer.id)
        XCTAssertNil(subject.selectionNotice)
        subject.selectFeature("open", in: first.id) // No longer valid; cannot reopen.
        XCTAssertEqual(subject.selectedFeature?.projectID, peer.id)
        let excluded = inspectionWithFeatures([], excluded: [".kontrol/features/open.md"],
            diagnostics: [ProjectDiagnostic(code: .invalidFrontmatter, severity: .error,
                relativePath: ".kontrol/features/open.md", recovery: .editSource)])
        subject.refresh(peer.id)
        await eventually { await io.starts(for: peer.bookmarkData) == 2 }
        await io.release(peer.bookmarkData, result: .success(excluded))
        await eventually { subject.rows[1].inspection?.readAt == excluded.readAt }
        XCTAssertNil(subject.selectedFeatureContent)
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice, ProjectFeatureSelectionNotice(projectID: peer.id,
            featureID: "open", reason: .validationExcluded))
        subject.select(first.id)
        XCTAssertNil(subject.selectionNotice)
    }

    func testDiagnosticIdentifiesMovedExcludedFeatureWithoutInferringFromFilename() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(47)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("open")])))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("open", in: ref.id)
        let moved = ".kontrol/features/renamed.md"
        let excluded = inspectionWithFeatures([], excluded: [moved], diagnostics: [
            ProjectDiagnostic(code: .duplicateID, severity: .error, relativePath: moved,
                affectedIDs: ["open"], recovery: .editSource)])
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 2 }
        await io.release(ref.bookmarkData, result: .success(excluded))
        await eventually { subject.rows[0].inspection?.readAt == excluded.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice?.reason, .validationExcluded)
    }

    func testMovedDependencyExclusionsIdentifyRecordNotSortedTargetID() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(48)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("z-open")])))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("z-open", in: ref.id)

        // The validator sorts affected IDs: the missing target precedes the moved
        // record alphabetically. Reconcile using its diagnostic path and source ID.
        let moved = ".kontrol/features/moved.md"
        let missingRecord = ProjectFeature(id: "z-open", title: "Moved", status: .ready,
            priority: .medium, effort: .small, dependsOn: ["a-missing"], areas: [],
            completedAt: nil, body: "", sourcePath: moved)
        let missing = ProjectValidator().validate([missingRecord])
        XCTAssertEqual(missing.diagnostics.map(\.affectedIDs), [["a-missing", "z-open"]])
        let source = ProjectSourceDocument(relativePath: moved, bytes: Data(
            "---\nid: z-open\ntitle: Moved\nstatus: ready\npriority: medium\neffort: small\ndepends_on: [a-missing]\n---\n".utf8))
        let excluded = inspectionWithFeatures(missing.features, excluded: missing.excludedFeaturePaths,
            diagnostics: missing.diagnostics, sources: [source])
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 2 }
        await io.release(ref.bookmarkData, result: .success(excluded))
        await eventually { subject.rows[0].inspection?.readAt == excluded.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice?.reason, .validationExcluded)

        // Repeat for an invalid target (duplicate ID), including propagation to a
        // moved dependent. The dependent's ID is again last in sorted affectedIDs.
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 3 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("z-open")])))
        await eventually { repo.successfulReads == 2 }
        subject.selectFeature("z-open", in: ref.id)
        let invalidRecord = ProjectFeature(id: "z-open", title: "Moved", status: .ready,
            priority: .medium, effort: .small, dependsOn: ["a-duplicate"], areas: [],
            completedAt: nil, body: "", sourcePath: moved)
        let invalid = ProjectValidator().validate([invalidRecord,
            feature("a-duplicate"), ProjectFeature(id: "a-duplicate", title: "Other", status: .ready,
                priority: .medium, effort: .small, dependsOn: [], areas: [], completedAt: nil,
                body: "", sourcePath: ".kontrol/features/other.md")])
        XCTAssertTrue(invalid.diagnostics.contains { $0.code == .invalidDependency &&
            $0.relativePath == moved && $0.affectedIDs == ["a-duplicate", "z-open"] })
        let invalidInspection = inspectionWithFeatures(invalid.features, excluded: invalid.excludedFeaturePaths,
            diagnostics: invalid.diagnostics, sources: [ProjectSourceDocument(relativePath: moved, bytes: Data(
                "---\nid: z-open\ntitle: Moved\nstatus: ready\npriority: medium\neffort: small\ndepends_on: [a-duplicate]\n---\n".utf8))])
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 4 }
        await io.release(ref.bookmarkData, result: .success(invalidInspection))
        await eventually { subject.rows[0].inspection?.readAt == invalidInspection.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice?.reason, .validationExcluded)
    }

    func testDeletedDependencyTargetIsNotConfusedWithMovedExcludedDependent() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(49)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("a-target")])))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("a-target", in: ref.id)
        let dependentPath = ".kontrol/features/moved-dependent.md"
        let dependent = ProjectFeature(id: "z-dependent", title: "Dependent", status: .ready,
            priority: .medium, effort: .small, dependsOn: ["a-target"], areas: [],
            completedAt: nil, body: "", sourcePath: dependentPath)
        let validated = ProjectValidator().validate([dependent])
        XCTAssertEqual(validated.diagnostics.map(\.affectedIDs), [["a-target", "z-dependent"]])
        let source = ProjectSourceDocument(relativePath: dependentPath, bytes: Data(
            "---\nid: z-dependent\ntitle: Dependent\nstatus: ready\npriority: medium\neffort: small\ndepends_on: [a-target]\n---\n".utf8))
        let deleted = inspectionWithFeatures(validated.features, excluded: validated.excludedFeaturePaths,
            diagnostics: validated.diagnostics, sources: [source])
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 2 }
        await io.release(ref.bookmarkData, result: .success(deleted))
        await eventually { subject.rows[0].inspection?.readAt == deleted.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice?.reason, .removed)
    }

    func testFailedAndCanceledRefreshRetainSelectedDetailAndMarkOldContent() async throws {
        let io = DeferredInspector(), repo = StubRepository(), ref = reference(43)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo)
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        let original = inspectionWithFeatures([feature("open")])
        await io.release(ref.bookmarkData, result: .success(original))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("open", in: ref.id)
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 2 }
        await io.release(ref.bookmarkData, result: .failure(ProjectInspectionFailure.inconsistentRead))
        await eventually { subject.rows[0].refreshFailure == .inspection(.inconsistentRead) }
        XCTAssertEqual(subject.selectedFeatureContent, original.features[0])
        XCTAssertNil(subject.selectionNotice)
        XCTAssertTrue(subject.rows[0].isRetainedInspection)
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 3 }
        subject.cancelRefresh(ref.id)
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([])))
        await eventually { !subject.rows[0].isRefreshing }
        XCTAssertEqual(subject.selectedFeatureContent, original.features[0])
        XCTAssertTrue(subject.rows[0].isRetainedInspection)
        XCTAssertNil(subject.selectionNotice)
        let partial = inspectionWithFeatures([feature("open")], excluded: [".kontrol/features/bad.md"])
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 4 }
        await io.release(ref.bookmarkData, result: .success(partial))
        await eventually { subject.rows[0].inspection?.readAt == partial.readAt }
        XCTAssertTrue(subject.rows[0].isStale)
        XCTAssertFalse(subject.rows[0].isRetainedInspection)
        XCTAssertNil(subject.rows[0].refreshFailure)
        XCTAssertEqual(subject.selectedFeatureContent, partial.features[0])
    }

    func testReconnectPreservesFeatureIdentityUntilReplacementAndRejectsLateOldRead() async throws {
        let replacement = inspectionWithFeatures([feature("open", title: "Reconnected")])
        let io = DeferredInspector(selectedInspection: replacement)
        let repo = StubRepository(), ref = reference(44)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: StubIdentity(selectedIdentity: identity, saved: [:]))
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        let old = inspectionWithFeatures([feature("open")])
        await io.release(ref.bookmarkData, result: .success(old))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("open", in: ref.id)
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 2 }
        _ = try await subject.reconnect(ref.id, to: folder)
        XCTAssertEqual(subject.selectedFeature?.featureID, "open")
        XCTAssertNil(subject.selectedFeatureContent) // No independently cached body.
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([])))
        await eventually { await io.starts(for: Data([9])) == 1 }
        XCTAssertEqual(subject.selectedFeature?.projectID, ref.id)
        XCTAssertNil(subject.selectionNotice)
        await io.release(Data([9]), result: .success(replacement))
        await eventually { repo.successfulReads == 2 }
        XCTAssertEqual(subject.selectedFeatureContent?.title, "Reconnected")
        XCTAssertNil(subject.selectionNotice)
        let oldStarts = await io.starts(for: ref.bookmarkData)
        XCTAssertEqual(oldStarts, 2)
    }

    func testReconnectReplacementExclusionUsesPreviousSourcePath() async throws {
        let path = ".kontrol/features/open.md"
        let invalid = inspectionWithFeatures([], excluded: [path], diagnostics: [
            ProjectDiagnostic(code: .malformedYAML, severity: .error, relativePath: path,
                recovery: .editSource)])
        let io = DeferredInspector(selectedInspection: inspectionWithFeatures([feature("open")]))
        let repo = StubRepository(), ref = reference(45)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: StubIdentity(selectedIdentity: identity, saved: [:]))
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("open")])))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("open", in: ref.id)
        _ = try await subject.reconnect(ref.id, to: folder)
        await eventually { await io.starts(for: Data([9])) == 1 }
        await io.release(Data([9]), result: .success(invalid))
        await eventually { subject.rows[0].inspection?.readAt == invalid.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice?.reason, .validationExcluded)
    }

    func testLatePreReconnectReadAndLaterRefreshCannotReopenClosedDetail() async throws {
        let io = DeferredInspector(selectedInspection: inspectionWithFeatures([feature("open")]))
        let repo = StubRepository(), ref = reference(46)
        repo.saved = [ref]
        let subject = ProjectStore(inspector: io, repository: repo,
            identifier: StubIdentity(selectedIdentity: identity, saved: [:]))
        try subject.enterProjects()
        await eventually { await io.starts(for: ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, result: .success(inspectionWithFeatures([feature("open")])))
        await eventually { repo.successfulReads == 1 }
        subject.selectFeature("open", in: ref.id)
        subject.refresh(ref.id)
        await eventually { await io.starts(for: ref.bookmarkData) == 2 }
        _ = try await subject.reconnect(ref.id, to: folder)
        let late = inspectionWithFeatures([feature("open", title: "Old")])
        await io.release(ref.bookmarkData, result: .success(late))
        await eventually { await io.starts(for: Data([9])) == 1 }
        XCTAssertEqual(subject.selectedFeature?.featureID, "open")
        XCTAssertNil(subject.rows[0].inspection)
        let removed = inspectionWithFeatures([])
        await io.release(Data([9]), result: .success(removed))
        await eventually { subject.rows[0].inspection?.readAt == removed.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice?.reason, .removed)
        subject.refresh(ref.id)
        await eventually { await io.starts(for: Data([9])) == 2 }
        await io.release(Data([9]), result: .success(late))
        await eventually { subject.rows[0].inspection?.readAt == late.readAt }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertEqual(subject.selectionNotice?.reason, .removed)
        XCTAssertEqual(subject.rows[0].inspection, late)
        XCTAssertEqual(repo.successfulReads, 3)
    }

    func testSameFilesystemIdentitySelectsExistingButSameManifestDifferentFolderAdds() async throws {
        let io = StubInspector(), repo = StubRepository()
        let old = ProjectReferenceSnapshot(id: UUID(), manifestID: "shared", bookmarkData: Data([1]),
            displayOrder: 4, displayNameHint: "Old", lastSuccessfulReadAt: nil, revision: UUID())
        repo.saved = [old]
        io.inspections = [inspection(), inspection()]
        let same = store(io, repo, saved: [Data([1]): identity])
        _ = try await same.previewFolder(folder)
        let existing = try await same.addPreviewedProject()
        XCTAssertEqual(existing, .selectedExisting(old.id))
        XCTAssertEqual(io.bookmarkCount, 0)
        XCTAssertEqual(repo.inserts, 0)
        let otherIO = StubInspector()
        otherIO.inspections = [inspection(), inspection()]
        let distinct = store(otherIO, repo, saved: [Data([1]): ProjectFolderIdentity(device: 1, inode: 3)])
        _ = try await distinct.previewFolder(folder)
        guard case .added = try await distinct.addPreviewedProject() else { return XCTFail("Distinct folder") }
        XCTAssertEqual(repo.saved.map(\.manifestID), ["shared", "shared"])
        XCTAssertEqual(repo.saved.map(\.displayOrder), [4, 5])
    }
}
