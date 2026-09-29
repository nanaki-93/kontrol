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
        func coordinate(_ target: URL, _ body: (URL) throws -> FeatureMutationReceipt) throws -> FeatureMutationReceipt {
            try body(relocate ? target.deletingLastPathComponent() : target)
        }
    }
    private final class IO: FeatureWriteIO {
        var before: (() -> Void)?
        var verify: (() -> Void)?
        func create(_ parent: Int32, _ name: String) -> Int32 {
            openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
        func flush(_ fd: Int32) -> Int32 { fsync(fd) }
        func replace(_ parent: Int32, _ temporary: String, _ target: String) -> Int32 {
            renameat(parent, temporary, parent, target)
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
