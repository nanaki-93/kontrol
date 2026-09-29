import Foundation
import XCTest
@testable import Kontrol

private actor CompletionInspector: ProjectInspecting {
    private var waiting: [(Data, CheckedContinuation<ProjectInspection, Error>)] = []
    private var selected: CheckedContinuation<ProjectInspection, Error>?
    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        try await withCheckedThrowingContinuation { selected = $0 }
    }
    func hasSelected() -> Bool { selected != nil }
    func releaseSelected() { selected?.resume(throwing: CancellationError()); selected = nil }
    func makeBookmark(selectedFolder: URL) async throws -> Data { Data() }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        try await withCheckedThrowingContinuation { waiting.append((bookmarkData, $0)) }
    }
    func count(_ bookmark: Data) -> Int { waiting.filter { $0.0 == bookmark }.count }
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
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        requests.append(request)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        throw FeatureMutationFailure.undoConflict
    }
    func count() -> Int { requests.count }
    func request(_ index: Int) -> FeatureCompletionRequest { requests[index] }
    func fail(_ failure: FeatureMutationFailure = .conflict) {
        waiting.removeFirst().resume(throwing: failure)
    }
    func succeed() {
        let request = requests[requests.count - waiting.count]
        waiting.removeFirst().resume(returning: FeatureMutationReceipt(projectID: request.reference.id,
            grantBookmarkData: request.reference.bookmarkData, featureID: request.featureID,
            verifiedSource: request.source, inverse: FeatureInversePatch(relativePath: request.source.relativePath,
                originalSHA256: request.source.sha256, completedSHA256: request.source.sha256, edits: [])))
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
    func fetchAll() throws -> [ProjectReferenceSnapshot] { references }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot { throw ProjectStoreError.busy }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot { throw ProjectStoreError.busy }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID, nameHint: String,
                              readAt: Date) throws -> ProjectReferenceSnapshot {
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
        await other.value
        XCTAssertEqual(store.rows[1].completion, .saved("ready"))
        XCTAssertEqual(store.rows[1].inspection, initial)
        XCTAssertFalse(store.canMarkComplete("ready", in: peer.id), "Saved, not yet reconciled")
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
}
