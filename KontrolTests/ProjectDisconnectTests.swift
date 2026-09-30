import Foundation
import SwiftData
import XCTest
@testable import Kontrol

/// Any external access is counted; selected inspection can be held for reconnect admission.
private actor DisconnectIO: ProjectInspecting, ProjectFolderIdentifying, FeatureFileWriting {
    private var calls: [String] = []
    private var reads: [(Data, CheckedContinuation<ProjectInspection, Error>)] = []
    private var selectedRead: CheckedContinuation<ProjectInspection, Error>?
    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        calls.append("selected inspection")
        return try await withCheckedThrowingContinuation { selectedRead = $0 }
    }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        calls.append("bookmark inspection")
        return try await withCheckedThrowingContinuation { reads.append((bookmarkData, $0)) }
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data {
        calls.append("bookmark creation")
        throw ProjectStoreError.invalidReconnect
    }
    func selected(_ folder: URL) async throws -> ProjectFolderIdentity {
        calls.append("selected identity")
        return ProjectFolderIdentity(device: 1, inode: 1)
    }
    func bookmarked(_ data: Data) async throws -> ProjectFolderIdentity {
        calls.append("bookmark identity")
        throw ProjectFolderAccessError.unresolved
    }
    func location(bookmarked data: Data) async throws -> String {
        calls.append("location")
        return "Transient location"
    }
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        calls.append("complete")
        throw FeatureMutationFailure.writeFailed
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        calls.append("undo")
        throw FeatureMutationFailure.writeFailed
    }
    func history() -> [String] { calls }
    func hasSelectedRead() -> Bool { selectedRead != nil }
    func failSelectedRead(_ failure: Error = CancellationError()) {
        selectedRead?.resume(throwing: failure); selectedRead = nil
    }
    func count(_ data: Data) -> Int { reads.filter { $0.0 == data }.count }
    func release(_ data: Data, _ result: Result<ProjectInspection, Error>) {
        guard let index = reads.firstIndex(where: { $0.0 == data }) else { return }
        reads.remove(at: index).1.resume(with: result)
    }
}

@MainActor
final class ProjectDisconnectTests: XCTestCase {
    private enum SaveFailure: Error { case injected }

    private func diskURL() -> URL {
        // Core Data workers may outlive a test. Cleanup only after the host exits.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolProjectDisconnectTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        print("Project disconnect test store cleanup after host exit: \(root.path)")
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("Kontrol.store")
    }

    private func input(_ n: UInt8, order: Int = 0, id: UUID = UUID()) -> NewProjectReference {
        NewProjectReference(id: id, manifestID: "sample", bookmarkData: Data([n]),
                            displayOrder: order, displayNameHint: "Folder \(n)")
    }

    private func store(_ repo: any ProjectReferenceRepository, _ io: DisconnectIO) -> ProjectStore {
        ProjectStore(inspector: io, repository: repo, identifier: io, writer: io)
    }

    private func inspection(_ includeFeature: Bool = true) throws -> ProjectInspection {
        let source = ProjectSourceDocument(relativePath: ".kontrol/features/F1.md",
            bytes: Data("---\nid: F1\ntitle: First\nstatus: ready\npriority: medium\neffort: small\n---\nExact body".utf8))
        guard case let .supported(feature) = try ManifestParser().feature(source) else {
            throw ProjectStoreError.invalidPreview
        }
        return ProjectInspection(manifest: ProjectManifest(schemaVersion: 1, id: "sample", name: "Sample",
            description: "", stack: [], goals: [], currentFocus: []), roadmap: .absent,
            features: includeFeature ? [feature] : [], excludedFeaturePaths: [], featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [],
            sources: includeFeature ? [source] : [], readAt: Date())
    }

    private func eventually(_ condition: @escaping () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for operation", file: file, line: line)
    }

    func testLocalOnlyDisconnectCommitsBeforePublicationAndReopensWithSurvivors() async throws {
        let url = diskURL(), io = DisconnectIO()
        let survivors = try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let repo = SwiftDataProjectReferenceRepository(container: container)
            let first = try repo.insert(input(1, order: 0))
            let removed = try repo.insert(input(2, order: 1)) // Deliberately unusable opaque bookmark.
            let last = try repo.insert(input(3, order: 2))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(try TaskItem(id: UUID(), title: "Unrelated task", createdAt: Date()))
            try context.save()
            var subject: ProjectStore!
            var commits = 0
            let removing = SwiftDataProjectReferenceRepository(container: container, beforeSave: {
                commits += 1
                XCTAssertEqual(subject.rows.map(\.reference), [first, removed, last])
                XCTAssertEqual(subject.selectedID, removed.id, "Publication must wait for durable commit")
            })
            subject = store(removing, io)
            try subject.loadReferencesIfNeeded()
            subject.select(removed.id)
            try subject.disconnect(id: removed.id, expectedRevision: removed.revision)
            XCTAssertEqual(commits, 1)
            XCTAssertEqual(subject.rows.map(\.reference), [first, last])
            XCTAssertEqual(subject.selectedID, first.id)
            XCTAssertNil(subject.selectedFeature)
            XCTAssertNil(subject.selectionNotice)
            XCTAssertEqual(try repo.fetchAll(), [first, last])
            XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).map(\.title), ["Unrelated task"])
            for _ in 0..<5 { subject.refreshOnMainWindowActivation() }
            XCTAssertThrowsError(try subject.disconnect(id: removed.id, expectedRevision: removed.revision)) {
                XCTAssertEqual($0 as? ProjectReferencePersistenceError, .notFound)
            }
            XCTAssertEqual(commits, 1, "No automatic retry or repeated deletion")
            return [first, last]
        }
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
        let subject = store(SwiftDataProjectReferenceRepository(container: reopened), io)
        try subject.loadReferencesIfNeeded()
        XCTAssertEqual(subject.rows.map(\.reference), survivors)
        XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>()).map(\.title), ["Unrelated task"])
        let calls = await io.history()
        XCTAssertEqual(calls, [], "Disconnect/listing/reopen cannot inspect, identify, resolve, locate, or write")
    }

    func testSelectedRemovalUsesDisplayOrderThenUUIDAndLastRemovalClearsSelection() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataProjectReferenceRepository(container: container), io = DisconnectIO()
        let high = try repo.insert(input(1, order: 2))
        let tieLast = try repo.insert(input(2, order: 1,
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!))
        let tieFirst = try repo.insert(input(3, order: 1,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        let subject = store(repo, io)
        try subject.loadReferencesIfNeeded()
        subject.select(high.id)
        for (removed, next) in [(high, Optional(tieFirst.id)), (tieFirst, Optional(tieLast.id)), (tieLast, nil)] {
            try subject.disconnect(id: removed.id, expectedRevision: removed.revision)
            XCTAssertEqual(subject.selectedID, next)
        }
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertNil(subject.selectedFeatureContent)
        let calls = await io.history()
        XCTAssertEqual(calls, [])
    }

    func testRemovalPreservesUnrelatedInspectedSelectionDetailAndLocation() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataProjectReferenceRepository(container: container), io = DisconnectIO()
        let removed = try repo.insert(input(1)), survivor = try repo.insert(input(2, order: 1))
        let subject = store(repo, io)
        try subject.enterProjects()
        await eventually { await io.count(survivor.bookmarkData) == 1 }
        await io.release(removed.bookmarkData, .success(try inspection()))
        await io.release(survivor.bookmarkData, .success(try inspection()))
        await eventually { subject.rows.allSatisfy { !$0.isRefreshing } }
        subject.selectFeature("F1", in: survivor.id)
        let row = subject.rows[1], detail = subject.selectedFeatureContent
        let before = await io.history()
        try subject.disconnect(id: removed.id, expectedRevision: subject.rows[0].reference.revision)
        XCTAssertEqual(subject.rows.count, 1)
        XCTAssertEqual(subject.rows[0].reference, row.reference)
        XCTAssertEqual(subject.rows[0].inspection, row.inspection)
        XCTAssertEqual(subject.rows[0].locationHint, row.locationHint)
        XCTAssertEqual(subject.rows[0].lastReadAt, row.lastReadAt)
        XCTAssertEqual(subject.selectedID, survivor.id)
        XCTAssertEqual(subject.selectedFeature, ProjectFeatureIdentity(projectID: survivor.id, featureID: "F1"))
        XCTAssertEqual(subject.selectedFeatureContent, detail)
        let after = await io.history()
        XCTAssertEqual(after, before)
    }

    func testFailedDurableDeletionRetainsUsableDetailLocationAndRequiresExplicitRetry() async throws {
        let url = diskURL()
        let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
        let repo = SwiftDataProjectReferenceRepository(container: container), io = DisconnectIO()
        let ref = try repo.insert(input(1))
        var fail = false, attempts = 0
        let removing = SwiftDataProjectReferenceRepository(container: container, beforeSave: {
            if fail { attempts += 1; throw SaveFailure.injected }
        })
        let subject = store(removing, io)
        try subject.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(try inspection()))
        await eventually { !subject.rows[0].isRefreshing }
        subject.selectFeature("F1", in: ref.id)
        let row = subject.rows[0], detail = subject.selectedFeatureContent
        fail = true
        XCTAssertThrowsError(try subject.disconnect(id: ref.id, expectedRevision: row.reference.revision)) {
            XCTAssertTrue($0 is SaveFailure)
        }
        XCTAssertEqual(subject.rows[0].reference, row.reference)
        XCTAssertEqual(subject.rows[0].inspection, row.inspection)
        XCTAssertEqual(subject.rows[0].locationHint, row.locationHint)
        XCTAssertEqual(subject.rows[0].lastReadAt, row.lastReadAt)
        XCTAssertEqual(subject.rows[0].completion, row.completion)
        XCTAssertEqual(subject.rows[0].refreshFailure, row.refreshFailure)
        XCTAssertFalse(subject.rows[0].isStale)
        XCTAssertTrue(subject.canMarkComplete("F1", in: ref.id))
        XCTAssertEqual(subject.selectedFeatureContent, detail)
        XCTAssertEqual(subject.selectedID, ref.id)
        XCTAssertNil(subject.selectionNotice)
        XCTAssertEqual(try repo.fetchAll(), [row.reference])
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
        XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll(), [row.reference])
        await Task.yield()
        XCTAssertEqual(attempts, 1)
        fail = false
        try subject.disconnect(id: ref.id, expectedRevision: row.reference.revision)
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertNil(subject.selectedFeature)
        XCTAssertNil(subject.selectedFeatureContent)
        XCTAssertNil(subject.selectedID)
    }

    func testStaleAndMissingConfirmationsLeaveRowsAndDetailForExplicitReview() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataProjectReferenceRepository(container: container), io = DisconnectIO()
        let original = try repo.insert(input(1))
        let subject = store(repo, io)
        try subject.enterProjects()
        await eventually { await io.count(original.bookmarkData) == 1 }
        await io.release(original.bookmarkData, .success(try inspection()))
        await eventually { !subject.rows[0].isRefreshing }
        subject.selectFeature("F1", in: original.id)
        let current = subject.rows[0].reference, detail = subject.selectedFeatureContent
        let before = await io.history()
        XCTAssertThrowsError(try subject.disconnect(id: original.id, expectedRevision: original.revision)) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .staleRevision)
        }
        XCTAssertThrowsError(try subject.disconnect(id: UUID(), expectedRevision: UUID())) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .notFound)
        }
        // The store baseline can match confirmation but still be stale in durable storage.
        let replacement = try repo.reconnect(id: current.id, expectedRevision: current.revision,
            input: ReconnectedProjectReference(manifestID: current.manifestID,
                bookmarkData: Data([99]), displayNameHint: "Replaced grant"))
        XCTAssertThrowsError(try subject.disconnect(id: current.id, expectedRevision: current.revision)) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .staleRevision)
        }
        XCTAssertEqual(try repo.fetchAll(), [replacement])
        XCTAssertEqual(subject.rows[0].reference, current)
        XCTAssertEqual(subject.selectedFeatureContent, detail)
        try repo.remove(id: replacement.id, expectedRevision: replacement.revision)
        XCTAssertThrowsError(try subject.disconnect(id: current.id, expectedRevision: current.revision)) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .notFound)
        }
        XCTAssertEqual(subject.rows[0].reference, current, "No implicit reload or adoption of newer confirmation")
        XCTAssertEqual(subject.selectedFeatureContent, detail)
        let after = await io.history()
        XCTAssertEqual(after, before)
        try subject.reloadReferences()
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertNil(subject.selectedFeature)
    }

    func testRemovalClearsObsoleteFeatureNoticeAndExternalFailuresRemainRemovable() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataProjectReferenceRepository(container: container), io = DisconnectIO()
        let ref = try repo.insert(input(1))
        var fail = false
        let removing = SwiftDataProjectReferenceRepository(container: container, beforeSave: {
            if fail { throw SaveFailure.injected }
        })
        let subject = store(removing, io)
        try subject.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(try inspection()))
        await eventually { !subject.rows[0].isRefreshing }
        subject.selectFeature("F1", in: ref.id)
        subject.refresh(ref.id)
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(try inspection(false)))
        await eventually { !subject.rows[0].isRefreshing }
        XCTAssertEqual(subject.selectionNotice?.reason, .removed)
        let notice = subject.selectionNotice, row = subject.rows[0]
        let before = await io.history()
        fail = true
        XCTAssertThrowsError(try subject.disconnect(id: ref.id, expectedRevision: row.reference.revision))
        XCTAssertEqual(subject.selectionNotice, notice)
        XCTAssertEqual(subject.rows[0].inspection, row.inspection)
        XCTAssertEqual(subject.rows[0].locationHint, row.locationHint)
        XCTAssertEqual(subject.selectedID, ref.id)
        fail = false
        try subject.disconnect(id: ref.id, expectedRevision: subject.rows[0].reference.revision)
        XCTAssertNil(subject.selectionNotice)
        XCTAssertNil(subject.selectedFeature)
        let after = await io.history()
        XCTAssertEqual(after, before)

        for (n, failure) in [(UInt8(2), ProjectInspectionFailure.access(.unresolvedBookmark)),
                             (UInt8(3), .access(.accessDenied)), (UInt8(4), .unreadableFolder)] {
            let inaccessible = try repo.insert(input(n))
            try subject.reloadReferences()
            subject.refresh(inaccessible.id)
            await eventually { await io.count(inaccessible.bookmarkData) == 1 }
            await io.release(inaccessible.bookmarkData, .failure(failure))
            await eventually { !subject.rows[0].isRefreshing }
            XCTAssertEqual(subject.rows[0].refreshFailure, .inspection(failure))
            let calls = await io.history()
            try subject.disconnect(id: inaccessible.id, expectedRevision: inaccessible.revision)
            XCTAssertTrue(subject.rows.isEmpty)
            let remainingCalls = await io.history()
            XCTAssertEqual(remainingCalls, calls, "Removal must not retry inaccessible external IO")
        }
    }

    func testDisconnectClearsOnlyItsReconnectNoticeAfterDurableSuccess() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataProjectReferenceRepository(container: container), io = DisconnectIO()
        let ref = try repo.insert(input(1)), peer = try repo.insert(input(2, order: 1))
        var fail = false
        let removing = SwiftDataProjectReferenceRepository(container: container, beforeSave: {
            if fail { throw SaveFailure.injected }
        })
        let subject = store(removing, io)
        try subject.loadReferencesIfNeeded()
        let reconnect = Task { try await subject.reconnect(ref.id, to: URL(fileURLWithPath: "/tmp/not-accessed")) }
        await eventually { await io.hasSelectedRead() }
        await io.failSelectedRead(ProjectInspectionFailure.unreadableFolder)
        do { _ = try await reconnect.value; XCTFail("Expected fixture failure") }
        catch { XCTAssertEqual(error as? ProjectInspectionFailure, .unreadableFolder) }
        XCTAssertEqual(subject.reconnectMessage, "Project not reconnected")
        fail = true
        XCTAssertThrowsError(try subject.disconnect(id: ref.id, expectedRevision: ref.revision))
        XCTAssertEqual(subject.reconnectMessage, "Project not reconnected")
        fail = false
        try subject.disconnect(id: peer.id, expectedRevision: peer.revision)
        XCTAssertEqual(subject.reconnectMessage, "Project not reconnected", "An unrelated notice survives")
        try subject.disconnect(id: ref.id, expectedRevision: ref.revision)
        XCTAssertNil(subject.reconnectMessage)
    }

    func testReconnectBusyRejectionDoesNotCancelOwnerOrQueueDeletion() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repo = SwiftDataProjectReferenceRepository(container: container), io = DisconnectIO()
        let ref = try repo.insert(input(1)), peer = try repo.insert(input(2, order: 1))
        var saves = 0
        let removing = SwiftDataProjectReferenceRepository(container: container, beforeSave: { saves += 1 })
        let subject = store(removing, io)
        try subject.loadReferencesIfNeeded()
        let reconnect = Task { try await subject.reconnect(ref.id, to: URL(fileURLWithPath: "/tmp/not-accessed")) }
        await eventually { await io.hasSelectedRead() }
        for _ in 0..<3 {
            XCTAssertThrowsError(try subject.disconnect(id: ref.id, expectedRevision: ref.revision)) {
                XCTAssertEqual($0 as? ProjectStoreError, .busy)
            }
        }
        XCTAssertEqual(subject.rows.map(\.reference), [ref, peer])
        XCTAssertEqual(saves, 0)
        let stillRunning = await io.hasSelectedRead()
        XCTAssertTrue(stillRunning)
        // A different identity is removable without interrupting the reconnect owner.
        try subject.disconnect(id: peer.id, expectedRevision: peer.revision)
        XCTAssertEqual(saves, 1)
        await io.failSelectedRead()
        do { _ = try await reconnect.value; XCTFail("Expected fixture cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await Task.yield()
        XCTAssertEqual(subject.rows.map(\.reference), [ref])
        XCTAssertEqual(try repo.fetchAll(), [ref])
        XCTAssertEqual(saves, 1, "Rejected removal is never automatically retried after reconnect")
    }
}
