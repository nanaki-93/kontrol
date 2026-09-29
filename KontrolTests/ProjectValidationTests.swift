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
}
