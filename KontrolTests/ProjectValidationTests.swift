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
