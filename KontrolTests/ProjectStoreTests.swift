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
    var bookmarkCount = 0

    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        inspectionCount += 1
        if inspectionCanceled { throw CancellationError() }
        return inspections.removeFirst()
    }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection { throw CancellationError() }
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

@MainActor
private final class StubRepository: ProjectReferenceRepository {
    var saved: [ProjectReferenceSnapshot] = []
    var fetches = 0
    var inserts = 0
    var failInsert = false
    var failReadSave = false
    var failReconnect = false
    var reconnects = 0
    var successfulReads = 0
    func fetchAll() throws -> [ProjectReferenceSnapshot] { fetches += 1; return saved }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot {
        inserts += 1
        if failInsert { throw ProjectReferencePersistenceError.invalidReference }
        let receipt = ProjectReferenceSnapshot(id: input.id, manifestID: input.manifestID,
            bookmarkData: input.bookmarkData, displayOrder: input.displayOrder,
            displayNameHint: input.displayNameHint, lastSuccessfulReadAt: nil, revision: UUID())
        saved.append(receipt)
        return receipt
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
    func makeBookmark(selectedFolder: URL) async throws -> Data { newBookmark }
    func counts() -> (Int, Int, Int) { (started.count, active, peak) }
    func starts(for data: Data) -> Int { started.filter { $0 == data }.count }
    func release(_ data: Data, result: Result<ProjectInspection, Error>) {
        guard let index = waiting.firstIndex(where: { $0.0 == data }) else { return }
        let continuation = waiting.remove(at: index).1
        continuation.resume(with: result)
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
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ProjectReference>()).count, 1)
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
