import Foundation
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
        throw ProjectReferencePersistenceError.notFound
    }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID, nameHint: String,
                              readAt: Date) throws -> ProjectReferenceSnapshot {
        throw ProjectReferencePersistenceError.notFound
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
