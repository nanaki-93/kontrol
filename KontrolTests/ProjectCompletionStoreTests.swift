import Foundation
import XCTest
@testable import Kontrol

private actor CompletionInspector: ProjectInspecting {
    private var waiting: [(Data, CheckedContinuation<ProjectInspection, Error>)] = []
    private var peak = 0
    private var selected: CheckedContinuation<ProjectInspection, Error>?
    private var replacementBookmark = Data([99])
    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        try await withCheckedThrowingContinuation { selected = $0 }
    }
    func hasSelected() -> Bool { selected != nil }
    func releaseSelected(_ result: Result<ProjectInspection, Error> = .failure(CancellationError())) {
        selected?.resume(with: result); selected = nil
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data { replacementBookmark }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        try await withCheckedThrowingContinuation {
            waiting.append((bookmarkData, $0))
            peak = max(peak, waiting.count)
        }
    }
    func count(_ bookmark: Data) -> Int { waiting.filter { $0.0 == bookmark }.count }
    func peakReads() -> Int { peak }
    func release(_ bookmark: Data, _ result: Result<ProjectInspection, Error>) {
        guard let index = waiting.firstIndex(where: { $0.0 == bookmark }) else { return }
        waiting.remove(at: index).1.resume(with: result)
    }
}

private actor CompletionValidationGate {
    private var waiting: CheckedContinuation<Bool, Never>?
    private var entered = false
    func validate(_ source: ProjectSourceDocument, _ feature: ProjectFeature) async -> Bool {
        entered = true
        return await withCheckedContinuation { waiting = $0 }
    }
    func hasEntered() -> Bool { entered }
    func release(_ valid: Bool) { waiting?.resume(returning: valid); waiting = nil }
}

private actor CompletionWriter: FeatureFileWriting {
    private var requests: [FeatureCompletionRequest] = []
    private var waiting: [CheckedContinuation<FeatureMutationReceipt, Error>] = []
    private var undoRequests: [FeatureUndoRequest] = []
    private var undoWaiting: [CheckedContinuation<FeatureMutationReceipt, Error>] = []
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        requests.append(request)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        undoRequests.append(request)
        return try await withCheckedThrowingContinuation { undoWaiting.append($0) }
    }
    func undoCount() -> Int { undoRequests.count }
    func undoRequest(_ index: Int) -> FeatureUndoRequest { undoRequests[index] }
    func failUndo(_ failure: FeatureMutationFailure) {
        undoWaiting.removeFirst().resume(throwing: failure)
    }
    func succeedUndo() {
        let request = undoRequests[undoRequests.count - undoWaiting.count]
        let source = requests.first { $0.source.sha256 == request.receipt.inverse.originalSHA256 }!.source
        undoWaiting.removeFirst().resume(returning: FeatureMutationReceipt(projectID: request.reference.id,
            grantBookmarkData: request.reference.bookmarkData, featureID: request.receipt.featureID,
            verifiedSource: source, inverse: request.receipt.inverse))
    }
    func count() -> Int { requests.count }
    func request(_ index: Int) -> FeatureCompletionRequest { requests[index] }
    func fail(_ failure: FeatureMutationFailure = .conflict) {
        waiting.removeFirst().resume(throwing: failure)
    }
    func succeed() {
        let request = requests[requests.count - waiting.count]
        let bytes = String(decoding: request.source.bytes, as: UTF8.self)
            .replacingOccurrences(of: "status: ready", with: "status: completed")
            .replacingOccurrences(of: "status: active", with: "status: completed")
        let saved = ProjectSourceDocument(relativePath: request.source.relativePath, bytes: Data(bytes.utf8))
        waiting.removeFirst().resume(returning: FeatureMutationReceipt(projectID: request.reference.id,
            grantBookmarkData: request.reference.bookmarkData, featureID: request.featureID,
            verifiedSource: saved, inverse: FeatureInversePatch(relativePath: request.source.relativePath,
                originalSHA256: request.source.sha256, completedSHA256: saved.sha256, edits: [])))
    }
}

private struct CompletionIdentity: ProjectFolderIdentifying {
    func selected(_ folder: URL) async throws -> ProjectFolderIdentity {
        ProjectFolderIdentity(device: 1, inode: 1)
    }
    func bookmarked(_ data: Data) async throws -> ProjectFolderIdentity {
        ProjectFolderIdentity(device: 1, inode: 1)
    }
}

@MainActor
private final class CompletionRepository: ProjectReferenceRepository {
    var references: [ProjectReferenceSnapshot] = []
    var failReadSave = false
    var successfulReads = 0
    func fetchAll() throws -> [ProjectReferenceSnapshot] { references }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot { throw ProjectStoreError.busy }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot {
        let index = references.firstIndex { $0.id == id }!
        let prior = references[index]
        guard prior.revision == expectedRevision else { throw ProjectStoreError.projectNotReconnected }
        let next = ProjectReferenceSnapshot(id: id, manifestID: prior.manifestID,
            bookmarkData: input.bookmarkData, displayOrder: prior.displayOrder,
            displayNameHint: input.displayNameHint, lastSuccessfulReadAt: nil, revision: UUID())
        references[index] = next
        return next
    }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID, nameHint: String,
                              readAt: Date) throws -> ProjectReferenceSnapshot {
        if failReadSave { throw ProjectReferencePersistenceError.invalidReference }
        successfulReads += 1
        let index = references.firstIndex { $0.id == id }!
        let prior = references[index]
        let next = ProjectReferenceSnapshot(id: id, manifestID: prior.manifestID,
            bookmarkData: prior.bookmarkData, displayOrder: prior.displayOrder,
            displayNameHint: nameHint, lastSuccessfulReadAt: readAt, revision: UUID())
        references[index] = next
        return next
    }
}

@MainActor
final class ProjectCompletionStoreTests: XCTestCase {
    private func reference(_ n: UInt8) -> ProjectReferenceSnapshot {
        ProjectReferenceSnapshot(id: UUID(), manifestID: "sample", bookmarkData: Data([n]),
            displayOrder: Int(n), displayNameHint: "Sample", lastSuccessfulReadAt: nil, revision: UUID())
    }

    private func inspection(_ statuses: [String: ProjectFeatureStatus],
                            manifestID: String = "sample", version: Int = 1,
                            enumeration: ProjectFeatureEnumeration = .complete,
                            invalidPeer: Bool = false) -> ProjectInspection {
        let sources = statuses.map { id, status in
            ProjectSourceDocument(relativePath: ".kontrol/features/\(id).md", bytes: Data(
                "---\nid: \(id)\ntitle: \(id)\nstatus: \(status.rawValue)\npriority: medium\neffort: small\n---\nBody".utf8))
        }
        let parser = ManifestParser()
        let features = sources.compactMap { source -> ProjectFeature? in
            guard case let .supported(feature) = try? parser.feature(source) else { return nil }
            return feature
        }
        return ProjectInspection(manifest: ProjectManifest(schemaVersion: version, id: manifestID,
            name: "Sample", description: "", stack: [], goals: [], currentFocus: []),
            roadmap: .absent, features: features,
            excludedFeaturePaths: invalidPeer ? [".kontrol/features/bad.md"] : [],
            featureEnumeration: enumeration, context: .absent, rules: .absent,
            history: .absent, diagnostics: [], sources: sources, readAt: Date())
    }

    private func savedInspection(_ initial: ProjectInspection, featureID: String) -> ProjectInspection {
        let sources = initial.sources.map { source in
            guard source.relativePath == ".kontrol/features/\(featureID).md" else { return source }
            let bytes = String(decoding: source.bytes, as: UTF8.self)
                .replacingOccurrences(of: "status: ready", with: "status: completed")
                .replacingOccurrences(of: "status: active", with: "status: completed")
            return ProjectSourceDocument(relativePath: source.relativePath, bytes: Data(bytes.utf8))
        }
        let parser = ManifestParser()
        let features = sources.compactMap { source -> ProjectFeature? in
            guard case let .supported(feature) = try? parser.feature(source) else { return nil }
            return feature
        }
        return ProjectInspection(manifest: initial.manifest, roadmap: initial.roadmap,
            features: features, excludedFeaturePaths: initial.excludedFeaturePaths,
            featureEnumeration: initial.featureEnumeration, context: initial.context, rules: initial.rules,
            history: initial.history, diagnostics: initial.diagnostics, sources: sources, readAt: Date())
    }

    private func eventually(_ condition: @escaping () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for operation", file: file, line: line)
    }

    func testEligibilityInspectedSourceAndProjectScopedSerialization() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let first = reference(1), peer = reference(2)
        repo.references = [first, peer]
        let instant = Date(timeIntervalSince1970: 12345)
        let store = ProjectStore(inspector: io, repository: repo, writer: writer,
                                 completionClock: { instant })
        try store.enterProjects()
        await eventually { await io.count(first.bookmarkData) == 1 }
        await eventually { await io.count(peer.bookmarkData) == 1 }
        XCTAssertFalse(store.canMarkComplete("ready", in: first.id)) // Refresh in progress.
        let statuses: [String: ProjectFeatureStatus] = ["planned": .planned, "ready": .ready,
            "active": .active, "blocked": .blocked, "done": .completed]
        let initial = inspection(statuses, invalidPeer: true)
        await io.release(first.bookmarkData, .success(initial))
        await io.release(peer.bookmarkData, .success(initial))
        await eventually { !store.rows[0].isRefreshing && !store.rows[1].isRefreshing }
        for id in ["planned", "ready", "active", "blocked"] {
            XCTAssertTrue(store.canMarkComplete(id, in: first.id), id)
        }
        XCTAssertFalse(store.canMarkComplete("done", in: first.id))
        XCTAssertFalse(store.canMarkComplete("missing", in: first.id))
        let completion = Task { await store.markComplete("active", in: first.id) }
        await eventually { await writer.count() == 1 }
        let request = await writer.request(0)
        XCTAssertEqual(request.completedAt, instant)
        XCTAssertEqual(request.source, initial.sources.first { $0.relativePath == ".kontrol/features/active.md" })
        XCTAssertEqual(request.reference, store.rows[0].reference)
        XCTAssertEqual(store.rows[0].completion, .writing("active"))
        XCTAssertEqual(store.rows[0].inspection, initial)
        do {
            _ = try await store.reconnect(first.id, to: URL(fileURLWithPath: "/tmp/unused"))
            XCTFail("Reconnect cannot replace a grant during mutation")
        } catch {
            XCTAssertEqual(error as? ProjectStoreError, .busy)
        }
        await store.markComplete("active", in: first.id)
        await store.markComplete("ready", in: first.id)
        let firstCount = await writer.count()
        XCTAssertEqual(firstCount, 1)
        let other = Task { await store.markComplete("ready", in: peer.id) }
        await eventually { await writer.count() == 2 }
        XCTAssertEqual(store.rows[1].completion, .writing("ready"))
        await writer.fail()
        await completion.value
        XCTAssertEqual(store.rows[0].completion, .failed("active", .conflict))
        XCTAssertEqual(store.rows[0].inspection, initial)
        XCTAssertFalse(store.canMarkComplete("active", in: first.id), "Conflict requires a new inspection")
        await writer.succeed()
        await eventually { await io.count(peer.bookmarkData) == 1 }
        XCTAssertEqual(store.rows[1].completion, .refreshing("ready"))
        XCTAssertEqual(store.rows[1].inspection, initial, "Old content is retained only during reconciliation")
        let reconciled = savedInspection(initial, featureID: "ready")
        await io.release(peer.bookmarkData, .success(reconciled))
        await other.value
        XCTAssertEqual(store.rows[1].completion, .saved("ready"))
        XCTAssertEqual(store.rows[1].inspection, reconciled)
        XCTAssertFalse(store.canMarkComplete("ready", in: peer.id))
    }

    func testRefreshesDuringWriteCoalesceIntoOneDiskDerivedReadAcrossSelectionChanges() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let first = reference(21), peer = reference(22)
        repo.references = [first, peer]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually {
            let firstCount = await io.count(first.bookmarkData)
            let peerCount = await io.count(peer.bookmarkData)
            return firstCount == 1 && peerCount == 1
        }
        let original = inspection(["ready": .ready])
        await io.release(first.bookmarkData, .success(original))
        await io.release(peer.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 2 }
        store.selectFeature("ready", in: first.id)
        let pending = Task { await store.markComplete("ready", in: first.id) }
        await eventually { await writer.count() == 1 }
        for _ in 0..<10 { store.refresh(first.id); store.refreshOnMainWindowActivation() }
        store.select(peer.id)
        XCTAssertEqual(store.selectedID, peer.id)
        XCTAssertEqual(store.rows[0].inspection, original)
        XCTAssertEqual(store.rows[0].completion, .writing("ready"))
        let readsDuringWrite = await io.count(first.bookmarkData)
        XCTAssertEqual(readsDuringWrite, 0)
        await writer.succeed()
        await eventually { await io.count(first.bookmarkData) == 1 }
        XCTAssertEqual(store.rows[0].completion, .refreshing("ready"))
        do {
            _ = try await store.reconnect(first.id, to: URL(fileURLWithPath: "/tmp/unused"))
            XCTFail("Reconnect cannot commit during reconciliation")
        } catch {
            XCTAssertEqual(error as? ProjectStoreError, .busy)
        }
        XCTAssertFalse(store.canMarkComplete("ready", in: first.id))
        store.refresh(first.id)
        store.cancelRefresh(first.id) // Cannot cancel a verified write's reconciliation.
        let refreshed = savedInspection(original, featureID: "ready")
        await io.release(first.bookmarkData, .success(refreshed))
        await pending.value
        XCTAssertEqual(store.rows[0].inspection, refreshed)
        XCTAssertEqual(store.rows[0].completion, .saved("ready"))
        XCTAssertEqual(store.selectedID, peer.id)
        let readsAfterWrite = await io.count(first.bookmarkData)
        XCTAssertEqual(readsAfterWrite, 0)
        XCTAssertEqual(repo.successfulReads, 3)
        store.selectFeature("ready", in: first.id)
        XCTAssertEqual(store.selectedFeatureContent?.status, .completed)
        XCTAssertNil(store.selectionNotice)
    }

    func testFailedWriteRunsCoalescedRefreshWithoutPublishingAnAssumedSave() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(26)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["ready": .ready])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let pending = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await writer.count() == 1 }
        for _ in 0..<8 { store.refresh(ref.id) }
        let readsBeforeFailure = await io.count(ref.bookmarkData)
        XCTAssertEqual(readsBeforeFailure, 0)
        await writer.fail()
        await pending.value
        await eventually { await io.count(ref.bookmarkData) == 1 }
        XCTAssertEqual(store.rows[0].completion, .failed("ready", .conflict))
        XCTAssertEqual(store.rows[0].inspection, original)
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 2 }
        let remaining = await io.count(ref.bookmarkData)
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(store.canMarkComplete("ready", in: ref.id))
    }

    func testCompletionRetainsOpenDetailByIDAfterCandidateDisappears() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(25)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["ready": .ready])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        store.selectFeature("ready", in: ref.id)
        let pending = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let saved = savedInspection(original, featureID: "ready")
        await io.release(ref.bookmarkData, .success(saved))
        await pending.value
        XCTAssertEqual(store.selectedFeature, ProjectFeatureIdentity(projectID: ref.id, featureID: "ready"))
        XCTAssertEqual(store.selectedFeatureContent?.status, .completed)
        XCTAssertNil(store.selectionNotice)
        XCTAssertEqual(store.rows[0].inspection, saved)
    }

    func testVerifiedSaveWithFailedInspectionOrReceiptNeverPublishesOldProgress() async throws {
        for failsReceipt in [false, true] {
            let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
            let ref = reference(failsReceipt ? 24 : 23)
            repo.references = [ref]
            let store = ProjectStore(inspector: io, repository: repo, writer: writer)
            try store.enterProjects()
            await eventually { await io.count(ref.bookmarkData) == 1 }
            let original = inspection(["ready": .ready])
            await io.release(ref.bookmarkData, .success(original))
            await eventually { repo.successfulReads == 1 }
            let pending = Task { await store.markComplete("ready", in: ref.id) }
            await eventually { await writer.count() == 1 }
            await writer.succeed()
            await eventually { await io.count(ref.bookmarkData) == 1 }
            if failsReceipt {
                repo.failReadSave = true
                await io.release(ref.bookmarkData, .success(savedInspection(original, featureID: "ready")))
            } else {
                await io.release(ref.bookmarkData, .failure(ProjectInspectionFailure.inconsistentRead))
            }
            await pending.value
            let expected: ProjectRefreshFailure = failsReceipt ? .persistence : .inspection(.inconsistentRead)
            XCTAssertEqual(store.rows[0].completion, .savedButRefreshFailed("ready", expected))
            XCTAssertEqual(store.rows[0].refreshFailure, expected)
            XCTAssertNil(store.rows[0].inspection)
            XCTAssertTrue(store.rows[0].isStale)
            XCTAssertFalse(store.canMarkComplete("ready", in: ref.id))
            XCTAssertEqual(repo.successfulReads, 1)
            repo.failReadSave = false
            store.refresh(ref.id)
            await eventually { await io.count(ref.bookmarkData) == 1 }
            let repaired = savedInspection(original, featureID: "ready")
            await io.release(ref.bookmarkData, .success(repaired))
            await eventually { store.rows[0].inspection?.readAt == repaired.readAt }
            XCTAssertNil(store.rows[0].refreshFailure)
            XCTAssertEqual(store.rows[0].inspection?.features.first?.status, .completed)
        }
    }

    func testOldRevisionResultIsRefusedAndMutationReconciliationRespectsThreeSlots() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let refs = (30...34).map { reference(UInt8($0)) }
        repo.references = refs
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.peakReads() == 3 }
        let original = inspection(["ready": .ready])
        await io.release(refs[0].bookmarkData, .success(original))
        await eventually { await io.count(refs[3].bookmarkData) == 1 }
        await io.release(refs[3].bookmarkData, .success(original))
        await eventually { repo.successfulReads == 2 }
        await eventually { await io.count(refs[4].bookmarkData) == 1 }
        let pending = Task { await store.markComplete("ready", in: refs[3].id) }
        await eventually { await writer.count() == 1 }
        store.refresh(refs[3].id)
        await writer.succeed()
        let queued = await io.count(refs[3].bookmarkData)
        XCTAssertEqual(queued, 0, "Three older reads still occupy slots")
        await io.release(refs[1].bookmarkData, .success(inspection(["ready": .completed])))
        await eventually { await io.count(refs[3].bookmarkData) == 1 }
        // A stale snapshot from a noncooperative reader is not the saved revision.
        await io.release(refs[3].bookmarkData, .success(original))
        await pending.value
        XCTAssertEqual(store.rows[3].completion,
                       .savedButRefreshFailed("ready", .inspection(.inconsistentRead)))
        XCTAssertNil(store.rows[3].inspection)
        await io.release(refs[2].bookmarkData, .success(original))
        await io.release(refs[4].bookmarkData, .success(original))
        let peak = await io.peakReads()
        XCTAssertEqual(peak, 3)
    }

    func testInspectedFeatureMustMatchItsExactSource() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(8)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let valid = inspection(["ready": .ready])
        let changed = ProjectSourceDocument(relativePath: valid.sources[0].relativePath,
            bytes: Data("---\nid: ready\ntitle: Changed\nstatus: ready\npriority: medium\neffort: small\n---\nBody".utf8))
        let mismatched = ProjectInspection(manifest: valid.manifest, roadmap: valid.roadmap,
            features: valid.features, excludedFeaturePaths: [], featureEnumeration: .complete,
            context: valid.context, rules: valid.rules, history: valid.history,
            diagnostics: [], sources: [changed], readAt: valid.readAt)
        await io.release(ref.bookmarkData, .success(mismatched))
        await eventually { !store.rows[0].isRefreshing }
        XCTAssertTrue(store.canMarkComplete("ready", in: ref.id),
                      "The synchronous view gate does not parse source bytes")
        await store.markComplete("ready", in: ref.id)
        let count = await writer.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.rows[0].completion, .failed("ready", .unpatchableSource))
    }

    func testValidationSuspendsAfterClaimAndRejectsWithoutWriting() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let gate = CompletionValidationGate(), ref = reference(10)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer,
            completionValidator: { source, feature in await gate.validate(source, feature) })
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(inspection(["ready": .ready])))
        await eventually { !store.rows[0].isRefreshing }
        let pending = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await gate.hasEntered() }
        XCTAssertEqual(store.rows[0].completion, .writing("ready"))
        XCTAssertFalse(store.canMarkComplete("ready", in: ref.id))
        await store.markComplete("ready", in: ref.id)
        let beforeRelease = await writer.count()
        XCTAssertEqual(beforeRelease, 0)
        do {
            _ = try await store.reconnect(ref.id, to: URL(fileURLWithPath: "/tmp/unused"))
            XCTFail("Reconnect must not commit while validation is suspended")
        } catch {
            XCTAssertEqual(error as? ProjectStoreError, .busy)
        }
        await gate.release(false)
        await pending.value
        XCTAssertEqual(store.rows[0].completion, .failed("ready", .unpatchableSource))
        let afterRelease = await writer.count()
        XCTAssertEqual(afterRelease, 0)
    }

    func testReconnectAndCanceledInFlightReadBlockCompletion() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(9)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo,
                                 identifier: CompletionIdentity(), writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(inspection(["ready": .ready])))
        await eventually { !store.rows[0].isRefreshing }
        let reconnect = Task { try await store.reconnect(ref.id, to: URL(fileURLWithPath: "/tmp/unused")) }
        await eventually { await io.hasSelected() }
        XCTAssertFalse(store.canMarkComplete("ready", in: ref.id))
        await store.markComplete("ready", in: ref.id)
        await io.releaseSelected()
        _ = try? await reconnect.value
        store.refresh(ref.id)
        await eventually { await io.count(ref.bookmarkData) == 1 }
        store.cancelRefresh(ref.id)
        XCTAssertFalse(store.canMarkComplete("ready", in: ref.id),
                       "A canceled noncooperative reader still owns its concurrency slot")
        await store.markComplete("ready", in: ref.id)
        let count = await writer.count()
        XCTAssertEqual(count, 0)
        await io.release(ref.bookmarkData, .failure(CancellationError()))
    }

    func testUnsupportedIncompleteRetainedAndRefreshingCannotWrite() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let refs = (1...4).map { reference(UInt8($0)) }
        repo.references = refs
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(refs[0].bookmarkData) == 1 }
        await io.release(refs[0].bookmarkData, .success(inspection(["ready": .ready], version: 2)))
        await eventually { !store.rows[0].isRefreshing }
        await io.release(refs[1].bookmarkData, .success(inspection(["ready": .ready], enumeration: .failed)))
        await eventually { !store.rows[1].isRefreshing }
        await io.release(refs[2].bookmarkData, .success(inspection(["ready": .ready], manifestID: "different")))
        await eventually { !store.rows[2].isRefreshing }
        await io.release(refs[3].bookmarkData, .success(inspection(["ready": .ready])))
        await eventually { !store.rows[3].isRefreshing }
        store.refresh(refs[3].id)
        await eventually { await io.count(refs[3].bookmarkData) == 1 }
        for ref in refs { await store.markComplete("ready", in: ref.id) }
        let rejectedCount = await writer.count()
        XCTAssertEqual(rejectedCount, 0)
        await io.release(refs[3].bookmarkData, .failure(ProjectInspectionFailure.inconsistentRead))
        await eventually { !store.rows[3].isRefreshing }
        XCTAssertTrue(store.rows[3].isRetainedInspection)
        XCTAssertFalse(store.canMarkComplete("ready", in: refs[3].id))
        await store.markComplete("ready", in: refs[3].id)
        let retainedCount = await writer.count()
        XCTAssertEqual(retainedCount, 0)
    }

    func testUndoTokenSurvivesSelectionAndReadRevisionThenRestoresInspection() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let first = reference(51), peer = reference(52)
        repo.references = [first, peer]
        var now = Date(timeIntervalSince1970: 1000)
        let store = ProjectStore(inspector: io, repository: repo, writer: writer,
                                 completionClock: { now })
        try store.enterProjects()
        await eventually {
            let firstCount = await io.count(first.bookmarkData)
            let peerCount = await io.count(peer.bookmarkData)
            return firstCount == 1 && peerCount == 1
        }
        let original = inspection(["ready": .ready])
        await io.release(first.bookmarkData, .success(original))
        await io.release(peer.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 2 }
        let completion = Task { await store.markComplete("ready", in: first.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(first.bookmarkData) == 1 }
        let saved = savedInspection(original, featureID: "ready")
        await io.release(first.bookmarkData, .success(saved))
        await completion.value
        XCTAssertEqual(store.undoExpiration(in: first.id), now.addingTimeInterval(30))
        store.select(peer.id)
        XCTAssertFalse(store.canUndoCompletion(in: peer.id))
        store.refresh(first.id)
        await eventually { await io.count(first.bookmarkData) == 1 }
        await io.release(first.bookmarkData, .success(saved))
        await eventually { repo.successfulReads == 4 }
        XCTAssertNotEqual(store.rows[0].reference.revision, first.revision)
        XCTAssertTrue(store.canUndoCompletion(in: first.id))
        now.addTimeInterval(29)
        let undo = Task { await store.undoCompletion(in: first.id) }
        await eventually { await writer.undoCount() == 1 }
        let request = await writer.undoRequest(0)
        XCTAssertEqual(request.reference.revision, store.rows[0].reference.revision)
        XCTAssertEqual(request.receipt.verifiedSource, saved.sources[0])
        XCTAssertEqual(request.receipt.featureID, "ready")
        XCTAssertEqual(store.rows[0].completion, .undoing("ready"))
        XCTAssertFalse(store.canUndoCompletion(in: first.id))
        await store.undoCompletion(in: first.id)
        let duplicateCount = await writer.undoCount()
        XCTAssertEqual(duplicateCount, 1)
        await writer.succeedUndo()
        await eventually { await io.count(first.bookmarkData) == 1 }
        await io.release(first.bookmarkData, .success(original))
        await undo.value
        XCTAssertEqual(store.rows[0].completion, .undone("ready"))
        XCTAssertEqual(store.rows[0].inspection, original)
        XCTAssertTrue(store.canMarkComplete("ready", in: first.id))
        XCTAssertFalse(store.canUndoCompletion(in: first.id))
        XCTAssertEqual(store.selectedID, peer.id)
    }

    func testAcceptedRefreshInvalidatesUndoWhenTargetEditedOrRemoved() async throws {
        for removeTarget in [false, true] {
            let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
            let ref = reference(removeTarget ? 59 : 58)
            repo.references = [ref]
            let store = ProjectStore(inspector: io, repository: repo, writer: writer)
            try store.enterProjects()
            await eventually { await io.count(ref.bookmarkData) == 1 }
            let original = inspection(["ready": .ready, "peer": .ready])
            await io.release(ref.bookmarkData, .success(original))
            await eventually { repo.successfulReads == 1 }
            let completion = Task { await store.markComplete("ready", in: ref.id) }
            await eventually { await writer.count() == 1 }
            await writer.succeed()
            await eventually { await io.count(ref.bookmarkData) == 1 }
            let saved = savedInspection(original, featureID: "ready")
            await io.release(ref.bookmarkData, .success(saved))
            await completion.value
            XCTAssertTrue(store.canUndoCompletion(in: ref.id))

            // A peer change is not a conflict with the token's target.
            store.refresh(ref.id)
            await eventually { await io.count(ref.bookmarkData) == 1 }
            let peerChanged = savedInspection(saved, featureID: "peer")
            await io.release(ref.bookmarkData, .success(peerChanged))
            await eventually { store.rows[0].inspection?.readAt == peerChanged.readAt }
            XCTAssertTrue(store.canUndoCompletion(in: ref.id))

            store.refresh(ref.id)
            await eventually { await io.count(ref.bookmarkData) == 1 }
            let sources = peerChanged.sources.compactMap { source -> ProjectSourceDocument? in
                guard source.relativePath == ".kontrol/features/ready.md" else { return source }
                if removeTarget { return nil }
                return ProjectSourceDocument(relativePath: source.relativePath,
                    bytes: source.bytes + Data("\nExternal edit".utf8))
            }
            let features = sources.compactMap { source -> ProjectFeature? in
                guard case let .supported(feature) = try? ManifestParser().feature(source) else { return nil }
                return feature
            }
            let changed = ProjectInspection(manifest: peerChanged.manifest, roadmap: peerChanged.roadmap,
                features: features, excludedFeaturePaths: [], featureEnumeration: .complete,
                context: peerChanged.context, rules: peerChanged.rules, history: peerChanged.history,
                diagnostics: [], sources: sources, readAt: Date())
            await io.release(ref.bookmarkData, .success(changed))
            await eventually { store.rows[0].inspection?.readAt == changed.readAt }
            XCTAssertFalse(store.canUndoCompletion(in: ref.id))
            XCTAssertNil(store.undoExpiration(in: ref.id))
            XCTAssertEqual(store.rows[0].inspection, changed, "Refresh publishes external bytes")
            await store.undoCompletion(in: ref.id)
            let undoCount = await writer.undoCount()
            XCTAssertEqual(undoCount, 0, "An observed conflict must not reach undo IO")
        }
    }

    func testFailedRefreshRetainsTokenButCannotUndoUntilFreshRead() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(60)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["ready": .ready])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let completion = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let saved = savedInspection(original, featureID: "ready")
        await io.release(ref.bookmarkData, .success(saved))
        await completion.value
        let expiry = store.undoExpiration(in: ref.id)
        store.refresh(ref.id)
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .failure(ProjectInspectionFailure.inconsistentRead))
        await eventually { store.rows[0].refreshFailure != nil && !store.rows[0].isRefreshing }
        XCTAssertTrue(store.rows[0].isRetainedInspection)
        XCTAssertEqual(store.rows[0].inspection, saved)
        XCTAssertEqual(store.undoExpiration(in: ref.id), expiry, "Failed reads do not discard the token")
        XCTAssertFalse(store.canUndoCompletion(in: ref.id))
        await store.undoCompletion(in: ref.id)
        let blockedCount = await writer.undoCount()
        XCTAssertEqual(blockedCount, 0)

        store.refresh(ref.id)
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(saved))
        await eventually { store.rows[0].refreshFailure == nil && !store.rows[0].isRefreshing }
        XCTAssertTrue(store.canUndoCompletion(in: ref.id))
        XCTAssertEqual(store.undoExpiration(in: ref.id), expiry)
    }

    func testTargetReadFailureDoesNotMasqueradeAsRemoval() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(61)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["ready": .ready, "peer": .ready])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let completion = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let saved = savedInspection(original, featureID: "ready")
        await io.release(ref.bookmarkData, .success(saved))
        await completion.value
        let expiry = store.undoExpiration(in: ref.id)

        let path = ".kontrol/features/ready.md"
        let diagnostic = ProjectDiagnostic(code: .unreadableFile, severity: .error,
            relativePath: path, recovery: .refresh)
        let unreadable = ProjectInspection(manifest: saved.manifest, roadmap: saved.roadmap,
            features: saved.features.filter { $0.id != "ready" }, excludedFeaturePaths: [path],
            featureEnumeration: .complete, context: saved.context, rules: saved.rules,
            history: saved.history, diagnostics: [diagnostic],
            sources: saved.sources.filter { $0.relativePath != path }, readAt: Date())
        store.refresh(ref.id)
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(unreadable))
        await eventually { store.rows[0].inspection?.readAt == unreadable.readAt }
        XCTAssertEqual(store.undoExpiration(in: ref.id), expiry,
                       "A complete listing with an unreadable target does not prove deletion")
        XCTAssertFalse(store.rows[0].isRetainedInspection)

        store.refresh(ref.id)
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(saved))
        await eventually { store.rows[0].inspection?.readAt == saved.readAt }
        XCTAssertTrue(store.canUndoCompletion(in: ref.id))
        let undo = Task { await store.undoCompletion(in: ref.id) }
        await eventually { await writer.undoCount() == 1 }
        await writer.succeedUndo()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(original))
        await undo.value
        XCTAssertEqual(store.rows[0].inspection, original)
        XCTAssertFalse(store.canUndoCompletion(in: ref.id))
    }

    func testExpiryAndFailedUnrelatedCompletionDoNotConsumeToken() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(53)
        repo.references = [ref]
        var now = Date(timeIntervalSince1970: 1000)
        let store = ProjectStore(inspector: io, repository: repo, writer: writer,
                                 completionClock: { now })
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["one": .ready, "two": .active])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let first = Task { await store.markComplete("one", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let saved = savedInspection(original, featureID: "one")
        await io.release(ref.bookmarkData, .success(saved))
        await first.value
        let failed = Task { await store.markComplete("two", in: ref.id) }
        await eventually { await writer.count() == 2 }
        await writer.fail(.temporaryFileFailed)
        await failed.value
        XCTAssertTrue(store.canUndoCompletion(in: ref.id))
        now.addTimeInterval(30)
        XCTAssertNil(store.undoExpiration(in: ref.id))
        await store.undoCompletion(in: ref.id)
        let expiredCount = await writer.undoCount()
        XCTAssertEqual(expiredCount, 0)
    }

    func testUndoConflictInvalidatesTokenAndDoesNotPublishOldBytes() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(54)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["ready": .ready])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let completion = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let saved = savedInspection(original, featureID: "ready")
        await io.release(ref.bookmarkData, .success(saved))
        await completion.value
        let undo = Task { await store.undoCompletion(in: ref.id) }
        await eventually { await writer.undoCount() == 1 }
        await writer.failUndo(.undoConflict)
        await undo.value
        XCTAssertEqual(store.rows[0].completion, .undoFailed("ready", .undoConflict))
        XCTAssertEqual(store.rows[0].inspection, saved)
        XCTAssertTrue(store.rows[0].isRetainedInspection)
        XCTAssertFalse(store.canUndoCompletion(in: ref.id))
        await store.undoCompletion(in: ref.id)
        let conflictCount = await writer.undoCount()
        XCTAssertEqual(conflictCount, 1)
    }

    func testLatestSuccessfulTokenAndRecoverableUndoFailure() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(56)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["one": .ready, "two": .active])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let first = Task { await store.markComplete("one", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let firstSaved = savedInspection(original, featureID: "one")
        await io.release(ref.bookmarkData, .success(firstSaved))
        await first.value
        let second = Task { await store.markComplete("two", in: ref.id) }
        await eventually { await writer.count() == 2 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let bothSaved = savedInspection(firstSaved, featureID: "two")
        await io.release(ref.bookmarkData, .success(bothSaved))
        await second.value
        let failingUndo = Task { await store.undoCompletion(in: ref.id) }
        await eventually { await writer.undoCount() == 1 }
        let targetedUndo = await writer.undoRequest(0)
        XCTAssertEqual(targetedUndo.receipt.featureID, "two")
        await writer.failUndo(.temporaryFileFailed)
        await failingUndo.value
        XCTAssertEqual(store.rows[0].completion, .undoFailed("two", .temporaryFileFailed))
        XCTAssertTrue(store.canUndoCompletion(in: ref.id))
        let undo = Task { await store.undoCompletion(in: ref.id) }
        await eventually { await writer.undoCount() == 2 }
        store.refresh(ref.id)
        let readsDuringUndo = await io.count(ref.bookmarkData)
        XCTAssertEqual(readsDuringUndo, 0)
        await writer.succeedUndo()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(firstSaved))
        await undo.value
        XCTAssertEqual(store.rows[0].inspection, firstSaved)
        XCTAssertEqual(store.rows[0].completion, .undone("two"))
        XCTAssertFalse(store.canUndoCompletion(in: ref.id), "Undo is not a stack")
    }

    func testVerifiedUndoWithFailedRefreshHasNoAssumedProgressOrUndoToken() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(57)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo, writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["ready": .ready])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let completion = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(savedInspection(original, featureID: "ready")))
        await completion.value
        let undo = Task { await store.undoCompletion(in: ref.id) }
        await eventually { await writer.undoCount() == 1 }
        await writer.succeedUndo()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .failure(ProjectInspectionFailure.inconsistentRead))
        await undo.value
        XCTAssertEqual(store.rows[0].completion,
                       .undoneButRefreshFailed("ready", .inspection(.inconsistentRead)))
        XCTAssertNil(store.rows[0].inspection)
        XCTAssertFalse(store.canUndoCompletion(in: ref.id))
        store.refresh(ref.id)
        await eventually { await io.count(ref.bookmarkData) == 1 }
        await io.release(ref.bookmarkData, .success(original))
        await eventually { store.rows[0].inspection?.readAt == original.readAt }
        XCTAssertTrue(store.canMarkComplete("ready", in: ref.id))
    }

    func testReconnectReplacementClearsTokenButFailedReconnectKeepsIt() async throws {
        let io = CompletionInspector(), writer = CompletionWriter(), repo = CompletionRepository()
        let ref = reference(55)
        repo.references = [ref]
        let store = ProjectStore(inspector: io, repository: repo,
                                 identifier: CompletionIdentity(), writer: writer)
        try store.enterProjects()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let original = inspection(["ready": .ready])
        await io.release(ref.bookmarkData, .success(original))
        await eventually { repo.successfulReads == 1 }
        let completion = Task { await store.markComplete("ready", in: ref.id) }
        await eventually { await writer.count() == 1 }
        await writer.succeed()
        await eventually { await io.count(ref.bookmarkData) == 1 }
        let saved = savedInspection(original, featureID: "ready")
        await io.release(ref.bookmarkData, .success(saved))
        await completion.value
        let failed = Task { try await store.reconnect(ref.id, to: URL(fileURLWithPath: "/tmp/unused")) }
        await eventually { await io.hasSelected() }
        await io.releaseSelected(.failure(CancellationError()))
        _ = try? await failed.value
        XCTAssertTrue(store.canUndoCompletion(in: ref.id))
        let reconnect = Task { try await store.reconnect(ref.id, to: URL(fileURLWithPath: "/tmp/unused")) }
        await eventually { await io.hasSelected() }
        await io.releaseSelected(.success(saved))
        _ = try await reconnect.value
        XCTAssertFalse(store.canUndoCompletion(in: ref.id))
        XCTAssertNil(store.undoExpiration(in: ref.id))
        await store.undoCompletion(in: ref.id)
        let replacedCount = await writer.undoCount()
        XCTAssertEqual(replacedCount, 0)
        await eventually { await io.count(Data([99])) == 1 }
        await io.release(Data([99]), .success(saved))
    }
}
