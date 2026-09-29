import AppKit
import SwiftUI
import XCTest
@testable import Kontrol

private struct ListInspector: ProjectInspecting {
    func inspect(selectedFolder: URL) async throws -> ProjectInspection { throw CancellationError() }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection { throw CancellationError() }
    func makeBookmark(selectedFolder: URL) async throws -> Data { throw CancellationError() }
}

@MainActor
private final class ListRepository: ProjectReferenceRepository {
    let references: [ProjectReferenceSnapshot]
    init(_ references: [ProjectReferenceSnapshot]) { self.references = references }
    func fetchAll() throws -> [ProjectReferenceSnapshot] { references }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot { throw CancellationError() }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot { throw CancellationError() }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID,
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot { throw CancellationError() }
}

@MainActor
final class ProjectsPresentationTests: XCTestCase {
    private func reference(_ id: UUID, order: Int) -> ProjectReferenceSnapshot {
        ProjectReferenceSnapshot(id: id, manifestID: "same-id", bookmarkData: Data([UInt8(order + 1)]),
                                 displayOrder: order, displayNameHint: "Same project",
                                 lastSuccessfulReadAt: nil, revision: UUID())
    }

    func testEmptyAndMultipleProjectHostsCompileWithSharedStore() throws {
        let empty = ProjectStore(inspector: ListInspector(), repository: ListRepository([]))
        let emptyHost = NSHostingView(rootView: ProjectsView(store: empty))
        XCTAssertTrue(emptyHost.rootView.store === empty)
        XCTAssertTrue(empty.rows.isEmpty)

        let first = UUID(), second = UUID()
        let store = ProjectStore(inspector: ListInspector(),
                                 repository: ListRepository([reference(second, order: 2), reference(first, order: 0)]))
        try store.enterProjects()
        let host = NSHostingView(rootView: ProjectsView(store: store))
        XCTAssertTrue(host.rootView.store === store)
        XCTAssertEqual(ProjectsView.ordered(store.rows).map(\.reference.id), [first, second])
        store.select(second)
        XCTAssertEqual(store.selectedID, second)
        store.select(UUID())
        XCTAssertEqual(store.selectedID, second, "Unknown identities cannot change selection")
        XCTAssertEqual(ProjectsView.location(store.rows[0]),
                       "Location unavailable · reference \(second.uuidString)")
    }

    func testFolderOnlyPickerAndPreviewHostCompile() {
        let panel = ProjectAddView.configuredPicker()
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
        let store = ProjectStore(inspector: ListInspector(), repository: ListRepository([]))
        let host = NSHostingView(rootView: ProjectAddView(store: store, close: {}))
        XCTAssertTrue(host.rootView.store === store)
        XCTAssertNil(store.preview, "Opening a sheet does not preview or persist a project")
    }

    func testValidationSummaryUsesInspectedResultsNotPlaceholderCounts() {
        let manifest = ProjectManifest(schemaVersion: 1, id: "fixture", name: "Fixture",
                                       description: "", stack: [], goals: [], currentFocus: [])
        let complete = ProjectInspection(manifest: manifest, roadmap: .absent, features: [],
            excludedFeaturePaths: [], featureEnumeration: .complete, context: .absent,
            rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())
        XCTAssertEqual(ProjectAddView.summary(complete), "Valid · 0 of 0 features completed")
        let invalid = ProjectInspection(manifest: nil, roadmap: .absent, features: [],
            excludedFeaturePaths: [], featureEnumeration: .complete, context: .absent,
            rules: .absent, history: .absent,
            diagnostics: [ProjectDiagnostic(code: .missingManifest, severity: .error,
                relativePath: ".kontrol/project.yaml", recovery: .reselectFolder)],
            sources: [], readAt: Date())
        XCTAssertEqual(ProjectAddView.summary(invalid), "Validation: 1 issue · Project cannot be added")
    }

    func testDetailsUseInspectionValuesAndExplicitCountQualifications() {
        let manifest = ProjectManifest(schemaVersion: 1, id: "local-id", name: "Disk name",
            description: "Disk description", stack: ["Swift"], goals: ["Ship"], currentFocus: ["Review"])
        let source = ProjectSourceDocument(relativePath: ".kontrol/context.md", bytes: Data("Disk notes\r\n".utf8))
        let inspection = ProjectInspection(manifest: manifest,
            roadmap: .present(ProjectRoadmap(schemaVersion: 1, milestones: [
                RoadmapMilestone(id: "b", title: "Second", status: "active"),
                RoadmapMilestone(id: "a", title: "First", status: "planned")])),
            features: [], excludedFeaturePaths: [], featureEnumeration: .complete,
            context: .present(source), rules: .absent,
            history: .present(ProjectSourceDocument(relativePath: ".kontrol/history.yaml",
                bytes: Data("status: completed\n".utf8))),
            diagnostics: [], sources: [source], readAt: Date())
        XCTAssertEqual(ProjectDetailsView.progress(inspection), "0 of 0 features completed (complete enumeration)")
        XCTAssertEqual(ProjectDetailsView.documentText(inspection.history), "status: completed\n")
        XCTAssertEqual(ProjectDetailsView.documentText(inspection.context), "Disk notes\r\n")
        XCTAssertEqual(ProjectDetailsView.documentText(inspection.rules), "No file provided")
        var row = ProjectRowState(reference: reference(UUID(), order: 0), inspection: inspection)
        let store = ProjectStore(inspector: ListInspector(), repository: ListRepository([row.reference]))
        let host = NSHostingView(rootView: ProjectDetailsView(row: row, back: {}, refresh: { store.refresh(row.reference.id) }))
        XCTAssertEqual(host.rootView.row.inspection?.manifest?.name, "Disk name")
        XCTAssertEqual(host.rootView.row.inspection?.roadmap, inspection.roadmap)
        row.inspection = ProjectInspection(manifest: manifest, roadmap: .absent, features: [],
            excludedFeaturePaths: [".kontrol/features/bad.md"], featureEnumeration: .complete,
            context: .absent, rules: .failed, history: .absent, diagnostics: [], sources: [], readAt: Date())
        XCTAssertEqual(ProjectDetailsView.progress(row.inspection!),
                       "0 of 0 valid features completed (partial; 1 file excluded)")
        XCTAssertEqual(ProjectDetailsView.documentText(row.inspection!.rules),
                       "File could not be read; Refresh after repairing it")
        let unavailable = ProjectInspection(manifest: manifest, roadmap: .absent, features: [],
            excludedFeaturePaths: [], featureEnumeration: .failed, context: .absent,
            rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())
        XCTAssertTrue(ProjectDetailsView.progress(unavailable).contains("unavailable"))
    }

    func testDiagnosticsAndUnsupportedSourcesAreBoundedAndReadOnly() {
        let diagnostic = ProjectDiagnostic(code: .missingDependency, severity: .error,
            relativePath: ".kontrol/features/bad\nname.md", line: 9,
            affectedIDs: ["absent"], recovery: .editSource)
        let text = ProjectDetailsView.diagnosticText(diagnostic)
        XCTAssertTrue(text.contains(".kontrol/features/bad\\u{A}name.md · line 9"))
        XCTAssertTrue(text.contains("Dependency ID is missing · IDs: absent · Refresh"))
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertTrue(ProjectDetailsView.diagnosticText(ProjectDiagnostic(code: .unreadableFile,
            severity: .error, relativePath: "/Users/private/secret", recovery: .refresh))
            .hasPrefix("Project file:"), "Never show an absolute path supplied by an IO error")
        let source = ProjectSourceDocument(relativePath: ".kontrol/project.yaml",
            bytes: Data(String(repeating: "x", count: 40_000).utf8))
        XCTAssertEqual(ProjectDetailsView.unsupportedText(source).prefix(32_768).count, 32_768)
        XCTAssertTrue(ProjectDetailsView.unsupportedText(source).contains("Preview limited"))
        XCTAssertEqual(ProjectDetailsView.diagnosticReason(.unsupportedVersion),
                       "Schema version is unsupported; upgrade the source externally")

        let unsupported = ProjectInspection(manifest: nil, roadmap: .absent, features: [],
            excludedFeaturePaths: [], featureEnumeration: .complete, context: .absent,
            rules: .absent, history: .absent, diagnostics: [ProjectDiagnostic(code: .unsupportedVersion,
                severity: .error, relativePath: source.relativePath, recovery: .upgradeSource)],
            sources: [source], readAt: Date())
        XCTAssertEqual(ProjectDetailsView.progress(unsupported),
                       "Feature progress unavailable; enumeration or manifest is incomplete")
        let unsupportedRow = ProjectRowState(reference: reference(UUID(), order: 0), inspection: unsupported)
        XCTAssertEqual(ProjectsView.status(unsupportedRow),
                       "Unsupported project format · progress unavailable; upgrade source")
        let row = ProjectRowState(reference: reference(UUID(), order: 0), inspection: unsupported,
                                  isStale: true)
        let host = NSHostingView(rootView: ProjectDetailsView(row: row, back: {}, refresh: {}))
        XCTAssertEqual(host.rootView.row.inspection?.sources, [source])
    }

    func testRetainedSnapshotFailuresRequireCorrectRecoveryWithoutHidingPeers() {
        let healthy = ProjectRowState(reference: reference(UUID(), order: 0), inspection:
            ProjectInspection(manifest: ProjectManifest(schemaVersion: 1, id: "same-id", name: "Healthy",
                description: "", stack: [], goals: [], currentFocus: []), roadmap: .absent,
                features: [], excludedFeaturePaths: [], featureEnumeration: .complete,
                context: .absent, rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date()))
        var failed = ProjectRowState(reference: reference(UUID(), order: 1), inspection: healthy.inspection)
        failed.isStale = true
        failed.lastReadAt = healthy.inspection?.readAt
        failed.refreshFailure = .inspection(.access(.staleBookmark))
        XCTAssertEqual(ProjectsView.ordered([failed, healthy]).count, 2)
        XCTAssertTrue(ProjectsView.status(healthy).contains("Ready"))
        XCTAssertTrue(ProjectsView.status(failed).contains("Reconnect required"))
        XCTAssertTrue(ProjectsView.status(failed).contains("Last read:"))
        XCTAssertTrue(ProjectsView.status(failed).contains("stale"))
        XCTAssertTrue(ProjectDetailsView.failureText(failed.refreshFailure!).contains("Reconnect"))
        failed.refreshFailure = .inspection(.inconsistentRead)
        XCTAssertTrue(ProjectDetailsView.failureText(failed.refreshFailure!).contains("Refresh"))
        failed.refreshFailure = .manifestMismatch
        XCTAssertTrue(ProjectDetailsView.failureText(failed.refreshFailure!).contains("different project ID"))
        XCTAssertTrue(ProjectsView.status(failed).contains("Different project ID"))
        failed.refreshFailure = .persistence
        XCTAssertTrue(ProjectDetailsView.failureText(failed.refreshFailure!).contains("could not be saved"))
        XCTAssertTrue(ProjectsView.status(failed).contains("Local save failed"))
        let host = NSHostingView(rootView: ProjectDetailsView(row: failed, back: {}, refresh: {},
            recoveryMessage: "Project not reconnected. The saved reference is unchanged."))
        XCTAssertTrue(host.rootView.row.isStale)
        XCTAssertNotNil(host.rootView.row.lastReadAt)
        XCTAssertNotNil(host.rootView.recoveryMessage)
    }

    func testPerRowStatusKeepsPartialAndGrantFailuresDistinct() {
        let id = UUID()
        let base = ProjectRowState(reference: reference(id, order: 0), inspection: nil)
        var loading = base
        loading.isRefreshing = true
        XCTAssertEqual(ProjectsView.status(loading), "Loading project")
        var revoked = base
        revoked.refreshFailure = .inspection(.access(.staleBookmark))
        XCTAssertTrue(ProjectsView.status(revoked).contains("Reconnect required"))
        var partial = base
        partial.inspection = ProjectInspection(
            manifest: ProjectManifest(schemaVersion: 1, id: "same-id", name: "Same project",
                                      description: "", stack: [], goals: [], currentFocus: []),
            roadmap: .absent, features: [], excludedFeaturePaths: [".kontrol/features/bad.md"],
            featureEnumeration: .complete, context: .absent, rules: .absent, history: .absent,
            diagnostics: [], sources: [], readAt: Date())
        XCTAssertEqual(ProjectsView.status(partial), "Partial: 0 of 0 valid features · 1 file excluded")
        partial.locationHint = "/Projects/second"
        XCTAssertEqual(ProjectsView.location(partial), "/Projects/second")
        partial.isStale = true
        XCTAssertEqual(ProjectsView.location(partial), "Last seen: /Projects/second")
    }
}
