import Darwin
import Foundation
import XCTest
@testable import Kontrol

final class FeatureFileWriterTests: XCTestCase {
    private final class Grant: ProjectBookmarkOperations {
        let root: URL
        var stale = false
        var allowed = true
        var starts = 0
        var stops = 0
        init(_ root: URL) { self.root = root }
        func resolve(_ data: Data) throws -> (folder: URL, isStale: Bool) { (root, stale) }
        func createBookmark(for selectedFolder: URL) throws -> Data { Data([1]) }
        func startAccessing(_ folder: URL) -> Bool { starts += 1; return allowed }
        func stopAccessing(_ folder: URL) { stops += 1 }
    }
    private struct Coordinator: FeatureWriteCoordinating {
        var relocate = false
        var fail = false
        var failAfterBody = false
        func coordinate(_ target: URL, _ body: (URL) throws -> FeatureMutationReceipt) throws -> FeatureMutationReceipt {
            if fail { throw NSError(domain: "injected", code: 1) }
            let receipt = try body(relocate ? target.deletingLastPathComponent() : target)
            if failAfterBody { throw NSError(domain: "injected", code: 2) }
            return receipt
        }
    }
    private final class IO: FeatureWriteIO {
        var before: (() -> Void)?
        var verify: (() -> Void)?
        var failCreate = false
        var failWrite = false
        var diskFull = false
        var failFlush = false
        var failReplace = false
        var replaceThenFail = false
        var shortWrite = false
        var writes = 0
        func create(_ parent: Int32, _ name: String) -> Int32 {
            if failCreate { errno = EACCES; return -1 }
            return openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
            writes += 1
            if diskFull && writes > 1 { errno = ENOSPC; return -1 }
            if failWrite && writes > 1 { errno = EIO; return -1 }
            return Darwin.write(fd, buffer, shortWrite ? min(count, 3) : count)
        }
        func flush(_ fd: Int32) -> Int32 {
            if failFlush { errno = EIO; return -1 }
            return fsync(fd)
        }
        func replace(_ parent: Int32, _ temporary: String, _ target: String) -> Int32 {
            if failReplace { errno = EIO; return -1 }
            let result = renameat(parent, temporary, parent, target)
            if replaceThenFail { errno = EIO; return -1 }
            return result
        }
        func beforeReplacement() { before?() }
        func beforeVerification() { verify?() }
    }
    private let original = "---\nid: feature-a\ntitle: Feature A\nstatus: 'ready' # unchanged\npriority: high\neffort: small\nunknown: retained\n---\n# Body\nstatus: ready\n"

    private func fixture() throws -> (URL, Grant, ProjectReferenceSnapshot, ProjectSourceDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent(".kontrol/features")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("schema_version: 1\nid: project-a\nname: Project A\n".utf8)
            .write(to: root.appendingPathComponent(".kontrol/project.yaml"))
        try Data(original.utf8).write(to: dir.appendingPathComponent("feature.md"))
        let grant = Grant(root)
        let reference = ProjectReferenceSnapshot(id: UUID(), manifestID: "project-a", bookmarkData: Data([1]),
                                                 displayOrder: 0, displayNameHint: "Project A",
                                                 lastSuccessfulReadAt: nil, revision: UUID())
        return (root, grant, reference,
                ProjectSourceDocument(relativePath: ".kontrol/features/feature.md", bytes: Data(original.utf8)))
    }
    private func request(_ ref: ProjectReferenceSnapshot, _ source: ProjectSourceDocument,
                         id: String = "feature-a") -> FeatureCompletionRequest {
        FeatureCompletionRequest(reference: ref, featureID: id, source: source,
                                 completedAt: Date(timeIntervalSince1970: 1_780_000_000))
    }
    private func writer(_ grant: Grant, coordinator: any FeatureWriteCoordinating = Coordinator(),
                        io: any FeatureWriteIO = SystemFeatureWriteIO()) -> FeatureFileWriter {
        FeatureFileWriter(access: ProjectFolderAccess(operations: grant), coordinator: coordinator, io: io)
    }
    private func assertFailure(_ expected: FeatureMutationFailure, _ body: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as FeatureMutationFailure { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected failure \(type(of: error))", file: file, line: line) }
    }
    func testRealWriteMinimalDiffMetadataDigestAndScope() async throws {
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        XCTAssertEqual(chmod(target.path, 0o640), 0)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        let receipt = try await writer(grant).complete(request(ref, source))
        let actual = try Data(contentsOf: target)
        XCTAssertEqual(receipt.verifiedSource.bytes, actual)
        XCTAssertEqual(receipt.verifiedSHA256, ProjectSourceDocument(relativePath: source.relativePath, bytes: actual).sha256)
        XCTAssertEqual(String(decoding: actual, as: UTF8.self),
                       original.replacingOccurrences(of: "status: 'ready'", with: "status: 'completed'")
                        .replacingOccurrences(of: "---\n# Body", with: "completed_at: \"2026-05-28T20:26:40Z\"\n---\n# Body"))
        guard case let .supported(feature) = try ManifestParser().feature(receipt.verifiedSource) else {
            return XCTFail("Patched file must parse")
        }
        XCTAssertEqual(feature.status, .completed)
        XCTAssertNotNil(feature.completedAt)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber, mode)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
        XCTAssertEqual(grant.starts, 1)
        XCTAssertEqual(grant.stops, 1)
    }
    func testInvalidPathsAndRelocatedCoordinatorNeverWrite() async throws {
        let (root, grant, ref, source) = try fixture()
        for path in ["/tmp/x.md", ".kontrol/features/../x.md", ".kontrol/features/nested/a.md",
                     ".kontrol/features/a.md/", ".kontrol/features/.md"] {
            let invalid = ProjectSourceDocument(relativePath: path, bytes: source.bytes)
            await assertFailure(.unsafePath) { _ = try await writer(grant).complete(request(ref, invalid)) }
        }
        await assertFailure(.unsafePath) {
            _ = try await writer(grant, coordinator: Coordinator(relocate: true)).complete(request(ref, source))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source.relativePath)), source.bytes)
    }
    func testConflictsAndManifestIdentityLeaveSourceUntouched() async throws {
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        try Data(original.replacingOccurrences(of: "unknown: retained", with: "unknown: external").utf8).write(to: target)
        let external = try Data(contentsOf: target)
        await assertFailure(.conflict) { _ = try await writer(grant).complete(request(ref, source)) }
        XCTAssertEqual(try Data(contentsOf: target), external)
        try source.bytes.write(to: target)
        await assertFailure(.changedIdentity) { _ = try await writer(grant).complete(request(ref, source, id: "other")) }
        let manifest = root.appendingPathComponent(".kontrol/project.yaml")
        try Data("schema_version: 1\nid: other\nname: Other\n".utf8).write(to: manifest)
        await assertFailure(.manifestMismatch) { _ = try await writer(grant).complete(request(ref, source)) }
        XCTAssertEqual(try Data(contentsOf: target), source.bytes)
    }
    func testUnsafeEntriesAndSubstitutedDirectoryNeverWriteOutsideRoot() async throws {
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        let outside = root.appendingPathComponent("outside.md")
        try source.bytes.write(to: outside)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        await assertFailure(.unsafePath) { _ = try await writer(grant).complete(request(ref, source)) }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        await assertFailure(.unsafePath) { _ = try await writer(grant).complete(request(ref, source)) }
        try FileManager.default.removeItem(at: target)
        try source.bytes.write(to: target)
        let features = target.deletingLastPathComponent()
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: features, to: moved)
        try FileManager.default.createSymbolicLink(at: features, withDestinationURL: moved)
        await assertFailure(.unsafePath) { _ = try await writer(grant).complete(request(ref, source)) }
        try FileManager.default.removeItem(at: features)
        try FileManager.default.moveItem(at: moved, to: features)
        let kontrol = root.appendingPathComponent(".kontrol")
        try FileManager.default.moveItem(at: kontrol, to: moved)
        try FileManager.default.createSymbolicLink(at: kontrol, withDestinationURL: moved)
        await assertFailure(.unsafePath) { _ = try await writer(grant).complete(request(ref, source)) }
        XCTAssertEqual(try Data(contentsOf: outside), source.bytes)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("features/feature.md")), source.bytes)
    }
    func testCurrentFeatureIdentityAndStateAreRecheckedEvenForMatchingDigest() async throws {
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        for (changed, expected) in [
            (original.replacingOccurrences(of: "id: feature-a", with: "id: another"), FeatureMutationFailure.changedIdentity),
            (original.replacingOccurrences(of: "status: 'ready'", with: "status: 'completed'"), .unpatchableSource)
        ] {
            let bytes = Data(changed.utf8)
            try bytes.write(to: target)
            let inspected = ProjectSourceDocument(relativePath: source.relativePath, bytes: bytes)
            await assertFailure(expected) {
                _ = try await writer(grant).complete(request(ref, inspected))
            }
            XCTAssertEqual(try Data(contentsOf: target), bytes)
        }
    }
    func testTargetReplacementRacePreservesExternalRevisionAndCleansTemp() async throws {
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        let external = Data(original.replacingOccurrences(of: "unknown: retained", with: "unknown: editor").utf8)
        let io = IO()
        io.before = { try? external.write(to: target) }
        await assertFailure(.changedIdentity) { _ = try await writer(grant, io: io).complete(request(ref, source)) }
        XCTAssertEqual(try Data(contentsOf: target), external)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
    }
    func testManifestSubstitutionImmediatelyBeforeReplaceRefusesMutation() async throws {
        let (root, grant, ref, source) = try fixture()
        let manifest = root.appendingPathComponent(".kontrol/project.yaml")
        let io = IO()
        io.before = {
            try? Data("schema_version: 1\nid: other\nname: Other\n".utf8).write(to: manifest)
        }
        await assertFailure(.changedIdentity) { _ = try await writer(grant, io: io).complete(request(ref, source)) }
        let target = root.appendingPathComponent(source.relativePath)
        XCTAssertEqual(try Data(contentsOf: target), source.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
    }
    func testInjectedPreCommitFailuresLeaveExactBytesAndNoOwnedTemp() async throws {
        for (expected, configure) in [
            (FeatureMutationFailure.temporaryFileFailed, { (io: IO) in io.failCreate = true }),
            (.temporaryWriteFailed, { (io: IO) in io.failWrite = true; io.shortWrite = true }),
            (.diskFull, { (io: IO) in io.diskFull = true; io.shortWrite = true }),
            (.flushFailed, { (io: IO) in io.failFlush = true }),
        ] {
            let (root, grant, ref, source) = try fixture()
            let io = IO()
            configure(io)
            await assertFailure(expected) { _ = try await writer(grant, io: io).complete(request(ref, source)) }
            let target = root.appendingPathComponent(source.relativePath)
            XCTAssertEqual(try Data(contentsOf: target), source.bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
            XCTAssertEqual(grant.starts, grant.stops)
        }
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        await assertFailure(.coordinationFailed) {
            _ = try await writer(grant, coordinator: Coordinator(fail: true)).complete(request(ref, source))
        }
        XCTAssertEqual(try Data(contentsOf: target), source.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
    }
    func testShortWritesCompleteAndAmbiguousReplacementNeverIssuesReceipt() async throws {
        let (root, grant, ref, source) = try fixture()
        let io = IO()
        io.shortWrite = true
        let receipt = try await writer(grant, io: io).complete(request(ref, source))
        XCTAssertGreaterThan(io.writes, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source.relativePath)), receipt.verifiedSource.bytes)
        for afterRename in [false, true] {
            let (root, grant, ref, source) = try fixture()
            let io = IO()
            io.failReplace = !afterRename
            io.replaceThenFail = afterRename
            await assertFailure(.unverifiedWrite) { _ = try await writer(grant, io: io).complete(request(ref, source)) }
            let target = root.appendingPathComponent(source.relativePath)
            XCTAssertEqual(try Data(contentsOf: target), afterRename ? receipt.verifiedSource.bytes : source.bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
        }
    }
    func testVerificationMismatchAndReadFailureAreUnverifiedWithoutCompensation() async throws {
        for remove in [false, true] {
            let (root, grant, ref, source) = try fixture()
            let target = root.appendingPathComponent(source.relativePath)
            let external = Data("external editor\n".utf8)
            let io = IO()
            io.verify = {
                if remove { try? FileManager.default.removeItem(at: target) }
                else { try? external.write(to: target) }
            }
            await assertFailure(.unverifiedWrite) { _ = try await writer(grant, io: io).complete(request(ref, source)) }
            if remove { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
            else { XCTAssertEqual(try Data(contentsOf: target), external) }
            XCTAssertEqual(grant.starts, grant.stops)
        }
    }
    func testCancellationBeforeAndAfterCommit() async throws {
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        let io = IO()
        let operation = Task {
            await assertFailure(.canceled) { _ = try await writer(grant, io: io).complete(request(ref, source)) }
        }
        io.before = { operation.cancel() }
        await operation.value
        XCTAssertEqual(try Data(contentsOf: target), source.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])

        let (root2, grant2, ref2, source2) = try fixture()
        let io2 = IO()
        let committed = Task { try await writer(grant2, io: io2).complete(request(ref2, source2)) }
        io2.verify = { committed.cancel() }
        let receipt = try await committed.value
        XCTAssertEqual(try Data(contentsOf: root2.appendingPathComponent(source2.relativePath)), receipt.verifiedSource.bytes)
    }
    func testCoordinatorFailureAfterBodyCannotReturnVerifiedReceipt() async throws {
        let (_, grant, ref, source) = try fixture()
        await assertFailure(.unverifiedWrite) {
            _ = try await writer(grant, coordinator: Coordinator(failAfterBody: true)).complete(request(ref, source))
        }
        XCTAssertEqual(grant.starts, grant.stops)
    }
    func testUndoRestoresLexicalBytesPermissionsAndLeavesNoArtifact() async throws {
        let (root, grant, ref, source) = try fixture()
        let target = root.appendingPathComponent(source.relativePath)
        let originalWithDate = Data(original.replacingOccurrences(of: "unknown: retained",
            with: "completed_at: null # preserve\nunknown: retained").utf8)
        try originalWithDate.write(to: target)
        XCTAssertEqual(chmod(target.path, 0o640), 0)
        let inspected = ProjectSourceDocument(relativePath: source.relativePath, bytes: originalWithDate)
        let service = writer(grant)
        let completion = try await service.complete(request(ref, inspected))
        let undo = try await service.undo(FeatureUndoRequest(reference: ref, receipt: completion))
        XCTAssertEqual(undo.verifiedSource.bytes, originalWithDate)
        XCTAssertEqual(undo.verifiedSHA256, inspected.sha256)
        XCTAssertEqual(try Data(contentsOf: target), originalWithDate)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
        XCTAssertEqual(grant.starts, 2)
        XCTAssertEqual(grant.stops, 2)
    }
    func testUndoExternalEditConflictsBeforeCreatingTemporaryFile() async throws {
        let (root, grant, ref, source) = try fixture()
        let service = writer(grant)
        let receipt = try await service.complete(request(ref, source))
        let target = root.appendingPathComponent(source.relativePath)
        let external = Data(String(decoding: receipt.verifiedSource.bytes, as: UTF8.self)
            .replacingOccurrences(of: "unknown: retained", with: "unknown: external").utf8)
        try external.write(to: target)
        let io = IO()
        io.failCreate = true // Digest mismatch must precede even an attempted temp creation.
        await assertFailure(.undoConflict) {
            _ = try await writer(grant, io: io).undo(FeatureUndoRequest(reference: ref, receipt: receipt))
        }
        XCTAssertEqual(try Data(contentsOf: target), external)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
    }
    func testUndoIdentityAuthorizationAndCoordinatorGuards() async throws {
        let (root, grant, ref, source) = try fixture()
        let receipt = try await writer(grant).complete(request(ref, source))
        let target = root.appendingPathComponent(source.relativePath)
        let otherRef = ProjectReferenceSnapshot(id: UUID(), manifestID: ref.manifestID,
            bookmarkData: ref.bookmarkData, displayOrder: 0, displayNameHint: "Other",
            lastSuccessfulReadAt: nil, revision: UUID())
        await assertFailure(.changedIdentity) {
            _ = try await writer(grant).undo(FeatureUndoRequest(reference: otherRef, receipt: receipt))
        }
        await assertFailure(.unsafePath) {
            _ = try await writer(grant, coordinator: Coordinator(relocate: true))
                .undo(FeatureUndoRequest(reference: ref, receipt: receipt))
        }
        grant.stale = true
        await assertFailure(.accessDenied) {
            _ = try await writer(grant).undo(FeatureUndoRequest(reference: ref, receipt: receipt))
        }
        grant.stale = false
        let manifest = root.appendingPathComponent(".kontrol/project.yaml")
        try Data("schema_version: 1\nid: other\nname: Other\n".utf8).write(to: manifest)
        await assertFailure(.manifestMismatch) {
            _ = try await writer(grant).undo(FeatureUndoRequest(reference: ref, receipt: receipt))
        }
        XCTAssertEqual(try Data(contentsOf: target), receipt.verifiedSource.bytes)
    }
    func testUndoRejectsReplacementGrantEvenWhenManifestAndFeatureBytesMatch() async throws {
        let (_, originalGrant, ref, source) = try fixture()
        let completion = try await writer(originalGrant).complete(request(ref, source))
        XCTAssertEqual(completion.grantBookmarkData, ref.bookmarkData)

        let (otherRoot, replacementGrant, _, _) = try fixture()
        let otherTarget = otherRoot.appendingPathComponent(source.relativePath)
        // A new folder has the same manifest ID and the exact completed revision.
        try completion.verifiedSource.bytes.write(to: otherTarget)
        let replacement = ProjectReferenceSnapshot(id: ref.id, manifestID: ref.manifestID,
            bookmarkData: Data([2]), displayOrder: ref.displayOrder, displayNameHint: ref.displayNameHint,
            lastSuccessfulReadAt: ref.lastSuccessfulReadAt, revision: UUID())
        await assertFailure(.changedIdentity) {
            _ = try await writer(replacementGrant).undo(FeatureUndoRequest(reference: replacement, receipt: completion))
        }
        XCTAssertEqual(replacementGrant.starts, 0) // Refuse before resolving or entering the new grant.
        XCTAssertEqual(try Data(contentsOf: otherTarget), completion.verifiedSource.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: otherTarget.deletingLastPathComponent().path), ["feature.md"])

        // Recording a successful read changes only metadata revision, not authorization.
        let refreshed = ProjectReferenceSnapshot(id: ref.id, manifestID: ref.manifestID,
            bookmarkData: ref.bookmarkData, displayOrder: ref.displayOrder, displayNameHint: ref.displayNameHint,
            lastSuccessfulReadAt: Date(), revision: UUID())
        let restored = try await writer(originalGrant).undo(FeatureUndoRequest(reference: refreshed, receipt: completion))
        XCTAssertEqual(restored.verifiedSource.bytes, source.bytes)
    }
    func testUndoInjectedFailuresAndRacesNeverReturnSuccessfulReceipt() async throws {
        for failure in ["create", "write", "flush", "replace", "race", "verify"] {
            let (root, grant, ref, source) = try fixture()
            let receipt = try await writer(grant).complete(request(ref, source))
            let target = root.appendingPathComponent(source.relativePath)
            let io = IO()
            switch failure {
            case "create": io.failCreate = true
            case "write": io.failWrite = true; io.shortWrite = true
            case "flush": io.failFlush = true
            case "replace": io.failReplace = true
            case "race": io.before = { try? Data("external editor\n".utf8).write(to: target) }
            default: io.verify = { try? Data("external editor\n".utf8).write(to: target) }
            }
            let expected: FeatureMutationFailure
            switch failure {
            case "create": expected = .temporaryFileFailed
            case "write": expected = .temporaryWriteFailed
            case "flush": expected = .flushFailed
            case "race": expected = .changedIdentity
            default: expected = .unverifiedWrite
            }
            await assertFailure(expected) {
                _ = try await writer(grant, io: io).undo(FeatureUndoRequest(reference: ref, receipt: receipt))
            }
            XCTAssertEqual(try Data(contentsOf: target),
                           ["race", "verify"].contains(failure) ? Data("external editor\n".utf8) : receipt.verifiedSource.bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
            XCTAssertEqual(grant.starts, grant.stops)
        }
    }
    func testUndoUnsafeTargetAndLateDirectorySubstitutionNeverWriteOutsideRoot() async throws {
        let (root, grant, ref, source) = try fixture()
        let receipt = try await writer(grant).complete(request(ref, source))
        let target = root.appendingPathComponent(source.relativePath)
        let outside = root.appendingPathComponent("outside.md")
        try receipt.verifiedSource.bytes.write(to: outside)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        await assertFailure(.unsafePath) {
            _ = try await writer(grant).undo(FeatureUndoRequest(reference: ref, receipt: receipt))
        }
        XCTAssertEqual(try Data(contentsOf: outside), receipt.verifiedSource.bytes)
        try FileManager.default.removeItem(at: target)
        try receipt.verifiedSource.bytes.write(to: target)
        let features = target.deletingLastPathComponent()
        let moved = root.appendingPathComponent("moved")
        let io = IO()
        io.before = {
            try? FileManager.default.moveItem(at: features, to: moved)
            try? FileManager.default.createSymbolicLink(at: features, withDestinationURL: moved)
        }
        await assertFailure(.changedIdentity) {
            _ = try await writer(grant, io: io).undo(FeatureUndoRequest(reference: ref, receipt: receipt))
        }
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("feature.md")), receipt.verifiedSource.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["feature.md"])
    }
    func testUndoCanceledBeforeCommitAndAfterCommitVerification() async throws {
        let (root, grant, ref, source) = try fixture()
        let receipt = try await writer(grant).complete(request(ref, source))
        let target = root.appendingPathComponent(source.relativePath)
        let io = IO()
        let operation = Task {
            await assertFailure(.canceled) {
                _ = try await writer(grant, io: io).undo(FeatureUndoRequest(reference: ref, receipt: receipt))
            }
        }
        io.before = { operation.cancel() }
        await operation.value
        XCTAssertEqual(try Data(contentsOf: target), receipt.verifiedSource.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["feature.md"])
        let io2 = IO()
        let committed = Task { try await writer(grant, io: io2).undo(FeatureUndoRequest(reference: ref, receipt: receipt)) }
        io2.verify = { committed.cancel() }
        let undo = try await committed.value
        XCTAssertEqual(undo.verifiedSource.bytes, source.bytes)
        XCTAssertEqual(try Data(contentsOf: target), source.bytes)
    }
    func testUndoCoordinatorFailureAfterReplacementIsNotVerified() async throws {
        let (root, grant, ref, source) = try fixture()
        let receipt = try await writer(grant).complete(request(ref, source))
        await assertFailure(.unverifiedWrite) {
            _ = try await writer(grant, coordinator: Coordinator(failAfterBody: true))
                .undo(FeatureUndoRequest(reference: ref, receipt: receipt))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source.relativePath)), source.bytes)
        XCTAssertEqual(grant.starts, grant.stops)
    }
    func testRevokedGrantAndSubstitutionBeforeReplace() async throws {
        let (root, grant, ref, source) = try fixture()
        grant.stale = true
        await assertFailure(.accessDenied) { _ = try await writer(grant).complete(request(ref, source)) }
        XCTAssertEqual(grant.starts, 0)
        grant.stale = false
        grant.allowed = false
        await assertFailure(.accessDenied) { _ = try await writer(grant).complete(request(ref, source)) }
        XCTAssertEqual(grant.stops, 0)
        grant.allowed = true
        let features = root.appendingPathComponent(".kontrol/features")
        let moved = root.appendingPathComponent("moved")
        let io = IO()
        io.before = {
            try? FileManager.default.moveItem(at: features, to: moved)
            try? FileManager.default.createSymbolicLink(at: features, withDestinationURL: moved)
        }
        await assertFailure(.changedIdentity) { _ = try await writer(grant, io: io).complete(request(ref, source)) }
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("feature.md")), source.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["feature.md"])
        XCTAssertEqual(grant.starts, 2)
        XCTAssertEqual(grant.stops, 1) // Denied entry never acquires a scope.
    }
}
