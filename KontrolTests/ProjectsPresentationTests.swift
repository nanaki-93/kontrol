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
    var references: [ProjectReferenceSnapshot]
    init(_ references: [ProjectReferenceSnapshot]) { self.references = references }
    func fetchAll() throws -> [ProjectReferenceSnapshot] { references }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot { throw CancellationError() }
    func remove(id: UUID, expectedRevision: UUID) throws {
        guard let reference = references.first(where: { $0.id == id }) else { throw ProjectReferencePersistenceError.notFound }
        guard reference.revision == expectedRevision else { throw ProjectReferencePersistenceError.staleRevision }
        references.removeAll { $0.id == id }
    }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot { throw CancellationError() }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID,
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot {
        guard let reference = references.first(where: { $0.id == id }) else { throw CancellationError() }
        return reference
    }
}

/// Real store fixtures: the hosted view observes the same row that publishes each IO outcome.
private actor PresentationInspector: ProjectInspecting {
    private var current: ProjectInspection
    private var failNextRead = false
    private var failAfterUpdate = false
    init(_ initial: ProjectInspection) { current = initial }
    func update(_ inspection: ProjectInspection) {
        current = inspection
        if failAfterUpdate { failNextRead = true }
    }
    func failReconciliation() { failAfterUpdate = true }
    func inspect(selectedFolder: URL) async throws -> ProjectInspection { throw CancellationError() }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        if failNextRead {
            failNextRead = false
            throw ProjectInspectionFailure.inconsistentRead
        }
        return current
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data { throw CancellationError() }
}

private actor PresentationWriter: FeatureFileWriting {
    let inspector: PresentationInspector
    private var completionFailure: FeatureMutationFailure?
    private var waiting: CheckedContinuation<FeatureMutationReceipt, Error>?
    init(inspector: PresentationInspector, failure: FeatureMutationFailure? = nil) {
        self.inspector = inspector
        completionFailure = failure
    }
    func failNextCompletion(_ failure: FeatureMutationFailure) { completionFailure = failure }
    func hasWaitingCompletion() -> Bool { waiting != nil }
    func release() { waiting?.resume(throwing: completionFailure ?? .writeFailed); waiting = nil }
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        if completionFailure != nil {
            return try await withCheckedThrowingContinuation { waiting = $0 }
        }
        let patch = try FeatureFrontmatterPatcher().completeWithInverse(request.source,
            featureID: request.featureID, at: request.completedAt)
        guard case let .supported(feature) = try ManifestParser().feature(patch.source) else {
            throw FeatureMutationFailure.unverifiedWrite
        }
        let previous = try await inspector.inspect(bookmarkData: request.reference.bookmarkData)
        let inspection = ProjectInspection(manifest: previous.manifest, roadmap: previous.roadmap,
            features: previous.features.map { $0.id == feature.id ? feature : $0 },
            excludedFeaturePaths: previous.excludedFeaturePaths,
            featureEnumeration: previous.featureEnumeration, context: previous.context,
            rules: previous.rules, history: previous.history, diagnostics: previous.diagnostics,
            sources: previous.sources.map { $0.relativePath == patch.source.relativePath ? patch.source : $0 },
            readAt: Date())
        await inspector.update(inspection)
        return FeatureMutationReceipt(projectID: request.reference.id,
            grantBookmarkData: request.reference.bookmarkData, featureID: request.featureID,
            verifiedSource: patch.source, inverse: patch.inverse)
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        throw FeatureMutationFailure.undoConflict
    }
}

@MainActor
final class ProjectsPresentationTests: XCTestCase {
    private func reference(_ id: UUID, order: Int) -> ProjectReferenceSnapshot {
        ProjectReferenceSnapshot(id: id, manifestID: "same-id", bookmarkData: Data([UInt8(order + 1)]),
                                 displayOrder: order, displayNameHint: "Same project",
                                 lastSuccessfulReadAt: nil, revision: UUID())
    }

    // Non-GUI focus policy coverage; native responder handoff is a separate A13 fixture.
    func testFolderFocusPolicyUsesCurrentRowsDisplayOrderAndEnabledSurvivors() throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let deleted = UUID()
        let store = ProjectStore(inspector: ListInspector(), repository: ListRepository([
            reference(second, order: 1), reference(first, order: 1)]))
        try store.loadReferencesIfNeeded()
        func target(_ origin: ProjectFoldersSettingsView.FocusTarget, review: Bool = false,
                    failed: Bool = false, busy: Bool = false) -> ProjectFoldersSettingsView.FocusTarget {
            ProjectFoldersSettingsView.returnFocus(origin: origin, rows: store.rows,
                requiresReview: review, loadFailed: failed, reconnectUnavailable: busy)
        }
        XCTAssertEqual(target(.remove(deleted)), .remove(first), "Ties use UUID, not fetch order")
        XCTAssertEqual(target(.reconnect(deleted)), .reconnect(first))
        XCTAssertEqual(target(.remove(second)), .remove(second), "Cancel/failure keeps the surviving origin")
        XCTAssertEqual(target(.remove(second), review: true), .review)
        XCTAssertEqual(target(.remove(second), failed: true), .review)
        XCTAssertEqual(target(.reconnect(second), busy: true), .add, "Never focus disabled Reconnect")
        XCTAssertEqual(target(.review, failed: true), .review)
        XCTAssertEqual(target(.add), .add)
        let firstReference = try XCTUnwrap(store.rows.first { $0.reference.id == first }?.reference)
        try store.disconnect(id: first, expectedRevision: firstReference.revision)
        XCTAssertEqual(target(.remove(first)), .remove(second))
        XCTAssertEqual(target(.reconnect(first)), .reconnect(second))
        let last = try XCTUnwrap(store.rows.first?.reference)
        try store.disconnect(id: last.id, expectedRevision: last.revision)
        XCTAssertEqual(target(.remove(last.id)), .add)
        XCTAssertEqual(target(.reconnect(last.id)), .add)
    }

    func testSettingsRemovalUpdatesSharedProjectsSelectionDetailAndPickerOwnership() async throws {
        let id = UUID(), survivor = UUID()
        let inspector = CardInspector([1: cardInspection([card("next")]), 2: cardInspection([])])
        let store = ProjectStore(inspector: inspector, repository: ListRepository([
            reference(id, order: 0), reference(survivor, order: 1)]))
        try store.enterProjects()
        for _ in 0..<100 where store.rows.contains(where: { $0.isRefreshing }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        store.selectFeature("next", in: id)
        XCTAssertNotNil(store.selectedFeatureContent)
        let projects = NSHostingView(rootView: ProjectsView(store: store))
        let folders = NSHostingView(rootView: ProjectFoldersSettingsView(store: store))
        let management = ProjectFoldersSettingsState(store: store)
        management.requestRemoval(id)
        management.cancel()
        XCTAssertEqual(store.selectedFeature?.projectID, id)
        XCTAssertNotNil(store.selectedFeatureContent, "Cancel does not disturb open Projects detail")
        management.requestRemoval(id)
        management.confirm()
        XCTAssertEqual(management.outcome, .removed("Same project"))
        XCTAssertTrue(projects.rootView.store === folders.rootView.store)
        XCTAssertEqual(projects.rootView.store.selectedID, survivor)
        XCTAssertNil(projects.rootView.store.selectedFeature)
        XCTAssertNil(projects.rootView.store.selectedFeatureContent)
        let add = NSHostingView(rootView: ProjectAddView(store: folders.rootView.store, close: {}))
        XCTAssertTrue(add.rootView.store === store, "Re-add uses the existing preview/picker owner")
        XCTAssertNil(store.preview)
        var unavailable = try XCTUnwrap(store.rows.first)
        unavailable.refreshFailure = .inspection(.access(.staleBookmark))
        XCTAssertEqual(ProjectFoldersSettingsView.status(unavailable), "Folder access unavailable · saved local reference still exists")
        unavailable.inspection = nil
        unavailable.refreshFailure = nil
        XCTAssertEqual(ProjectFoldersSettingsView.status(unavailable), "Saved local reference · folder not inspected here")
        let panel = ProjectAddView.configuredPicker()
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
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

    func testCompletionControlsCompileForCardsAndValidatedDetailStatuses() async throws {
        let statuses: [(String, ProjectFeatureStatus)] = [
            ("ready", .ready), ("planned", .planned), ("active", .active),
            ("blocked", .blocked), ("done", .completed)
        ]
        let sources = statuses.map { id, status in
            ProjectSourceDocument(relativePath: ".kontrol/features/\(id).md", bytes: Data(
                "---\nid: \(id)\ntitle: Disk \(id)\nstatus: \(status.rawValue)\npriority: medium\neffort: small\n---\nSelectable body".utf8))
        }
        let features = try sources.map { source -> ProjectFeature in
            guard case let .supported(feature) = try ManifestParser().feature(source) else {
                throw ProjectStoreError.invalidPreview
            }
            return feature
        }
        let base = cardInspection(features)
        let inspection = ProjectInspection(manifest: base.manifest, roadmap: base.roadmap,
            features: features, excludedFeaturePaths: [], featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [],
            sources: sources, readAt: Date())
        let id = UUID()
        let store = ProjectStore(inspector: CardInspector([1: inspection]),
            repository: ListRepository([reference(id, order: 0)]))
        try store.enterProjects()
        for _ in 0..<100 where store.rows.first?.isRefreshing == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(ProjectsView.recommendations(row).map(\.id), ["ready"])
        let projects = NSHostingView(rootView: ProjectsView(store: store))
        XCTAssertTrue(projects.rootView.store === store)
        for feature in features {
            let eligible = feature.status != .completed
            XCTAssertEqual(ProjectsView.completionEnabled(feature.id, row: row, store: store), eligible)
            XCTAssertEqual(ProjectFeatureDetailView.completionTitle(for: feature.id, state: row.completion),
                           "Mark complete")
            XCTAssertEqual(ProjectFeatureDetailView.completionLabel(for: feature, state: row.completion),
                           "Mark Disk \(feature.id) complete")
            store.selectFeature(feature.id, in: id)
            let detail = NSHostingView(rootView: ProjectFeatureDetailView(row: row, featureID: feature.id,
                backToRoadmap: true, back: { store.closeFeature() },
                canMarkComplete: ProjectsView.completionEnabled(feature.id, row: row, store: store)))
            XCTAssertEqual(detail.rootView.canMarkComplete, eligible)
            XCTAssertEqual(detail.rootView.feature?.body, "Selectable body")
            store.closeFeature()
        }
        for state in [ProjectCompletionState.writing("ready"), .refreshing("ready")] {
            var busy = row
            busy.completion = state
            XCTAssertEqual(ProjectFeatureDetailView.completionTitle(for: "ready", state: state), "Saving…")
            XCTAssertEqual(ProjectFeatureDetailView.completionLabel(for: features[0], state: state),
                           "Saving Disk ready…")
            XCTAssertFalse(ProjectsView.completionEnabled("ready", row: busy, store: store))
            let detail = NSHostingView(rootView: ProjectFeatureDetailView(row: busy, featureID: "ready",
                backToRoadmap: false, back: {}, canMarkComplete: false))
            XCTAssertFalse(detail.rootView.canMarkComplete)
        }
        var stale = row
        stale.isStale = true // A freshly inspected partial result can remain actionable.
        XCTAssertTrue(ProjectsView.completionEnabled("ready", row: stale, store: store))
        stale.isRetainedInspection = true
        XCTAssertFalse(ProjectsView.completionEnabled("ready", row: stale, store: store))
        stale.isRetainedInspection = false
        stale.isRefreshing = true
        XCTAssertFalse(ProjectsView.completionEnabled("ready", row: stale, store: store))
        XCTAssertFalse(ProjectsView.completionEnabled("ready", row: row, store: store, isReconnecting: true))
        // Native button activation, selectable text and AX inspection remain hosted F13 checks.
    }

    func testCompletionOutcomeCopyAndRecoveryCompileAcrossWorkspaceAndDetail() {
        let projectID = UUID()
        let row = ProjectRowState(reference: reference(projectID, order: 0),
                                  inspection: cardInspection([card("next")]))
        let fixtures: [(ProjectCompletionState, String, ProjectsView.CompletionRecovery?)] = [
            (.writing("next"), "No completion has been verified", nil),
            (.refreshing("next"), "verifying project progress", nil),
            (.undoing("next"), "Undoing completion", nil),
            (.saved("next"), "saved and verified", nil),
            (.undone("next"), "undone and verified", nil),
            (.failed("next", .conflict), "Feature changed on disk", .refresh),
            (.undoFailed("next", .undoConflict), "Your changes were not overwritten", .refresh),
            (.failed("next", .unpatchableSource), "cannot be edited safely", .refresh),
            (.failed("next", .writeFailed), "Completion not verified", .refresh),
            (.failed("next", .unverifiedWrite), "outcome is uncertain", .refresh),
            (.undoFailed("next", .unverifiedWrite), "outcome is uncertain", .refresh),
            (.failed("next", .accessDenied), "Reconnect", .reconnect),
            (.savedButRefreshFailed("next", .inspection(.inconsistentRead)),
             "File saved and verified", .refresh),
            (.savedButRefreshFailed("next", .persistence), "local read receipt", .refresh),
            (.savedButRefreshFailed("next", .inspection(.access(.staleBookmark))),
             "until Reconnect", .reconnect),
            (.undoneButRefreshFailed("next", .persistence), "Undo saved and verified", .refresh)
        ]
        for (state, expected, recovery) in fixtures {
            var fixture = row
            fixture.completion = state
            let message = ProjectsView.completionMessage(state, feature: "Disk title next", project: "Disk project")
            XCTAssertTrue(message.contains(expected), "\(state): \(message)")
            XCTAssertTrue(message.contains("Disk title next in Disk project"), "Outcome must identify both targets")
            XCTAssertEqual(ProjectsView.completionRecovery(state), recovery)
            XCTAssertEqual(state.featureID, "next")
            let detail = NSHostingView(rootView: ProjectFeatureDetailView(row: fixture, featureID: "next",
                backToRoadmap: false, back: {}))
            XCTAssertEqual(detail.rootView.feature?.id, "next")
        }
        XCTAssertEqual(ProjectsView.conflict(.failed("next", .conflict), projectID: projectID),
                       ProjectFeatureIdentity(projectID: projectID, featureID: "next"))
        XCTAssertEqual(ProjectsView.conflict(.undoFailed("next", .undoConflict), projectID: projectID),
                       ProjectFeatureIdentity(projectID: projectID, featureID: "next"))
        XCTAssertNil(ProjectsView.conflict(.failed("next", .unverifiedWrite), projectID: projectID))
        XCTAssertNil(ProjectsView.conflict(.saved("next"), projectID: projectID))
        XCTAssertNil(ProjectsView.conflict(.failed("next", .writeFailed), projectID: projectID))
        var recovered = row
        recovered.completion = .savedButRefreshFailed("next", .persistence)
        recovered.refreshFailure = .persistence
        XCTAssertEqual(ProjectsView.displayedCompletion(recovered), recovered.completion)
        recovered.refreshFailure = nil
        XCTAssertEqual(ProjectsView.displayedCompletion(recovered), .saved("next"))
        recovered.completion = .undoneButRefreshFailed("next", .persistence)
        XCTAssertEqual(ProjectsView.displayedCompletion(recovered), .undone("next"))
        recovered.isRetainedInspection = true
        XCTAssertEqual(ProjectsView.displayedCompletion(recovered), recovered.completion)
        // Hosted dialog activation, live Undo expiry and VoiceOver remain F13 checks.
    }

    /// These hosts observe published store states, rather than detached rows that the
    /// ProjectsView can never render. Native AX/dialog interaction remains for F13.
    func testCompletionOutcomesHostPublishedRowsAndTokenTarget() async throws {
        let first = "first", next = "next"
        let projectID = UUID()
        let sources = [first, next].map { id in
            ProjectSourceDocument(relativePath: ".kontrol/features/\(id).md", bytes: Data(
                "---\nid: \(id)\ntitle: Disk \(id)\nstatus: ready\npriority: medium\neffort: small\n---\nBody".utf8))
        }
        let features = try sources.map { source -> ProjectFeature in
            guard case let .supported(feature) = try ManifestParser().feature(source) else {
                throw ProjectStoreError.invalidPreview
            }
            return feature
        }
        let base = cardInspection(features)
        let inspection = ProjectInspection(manifest: base.manifest, roadmap: base.roadmap,
            features: features, excludedFeaturePaths: [], featureEnumeration: .complete,
            context: .absent, rules: .absent, history: .absent, diagnostics: [],
            sources: sources, readAt: Date())

        func ready(_ store: ProjectStore) async throws {
            try store.enterProjects()
            for _ in 0..<200 where store.rows.first?.isRefreshing == true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(try XCTUnwrap(store.rows.first).isRefreshing)
            XCTAssertEqual(store.rows.first?.inspection?.features.count, 2)
        }
        func host(_ store: ProjectStore, _ state: ProjectCompletionState,
                  file: StaticString = #filePath, line: UInt = #line) {
            let view = NSHostingView(rootView: ProjectsView(store: store))
            XCTAssertTrue(view.rootView.store === store, file: file, line: line)
            let row = store.rows.first { $0.reference.id == projectID }
            XCTAssertEqual(row?.completion, state, file: file, line: line)
            if let row {
                XCTAssertEqual(ProjectsView.displayedCompletion(row), state, file: file, line: line)
            }
            XCTAssertEqual(store.selectedID, projectID, file: file, line: line)
        }

        // Each refusal must be in the hosted store's row, with no manufactured Undo.
        for (failure, expected) in [
            (FeatureMutationFailure.conflict, ProjectCompletionState.failed(next, .conflict)),
            (.unpatchableSource, .failed(next, .unpatchableSource)),
            (.writeFailed, .failed(next, .writeFailed)),
            (.unverifiedWrite, .failed(next, .unverifiedWrite)),
            (.accessDenied, .failed(next, .accessDenied))
        ] {
            let inspector = PresentationInspector(inspection)
            let writer = PresentationWriter(inspector: inspector, failure: failure)
            let store = ProjectStore(inspector: inspector, repository: ListRepository([reference(projectID, order: 0)]),
                                     writer: writer)
            try await ready(store)
            let task = Task { await store.markComplete(next, in: projectID) }
            for _ in 0..<200 where !(await writer.hasWaitingCompletion()) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let waiting = await writer.hasWaitingCompletion()
            XCTAssertTrue(waiting)
            host(store, .writing(next))
            await writer.release()
            await task.value
            host(store, expected)
            XCTAssertFalse(store.canUndoCompletion(in: projectID))
            XCTAssertNil(store.undoFeatureID(in: projectID))
            XCTAssertEqual(ProjectsView.conflict(store.rows[0].completion, projectID: projectID) != nil,
                           failure == .conflict)
        }

        var now = Date(timeIntervalSince1970: 1_000)
        let inspector = PresentationInspector(inspection)
        let writer = PresentationWriter(inspector: inspector)
        let store = ProjectStore(inspector: inspector, repository: ListRepository([reference(projectID, order: 0)]),
                                 writer: writer, completionClock: { now })
        try await ready(store)
        await store.markComplete(first, in: projectID)
        host(store, .saved(first))
        XCTAssertEqual(store.undoFeatureID(in: projectID), first)
        XCTAssertTrue(store.canUndoCompletion(in: projectID))
        XCTAssertEqual(ProjectsView.undoActionTitle(feature: "Disk first", project: "Disk project"),
                       "Undo completion of Disk first in Disk project")

        // A failed attempt on another feature must not relabel the older token.
        await writer.failNextCompletion(.writeFailed)
        let failed = Task { await store.markComplete(next, in: projectID) }
        for _ in 0..<200 where !(await writer.hasWaitingCompletion()) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        host(store, .writing(next))
        await writer.release()
        await failed.value
        host(store, .failed(next, .writeFailed))
        XCTAssertEqual(store.undoFeatureID(in: projectID), first)
        XCTAssertTrue(store.canUndoCompletion(in: projectID))
        now.addTimeInterval(30)
        host(store, .failed(next, .writeFailed))
        XCTAssertNil(store.undoFeatureID(in: projectID))
        XCTAssertFalse(store.canUndoCompletion(in: projectID))

        var expiryClock = Date(timeIntervalSince1970: 2_000)
        let expiryInspector = PresentationInspector(inspection)
        let expiryStore = ProjectStore(inspector: expiryInspector,
            repository: ListRepository([reference(projectID, order: 0)]),
            writer: PresentationWriter(inspector: expiryInspector), completionClock: { expiryClock })
        try await ready(expiryStore)
        await expiryStore.markComplete(first, in: projectID)
        host(expiryStore, .saved(first))
        XCTAssertTrue(expiryStore.canUndoCompletion(in: projectID))
        expiryClock.addTimeInterval(30)
        host(expiryStore, .saved(first)) // Saved outcome remains true; Undo is now expired.
        XCTAssertNil(expiryStore.undoExpiration(in: projectID))
        XCTAssertFalse(expiryStore.canUndoCompletion(in: projectID))

        let undoInspector = PresentationInspector(inspection)
        let undoWriter = PresentationWriter(inspector: undoInspector)
        let undoStore = ProjectStore(inspector: undoInspector,
            repository: ListRepository([reference(projectID, order: 0)]), writer: undoWriter)
        try await ready(undoStore)
        await undoStore.markComplete(first, in: projectID)
        host(undoStore, .saved(first))
        await undoStore.undoCompletion(in: projectID)
        host(undoStore, .undoFailed(first, .undoConflict))
        XCTAssertNil(undoStore.undoFeatureID(in: projectID))
        XCTAssertEqual(ProjectsView.conflict(undoStore.rows[0].completion, projectID: projectID),
                       ProjectFeatureIdentity(projectID: projectID, featureID: first))

        let staleInspector = PresentationInspector(inspection)
        await staleInspector.failReconciliation()
        let staleStore = ProjectStore(inspector: staleInspector,
            repository: ListRepository([reference(projectID, order: 0)]),
            writer: PresentationWriter(inspector: staleInspector))
        try await ready(staleStore)
        await staleStore.markComplete(first, in: projectID)
        host(staleStore, .savedButRefreshFailed(first, .inspection(.inconsistentRead)))
        XCTAssertNil(staleStore.rows[0].inspection, "No unverified count may be shown")
        XCTAssertNil(ProjectsView.conflict(staleStore.rows[0].completion, projectID: projectID))
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

    func testFeatureDetailHostsSelectableLongMarkdownEmptyDependenciesRefreshAndStale() async throws {
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

    func testKeyboardFocusReturnAndAccessibleActionLabelsCompile() {
        let id = UUID()
        let feature = card("next", status: .ready)
        let inspection = cardInspection([feature, card("planned", status: .planned)])
        let row = ProjectRowState(reference: reference(id, order: 0), inspection: inspection)
        let cardOrigin: ProjectsView.NavigationFocus = .card(id, "next")
        let roadmapOrigin: ProjectsView.NavigationFocus = .roadmap(id, "planned")
        XCTAssertEqual(ProjectsView.returnFocus(origin: cardOrigin, row: row, roadmap: false), cardOrigin)
        XCTAssertEqual(ProjectsView.returnFocus(origin: roadmapOrigin, row: row, roadmap: true), roadmapOrigin)
        XCTAssertEqual(ProjectsView.returnFocus(origin: cardOrigin, row: row, roadmap: true), .projectHeading(id))
        XCTAssertEqual(ProjectsView.folderLabel(row), "Select project Disk project, Ready · 0 of 2 features completed")
        XCTAssertEqual(ProjectsView.cardLabel(feature), "View feature Disk title next, ready, medium priority, small effort")
        XCTAssertEqual(ProjectDetailsView.roadmapLabel(inspection.features[1]),
                       "View feature Disk title planned, planned, ID planned in validated roadmap")
        let detail = NSHostingView(rootView: ProjectFeatureDetailView(row: row, featureID: "next",
            backToRoadmap: false, back: {}))
        XCTAssertEqual(detail.rootView.backLabel, "Back to projects from feature Disk title next")
        var removed = row
        removed.inspection = cardInspection([inspection.features[1]])
        XCTAssertEqual(ProjectsView.returnFocus(origin: cardOrigin, row: removed, roadmap: false), .projectHeading(id),
                       "A deleted card must not receive keyboard focus")
        XCTAssertEqual(ProjectsView.returnFocus(origin: roadmapOrigin, row: removed, roadmap: true), roadmapOrigin)
        removed.inspection = cardInspection([])
        XCTAssertEqual(ProjectsView.returnFocus(origin: roadmapOrigin, row: removed, roadmap: true), .projectHeading(id),
                       "An excluded roadmap item must fall back to the selected-project heading")
        removed.inspection = nil
        XCTAssertEqual(ProjectsView.returnFocus(origin: cardOrigin, row: removed, roadmap: false), .projectHeading(id))
        XCTAssertNil(ProjectsView.returnFocus(origin: cardOrigin, row: nil, roadmap: false))
        // Native keyboard, VoiceOver, zoom and window-size observations remain F13 checks.
    }

    func testCompletionFocusTargetsAndRecoveryLabelsCompile() {
        let id = UUID(), otherID = UUID()
        let ready = card("ready")
        let completed = card("ready", status: .completed)
        let row = ProjectRowState(reference: reference(id, order: 0), inspection: cardInspection([ready]))
        let cardAction: ProjectsView.NavigationFocus = .cardCompletion(id, "ready")
        let detailAction: ProjectsView.NavigationFocus = .detailCompletion(id, "ready")
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: cardAction, row: row,
            detailVisible: false, canComplete: true), cardAction,
            "An unsuccessful write keeps the surviving card completion action reachable")
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: detailAction, row: row,
            detailVisible: true, canComplete: true), detailAction)
        var saved = row
        saved.inspection = cardInspection([completed])
        saved.completion = .saved("ready")
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: cardAction, row: saved,
            detailVisible: false, canComplete: false), .projectHeading(id),
            "A completed card disappears; focus the selected project's heading")
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: detailAction, row: saved,
            detailVisible: true, canComplete: false), .featureHeading,
            "Selected detail survives completion with a focusable heading and Back action")
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: detailAction, row: saved,
            detailVisible: false, canComplete: false), .projectHeading(id))
        var retained = row
        retained.isRetainedInspection = true
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: cardAction, row: retained,
            detailVisible: false, canComplete: false), .projectHeading(id))
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: detailAction, row: retained,
            detailVisible: true, canComplete: false), .featureHeading)
        XCTAssertEqual(ProjectsView.completionReturnFocus(origin: cardAction,
            row: ProjectRowState(reference: reference(otherID, order: 1), inspection: row.inspection),
            detailVisible: false, canComplete: true), .projectHeading(otherID),
            "A selection switch must never focus a prior project's control")
        XCTAssertNil(ProjectsView.completionReturnFocus(origin: cardAction, row: nil,
            detailVisible: false, canComplete: false))
        XCTAssertEqual(ProjectFeatureDetailView.completionLabel(for: ready, state: nil),
                       "Mark Disk title ready complete")
        XCTAssertEqual(ProjectsView.undoActionTitle(feature: "Disk title ready", project: "Disk project"),
                       "Undo completion of Disk title ready in Disk project")
        XCTAssertEqual(ProjectsView.conflict(.failed("ready", .conflict), projectID: id),
                       ProjectFeatureIdentity(projectID: id, featureID: "ready"))
        XCTAssertEqual(ProjectsView.completionRecovery(.failed("ready", .conflict)), .refresh)
        XCTAssertEqual(ProjectsView.completionRecovery(.failed("ready", .accessDenied)), .reconnect)
        let conflict = ProjectFeatureIdentity(projectID: id, featureID: "ready")
        let otherDetail = ProjectFeatureIdentity(projectID: otherID, featureID: "ready")
        retained.completion = .failed("ready", .conflict)
        let retainedDetail = NSHostingView(rootView: ProjectFeatureDetailView(row: retained,
            featureID: "ready", backToRoadmap: false, back: {}))
        XCTAssertEqual(retainedDetail.rootView.feature?.id, conflict.featureID)
        XCTAssertEqual(ProjectsView.conflict(retained.completion, projectID: id), conflict)
        XCTAssertEqual(ProjectsView.conflictRefreshFocus(projectID: id, selectedFeature: conflict,
            detailAvailable: true), .featureHeading,
            "Refresh from a retained feature detail must focus its rendered heading, not the absent workspace heading")
        XCTAssertEqual(ProjectsView.conflictRefreshFocus(projectID: id, selectedFeature: conflict,
            detailAvailable: false), .projectHeading(id),
            "If Refresh closes the detail, focus the selected project's heading")
        XCTAssertEqual(ProjectsView.conflictRefreshFocus(projectID: id, selectedFeature: otherDetail,
            detailAvailable: true), .projectHeading(id),
            "A selection switch must not focus another project's detail")
        XCTAssertEqual(ProjectsView.conflictRefreshFocus(projectID: id, selectedFeature: nil,
            detailAvailable: false), .projectHeading(id),
            "Refresh from the workspace keeps its heading reachable")
        let host = NSHostingView(rootView: ProjectFeatureDetailView(row: saved, featureID: "ready",
            backToRoadmap: false, back: {}))
        XCTAssertEqual(host.rootView.feature?.status, .completed)
        // Native tab order, alert focus, VoiceOver and layout measurements remain F13 checks.
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
