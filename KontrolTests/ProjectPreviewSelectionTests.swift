import Foundation
import XCTest
@testable import Kontrol

@MainActor
final class ProjectPreviewSelectionTests: XCTestCase {
    private typealias Selection = ProjectsView.ProjectPreviewSelection
    private typealias Projection = ProjectsView.PreviewProjection

    private func feature(_ id: String, status: ProjectFeatureStatus = .ready,
                         priority: ProjectFeaturePriority = .medium) -> ProjectFeature {
        ProjectFeature(id: id, title: "Feature \(id)", status: status, priority: priority,
                       effort: .small, dependsOn: [], areas: [], completedAt: nil,
                       body: "Body \(id)", sourcePath: ".kontrol/features/\(id).md")
    }

    private func row(_ id: UUID, _ features: [ProjectFeature], excluded: [String] = []) -> ProjectRowState {
        let reference = ProjectReferenceSnapshot(id: id, manifestID: "fixture", bookmarkData: Data([1]),
            displayOrder: 0, displayNameHint: "Fixture", lastSuccessfulReadAt: nil, revision: UUID())
        let inspection = ProjectInspection(manifest: ProjectManifest(schemaVersion: 1, id: "fixture",
            name: "Fixture", description: "", stack: [], goals: [], currentFocus: []),
            roadmap: .absent, features: features, excludedFeaturePaths: excluded,
            featureEnumeration: .complete, context: .absent, rules: .absent, history: .absent,
            diagnostics: [], sources: [], readAt: Date(timeIntervalSince1970: 42))
        return ProjectRowState(reference: reference, inspection: inspection)
    }

    private func preview(_ id: UUID, _ selection: Selection, _ row: ProjectRowState) -> Projection {
        ProjectsView.preview(for: id, selection: selection, row: row)!
    }

    func testInitialSelectionAndSameProjectRefreshKeepSelectorOrderAndExactID() {
        let id = UUID()
        let first = row(id, [feature("low", priority: .low), feature("high", priority: .high), feature("mid")])
        let initial = preview(id, .init(), first)
        XCTAssertEqual(initial.candidates.map(\.id), ProjectsView.recommendations(first).map(\.id))
        XCTAssertEqual(initial.candidates.map(\.id), ["high", "mid", "low"])
        XCTAssertEqual(initial.currentIdentity, ProjectFeatureIdentity(projectID: id, featureID: "high"))
        let selected = initial.selection.selecting("mid", from: initial)
        XCTAssertEqual(selected.featureID, "mid")
        XCTAssertEqual(selected.selecting("unknown", from: initial), selected)
        let refreshed = row(id, [feature("mid"), feature("high", priority: .high), feature("low", priority: .low)])
        XCTAssertEqual(preview(id, selected, refreshed).currentIdentity,
                       ProjectFeatureIdentity(projectID: id, featureID: "mid"))
        XCTAssertEqual(refreshed.inspection?.features.map(\.id), ["mid", "high", "low"],
                       "Browsing does not edit the inspection or route to a feature")
    }

    func testDuplicateFeatureIDInAnotherProjectCannotCarryPreviewAcrossSwitch() {
        let a = UUID(), b = UUID()
        let old = preview(a, .init(), row(a, [feature("shared"), feature("other")]))
        let chosen = old.selection.selecting("other", from: old)
        let next = preview(b, chosen, row(b, [feature("first", priority: .high), feature("other"), feature("shared")]))
        XCTAssertEqual(next.currentIdentity, ProjectFeatureIdentity(projectID: b, featureID: "first"))
        let duplicate = preview(a, next.selection, row(a, [feature("shared")]))
        XCTAssertEqual(duplicate.currentIdentity, ProjectFeatureIdentity(projectID: a, featureID: "shared"))
        XCTAssertNotEqual(duplicate.currentIdentity, next.currentIdentity)
    }

    func testCandidateRemovalFallsBackThenAuthoritativeEmptyClearsIdentity() {
        let id = UUID()
        let initial = preview(id, .init(), row(id, [feature("a"), feature("b")]))
        let chosen = initial.selection.selecting("b", from: initial)
        let removed = preview(id, chosen, row(id, [feature("a"), feature("b", status: .completed)]))
        XCTAssertEqual(removed.currentIdentity?.featureID, "a")
        XCTAssertEqual(chosen.selecting("b", from: removed), chosen, "Stale event cannot select a fallback")
        let empty = preview(id, removed.selection, row(id, [feature("a", status: .completed)]))
        XCTAssertNil(empty.selection.featureID)
        XCTAssertNil(empty.currentIdentity)
        XCTAssertTrue(empty.candidates.isEmpty)
        XCTAssertNil(ProjectsView.preview(for: nil, selection: chosen, row: nil))
    }

    func testFailedRetainedAndInFlightReadsKeepIdentityWithoutCurrentAction() {
        let id = UUID()
        let current = row(id, [feature("a"), feature("b")])
        let chosen = preview(id, .init(), current).selection.selecting("b", from: preview(id, .init(), current))
        var retained = current
        retained.isStale = true
        retained.isRetainedInspection = true
        retained.refreshFailure = .inspection(.inconsistentRead)
        for unavailable in [retained, rowWithoutInspection(current), refreshing(current)] {
            let result = preview(id, chosen, unavailable)
            XCTAssertEqual(result.selection, chosen)
            XCTAssertNil(result.currentIdentity)
            XCTAssertTrue(result.candidates.isEmpty)
            XCTAssertEqual(chosen.selecting("a", from: result), chosen)
        }
        XCTAssertEqual(preview(id, chosen, current).currentIdentity?.featureID, "b")
    }

    private func rowWithoutInspection(_ row: ProjectRowState) -> ProjectRowState {
        var result = row
        result.inspection = nil
        result.refreshFailure = .inspection(.unreadableFolder)
        return result
    }

    private func refreshing(_ row: ProjectRowState) -> ProjectRowState {
        var result = row
        result.isRefreshing = true
        return result
    }

    func testAcceptedPartialReadRemainsEligibleAndCountsOnlyValidFeatures() {
        let id = UUID()
        var partial = row(id, [feature("done", status: .completed), feature("next")],
                          excluded: [".kontrol/features/invalid.md"])
        partial.isStale = true
        let result = preview(id, .init(), partial)
        XCTAssertEqual(result.candidates.map(\.id), ["next"])
        XCTAssertEqual(result.currentIdentity, ProjectFeatureIdentity(projectID: id, featureID: "next"))
        XCTAssertEqual(partial.inspection?.featureCount, .partial(completed: 1, total: 2, excludedFiles: 1))
        partial.isRetainedInspection = true
        XCTAssertNil(preview(id, result.selection, partial).currentIdentity)
    }
}
