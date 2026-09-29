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
}
