import Darwin
import Foundation
import XCTest
@testable import Kontrol

final class ProjectFileReaderTests: XCTestCase {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".kontrol/features"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try Data("schema_version: 1\r\nid: test\r\nname: Test\r\n".utf8)
            .write(to: folder.appendingPathComponent(".kontrol/project.yaml"))
        return folder
    }

    private func path(_ folder: URL, _ name: String) -> URL {
        folder.appendingPathComponent(".kontrol/" + name)
    }

    private func codes(_ result: ProjectFileRead, _ path: String) -> [ProjectDiagnosticCode] {
        result.diagnostics.filter { $0.relativePath == path }.map(\.code)
    }

    func testOnlyAllowlistedDirectFilesAreReadInStableOrderAndNeverModified() throws {
        let root = try fixture()
        let original = try Data(contentsOf: path(root, "project.yaml"))
        try Data("notes".utf8).write(to: path(root, "context.md"))
        try Data("history".utf8).write(to: path(root, "history.yaml"))
        for name in ["z.md", "a.md", "ignore.txt"] {
            try Data(name.utf8).write(to: path(root, "features/" + name))
        }
        try FileManager.default.createDirectory(at: path(root, "features/nested"), withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: path(root, "features/nested/hidden.md"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("not-allowed.md"))
        let read = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(read.sources.map(\.relativePath), [".kontrol/project.yaml", ".kontrol/context.md",
                                                         ".kontrol/history.yaml", ".kontrol/features/a.md",
                                                         ".kontrol/features/z.md"])
        XCTAssertEqual(read.featureEnumeration, .complete)
        XCTAssertTrue(read.diagnostics.isEmpty)
        XCTAssertEqual(read.sources[0].bytes, original)
        XCTAssertEqual(try Data(contentsOf: path(root, "project.yaml")), original)
        if case .absent = read.roadmap {} else { XCTFail("roadmap should be absent") }
    }

    func testMissingRequiredAndOptionalVersusUnreadableOrInvalidEncoding() throws {
        let root = try fixture()
        try FileManager.default.removeItem(at: path(root, "project.yaml"))
        var result = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(result, ".kontrol/project.yaml"), [.missingManifest])
        if case .absent = result.context {} else { XCTFail("missing optional") }
        try Data([0xff]).write(to: path(root, "context.md"))
        result = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(result, ".kontrol/context.md"), [.invalidUTF8])
        if case .failed = result.context {} else { XCTFail("invalid UTF-8 is not absence") }
        try FileManager.default.createDirectory(at: path(root, "rules.md"), withIntermediateDirectories: false)
        result = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(result, ".kontrol/rules.md"), [.unsafeEntry])
        if case .failed = result.rules {} else { XCTFail("nonregular optional is not absence") }
        let unreadable = path(root, "history.yaml")
        try Data("history".utf8).write(to: unreadable)
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        defer { _ = chmod(unreadable.path, S_IRUSR | S_IWUSR) }
        result = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(result, ".kontrol/history.yaml"), [.unreadableFile])
        if case .failed = result.history {} else { XCTFail("unreadable optional is not absence") }
    }

    func testSymlinksAndNonregularFeatureEntriesNeverFollowOutsideRoot() throws {
        let root = try fixture()
        let outside = root.appendingPathComponent("outside")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.removeItem(at: path(root, "project.yaml"))
        try FileManager.default.createSymbolicLink(at: path(root, "project.yaml"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: path(root, "features/escape.md"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: path(root, "features/dir.md"), withIntermediateDirectories: false)
        let result = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(result, ".kontrol/project.yaml"), [.unsafeEntry])
        XCTAssertEqual(codes(result, ".kontrol/features/escape.md"), [.unsafeEntry])
        XCTAssertEqual(codes(result, ".kontrol/features/dir.md"), [.unsafeEntry])
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.featureEnumeration, .complete) // Enumerated successfully; files excluded.
        XCTAssertEqual(try Data(contentsOf: outside), Data("secret".utf8))
        try FileManager.default.removeItem(at: path(root, "features"))
        try FileManager.default.createSymbolicLink(at: path(root, "features"), withDestinationURL: root)
        let unsafe = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(unsafe.featureEnumeration, .failed)
        XCTAssertEqual(codes(unsafe, ".kontrol/features"), [.unsafeEntry])
        try FileManager.default.removeItem(at: path(root, "features"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".kontrol"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".kontrol"), withDestinationURL: root)
        let intermediate = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(intermediate, ".kontrol"), [.unsafeEntry])
        XCTAssertEqual(intermediate.featureEnumeration, .failed)
    }

    func testLimitsAreDiagnosticsNotTruncationOrEmptySuccess() throws {
        let root = try fixture()
        try Data(repeating: 65, count: ProjectFileReader.fileLimit + 1).write(to: path(root, "context.md"))
        var read = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(read, ".kontrol/context.md"), [.sizeLimit])
        XCTAssertFalse(read.sources.contains { $0.relativePath == ".kontrol/context.md" })
        for index in 0...ProjectFileReader.featureLimit {
            try Data().write(to: path(root, "features/\(index).md"))
        }
        read = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(codes(read, ".kontrol/features"), [.sizeLimit])
        XCTAssertEqual(read.featureEnumeration, .failed)
        XCTAssertTrue(read.features.isEmpty)
        // 16 MiB total with individually valid files.
        for index in 0...ProjectFileReader.featureLimit {
            try FileManager.default.removeItem(at: path(root, "features/\(index).md"))
        }
        for index in 0..<17 {
            try Data(repeating: 66, count: ProjectFileReader.fileLimit)
                .write(to: path(root, "features/\(index).md"))
        }
        read = try ProjectFileReader().read(folder: root)
        XCTAssertTrue(read.diagnostics.contains { $0.code == .sizeLimit && $0.relativePath.hasSuffix(".md") })
        XCTAssertEqual(read.features.count, 15) // manifest and feature files share the 16 MiB budget.
    }

    func testFeatureEnumerationStopsAtFirstExcessMatchWithoutReadingFiles() throws {
        let root = try fixture()
        let original = try Data(contentsOf: path(root, "project.yaml"))
        let featureCount = ProjectFileReader.featureLimit + 32
        for index in 0..<featureCount {
            try Data("untouched".utf8).write(to: path(root, "features/\(index).md"))
        }
        var visited = 0
        let reader = ProjectFileReader(onFeatureEntry: { _ in visited += 1 })
        let result = try reader.read(folder: root)
        XCTAssertEqual(visited, ProjectFileReader.featureLimit + 1,
                       "enumeration must stop at the first over-limit Markdown entry")
        XCTAssertEqual(codes(result, ".kontrol/features"), [.sizeLimit])
        XCTAssertEqual(result.featureEnumeration, .failed)
        XCTAssertTrue(result.features.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path(root, "project.yaml")), original)
        XCTAssertEqual(try Data(contentsOf: path(root, "features/0.md")), Data("untouched".utf8))
    }

    func testChangedFileAndSubstitutionAreRejectedAfterOpening() throws {
        let root = try fixture()
        let original = try Data(contentsOf: path(root, "project.yaml"))
        let edited = ProjectFileReader(beforeVerification: { name in
            if name == ".kontrol/project.yaml" {
                try? Data("changed".utf8).write(to: self.path(root, "project.yaml"))
            }
        })
        let result = try edited.read(folder: root)
        XCTAssertEqual(codes(result, ".kontrol/project.yaml"), [.changedDuringRead])
        if case .failed = result.manifest {} else { XCTFail("changed manifest cannot be trusted") }
        try original.write(to: path(root, "project.yaml"))
        let replacement = ProjectFileReader(beforeVerification: { name in
            if name == ".kontrol/features/a.md" {
                try? FileManager.default.removeItem(at: self.path(root, "features/a.md"))
                try? FileManager.default.createSymbolicLink(at: self.path(root, "features/a.md"),
                                                             withDestinationURL: root.appendingPathComponent("outside"))
            }
        })
        try Data("good".utf8).write(to: path(root, "features/a.md"))
        let changed = try replacement.read(folder: root)
        XCTAssertEqual(codes(changed, ".kontrol/features/a.md"), [.changedDuringRead])
        XCTAssertEqual(changed.featureEnumeration, .failed)
        XCTAssertTrue(changed.features.isEmpty)
    }

    func testIntermediateDirectorySubstitutionDuringVerificationInvalidatesSources() throws {
        let root = try fixture()
        try Data("original".utf8).write(to: path(root, "features/a.md"))
        let reader = ProjectFileReader(beforeVerification: { name in
            if name == ".kontrol/project.yaml" {
                try? FileManager.default.moveItem(at: self.path(root, "features"),
                                                  to: self.path(root, "old-features"))
                try? FileManager.default.createSymbolicLink(at: self.path(root, "features"),
                                                             withDestinationURL: root)
            }
        })
        let result = try reader.read(folder: root)
        XCTAssertEqual(result.featureEnumeration, .failed)
        XCTAssertTrue(result.features.isEmpty)
        XCTAssertTrue(codes(result, ".kontrol/features").contains(.changedDuringRead))
        XCTAssertEqual(try Data(contentsOf: path(root, "old-features/a.md")), Data("original".utf8))
    }

    func testMissingFeaturesDirectoryAndMissingKontrolAreNotFabricatedReads() throws {
        let root = try fixture()
        try FileManager.default.removeItem(at: path(root, "features"))
        let empty = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(empty.featureEnumeration, .complete)
        XCTAssertTrue(empty.features.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".kontrol"))
        let missing = try ProjectFileReader().read(folder: root)
        XCTAssertEqual(missing.featureEnumeration, .failed)
        XCTAssertEqual(codes(missing, ".kontrol/project.yaml"), [.missingManifest])
    }

    func testInspectorSelectedAndBookmarkUseScopedReadsAndReleaseOnFailure() async throws {
        let root = try fixture()
        let grant = InspectorGrant(root: root)
        let inspector = ProjectInspector(access: ProjectFolderAccess(operations: grant))
        let selected = try await inspector.inspect(selectedFolder: root)
        XCTAssertTrue(ProjectInspector.canAdd(selected))
        XCTAssertEqual(selected.featureCount, .complete(completed: 0, total: 0))
        let bookmarked = try await inspector.inspect(bookmarkData: Data([7]))
        XCTAssertEqual(bookmarked.manifest, selected.manifest)
        XCTAssertEqual(grant.starts, 2)
        XCTAssertEqual(grant.stops, 2)
        let bookmark = try await inspector.makeBookmark(selectedFolder: root)
        XCTAssertEqual(bookmark, Data([7]))
        XCTAssertEqual(grant.starts, 3)
        XCTAssertEqual(grant.stops, 3)
        grant.stale = true
        do {
            _ = try await inspector.inspect(bookmarkData: Data([7]))
            XCTFail("stale bookmark must not read")
        } catch let failure as ProjectInspectionFailure {
            XCTAssertEqual(failure, .access(.staleBookmark))
            XCTAssertEqual(failure.recovery, .reconnect)
        }
        XCTAssertEqual(grant.starts, 3)
        grant.stale = false
        grant.allowed = false
        do {
            _ = try await inspector.inspect(bookmarkData: Data([7]))
            XCTFail("revoked access must not read")
        } catch let failure as ProjectInspectionFailure {
            XCTAssertEqual(failure, .access(.accessDenied))
        }
        do {
            _ = try await inspector.inspect(selectedFolder: root)
            XCTFail("denied selection must not read")
        } catch let failure as ProjectInspectionFailure {
            XCTAssertEqual(failure.recovery, .reselectFolder)
        }
        XCTAssertEqual(grant.stops, 3)
    }

    func testInspectorMissingRequiredOptionalFailuresAndUnsupportedAreDistinct() async throws {
        let root = try fixture()
        let inspector = ProjectInspector(access: ProjectFolderAccess(operations: InspectorGrant(root: root)))
        try FileManager.default.removeItem(at: path(root, "project.yaml"))
        var snapshot = try await inspector.inspect(selectedFolder: root)
        XCTAssertFalse(ProjectInspector.canAdd(snapshot))
        XCTAssertNil(snapshot.manifest)
        XCTAssertEqual(snapshot.featureCount, .unavailable)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .missingManifest })
        try Data("schema_version: 1\nid: demo\nname: Demo\n".utf8).write(to: path(root, "project.yaml"))
        try Data("notes\r\n".utf8).write(to: path(root, "context.md"))
        try Data("rules".utf8).write(to: path(root, "rules.md"))
        try Data("status: completed".utf8).write(to: path(root, "history.yaml"))
        snapshot = try await inspector.inspect(selectedFolder: root)
        XCTAssertTrue(ProjectInspector.canAdd(snapshot))
        XCTAssertEqual(snapshot.featureCount, .complete(completed: 0, total: 0))
        if case let .present(notes) = snapshot.context { XCTAssertEqual(notes.bytes, Data("notes\r\n".utf8)) }
        else { XCTFail("context missing") }
        try Data([0xff]).write(to: path(root, "rules.md"))
        snapshot = try await inspector.inspect(selectedFolder: root)
        XCTAssertFalse(ProjectInspector.canAdd(snapshot))
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .invalidUTF8 && $0.relativePath == ".kontrol/rules.md" })
        if case .failed = snapshot.rules {} else { XCTFail("unreadable optional is not absent") }
        try Data("schema_version: 9\nid: future\nname: Future\n".utf8).write(to: path(root, "project.yaml"))
        snapshot = try await inspector.inspect(selectedFolder: root)
        XCTAssertNil(snapshot.manifest)
        XCTAssertEqual(snapshot.featureCount, .unavailable)
        XCTAssertFalse(ProjectInspector.canAdd(snapshot))
        XCTAssertEqual(snapshot.sources.first?.text, "schema_version: 9\nid: future\nname: Future\n")
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .unsupportedVersion && $0.recovery == .upgradeSource })
    }

    func testInspectorExcludesUnreadableFeatureWithoutClaimingCompleteCount() async throws {
        let root = try fixture()
        let grant = InspectorGrant(root: root)
        let healthy = "---\nid: healthy\ntitle: Healthy\nstatus: completed\npriority: high\neffort: small\n---\n"
        try Data(healthy.utf8).write(to: path(root, "features/healthy.md"))
        let bad = path(root, "features/bad.md")
        try Data(healthy.utf8).write(to: bad)
        XCTAssertEqual(chmod(bad.path, 0), 0)
        defer { _ = chmod(bad.path, S_IRUSR | S_IWUSR) }
        let snapshot = try await ProjectInspector(access: ProjectFolderAccess(operations: grant))
            .inspect(selectedFolder: root)
        XCTAssertEqual(snapshot.featureCount, .partial(completed: 1, total: 1, excludedFiles: 1))
        XCTAssertEqual(snapshot.excludedFeaturePaths, [".kontrol/features/bad.md"])
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .unreadableFile && $0.relativePath == ".kontrol/features/bad.md" })
        XCTAssertFalse(ProjectInspector.canAdd(snapshot))
        XCTAssertEqual(grant.starts, grant.stops)
    }

    func testInspectorDoesNotPromoteChangedReadAndPropagatesCancellation() async throws {
        let root = try fixture()
        let grant = InspectorGrant(root: root)
        let changed = ProjectFileReader(beforeVerification: { path in
            if path == ".kontrol/project.yaml" {
                try? Data("changed".utf8).write(to: self.path(root, "project.yaml"))
            }
        })
        do {
            _ = try await ProjectInspector(access: ProjectFolderAccess(operations: grant), reader: changed)
                .inspect(selectedFolder: root)
            XCTFail("inconsistent read must be retryable failure")
        } catch let failure as ProjectInspectionFailure {
            XCTAssertEqual(failure, .inconsistentRead)
            XCTAssertEqual(failure.recovery, .refresh)
        }
        XCTAssertEqual(grant.starts, grant.stops)
        let duringRead = ProjectInspector(access: ProjectFolderAccess(operations: grant),
                                          reader: CancellingProjectReader())
        do {
            _ = try await duringRead.inspect(selectedFolder: root)
            XCTFail("cancellation during IO must not publish a snapshot")
        } catch is CancellationError {}
        XCTAssertEqual(grant.starts, grant.stops)
        let task = Task { () -> ProjectInspection in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProjectInspector(access: ProjectFolderAccess(operations: grant)).inspect(selectedFolder: root)
        }
        do { _ = try await task.value; XCTFail("cancelled inspection returned") }
        catch is CancellationError {}
    }
}

private struct CancellingProjectReader: ProjectFileReading {
    func read(folder: URL) throws -> ProjectFileRead {
        withUnsafeCurrentTask { $0?.cancel() }
        return try ProjectFileReader().read(folder: folder)
    }
}

private final class InspectorGrant: ProjectBookmarkOperations {
    let root: URL
    var starts = 0
    var stops = 0
    var stale = false
    var allowed = true
    init(root: URL) { self.root = root }
    func resolve(_ data: Data) throws -> (folder: URL, isStale: Bool) { (root, stale) }
    func createBookmark(for selectedFolder: URL) throws -> Data { Data([7]) }
    func startAccessing(_ folder: URL) -> Bool {
        guard allowed else { return false }
        starts += 1
        return true
    }
    func stopAccessing(_ folder: URL) { stops += 1 }
}
