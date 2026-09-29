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
