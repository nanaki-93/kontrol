import AppKit
import SwiftUI
import XCTest
@testable import Kontrol

private struct ListInspector: ProjectInspecting {
    func inspect(selectedFolder: URL) async throws -> ProjectInspection { throw CancellationError() }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection { throw CancellationError() }
    func makeBookmark(selectedFolder: URL) async throws -> Data { throw CancellationError() }
}

private actor CardInspector: ProjectInspecting {
    private var inspections: [UInt8: ProjectInspection]
    private var failing: Set<UInt8> = []

    init(_ inspections: [UInt8: ProjectInspection]) { self.inspections = inspections }
    func update(_ key: UInt8, to inspection: ProjectInspection) { inspections[key] = inspection }
    func fail(_ key: UInt8) { failing.insert(key) }
    func inspect(selectedFolder: URL) async throws -> ProjectInspection { throw CancellationError() }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        guard let key = bookmarkData.first, let inspection = inspections[key] else { throw CancellationError() }
        if failing.contains(key) { throw ProjectInspectionFailure.inconsistentRead }
        return inspection
    }
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
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot {
        guard let reference = references.first(where: { $0.id == id }) else { throw CancellationError() }
        return reference
    }
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

    private func card(_ id: String, status: ProjectFeatureStatus = .ready,
                      priority: ProjectFeaturePriority = .medium, effort: ProjectFeatureEffort = .small,
                      dependencies: [String] = [], areas: [String] = []) -> ProjectFeature {
        ProjectFeature(id: id, title: "Disk title \(id)", status: status, priority: priority,
                       effort: effort, dependsOn: dependencies, areas: areas, completedAt: nil,
                       body: "Disk body \(id)", sourcePath: ".kontrol/features/\(id).md")
    }

    private func cardInspection(_ features: [ProjectFeature], excluded: [String] = []) -> ProjectInspection {
        ProjectInspection(manifest: ProjectManifest(schemaVersion: 1, id: "same-id", name: "Disk project",
            description: "", stack: [], goals: [], currentFocus: ["Focus"]), roadmap: .absent,
            features: features, excludedFeaturePaths: excluded, featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())
    }

    func testSelectedWorkspaceHostsOneThreePartialAndRetainedFailure() async throws {
        let one = cardInspection([card("one", areas: ["Focus"])])
        let three = cardInspection([card("z"), card("a", priority: .high),
                                    card("m", dependencies: ["done"]), card("done", status: .completed),
                                    card("later", priority: .low)])
        let partial = cardInspection([card("valid"), card("finished", status: .completed)],
                                     excluded: [".kontrol/features/invalid.md"])
        let ids = (0..<4).map { _ in UUID() }
        let inspector = CardInspector([1: one, 2: three, 3: partial, 4: one])
        let store = ProjectStore(inspector: inspector, repository: ListRepository(
            ids.enumerated().map { reference($0.element, order: $0.offset) }))
        try store.enterProjects()
        for _ in 0..<100 where store.rows.contains(where: { $0.isRefreshing }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.rows.contains(where: { $0.isRefreshing }), "Fixture inspections must publish")
        let rows = ids.compactMap { id in store.rows.first { $0.reference.id == id } }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map { ProjectsView.recommendations($0).count }, [1, 3, 1, 1])
        XCTAssertEqual(ProjectsView.recommendations(rows[1]).map(\.id), ["a", "m", "z"])
        XCTAssertEqual(ProjectsView.cardMetadata(three.features[2], reason: .dependenciesComplete),
                       "medium priority · small effort · Ready · dependency complete")
        XCTAssertEqual(ProjectDetailsView.progress(partial),
                       "1 of 2 valid features completed (partial; 1 file excluded)")
        XCTAssertTrue(rows[2].isStale, "A current partial inspection is still actionable")
        for id in ids {
            store.select(id)
            let host = NSHostingView(rootView: ProjectsView(store: store))
            XCTAssertTrue(host.rootView.store === store)
            XCTAssertEqual(host.rootView.store.selectedID, id)
        }
        store.select(ids[0])
        store.selectFeature("one", in: ids[0])
        XCTAssertEqual(store.selectedFeatureContent?.body, "Disk body one")
        store.closeFeature()
        await inspector.fail(4)
        store.refresh(ids[3])
        for _ in 0..<100 where store.rows.first(where: { $0.reference.id == ids[3] })?.isRefreshing == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stale = try XCTUnwrap(store.rows.first { $0.reference.id == ids[3] })
        XCTAssertEqual(stale.refreshFailure, .inspection(.inconsistentRead))
        XCTAssertTrue(stale.isRetainedInspection)
        XCTAssertTrue(ProjectsView.recommendations(stale).isEmpty,
                      "Retained suggestions cannot be opened as current")
        store.select(ids[3])
        let staleHost = NSHostingView(rootView: ProjectsView(store: store))
        XCTAssertTrue(staleHost.rootView.store === store)
        store.selectFeature("one", in: ids[3])
        XCTAssertEqual(store.selectedFeatureContent?.body, "Disk body one",
                       "Old detail remains accessible only as a stale reference")
    }

    func testWorkspaceClassificationsCompileWithTruthfulProgressAndRecovery() async throws {
        let done = card("done", status: .completed)
        let waiting = card("waiting", dependencies: ["done", "active"])
        let mixed = cardInspection([card("planned", status: .planned), card("active", status: .active),
                                    card("blocked", status: .blocked), done, waiting])
        let excluded = cardInspection([done], excluded: [".kontrol/features/bad.md"])
        let empty = cardInspection([])
        let complete = cardInspection([done])
        let planned = cardInspection([card("planned", status: .planned)])
        let active = cardInspection([card("active", status: .active)])
        let blocked = cardInspection([card("blocked", status: .blocked)])
        let awaiting = cardInspection([done, waiting, card("active", status: .active)])
        func unavailable(manifest: ProjectManifest?, enumeration: ProjectFeatureEnumeration,
                         diagnostic: ProjectDiagnostic) -> ProjectInspection {
            ProjectInspection(manifest: manifest, roadmap: .absent, features: [],
                excludedFeaturePaths: [], featureEnumeration: enumeration, context: .absent,
                rules: .absent, history: .absent, diagnostics: [diagnostic], sources: [], readAt: Date())
        }
        let failed = unavailable(manifest: empty.manifest, enumeration: .failed,
            diagnostic: ProjectDiagnostic(code: .enumerationFailed, severity: .error,
                relativePath: ".kontrol/features", recovery: .refresh))
        let unsupported = unavailable(manifest: nil, enumeration: .complete,
            diagnostic: ProjectDiagnostic(code: .unsupportedVersion, severity: .error,
                relativePath: ".kontrol/project.yaml", recovery: .upgradeSource))
        let fixtures: [(ProjectInspection, FeatureSelectionState)] = [
            (excluded, .validationExclusions), (empty, .noFeatures), (complete, .allComplete),
            (planned, .noReadyFeatures), (active, .noReadyFeatures), (blocked, .noReadyFeatures),
            (awaiting, .noReadyFeatures), (mixed, .noReadyFeatures),
            (failed, .unavailable), (unsupported, .unavailable)
        ]
        let ids = fixtures.indices.map { _ in UUID() }
        let inspector = CardInspector(Dictionary(uniqueKeysWithValues: fixtures.enumerated().map {
            (UInt8($0.offset + 1), $0.element.0)
        }))
        let store = ProjectStore(inspector: inspector, repository: ListRepository(
            ids.enumerated().map { reference($0.element, order: $0.offset) }))
        try store.enterProjects()
        for _ in 0..<200 where store.rows.contains(where: { $0.isRefreshing }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.rows.contains(where: { $0.isRefreshing }), "All fixtures must publish")
        for (index, fixture) in fixtures.enumerated() {
            let row = try XCTUnwrap(store.rows.first { $0.reference.id == ids[index] })
            let selection = FeatureSelector().select(from: try XCTUnwrap(row.inspection))
            XCTAssertEqual(selection.state, fixture.1)
            XCTAssertTrue(ProjectsView.recommendations(row).isEmpty)
            store.select(ids[index])
            let host = NSHostingView(rootView: ProjectsView(store: store))
            XCTAssertTrue(host.rootView.store === store)
            XCTAssertEqual(host.rootView.store.selectedID, ids[index])
        }
        XCTAssertEqual(ProjectDetailsView.progress(failed),
                       "Feature progress unavailable; enumeration or manifest is incomplete")
        XCTAssertEqual(ProjectDetailsView.progress(unsupported),
                       "Feature progress unavailable; enumeration or manifest is incomplete")
        XCTAssertTrue(ProjectsView.unavailableGuidance(failed).contains("listing could not be completed"))
        XCTAssertTrue(ProjectsView.unavailableGuidance(unsupported).contains("manifest missing or unsupported"))
        XCTAssertEqual(ProjectDetailsView.progress(excluded),
                       "1 of 1 valid features completed (partial; 1 file excluded)")
        XCTAssertEqual(ProjectDetailsView.progress(empty), "0 of 0 features completed (complete enumeration)")
        let counts = try XCTUnwrap(FeatureSelector().select(from: mixed).statusCounts)
        XCTAssertEqual(ProjectsView.statusSummary(counts),
                       "Inspected valid features · planned: 1 · active: 1 · blocked: 1 · ready awaiting prerequisites: 1 · completed: 1")
        XCTAssertEqual(ProjectsView.unresolvedLabels(FeatureSelector().select(from: mixed), inspection: mixed),
                       ["Disk title waiting (waiting) awaits: Disk title active (active) · active"])
        XCTAssertEqual(ProjectsView.unresolvedLabels(FeatureSelector().select(from: awaiting), inspection: awaiting),
                       ["Disk title waiting (waiting) awaits: Disk title active (active) · active"])
        XCTAssertEqual(FeatureSelector().select(from: planned).statusCounts?.planned, 1)
        XCTAssertEqual(FeatureSelector().select(from: active).statusCounts?.active, 1)
        XCTAssertEqual(FeatureSelector().select(from: blocked).statusCounts?.blocked, 1)
        XCTAssertNil(FeatureSelector().select(from: failed).statusCounts)

        // A retained inspection is not a current complete or empty result; access failures reconnect.
        await inspector.fail(2)
        store.refresh(ids[1])
        for _ in 0..<100 where store.rows.first(where: { $0.reference.id == ids[1] })?.isRefreshing == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stale = try XCTUnwrap(store.rows.first { $0.reference.id == ids[1] })
        XCTAssertTrue(stale.isRetainedInspection)
        XCTAssertTrue(ProjectsView.recommendations(stale).isEmpty)
        store.select(ids[1])
        let staleHost = NSHostingView(rootView: ProjectsView(store: store))
        XCTAssertTrue(staleHost.rootView.store === store)
        XCTAssertTrue(ProjectsView.status(stale).contains("Refresh needed"))
        var revoked = stale
        revoked.refreshFailure = .inspection(.access(.staleBookmark))
        XCTAssertEqual(revoked.refreshFailure?.recovery, .reconnect)
        XCTAssertTrue(ProjectsView.unavailableGuidance(nil, recovery: .reconnect).contains("Reconnect"))
        let noInspection = ProjectRowState(reference: reference(UUID(), order: 11), inspection: nil,
                                           refreshFailure: .inspection(.access(.staleBookmark)))
        XCTAssertTrue(ProjectsView.status(noInspection).contains("Reconnect required"))
    }

    func testRoadmapIndexesAllValidatedStatusesAndRoutesBeyondTopThree() async throws {
        let features = [card("z-planned", status: .planned), card("d-ready"),
                        card("a-active", status: .active), card("x-blocked", status: .blocked),
                        card("b-done", status: .completed), card("c-ready"),
                        card("e-ready"), card("f-ready")]
        let milestones = [RoadmapMilestone(id: "later", title: "Second", status: "active"),
                          RoadmapMilestone(id: "earlier", title: "First", status: "planned")]
        let base = cardInspection(features, excluded: [".kontrol/features/invalid.md"])
        let inspection = ProjectInspection(manifest: base.manifest,
            roadmap: .present(ProjectRoadmap(schemaVersion: 1, milestones: milestones)),
            features: features, excludedFeaturePaths: base.excludedFeaturePaths,
            featureEnumeration: .complete, context: .present(ProjectSourceDocument(
                relativePath: ".kontrol/context.md", bytes: Data("Project notes".utf8))),
            rules: .absent, history: .absent, diagnostics: [], sources: [], readAt: Date())
        let projectID = UUID()
        let store = ProjectStore(inspector: CardInspector([1: inspection]),
                                 repository: ListRepository([reference(projectID, order: 0)]))
        try store.enterProjects()
        for _ in 0..<100 where store.rows.first?.isRefreshing == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.inspection, inspection)
        XCTAssertEqual(ProjectDetailsView.orderedFeatures(inspection).map(\.id),
                       ["a-active", "b-done", "c-ready", "d-ready", "e-ready", "f-ready", "x-blocked", "z-planned"])
        XCTAssertEqual(inspection.features.map(\.status),
                       [.planned, .ready, .active, .blocked, .completed, .ready, .ready, .ready])
        XCTAssertEqual(inspection.roadmap, .present(ProjectRoadmap(schemaVersion: 1, milestones: milestones)),
                       "Sorting feature IDs must not reorder milestones")
        XCTAssertEqual(ProjectsView.recommendations(row).map(\.id), ["c-ready", "d-ready", "e-ready"])
        XCTAssertEqual(ProjectDetailsView.progress(inspection),
                       "1 of 8 valid features completed (partial; 1 file excluded)")
        XCTAssertEqual(ProjectDetailsView.documentText(inspection.context), "Project notes")
        let details = NSHostingView(rootView: ProjectDetailsView(row: row, back: {}, refresh: {},
            viewFeature: { store.selectFeature($0, in: projectID) }))
        let projects = NSHostingView(rootView: ProjectsView(store: store))
        XCTAssertTrue(projects.rootView.store === store)
        for feature in ProjectDetailsView.orderedFeatures(inspection) {
            details.rootView.viewFeature(feature.id)
            XCTAssertEqual(store.selectedFeature, ProjectFeatureIdentity(projectID: projectID, featureID: feature.id))
            XCTAssertEqual(store.selectedFeatureContent, feature)
            store.closeFeature()
        }
        XCTAssertEqual(inspection.features.map(\.status), features.map(\.status),
                       "Roadmap selection must not change status or create work")
    }

    func testFullReadOnlyFeatureDetailHostsLongMarkdownEmptyDependenciesRefreshAndStale() async throws {
        let longBody = "## Verification scenarios (not an Acceptance heading)\n" +
            String(repeating: "- Read every requirement including **literal** [local text](https://example.invalid) and ![image](remote.png).\n", count: 400) +
            "\nFinal line must remain visible."
        let dependency = card("foundation", status: .completed)
        let active = card("active", status: .active)
        let feature = ProjectFeature(id: "detail", title: "Disk detail", status: .ready,
            priority: .high, effort: .large, dependsOn: ["foundation", "active"],
            areas: ["Focus", "Platform"], completedAt: nil, body: longBody,
            sourcePath: ".kontrol/features/detail.md")
        let empty = ProjectFeature(id: "empty", title: "Empty description", status: .planned,
            priority: .low, effort: .small, dependsOn: [], areas: [], completedAt: nil,
            body: "", sourcePath: ".kontrol/features/empty.md")
        let initial = cardInspection([feature, dependency, active, empty])
        let projectID = UUID()
        let inspector = CardInspector([1: initial])
        let store = ProjectStore(inspector: inspector,
            repository: ListRepository([reference(projectID, order: 0)]))
        try store.enterProjects()
        for _ in 0..<100 where store.rows.first?.isRefreshing == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(try XCTUnwrap(store.rows.first).isRefreshing)
        store.selectFeature("detail", in: projectID)
        let row = try XCTUnwrap(store.rows.first)
        let detail = NSHostingView(rootView: ProjectFeatureDetailView(row: row, featureID: "detail",
            backToRoadmap: true, back: { store.closeFeature() }))
        XCTAssertEqual(detail.rootView.feature?.body, longBody)
        XCTAssertTrue(detail.rootView.feature?.body.hasSuffix("Final line must remain visible.") == true)
        XCTAssertEqual(ProjectFeatureDetailView.dependencyLabels(for: feature, in: initial),
                       ["Disk title foundation (foundation) · Completed", "Disk title active (active) · Active"])
        XCTAssertEqual(detail.rootView.feature?.priority, .high)
        XCTAssertEqual(detail.rootView.feature?.effort, .large)
        XCTAssertEqual(detail.rootView.feature?.areas, ["Focus", "Platform"])
        let emptyDetail = NSHostingView(rootView: ProjectFeatureDetailView(row: row, featureID: "empty",
            backToRoadmap: false, back: {}))
        XCTAssertEqual(emptyDetail.rootView.feature?.body, "")
        XCTAssertEqual(emptyDetail.rootView.feature?.dependsOn, [])
        XCTAssertEqual(ProjectFeatureDetailView.dependencyLabels(for: empty, in: initial), [])

        let revised = ProjectFeature(id: "detail", title: "Externally revised", status: .blocked,
            priority: .medium, effort: .small, dependsOn: ["active"], areas: [],
            completedAt: nil, body: "## Other heading\nRevised whole body", sourcePath: feature.sourcePath)
        await inspector.update(1, to: cardInspection([revised, dependency, active, empty]))
        store.refresh(projectID)
        for _ in 0..<100 where store.rows.first?.isRefreshing == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedFeatureContent, revised, "Detail content must resolve from the latest inspection")
        let updated = NSHostingView(rootView: ProjectFeatureDetailView(row: try XCTUnwrap(store.rows.first),
            featureID: "detail", backToRoadmap: true, back: { store.closeFeature() }))
        XCTAssertEqual(updated.rootView.feature?.body, revised.body)
        XCTAssertEqual(ProjectFeatureDetailView.dependencyLabels(for: revised,
            in: try XCTUnwrap(store.rows.first?.inspection)), ["Disk title active (active) · Active"])
        await inspector.fail(1)
        store.refresh(projectID)
        for _ in 0..<100 where store.rows.first?.isRefreshing == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let staleRow = try XCTUnwrap(store.rows.first)
        XCTAssertTrue(staleRow.isRetainedInspection)
        let stale = NSHostingView(rootView: ProjectFeatureDetailView(row: staleRow, featureID: "detail",
            backToRoadmap: true, back: { store.closeFeature() }))
        XCTAssertEqual(stale.rootView.feature, revised)
        XCTAssertEqual(store.selectedFeatureContent, revised)
        let projects = NSHostingView(rootView: ProjectsView(store: store))
        XCTAssertTrue(projects.rootView.store === store)
        stale.rootView.back()
        XCTAssertNil(store.selectedFeature)
        XCTAssertEqual(ProjectsView.selectionNoticeText(ProjectFeatureSelectionNotice(projectID: projectID,
            featureID: "detail", reason: .removed)),
            "Feature detail was removed from this project. Detail closed; Refresh to inspect current work.")
        XCTAssertTrue(ProjectsView.selectionNoticeText(ProjectFeatureSelectionNotice(projectID: projectID,
            featureID: "detail", reason: .validationExcluded)).contains("failed validation"))
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
        let host = NSHostingView(rootView: ProjectDetailsView(row: row, back: {}, refresh: { store.refresh(row.reference.id) },
            viewFeature: { store.selectFeature($0, in: row.reference.id) }))
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
        let host = NSHostingView(rootView: ProjectDetailsView(row: row, back: {}, refresh: {}, viewFeature: { _ in }))
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
        let host = NSHostingView(rootView: ProjectDetailsView(row: failed, back: {}, refresh: {}, viewFeature: { _ in },
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
