import Foundation
import XCTest
@testable import Kontrol

final class ProjectValidationTests: XCTestCase {
    private let manifest = ProjectManifest(schemaVersion: 1, id: "demo", name: "Demo",
                                           description: "", stack: [], goals: [], currentFocus: [])

    private func inspection(manifest: ProjectManifest? = nil,
                            features: [ProjectFeature] = [],
                            excluded: [String] = [],
                            enumeration: ProjectFeatureEnumeration = .complete) -> ProjectInspection {
        ProjectInspection(manifest: manifest, roadmap: .absent, features: features,
                          excludedFeaturePaths: excluded, featureEnumeration: enumeration,
                          context: .absent, rules: .absent, history: .absent,
                          diagnostics: [], sources: [], readAt: Date(timeIntervalSince1970: 42))
    }

    private func feature(_ id: String, status: ProjectFeatureStatus) -> ProjectFeature {
        ProjectFeature(id: id, title: id, status: status, priority: .medium,
                       effort: .small, dependsOn: [], areas: [], completedAt: nil,
                       body: "\nBody\r\n", sourcePath: ".kontrol/features/\(id).md")
    }

    private func feature(_ id: String, path: String, status: ProjectFeatureStatus = .planned,
                         dependencies: [String] = []) -> ProjectFeature {
        ProjectFeature(id: id, title: id, status: status, priority: .medium,
                       effort: .small, dependsOn: dependencies, areas: [], completedAt: nil,
                       body: "", sourcePath: ".kontrol/features/\(path).md")
    }

    func testAllIdentitiesPrecedeEdgesAndAmbiguousTargetsAreExcluded() {
        let result = ProjectValidator().validate([
            feature("downstream", path: "a", dependencies: ["middle"]),
            feature("middle", path: "b", dependencies: ["same"]),
            feature("same", path: "z"), feature("same", path: "c"),
            feature("independent", path: "healthy", status: .completed)
        ])
        XCTAssertEqual(result.features.map(\.id), ["independent"])
        XCTAssertEqual(result.excludedFeaturePaths, [".kontrol/features/a.md", ".kontrol/features/b.md",
                                                     ".kontrol/features/c.md", ".kontrol/features/z.md"])
        XCTAssertEqual(result.diagnostics.map(\.code), [.invalidDependency, .invalidDependency,
                                                         .duplicateID, .duplicateID])
        XCTAssertEqual(result.diagnostics.map(\.affectedIDs), [["downstream", "middle"],
                                                                ["middle", "same"], ["same"], ["same"]])
        let snapshot = inspection(manifest: manifest, features: result.features,
                                  excluded: result.excludedFeaturePaths)
        XCTAssertEqual(snapshot.featureCount, .partial(completed: 1, total: 1, excludedFiles: 4))
    }

    func testCyclesSelfAndMissingTargetsInvalidateOnlyTheirDependents() {
        let result = ProjectValidator().validate([
            feature("external", path: "a", dependencies: ["cycleA"]),
            feature("cycleA", path: "b", dependencies: ["cycleB"]),
            feature("cycleB", path: "c", dependencies: ["cycleA"]),
            feature("missing", path: "d", dependencies: ["unknown"]),
            feature("self", path: "e", dependencies: ["self"]),
            feature("afterMissing", path: "f", dependencies: ["missing"]),
            feature("valid", path: "g", status: .completed)
        ])
        XCTAssertEqual(result.features.map(\.id), ["valid"])
        XCTAssertEqual(result.diagnostics.map(\.code), [.invalidDependency, .cyclicDependency,
                                                         .cyclicDependency, .missingDependency,
                                                         .selfDependency, .invalidDependency])
        XCTAssertEqual(result.diagnostics[1].affectedIDs, ["cycleA", "cycleB"])
        XCTAssertEqual(result.diagnostics[2].affectedIDs, ["cycleA", "cycleB"])
        XCTAssertEqual(result.diagnostics[3].affectedIDs, ["missing", "unknown"])
        XCTAssertEqual(result.excludedFeaturePaths.count, 6)
    }

    func testParsedPeerFailurePreservesMetadataAndHistoryCannotChangeCounts() {
        let path = ".kontrol/features/broken.md"
        let parseError = ProjectDiagnostic(code: .invalidFrontmatter, severity: .error,
                                           relativePath: path, line: 2, column: 1, recovery: .editSource)
        let result = ProjectValidator().validate([feature("healthy", path: "healthy", status: .completed),
                                                  feature("dependent", path: "dependent", dependencies: ["unknown"])],
                                                 excludedPaths: [path, path], diagnostics: [parseError])
        let history = ProjectSourceDocument(relativePath: ".kontrol/history.yaml",
                                            bytes: Data("status: completed\n".utf8))
        let snapshot = ProjectInspection(manifest: manifest, roadmap: .absent, features: result.features,
                                         excludedFeaturePaths: result.excludedFeaturePaths,
                                         featureEnumeration: .complete, context: .absent, rules: .absent,
                                         history: .present(history), diagnostics: result.diagnostics,
                                         sources: [history], readAt: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(snapshot.manifest?.name, "Demo")
        XCTAssertEqual(snapshot.featureCount, .partial(completed: 1, total: 1, excludedFiles: 2))
        XCTAssertEqual(result.diagnostics.map(\.relativePath), [path, ".kontrol/features/dependent.md"])
        XCTAssertEqual(ProjectValidator().validate([]).excludedFeaturePaths, [])
        XCTAssertEqual(inspection(manifest: manifest, features: result.features,
                                  excluded: result.excludedFeaturePaths, enumeration: .failed).featureCount, .unavailable)
    }

    func testIDsNotFilenamesAndDiagnosticsSortByPathLocationThenCode() {
        let path = ".kontrol/features/other.md"
        let first = ProjectDiagnostic(code: .invalidField, severity: .error, relativePath: path,
                                      line: 9, column: 2, recovery: .editSource)
        let second = ProjectDiagnostic(code: .invalidFrontmatter, severity: .error, relativePath: path,
                                       line: 2, column: 3, recovery: .editSource)
        let records = [feature("first", path: "other", status: .completed),
                       feature("second", path: "zzz", dependencies: ["first"])]
        let forward = ProjectValidator().validate(records, diagnostics: [first, second])
        let reverse = ProjectValidator().validate(records.reversed(), diagnostics: [first, second])
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.features.map(\.id), ["first", "second"])
        XCTAssertEqual(forward.diagnostics, [second, first])
        XCTAssertEqual(inspection(manifest: manifest, features: forward.features).featureCount,
                       .complete(completed: 1, total: 2))
    }

    func testEmptyIsCompleteOnlyAfterSuccessfulEnumerationAndValidManifest() {
        XCTAssertEqual(inspection(manifest: manifest).featureCount, .complete(completed: 0, total: 0))
        XCTAssertEqual(inspection(manifest: manifest, enumeration: .failed).featureCount, .unavailable)
        XCTAssertEqual(inspection().featureCount, .unavailable)
        let future = ProjectManifest(schemaVersion: 2, id: "future", name: "Future",
                                     description: "", stack: [], goals: [], currentFocus: [])
        XCTAssertEqual(inspection(manifest: future).featureCount, .unavailable)
    }

    func testExcludedFilesForcePartialCountEvenIfNoValidFeatures() {
        let completed = feature("done", status: .completed)
        let active = feature("todo", status: .active)
        let snapshot = inspection(manifest: manifest, features: [completed, active],
                                  excluded: [".kontrol/features/broken.md"])
        XCTAssertEqual(snapshot.featureCount, .partial(completed: 1, total: 2, excludedFiles: 1))
        XCTAssertEqual(inspection(manifest: manifest, excluded: [".kontrol/features/broken.md"]).featureCount,
                       .partial(completed: 0, total: 0, excludedFiles: 1))
        XCTAssertEqual(inspection(manifest: manifest, features: [completed, active]).featureCount,
                       .complete(completed: 1, total: 2))
        XCTAssertEqual(inspection(manifest: manifest, features: [completed], excluded: ["bad"],
                                  enumeration: .failed).featureCount, .unavailable)
    }

    func testOptionalAbsenceIsNotFailedReadOrPresentEmptyFile() {
        let empty = ProjectSourceDocument(relativePath: ".kontrol/context.md", bytes: Data())
        XCTAssertNotEqual(ProjectOptionalDocument.absent, .failed)
        XCTAssertNotEqual(ProjectOptionalDocument.absent, .present(empty))
        XCTAssertNotEqual(ProjectOptionalContent<ProjectRoadmap>.absent, .failed)
        XCTAssertEqual(inspection(manifest: manifest).history, .absent)
    }

    func testSourceRetainsExactBytesDigestAndLineEndings() {
        let raw = Data("# Café\r\nfield: 1\n---\r\nbody\r\n".utf8)
        let source = ProjectSourceDocument(relativePath: ".kontrol/features/story.md", bytes: raw)
        XCTAssertEqual(source.bytes, raw)
        XCTAssertEqual(source.text, "# Café\r\nfield: 1\n---\r\nbody\r\n")
        XCTAssertEqual(source.sha256.count, 64)
        XCTAssertEqual(source.sha256, ProjectSourceDocument(relativePath: source.relativePath, bytes: raw).sha256)
        XCTAssertNotEqual(source.sha256, ProjectSourceDocument(relativePath: source.relativePath,
                                                                bytes: Data("# Café\nfield: 1\n---\nbody\n".utf8)).sha256)
        let invalid = ProjectSourceDocument(relativePath: ".kontrol/rules.md", bytes: Data([0xff]))
        XCTAssertEqual(invalid.bytes, Data([0xff]))
        XCTAssertNil(invalid.text)
    }

    func testDiagnosticHasStableIdentityAndRelativeLocation() {
        let diagnostic = ProjectDiagnostic(code: .duplicateID, severity: .error,
                                           relativePath: ".kontrol/features/peer.md", line: 3,
                                           column: 1, affectedIDs: ["peer"], recovery: .editSource)
        XCTAssertEqual(diagnostic.code.rawValue, "duplicateID")
        XCTAssertEqual(diagnostic.relativePath, ".kontrol/features/peer.md")
        XCTAssertEqual(diagnostic.line, 3)
        XCTAssertEqual(diagnostic.column, 1)
        XCTAssertEqual(diagnostic.affectedIDs, ["peer"])
        XCTAssertEqual(diagnostic.recovery, .editSource)
    }

    func testInspectorEscapesControlCharactersInDisplayedDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let features = root.appendingPathComponent(".kontrol/features")
        try FileManager.default.createDirectory(at: features, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("schema_version: 1\nid: demo\nname: Demo\n".utf8)
            .write(to: root.appendingPathComponent(".kontrol/project.yaml"))
        let name = "bad\nname.md"
        try Data("not frontmatter".utf8).write(to: features.appendingPathComponent(name))
        let snapshot = try await ProjectInspector(access: ProjectFolderAccess(operations: ValidationGrant()))
            .inspect(selectedFolder: root)
        XCTAssertEqual(snapshot.excludedFeaturePaths, [".kontrol/features/" + name])
        XCTAssertEqual(snapshot.diagnostics.first?.relativePath, ".kontrol/features/bad\\u{A}name.md")
        XCTAssertFalse(snapshot.diagnostics.first!.relativePath.contains("\n"))
    }

    func testUnsupportedProjectSchemaKeepsPeersRawWithoutTrustedV1Records() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".kontrol/features")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data("schema_version: 9\nid: future\nname: Future\n".utf8)
        let roadmap = Data("schema_version: 1\nmilestones: []\n".utf8)
        let feature = Data("---\nid: done\ntitle: Done\nstatus: completed\npriority: high\neffort: small\n---\nBody\r\n".utf8)
        let featurePath = ".kontrol/features/done.md"
        try manifest.write(to: root.appendingPathComponent(".kontrol/project.yaml"))
        try roadmap.write(to: root.appendingPathComponent(".kontrol/roadmap.yaml"))
        try feature.write(to: root.appendingPathComponent(featurePath))

        let result = try await ProjectInspector(access: ProjectFolderAccess(operations: ValidationGrant()))
            .inspect(selectedFolder: root)
        XCTAssertNil(result.manifest)
        if case .failed = result.roadmap {} else { XCTFail("roadmap cannot be trusted without V1 manifest") }
        XCTAssertTrue(result.features.isEmpty)
        XCTAssertEqual(result.excludedFeaturePaths, [featurePath])
        XCTAssertEqual(result.featureCount, .unavailable)
        XCTAssertFalse(ProjectInspector.canAdd(result))
        XCTAssertEqual(result.diagnostics.map(\.code), [.unsupportedVersion])
        XCTAssertEqual(result.sources.map(\.bytes), [manifest, roadmap, feature])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(featurePath)), feature)
    }

    func testInspectorKeepsValidPeersAfterMalformedAndUnsupportedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".kontrol/features")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ value: String) throws {
            try Data(value.utf8).write(to: root.appendingPathComponent(".kontrol/" + name))
        }
        try write("project.yaml", "schema_version: 1\nid: demo\nname: Demo\n")
        try write("roadmap.yaml", "schema_version: 9\nmilestones: []\n")
        try write("features/good.md", "---\nid: stable\ntitle: Good\nstatus: completed\npriority: high\neffort: small\n---\nBody\n")
        try write("features/bad.md", "no frontmatter")
        try write("features/future.md", "---\nschema_version: 2\nid: future\n---\n")
        try write("features/dependent.md", "---\nid: dependent\ntitle: Dependent\nstatus: ready\npriority: low\neffort: large\ndepends_on: [stable]\n---\n")
        let inspector = ProjectInspector(access: ProjectFolderAccess(operations: ValidationGrant()))
        let result = try await inspector.inspect(selectedFolder: root)
        XCTAssertEqual(result.manifest?.id, "demo")
        XCTAssertEqual(result.features.map(\.id), ["dependent", "stable"])
        XCTAssertEqual(result.featureCount, .partial(completed: 1, total: 2, excludedFiles: 2))
        XCTAssertEqual(result.excludedFeaturePaths, [".kontrol/features/bad.md", ".kontrol/features/future.md"])
        if case .failed = result.roadmap {} else { XCTFail("unsupported roadmap cannot be V1") }
        XCTAssertEqual(result.diagnostics.map(\.code), [.invalidFrontmatter, .unsupportedVersion, .unsupportedVersion])
        XCTAssertEqual(result.sources.count, 6)
        XCTAssertFalse(ProjectInspector.canAdd(result))
        // An optional history file is not a second source of status.
        try write("history.yaml", "status: planned\n")
        let reread = try await inspector.inspect(selectedFolder: root)
        XCTAssertEqual(reread.featureCount, result.featureCount)
    }
}

private struct ValidationGrant: ProjectBookmarkOperations {
    func resolve(_ data: Data) throws -> (folder: URL, isStale: Bool) { throw ProjectFolderAccessError.unresolved }
    func createBookmark(for selectedFolder: URL) throws -> Data { Data([1]) }
    func startAccessing(_ folder: URL) -> Bool { true }
    func stopAccessing(_ folder: URL) {}
}
