import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

private actor SettingsCatalogGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SettingsNewsSpy: NewsRefreshing {
    private(set) var requests = 0
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] { requests += 1; return [] }
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        requests += 1
        throw FeedServiceError(code: .offline, retryNotBefore: nil)
    }
}

@MainActor
private final class SettingsPreferencesSpy: AppPreferencesRepository {
    var value: AppPreferencesSnapshot = .defaults
    var readFailure: AppPreferencesError?
    var saveFailure: AppPreferencesError?
    private(set) var saves = 0
    private(set) var loads = 0
    func load() throws -> AppPreferencesSnapshot {
        loads += 1
        if let readFailure { throw readFailure }
        return value
    }
    func save(_ draft: AppPreferencesDraft, expectedRevision: UUID?) throws -> AppPreferencesSnapshot {
        saves += 1
        if let saveFailure { throw saveFailure }
        guard expectedRevision == value.revision else { throw AppPreferencesError.staleRevision }
        value = AppPreferencesSnapshot(preferences: try draft.validated(), revision: UUID())
        return value
    }
}

private actor SettingsFolderInspectorSpy: ProjectInspecting {
    private(set) var calls = 0
    func inspect(selectedFolder: URL) async throws -> ProjectInspection { calls += 1; throw CancellationError() }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection { calls += 1; throw CancellationError() }
    func makeBookmark(selectedFolder: URL) async throws -> Data { calls += 1; throw CancellationError() }
}

@MainActor
private final class SettingsFolderRepository: ProjectReferenceRepository {
    var references: [ProjectReferenceSnapshot]
    var loadFailure: Error?
    var removeFailure: Error?
    private(set) var removals: [(UUID, UUID)] = []
    private(set) var loads = 0

    init(_ references: [ProjectReferenceSnapshot] = []) { self.references = references }
    func fetchAll() throws -> [ProjectReferenceSnapshot] {
        loads += 1
        if let loadFailure { throw loadFailure }
        return references
    }
    func remove(id: UUID, expectedRevision: UUID) throws {
        removals.append((id, expectedRevision))
        if let removeFailure { throw removeFailure }
        guard let reference = references.first(where: { $0.id == id }) else {
            throw ProjectReferencePersistenceError.notFound
        }
        guard reference.revision == expectedRevision else { throw ProjectReferencePersistenceError.staleRevision }
        references.removeAll { $0.id == id }
    }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot { throw CancellationError() }
    func reconnect(id: UUID, expectedRevision: UUID, input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot { throw CancellationError() }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID, nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot { throw CancellationError() }
}

@MainActor
private final class SettingsExportPanel: ExportDestinationSelecting {
    private(set) var selections = 0
    var failure: Error?
    var continuation: CheckedContinuation<ExportDestinationSelection, Never>?
    func selectDestination(suggestedAt date: Date) async throws -> ExportDestinationSelection {
        selections += 1
        if let failure { throw failure }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ selection: ExportDestinationSelection) {
        continuation?.resume(returning: selection)
        continuation = nil
    }
}

@MainActor
private final class SettingsExportRepository: ExportRepository {
    let repository: SwiftDataExportRepository
    var failure: Error?
    private(set) var captures = 0
    init(container: ModelContainer) { repository = SwiftDataExportRepository(container: container) }
    func snapshot(exportedAt: Date, appVersion: String) throws -> LocalDataExport {
        captures += 1
        if let failure { throw failure }
        // Fixture version only: production keeps the bundle-derived version.
        return try repository.snapshot(exportedAt: exportedAt, appVersion: "1.0")
    }
}

private actor SettingsExportPreparationGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct SettingsExportWriter: ExportFilePreparing, ExportFileDelivering {
    let writer: ExportFileWriter
    let gate: SettingsExportPreparationGate
    var failure: ExportService.Failure? = nil
    func approveDestination(_ url: URL) throws -> ApprovedExportDestination { try writer.approveDestination(url) }
    func prepare(_ snapshot: LocalDataExport) async throws -> PreparedExportArtifact {
        await gate.wait()
        try Task.checkCancellation()
        if failure == .preparation { throw ExportFileWriterError.preparationFailed }
        return try await writer.prepare(snapshot)
    }
    func deliver(_ artifact: PreparedExportArtifact, to destination: ApprovedExportDestination) async throws -> ExportDeliveryOutcome {
        if failure == .delivery { throw ExportFileWriterError.deliveryFailed }
        if failure == .cleanup {
            // Remove only this fixture's private artifact directory. The real
            // ownership boundary will then fail its required cleanup confirmation
            // (ENOENT), without leaving personal-data artifacts on disk.
            return try artifact.consume { url in
                try FileManager.default.removeItem(at: url.deletingLastPathComponent())
                throw ExportFileWriterError.deliveryFailed
            }
        }
        return try await writer.deliver(artifact, to: destination)
    }
}

@MainActor
final class SettingsSceneTests: XCTestCase {
    // Non-GUI presentation contract: safe categories, truthful outcomes, explicit
    // retry, and cancellation only while an operation still owns the lifecycle.
    func testLocalDataPresentationUsesActualStateAndSafeFailureCategories() {
        let fixtures: [(ExportService.State, String, String, Bool)] = [
            (.idle, "Ready to export", "Export…", false),
            (.selecting, "Choosing export destination…", "Export…", true),
            (.preparing, "Preparing local data…", "Export…", true),
            (.saved, "Export saved", "Export another snapshot…", false),
            (.canceled, "Export canceled · no file saved", "Export again…", false)
        ]
        for (state, status, action, cancel) in fixtures {
            let value = LocalDataSettingsView.presentation(state)
            XCTAssertEqual(value.status, status)
            XCTAssertEqual(value.actionTitle, action)
            XCTAssertEqual(value.canCancel, cancel)
            XCTAssertFalse(value.symbol.isEmpty)
            XCTAssertEqual(LocalDataSettingsView.summary(state), "Local data: \(status)")
        }
        let failures: [ExportService.Failure] = [.selection, .answerSave, .capture, .preparation, .delivery, .cleanup]
        let details = failures.map { LocalDataSettingsView.presentation(.failed($0)).detail }
        XCTAssertEqual(Set(details).count, failures.count, "Each failure needs its own safe recovery category")
        for failure in failures {
            let value = LocalDataSettingsView.presentation(.failed(failure))
            XCTAssertEqual(value.status, "Export not saved")
            XCTAssertEqual(value.actionTitle, "Retry export…")
            XCTAssertFalse(value.canCancel)
            XCTAssertFalse(value.detail.contains("/"), "No paths or raw diagnostics belong in presentation")
            XCTAssertEqual(LocalDataSettingsView.summary(.failed(failure)), "Local data: Export not saved")
        }
        XCTAssertTrue(details[1].contains("unsaved answers are retained"))
        XCTAssertTrue(details[5].contains("cleanup could not be confirmed"))
        XCTAssertTrue(LocalDataSettingsView.privacyGuidance.contains("No import or restore"))
        XCTAssertTrue(LocalDataSettingsView.privacyGuidance.contains("not an encrypted backup"))
    }

    // Hosted coverage: execute with A13's reserved native desktop, not inferred
    // from this task's non-GUI validation or compilation.
    func testNativeLocalDataRoutesShareSelectingPreparingCanceledFailureRetryAndSavedResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let panel = SettingsExportPanel()
        let repository = SettingsExportRepository(container: container)
        let gate = SettingsExportPreparationGate()
        let writer = SettingsExportWriter(writer: ExportFileWriter(temporaryRoot: root), gate: gate)
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
                                    exportRepository: repository, exportPanel: panel, exportWriter: writer)
        let launch = LaunchCoordinator(open: { container }, makeDependencies: { _, _ in graph })
        await launch.start()
        let navigation = NavigationStore()
        navigation.select(.settings)
        let native = show(SettingsSceneContent(launch: launch))
        let inline = show(MainWindowContent(launch: launch, navigation: navigation))
        defer { native.orderOut(nil); inline.orderOut(nil) }
        let windows = [native, inline]
        let generalClient = show(ScrollView { FoundationSettingsView(dependencies: graph) })
        defer { generalClient.orderOut(nil) }
        try press("settings-general", in: generalClient)
        try choose("Duration", item: "Custom", in: generalClient)
        try input("00037", in: generalClient)
        func waitForPanel() async throws {
            for _ in 0..<200 {
                if panel.continuation != nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Injected panel did not open")
        }
        func status(in window: NSWindow) throws -> String {
            settle()
            let element = try node("settings-export-status", in: window)
            return (axAttribute(element, kAXValueAttribute) as? String) ??
                (axAttribute(element, kAXDescriptionAttribute) as? String) ?? ""
        }
        for window in windows {
            XCTAssertEqual(try value("settings-local-data-summary", in: window), "Local data: Ready to export")
            try press("settings-local-data", in: window)
            for identifier in ["settings-local-data-content", "settings-export-inclusions", "settings-export-exclusions",
                               "settings-export-answer-guidance", "settings-export-privacy", "settings-export-start"] {
                _ = try node(identifier, in: window)
            }
        }
        try press("settings-export-start", in: native)
        try await waitForPanel()
        for window in windows {
            XCTAssertTrue(try status(in: window).contains("Choosing export destination"))
            _ = try node("settings-export-cancel", in: window)
        }
        XCTAssertFalse(graph.exportService.startExport(), "Second client cannot overlap selection")
        try press("settings-export-cancel", in: inline)
        panel.finish(.canceled)
        await graph.exportService.waitForCompletion()
        XCTAssertEqual(repository.captures, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        for window in windows { XCTAssertTrue(try status(in: window).contains("no file saved")) }
        repository.failure = NSError(domain: "sensitive /private/credential", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/private/secret.json token=secret"])
        try press("settings-export-start", in: inline)
        try await waitForPanel()
        let destination = try writer.approveDestination(root.appendingPathComponent("export.json"))
        panel.finish(.approved(destination))
        await graph.exportService.waitForCompletion()
        for window in windows {
            XCTAssertTrue(try status(in: window).contains("Export not saved"))
            XCTAssertEqual(try value("settings-export-detail", in: window), LocalDataSettingsView.presentation(.failed(.capture)).detail)
        }
        repository.failure = nil
        try press("settings-export-start", in: native)
        try await waitForPanel()
        panel.finish(.approved(destination))
        for _ in 0..<200 {
            if graph.exportService.state == .preparing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(graph.exportService.state, .preparing)
        for window in windows { XCTAssertTrue(try status(in: window).contains("Preparing local data")) }
        XCTAssertFalse(graph.exportService.startExport())
        // Leaving/reopening the section neither cancels nor resets shared work.
        try press("settings-back", in: inline)
        XCTAssertEqual(try value("settings-local-data-summary", in: inline), "Local data: Preparing local data…")
        try press("settings-local-data", in: inline)
        await gate.release()
        await graph.exportService.waitForCompletion()
        XCTAssertEqual(graph.exportService.state, .saved)
        XCTAssertNoThrow(try LocalDataExport.decode(Data(contentsOf: root.appendingPathComponent("export.json"))))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["export.json"])
        for window in windows {
            XCTAssertTrue(try status(in: window).contains("Export saved"))
            try press("settings-back", in: window)
            XCTAssertEqual(try value("settings-local-data-summary", in: window), "Local data: Export saved")
        }
        XCTAssertEqual(panel.selections, 3)
        XCTAssertEqual(try value("preferences-custom-minutes", in: generalClient), "00037",
                       "Shared export publications must not overwrite another client's General draft")
        XCTAssertEqual(graph.appPreferencesStore.committed, .defaults)
        XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: container).load(), .defaults)
    }

    // Native adapter fixture: compile during Step 3.3; execute with the A13
    // hosted/native gate. This does not observe actual cancellation/replacement.
    func testNativeExportPanelAppliesJSONConfigurationWithoutOverridingReplacementConfirmation() throws {
        let adapter = NativeExportSavePanel()
        let date = try ExportTimestamp(value: "2026-09-30T23:59:59.999Z").date
        adapter.configure(ExportSavePanelConfiguration(date: date))
        XCTAssertEqual(adapter.panel.allowedContentTypes.map(\.identifier), ["public.json"])
        XCTAssertFalse(adapter.panel.allowsOtherFileTypes)
        XCTAssertFalse(adapter.panel.isExtensionHidden)
        XCTAssertTrue(adapter.panel.canCreateDirectories)
        XCTAssertEqual(adapter.panel.nameFieldStringValue, "kontrol-export-2026-09-30.json")
        XCTAssertNil(adapter.panel.delegate, "Native replacement validation must not be overridden")
        XCTAssertNil(adapter.panel.accessoryView)
    }

    private func folderReference(_ id: UUID = UUID(), revision: UUID = UUID(), name: String = "Harbor", order: Int = 0) -> ProjectReferenceSnapshot {
        ProjectReferenceSnapshot(id: id, manifestID: "harbor", bookmarkData: Data([1]), displayOrder: order,
                                 displayNameHint: name, lastSuccessfulReadAt: nil, revision: revision)
    }

    // Explicit non-GUI selections: no NSWindow, AX, panels, or external-folder IO.
    func testFolderConfirmationCapturesNameIdentityRevisionCancelAndDurableSuccessAcrossClients() async throws {
        let reference = folderReference()
        let survivor = folderReference(name: "Peer", order: 1)
        let repository = SettingsFolderRepository([reference, survivor])
        let inspector = SettingsFolderInspectorSpy()
        let store = ProjectStore(inspector: inspector, repository: repository)
        let first = ProjectFoldersSettingsState(store: store)
        let second = ProjectFoldersSettingsState(store: store)
        first.load(); second.load()
        XCTAssertEqual(repository.loads, 1)
        XCTAssertTrue(first.store === second.store)
        XCTAssertEqual(ProjectFoldersSettingsView.summary(store), "Project folders: 2 saved references")
        first.requestRemoval(reference.id)
        let target = try XCTUnwrap(first.confirmation)
        XCTAssertEqual(target.id, reference.id)
        XCTAssertEqual(target.revision, reference.revision)
        XCTAssertEqual(target.name, "Harbor")
        XCTAssertEqual(target.title, "Remove Harbor?")
        XCTAssertTrue(target.message.contains("files remain on disk"))
        XCTAssertTrue(target.message.contains(".kontrol and Git"))
        first.cancel(); first.confirm()
        XCTAssertEqual(first.outcome, .canceled("Harbor"))
        XCTAssertTrue(repository.removals.isEmpty)
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertEqual(ProjectFoldersSettingsView.returnFocus(origin: .remove(reference.id), rows: store.rows,
            requiresReview: first.requiresReview, loadFailed: store.loadFailed), .remove(reference.id))
        first.requestRemoval(reference.id)
        second.requestRemoval(reference.id)
        first.confirm()
        XCTAssertEqual(first.outcome, .removed("Harbor"))
        XCTAssertEqual(repository.removals.count, 1)
        XCTAssertEqual(repository.removals.first?.1, reference.revision)
        XCTAssertEqual(store.selectedID, survivor.id)
        XCTAssertEqual(second.store.rows.map(\.reference.id), [survivor.id])
        XCTAssertEqual(ProjectFoldersSettingsView.returnFocus(origin: .remove(reference.id), rows: store.rows,
            requiresReview: first.requiresReview, loadFailed: store.loadFailed), .remove(survivor.id))
        second.confirm()
        XCTAssertEqual(second.outcome, .stale("Harbor"))
        XCTAssertTrue(second.requiresReview)
        XCTAssertEqual(repository.removals.count, 1, "Missing store identity must not submit another deletion")
        second.review()
        XCTAssertFalse(second.requiresReview)
        second.requestRemoval(survivor.id)
        second.confirm()
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(ProjectFoldersSettingsView.returnFocus(origin: .remove(survivor.id), rows: store.rows,
            requiresReview: second.requiresReview, loadFailed: store.loadFailed), .add)
        XCTAssertEqual(ProjectFoldersSettingsView.summary(store), "Project folders: 0 saved references")
        store.refreshOnMainWindowActivation()
        let calls = await inspector.calls
        XCTAssertEqual(calls, 0, "Listing, reviewing and removing do not admit external inspection")
    }

    func testFolderStaleConfirmationRequiresSuccessfulExplicitReloadAndSeparateReconfirmation() async throws {
        let original = folderReference()
        let repository = SettingsFolderRepository([original])
        let inspector = SettingsFolderInspectorSpy()
        let store = ProjectStore(inspector: inspector, repository: repository)
        let management = ProjectFoldersSettingsState(store: store)
        management.load()
        management.requestRemoval(original.id)
        let revised = folderReference(original.id, name: "Renamed elsewhere")
        repository.references = [revised]
        // Another client may reload or a read receipt may advance the row while the alert is open.
        try store.reloadReferences()
        XCTAssertEqual(management.confirmation?.revision, original.revision)
        XCTAssertEqual(management.confirmation?.name, original.displayNameHint)
        management.confirm()
        XCTAssertEqual(management.outcome, .stale("Harbor"))
        XCTAssertEqual(ProjectFoldersSettingsView.returnFocus(origin: .remove(original.id), rows: store.rows,
            requiresReview: management.requiresReview, loadFailed: store.loadFailed), .review)
        XCTAssertTrue(repository.removals.isEmpty)
        management.requestRemoval(original.id)
        XCTAssertNil(management.confirmation, "Cannot silently rebase a stale confirmation")
        repository.loadFailure = ProjectReferencePersistenceError.invalidReference
        management.review()
        XCTAssertTrue(management.requiresReview)
        XCTAssertEqual(management.outcome, .unavailable)
        XCTAssertEqual(store.rows.first?.reference, revised)
        XCTAssertEqual(ProjectFoldersSettingsView.returnFocus(origin: .review, rows: store.rows,
            requiresReview: management.requiresReview, loadFailed: store.loadFailed), .review)
        management.requestRemoval(original.id)
        XCTAssertNil(management.confirmation)
        repository.loadFailure = nil
        management.review()
        XCTAssertEqual(management.outcome, .reviewed)
        XCTAssertTrue(repository.removals.isEmpty, "Review never retries deletion")
        management.requestRemoval(original.id)
        XCTAssertEqual(management.confirmation?.name, "Renamed elsewhere")
        XCTAssertEqual(management.confirmation?.revision, revised.revision)
        management.confirm()
        XCTAssertEqual(management.outcome, .removed("Renamed elsewhere"))
        XCTAssertEqual(repository.removals.first?.1, revised.revision)
        let calls = await inspector.calls
        XCTAssertEqual(calls, 0)
    }

    func testFolderUnavailableMissingBusyAndFailedOutcomesNeverAutomaticallyDelete() throws {
        let reference = folderReference()
        let repository = SettingsFolderRepository([reference])
        repository.loadFailure = ProjectReferencePersistenceError.invalidReference
        let store = ProjectStore(inspector: SettingsFolderInspectorSpy(), repository: repository)
        let management = ProjectFoldersSettingsState(store: store)
        management.load()
        XCTAssertEqual(management.outcome, .unavailable)
        XCTAssertFalse(store.isLoaded)
        XCTAssertEqual(ProjectFoldersSettingsView.summary(store), "Project folders: saved references unavailable")
        repository.loadFailure = nil
        management.load()
        XCTAssertNil(management.outcome, "A successful later entry must retire initial unavailability")
        management.review()
        for (failure, expected) in [(ProjectStoreError.busy as Error, ProjectFoldersSettingsState.Outcome.busy),
                                    (ProjectReferencePersistenceError.invalidReference, .failed("Harbor"))] {
            repository.removeFailure = failure
            management.requestRemoval(reference.id)
            management.confirm()
            XCTAssertEqual(management.outcome, expected)
            XCTAssertEqual(store.rows.first?.reference, reference)
            XCTAssertEqual(ProjectFoldersSettingsView.returnFocus(origin: .remove(reference.id), rows: store.rows,
                requiresReview: management.requiresReview, loadFailed: store.loadFailed), .remove(reference.id))
            XCTAssertNil(management.confirmation)
            management.confirm()
        }
        XCTAssertEqual(repository.removals.count, 2, "No implicit retry after busy or failed removal")
        repository.removeFailure = nil
        management.requestRemoval(reference.id)
        repository.references = [] // Authoritative missing identity, without a prior store reload.
        management.confirm()
        XCTAssertEqual(management.outcome, .stale("Harbor"))
        XCTAssertTrue(management.requiresReview)
        XCTAssertEqual(store.rows.first?.reference, reference)
        management.review()
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertFalse(management.requiresReview)
    }

    private func folderOutcome(in window: NSWindow) throws -> String {
        let element = try node("settings-folders-result", in: window)
        // Native Label may expose its combined text as a description rather than value.
        return try XCTUnwrap((axAttribute(element, kAXValueAttribute) as? String) ??
                             (axAttribute(element, kAXDescriptionAttribute) as? String))
    }

    func testNativeFolderRouteNamedCancelStaleReviewFailureAndSuccessUseSharedStore() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let reference = folderReference()
        let repository = SettingsFolderRepository([reference])
        let inspector = SettingsFolderInspectorSpy()
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
                                    projectInspector: inspector, projectRepository: repository)
        let first = show(ScrollView { FoundationSettingsView(dependencies: graph) })
        let second = show(ScrollView { FoundationSettingsView(dependencies: graph) })
        defer { first.orderOut(nil); second.orderOut(nil) }
        for window in [first, second] {
            try press("settings-folders", in: window)
            _ = try node("settings-folders-content", in: window)
        }
        let removeID = "settings-folder-remove-\(reference.id.uuidString)"
        func dialogButton(_ name: String, window: NSWindow) throws -> AXUIElement {
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let deadline = Date().addingTimeInterval(2)
            repeat {
                if let button = axDescendants(app).first(where: {
                    axAttribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                    axAttribute($0, kAXDescriptionAttribute) as? String == name
                }) { return button }
                settle()
            } while Date() < deadline
            throw NSError(domain: "SettingsSceneTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing folder alert button \(name)"])
        }
        func dismiss(_ name: String) throws {
            XCTAssertEqual(AXUIElementPerformAction(try dialogButton(name, window: first), kAXPressAction as CFString), .success)
            settle()
        }
        try press(removeID, in: first)
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        for text in ["Remove Harbor?", "files remain on disk"] {
            XCTAssertTrue(axDescendants(app).contains {
                ((axAttribute($0, kAXValueAttribute) as? String) ?? (axAttribute($0, kAXDescriptionAttribute) as? String) ?? "").contains(text)
            }, "Confirmation must name its captured target and explain local-only removal: \(text)")
        }
        try dismiss("Cancel")
        XCTAssertTrue(repository.removals.isEmpty)
        XCTAssertTrue(try folderOutcome(in: first).contains("canceled"))
        try press(removeID, in: first)
        repository.references = [folderReference(reference.id, name: "Current Harbor")]
        try dismiss("Remove from Kontrol")
        XCTAssertTrue(try folderOutcome(in: first).contains("Reload & review"))
        XCTAssertEqual((axAttribute(try node(removeID, in: first), kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
        try press("settings-back", in: first)
        try press("settings-folders", in: first)
        XCTAssertEqual((axAttribute(try node(removeID, in: first), kAXEnabledAttribute) as? NSNumber)?.boolValue, false,
                       "Back/re-entry must not bypass explicit stale review")
        try press("settings-folders-reload", in: first)
        XCTAssertEqual(repository.removals.count, 1, "Reload is not an automatic deletion retry")
        repository.removeFailure = ProjectReferencePersistenceError.invalidReference
        try press(removeID, in: first)
        try dismiss("Remove from Kontrol")
        XCTAssertTrue(try folderOutcome(in: first).contains("was not removed"))
        repository.removeFailure = nil
        try press(removeID, in: first)
        try dismiss("Remove from Kontrol")
        for window in [first, second] { _ = try node("settings-folders-empty", in: window) }
        XCTAssertTrue(try folderOutcome(in: first).contains("Current Harbor removed"))
        try press("settings-back", in: first)
        XCTAssertEqual(try value("settings-folders-summary", in: first), "Project folders: 0 saved references")
        let calls = await inspector.calls
        XCTAssertEqual(calls, 0)
    }

    func testNativeFolderUnavailableRetryAndBusyOutcomeRetainReferences() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let reference = folderReference()
        let repository = SettingsFolderRepository([reference])
        repository.loadFailure = ProjectReferencePersistenceError.invalidReference
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
                                    projectInspector: SettingsFolderInspectorSpy(), projectRepository: repository)
        let window = show(ScrollView { FoundationSettingsView(dependencies: graph) })
        defer { window.orderOut(nil) }
        try press("settings-folders", in: window)
        _ = try node("settings-folders-unavailable", in: window)
        XCTAssertTrue(try folderOutcome(in: window).contains("could not be loaded"))
        repository.loadFailure = nil
        try press("settings-folders-reload", in: window)
        repository.removeFailure = ProjectStoreError.busy
        try press("settings-folder-remove-\(reference.id.uuidString)", in: window)
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let button = try XCTUnwrap(axDescendants(app).first {
            axAttribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
            axAttribute($0, kAXDescriptionAttribute) as? String == "Remove from Kontrol"
        })
        XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(try folderOutcome(in: window).contains("Nothing was removed or queued"))
        XCTAssertEqual(graph.projectStore.rows.first?.reference, reference)
        XCTAssertEqual(repository.removals.count, 1)
        try press("settings-back", in: window)
        XCTAssertEqual(try value("settings-folders-summary", in: window), "Project folders: 1 saved reference")
    }

    private func show<V: View>(_ view: V, size: CGSize = CGSize(width: 1000, height: 1000)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Settings behavior \(UUID().uuidString)"
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func node(_ identifier: String, in window: NSWindow) throws -> AXUIElement {
        let root = try axWindow(window)
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let found = axDescendants(root).first(where: {
                axAttribute($0, kAXIdentifierAttribute) as? String == identifier
            }) { return found }
            settle()
        } while Date() < deadline
        let identifiers = axDescendants(root).compactMap { axAttribute($0, kAXIdentifierAttribute) as? String }
        throw NSError(domain: "SettingsSceneTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing rendered control: \(identifier); present: \(identifiers)"])
    }

    private func press(_ identifier: String, in window: NSWindow) throws {
        try reveal(identifier, in: window)
        XCTAssertEqual(AXUIElementPerformAction(try node(identifier, in: window), kAXPressAction as CFString), .success)
        settle()
    }

    private func input(_ text: String, in window: NSWindow) throws {
        try reveal("preferences-custom-minutes", in: window)
        window.makeKeyAndOrderFront(nil)
        XCTAssertEqual(AXUIElementSetAttributeValue(try node("preferences-custom-minutes", in: window),
                                                  kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle()
    }

    private func value(_ identifier: String, in window: NSWindow) throws -> String {
        try XCTUnwrap(axAttribute(try node(identifier, in: window), kAXValueAttribute) as? String)
    }

    /// Dispatch the real native popup's target/action, not an editor/test binding.
    private func choose(_ title: String, item: String, in window: NSWindow) throws {
        func popups(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
        }
        let popup = try XCTUnwrap(window.contentView.flatMap { popups($0).first { $0.accessibilityLabel() == title } })
        _ = popup.scrollToVisible(popup.bounds)
        settle()
        let index = popup.indexOfItem(withTitle: item)
        XCTAssertGreaterThanOrEqual(index, 0)
        popup.selectItem(at: index)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        settle()
    }

    func testNativeGeneralEditorPresetsCustomValidationSaveCancelAndCommittedSummaries() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SettingsPreferencesSpy()
        let news = SettingsNewsSpy()
        var generators = 0
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
            appPreferencesRepository: repository, aiGenerator: { model, reference, credentials in
                generators += 1
                return OpenAILessonGenerator(model: model, credentialReference: reference, credentials: credentials)
            }, newsService: news)
        let window = show(FoundationSettingsView(dependencies: graph))
        defer { window.orderOut(nil) }
        try press("settings-general", in: window)
        try choose("Duration", item: "15 minutes", in: window)
        try press("preferences-save", in: window)
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 15 minutes")
        XCTAssertEqual(repository.saves, 1)
        try press("settings-general", in: window)
        try choose("Duration", item: "50 minutes", in: window)
        try press("preferences-cancel", in: window)
        XCTAssertEqual(repository.saves, 1, "Cancel must not persist")
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 15 minutes")
        try press("settings-general", in: window)
        try choose("Duration", item: "Custom", in: window)
        try input("1.5", in: window)
        try choose("Text size", item: "Large · at least 130%", in: window)
        try choose("Motion", item: "Reduce", in: window)
        try press("preferences-save", in: window)
        _ = try node("preferences-error", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "1.5")
        XCTAssertEqual(repository.saves, 1, "Invalid input never reaches persistence")
        XCTAssertEqual(graph.appPreferencesStore.committed?.preferences.focusDefaultMinutes, 15)
        try input("25", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "25", "Typing a preset must not collapse Custom")
        try input("00037", in: window)
        try press("preferences-save", in: window)
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 37 minutes")
        XCTAssertEqual(try value("settings-appearance-summary", in: window), "37 minutes · Large text · Reduced motion")
        XCTAssertEqual(repository.saves, 2)
        _ = try node("settings-preferences-saved", in: window)
        try press("settings-ai", in: window)
        for identifier in ["ai-settings", "ai-edit", "ai-enable", "ai-test-connection"] { _ = try node(identifier, in: window) }
        try press("settings-back", in: window)
        try press("settings-news", in: window)
        _ = try node("news-management", in: window)
        try press("settings-back", in: window)
        let snapshot = try XCTUnwrap(graph.newsStore.snapshot)
        let enabled = snapshot.feeds.filter(\.isEnabled).count
        XCTAssertEqual(try value("settings-news-summary", in: window),
                       "News: \(NewsManagementView.selectedCountText(snapshot)) · \(enabled) of \(snapshot.feeds.count) feeds enabled")
        let requests = await news.requests
        XCTAssertEqual(requests, 0, "Opening every Settings section and saving general preferences must not refresh/validate feeds")
        XCTAssertEqual(generators, 0, "Opening Settings must not construct a lesson generator")
        XCTAssertNoThrow(try graph.lessonDraftStore.flushAll())
    }

    func testNativeSaveFailureAndCrossWindowStaleReviewRetainDraftUntilExplicitSave() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SettingsPreferencesSpy()
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
                                    appPreferencesRepository: repository)
        let first = show(FoundationSettingsView(dependencies: graph))
        let second = show(FoundationSettingsView(dependencies: graph))
        defer { first.orderOut(nil); second.orderOut(nil) }
        try press("settings-general", in: first)
        try press("settings-general", in: second)
        try choose("Duration", item: "50 minutes", in: first)
        try choose("Duration", item: "Custom", in: second)
        try input("00037", in: second)
        try choose("Text size", item: "Large · at least 130%", in: second)
        try choose("Motion", item: "Reduce", in: second)
        repository.saveFailure = .persistenceFailure
        try press("preferences-save", in: second)
        _ = try node("preferences-error", in: second)
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        XCTAssertEqual(graph.appPreferencesStore.committed, .defaults)
        repository.saveFailure = nil
        try press("preferences-save", in: first)
        _ = try node("preferences-review", in: second)
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        let beforeReview = repository.saves
        try press("preferences-review", in: second)
        XCTAssertEqual(repository.saves, beforeReview, "Review reads/rebases only; never saves")
        XCTAssertEqual(try value("preferences-latest-saved", in: second), "Latest saved: 50 minutes · System text · System motion")
        repository.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 15), revision: UUID())
        try press("preferences-save", in: second)
        _ = try node("preferences-error", in: second)
        _ = try node("preferences-review", in: second)
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 15, "External stale baseline cannot be overwritten")
        try press("preferences-review", in: second)
        XCTAssertEqual(try value("preferences-latest-saved", in: second), "Latest saved: 15 minutes · System text · System motion")
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        try press("preferences-save", in: second)
        XCTAssertEqual(repository.value.preferences, try AppPreferences(focusDefaultMinutes: 37, textSize: .large, reduceMotion: .reduce))
        for window in [first, second] {
            XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 37 minutes")
        }
    }

    func testUnreadablePreferencesHaveExplicitRetryAndReviewWithoutAuthorizingFallbackSave() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SettingsPreferencesSpy()
        repository.readFailure = .invalidStoredData
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
                                    appPreferencesRepository: repository)
        let window = show(FoundationSettingsView(dependencies: graph))
        defer { window.orderOut(nil) }
        _ = try node("settings-preferences-unavailable", in: window)
        try press("settings-preferences-retry", in: window)
        XCTAssertEqual(repository.loads, 2)
        XCTAssertEqual(repository.saves, 0)
        try press("settings-general", in: window)
        XCTAssertEqual((axAttribute(try node("preferences-save", in: window), kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
        try choose("Duration", item: "Custom", in: window)
        try input("37", in: window)
        try press("preferences-review", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "37")
        XCTAssertEqual(repository.saves, 0)
        repository.readFailure = nil
        try press("preferences-review", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "37")
        try press("preferences-save", in: window)
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 37 minutes")
        XCTAssertEqual(repository.saves, 1)
        XCTAssertNil(graph.focusService.activeSession)
    }

    // These are hosted native keyboard/AX checks, not spoken VoiceOver acceptance.
    private func keyboard(_ code: UInt16, _ text: String, in window: NSWindow,
                          modifiers: NSEvent.ModifierFlags = []) throws {
        window.makeKeyAndOrderFront(nil)
        _ = try XCTUnwrap(window.isKeyWindow ? true : nil, "Keyboard events require the reserved key window")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        settle()
    }

    private func focusedIdentifier() throws -> String {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let value = try XCTUnwrap(axAttribute(app, kAXFocusedUIElementAttribute))
        return try XCTUnwrap(axAttribute(unsafeBitCast(value, to: AXUIElement.self), kAXIdentifierAttribute) as? String)
    }

    private func tab(to identifier: String, in window: NSWindow, backwards: Bool = false) throws {
        if backwards { window.selectPreviousKeyView(nil) } else { window.selectNextKeyView(nil) }
        settle()
        XCTAssertEqual(try focusedIdentifier(), identifier)
    }

    private func keyboardSession() throws {
        _ = try XCTUnwrap(AXIsProcessTrusted() ? true : nil,
                          "Hosted keyboard validation requires Accessibility permission")
        NSApp.activate(ignoringOtherApps: true)
        settle()
        _ = try XCTUnwrap(NSApp.isActive ? true : nil,
                          "Keyboard validation requires the reserved active GUI session")
    }

    func testKeyboardHubOrderEditorHandoffNamesTargetsAndFocusReturn() throws {
        try keyboardSession()
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container))
        let window = show(ScrollView { FoundationSettingsView(dependencies: graph) }, size: CGSize(width: 520, height: 340))
        defer { window.orderOut(nil) }
        window.makeFirstResponder(nil)
        try tab(to: "settings-general", in: window)
        try capture("keyboard-hub-general-focused", window: window)
        try tab(to: "settings-ai", in: window)
        try tab(to: "settings-news", in: window)
        try tab(to: "settings-folders", in: window)
        try tab(to: "settings-local-data", in: window)
        try tab(to: "settings-general", in: window)
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "preferences-duration")
        for (identifier, name, role) in [
            ("preferences-duration", "Duration", kAXPopUpButtonRole),
            ("preferences-text-size", "Text size", kAXPopUpButtonRole),
            ("preferences-motion", "Motion", kAXPopUpButtonRole),
            ("preferences-cancel", "Cancel", kAXButtonRole),
            ("preferences-save", "Save", kAXButtonRole)
        ] {
            let element = try node(identifier, in: window)
            XCTAssertEqual(axAttribute(element, kAXDescriptionAttribute) as? String, name)
            XCTAssertEqual(axAttribute(element, kAXRoleAttribute) as? String, role)
            XCTAssertGreaterThanOrEqual(try axFrame(element).height, AppMetrics.minimumTarget, identifier)
            XCTAssertGreaterThanOrEqual(try axFrame(element).width, AppMetrics.minimumTarget, identifier)
        }
        try tab(to: "preferences-text-size", in: window)
        try tab(to: "preferences-motion", in: window)
        try tab(to: "preferences-cancel", in: window)
        try tab(to: "preferences-save", in: window)
        try tab(to: "preferences-cancel", in: window, backwards: true)
        try keyboard(53, "\u{1b}", in: window)
        XCTAssertEqual(try focusedIdentifier(), "settings-general")
        for (identifier, next) in [("settings-ai", "settings-news"), ("settings-news", "settings-folders"), ("settings-folders", "settings-local-data"), ("settings-local-data", "settings-general")] {
            try tab(to: identifier, in: window)
            try keyboard(49, " ", in: window)
            XCTAssertEqual(try focusedIdentifier(), "settings-back")
            if identifier == "settings-folders" {
                try tab(to: "settings-folders-add", in: window)
                try tab(to: "settings-folders-reload", in: window)
                try tab(to: "settings-back", in: window)
            }
            let back = try node("settings-back", in: window)
            XCTAssertEqual(axAttribute(back, kAXDescriptionAttribute) as? String, "Back to Settings")
            try keyboard(49, " ", in: window)
            XCTAssertEqual(try focusedIdentifier(), identifier)
            // Check return resumes the original hub order rather than a dead responder.
            try tab(to: next, in: window)
            window.selectPreviousKeyView(nil)
            settle()
        }
    }

    private func dismissFolderConfirmation(_ name: String) throws {
        try dismissFolderDialog(name)
    }

    private func closeFolderFixture(_ window: NSWindow) {
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        window.orderOut(nil)
    }

    func testKeyboardFolderOrderCancelFailureBusyAndRemovalRestoreOnlySurvivingActions() throws {
        try keyboardSession()
        let first = folderReference(name: "Harbor"), peer = folderReference(name: "Peer", order: 1)
        let repository = SettingsFolderRepository([peer, first])
        let store = ProjectStore(inspector: SettingsFolderInspectorSpy(), repository: repository)
        let window = show(ScrollView { ProjectFoldersSettingsView(store: store) })
        defer { closeFolderFixture(window) }
        let reconnect = "settings-folder-reconnect-\(first.id.uuidString)"
        let remove = "settings-folder-remove-\(first.id.uuidString)"
        let peerRemove = "settings-folder-remove-\(peer.id.uuidString)"
        window.makeFirstResponder(nil)
        for identifier in ["settings-folders-add", "settings-folders-reload", reconnect, remove,
                           "settings-folder-reconnect-\(peer.id.uuidString)", peerRemove] {
            try tab(to: identifier, in: window)
            XCTAssertGreaterThanOrEqual(try axFrame(node(identifier, in: window)).height, AppMetrics.minimumTarget)
        }
        let action = try node(remove, in: window)
        XCTAssertEqual(axAttribute(action, kAXDescriptionAttribute) as? String, "Remove Harbor from Kontrol")
        XCTAssertEqual(axAttribute(action, kAXRoleAttribute) as? String, kAXButtonRole)
        try press(remove, in: window)
        try dismissFolderConfirmation("Cancel")
        XCTAssertEqual(try focusedIdentifier(), remove)
        XCTAssertTrue(repository.removals.isEmpty)
        try press(remove, in: window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        try keyboard(53, "\u{1b}", in: sheet)
        XCTAssertEqual(try focusedIdentifier(), remove)
        XCTAssertTrue(repository.removals.isEmpty, "Escape can only cancel")
        for failure in [ProjectReferencePersistenceError.invalidReference as Error, ProjectStoreError.busy] {
            repository.removeFailure = failure
            try press(remove, in: window)
            try dismissFolderConfirmation("Remove from Kontrol")
            XCTAssertEqual(try focusedIdentifier(), remove)
            XCTAssertEqual(store.rows.count, 2)
        }
        repository.removeFailure = nil
        try press(remove, in: window)
        try dismissFolderConfirmation("Remove from Kontrol")
        XCTAssertEqual(try focusedIdentifier(), peerRemove)
        try capture("keyboard-folder-survivor-focus", window: window)
        try keyboard(49, " ", in: window)
        try dismissFolderConfirmation("Remove from Kontrol")
        XCTAssertEqual(try focusedIdentifier(), "settings-folders-add")
        _ = try node("settings-folders-empty", in: window)
        try capture("keyboard-folder-last-removal-add-focus", window: window)
    }

    func testKeyboardFolderStaleAndFailedReviewKeepReviewFocusUntilSeparateReconfirmation() throws {
        try keyboardSession()
        let reference = folderReference()
        let repository = SettingsFolderRepository([reference])
        let store = ProjectStore(inspector: SettingsFolderInspectorSpy(), repository: repository)
        let management = ProjectFoldersSettingsState(store: store)
        let window = show(ScrollView { ProjectFoldersSettingsView(store: store, management: management) })
        defer { closeFolderFixture(window) }
        let remove = "settings-folder-remove-\(reference.id.uuidString)"
        try press(remove, in: window)
        repository.references = [folderReference(reference.id, name: "Renamed elsewhere")]
        try dismissFolderConfirmation("Remove from Kontrol")
        XCTAssertEqual(try focusedIdentifier(), "settings-folders-reload")
        XCTAssertTrue(management.requiresReview)
        repository.loadFailure = ProjectReferencePersistenceError.invalidReference
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "settings-folders-reload")
        XCTAssertTrue(management.requiresReview)
        XCTAssertEqual(store.rows.count, 1)
        try capture("keyboard-folder-failed-review-focus", window: window)
        repository.loadFailure = nil
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "settings-folders-reload")
        XCTAssertFalse(management.requiresReview)
        XCTAssertEqual(repository.removals.count, 1, "Review cannot delete or retry")
        try press(remove, in: window)
        XCTAssertEqual(management.confirmation?.title, "Remove Renamed elsewhere?")
        try dismissFolderConfirmation("Cancel")
        XCTAssertEqual(try focusedIdentifier(), remove)
        XCTAssertEqual(repository.removals.count, 1)
    }

    func testKeyboardFolderAddAndReconnectDismissalRestoreSurvivingActions() throws {
        try keyboardSession()
        let reference = folderReference(), peer = folderReference(name: "Peer", order: 1)
        let repository = SettingsFolderRepository([reference, peer])
        let store = ProjectStore(inspector: SettingsFolderInspectorSpy(), repository: repository)
        let window = show(ScrollView { ProjectFoldersSettingsView(store: store) })
        defer {
            for panel in NSApp.windows.compactMap({ $0 as? NSOpenPanel }) { panel.cancel(nil) }
            closeFolderFixture(window)
        }
        try press("settings-folders-add", in: window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        try press("project-add-cancel", in: sheet)
        XCTAssertEqual(try focusedIdentifier(), "settings-folders-add")
        try press("settings-folders-add", in: window)
        try keyboard(53, "\u{1b}", in: XCTUnwrap(window.attachedSheet))
        XCTAssertEqual(try focusedIdentifier(), "settings-folders-add")
        let reconnect = "settings-folder-reconnect-\(reference.id.uuidString)"
        try press(reconnect, in: window)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible })
        panel.cancel(nil)
        settle()
        XCTAssertEqual(try focusedIdentifier(), reconnect)
        XCTAssertTrue(repository.removals.isEmpty)
        XCTAssertTrue(store.rows.contains { $0.reference.id == reference.id })
        try capture("keyboard-folder-reconnect-canceled-focus", window: window)
        try press(reconnect, in: window)
        let secondPanel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible })
        try store.disconnect(id: reference.id, expectedRevision: reference.revision)
        secondPanel.cancel(nil)
        settle()
        XCTAssertEqual(try focusedIdentifier(), "settings-folder-reconnect-\(peer.id.uuidString)",
                       "Another client's deletion during the panel cannot restore a deleted row")
        XCTAssertNil(store.preview)
    }

    func testKeyboardValidationSaveFailureRecoveryAndEscapePreserveUnrelatedAnswers() throws {
        try keyboardSession()
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var failAnswerSaves = false
        let catalog = SwiftDataCatalogRepository(container: container, beforeSave: {
            if failAnswerSaves { throw LessonExperienceError.persistenceFailure }
        })
        // Import with a separate repository, then block answer autosaves to retain
        // a genuinely unrelated dirty answer throughout Settings cancellation.
        _ = try SwiftDataCatalogRepository(container: container).importIfNeeded(BundledCatalogLoader.load())
        let repository = SettingsPreferencesSpy()
        repository.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 37), revision: UUID())
        let graph = AppDependencies(container: container, catalogRepository: catalog, appPreferencesRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let lesson = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let opened = try graph.learningCatalogStore.openLesson(lessonID: lesson)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        graph.lessonDraftStore.observe(opened.detail)
        failAnswerSaves = true
        let answer = "  unrelated answer 🧪\n"
        graph.lessonDraftStore.edit(answer, attemptID: attempt.id)
        let window = show(ScrollView { FoundationSettingsView(dependencies: graph) }, size: CGSize(width: 520, height: 340))
        defer { window.orderOut(nil) }
        window.makeFirstResponder(nil)
        try tab(to: "settings-general", in: window)
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "preferences-duration")
        try tab(to: "preferences-custom-minutes", in: window)
        try keyboard(0, "a", in: window, modifiers: .command)
        try keyboard(18, "1.5", in: window)
        try keyboard(1, "s", in: window, modifiers: .command)
        XCTAssertEqual(try focusedIdentifier(), "preferences-custom-minutes")
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "1.5")
        XCTAssertEqual(repository.saves, 0)
        XCTAssertTrue(try value("preferences-error", in: window).contains("not been saved"))
        XCTAssertTrue((axAttribute(try node("preferences-custom-minutes", in: window), kAXHelpAttribute) as? String ?? "").contains("positive whole minutes"))
        try keyboard(0, "a", in: window, modifiers: .command)
        try keyboard(18, "0041", in: window)
        repository.saveFailure = .persistenceFailure
        try keyboard(1, "s", in: window, modifiers: .command)
        XCTAssertEqual(try focusedIdentifier(), "preferences-save")
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "0041")
        try capture("keyboard-save-failure-focus", window: window)
        repository.saveFailure = nil
        try keyboard(49, " ", in: window)
        XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 41)
        XCTAssertEqual(try focusedIdentifier(), "settings-general")
        try keyboard(49, " ", in: window)
        try tab(to: "preferences-custom-minutes", in: window)
        try keyboard(0, "a", in: window, modifiers: .command)
        try keyboard(18, "99", in: window)
        let saves = repository.saves
        try keyboard(53, "\u{1b}", in: window)
        XCTAssertEqual(repository.saves, saves)
        XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 41)
        XCTAssertEqual(try focusedIdentifier(), "settings-general")
        XCTAssertEqual(graph.lessonDraftStore.buffers[attempt.id]?.text, answer)
        XCTAssertEqual(graph.lessonDraftStore.buffers[attempt.id]?.isDirty, true)
        XCTAssertEqual(try catalog.loadLesson(lessonID: lesson).attempt?.answerDraft, "")
    }

    func testKeyboardReadRetryAndStaleReviewReturnToSurvivingControlsWithoutDiscardingDraft() throws {
        try keyboardSession()
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SettingsPreferencesSpy()
        repository.readFailure = .invalidStoredData
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container), appPreferencesRepository: repository)
        let window = show(ScrollView { FoundationSettingsView(dependencies: graph) }, size: CGSize(width: 520, height: 340))
        defer { window.orderOut(nil) }
        window.makeFirstResponder(nil)
        try tab(to: "settings-preferences-retry", in: window)
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "settings-preferences-retry")
        repository.readFailure = nil
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "settings-general")
        try keyboard(49, " ", in: window)
        // An out-of-process revision change is discovered by the actual Save.
        repository.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 50), revision: UUID())
        try tab(to: "preferences-text-size", in: window)
        try tab(to: "preferences-motion", in: window)
        try tab(to: "preferences-cancel", in: window)
        try tab(to: "preferences-save", in: window)
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "preferences-review")
        try capture("keyboard-stale-review-focus", window: window)
        XCTAssertTrue(try value("preferences-error", in: window).contains("changed elsewhere"))
        repository.readFailure = .persistenceFailure
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "preferences-review")
        XCTAssertEqual((axAttribute(try node("preferences-save", in: window), kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
        try tab(to: "preferences-cancel", in: window)
        try tab(to: "preferences-duration", in: window)
        try tab(to: "preferences-text-size", in: window)
        try tab(to: "preferences-motion", in: window)
        try tab(to: "preferences-review", in: window)
        repository.readFailure = nil
        let saves = repository.saves
        try keyboard(49, " ", in: window)
        XCTAssertEqual(try focusedIdentifier(), "preferences-duration")
        XCTAssertEqual(repository.saves, saves)
        XCTAssertEqual(try value("preferences-latest-saved", in: window), "Latest saved: 50 minutes · System text · System motion")
        try keyboard(1, "s", in: window, modifiers: .command)
        XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 25, "Review retains the draft, not the latest saved value")
        XCTAssertEqual(try focusedIdentifier(), "settings-general")
    }

    private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func axDescendants(_ element: AXUIElement) -> [AXUIElement] {
        let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + axDescendants($0) }
    }

    private func axWindow(_ window: NSWindow) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var match: AXUIElement?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            match = (axAttribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
                axAttribute($0, kAXTitleAttribute) as? String == window.title
            }
        } while match == nil && Date() < deadline
        return try XCTUnwrap(match, "Hosted Settings window did not enter the AX tree")
    }

    private func axFrame(_ element: AXUIElement) throws -> CGRect {
        let position = try XCTUnwrap(axAttribute(element, kAXPositionAttribute))
        let size = try XCTUnwrap(axAttribute(element, kAXSizeAttribute))
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions))
        return CGRect(origin: origin, size: dimensions)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }

    private func viewport(_ scroll: NSScrollView) throws -> CGRect {
        let window = try XCTUnwrap(scroll.window)
        let screenRect = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        return CGRect(x: screenRect.minX, y: screenHeight - screenRect.maxY,
                      width: screenRect.width, height: screenRect.height)
    }

    /// Native clip-view scrolling, followed by an actual onscreen AX press. Finding
    /// an offscreen AX node alone is not evidence that a compact user can reach it.
    private func reveal(_ identifier: String, in window: NSWindow) throws {
        guard window.contentView.flatMap({ scrollViews(in: $0).first }) != nil else { return }
        try reveal(identifier, in: window, matching: {
            self.axAttribute($0, kAXIdentifierAttribute) as? String == identifier
        })
    }

    private func reveal(_ name: String, in window: NSWindow,
                        matching predicate: (AXUIElement) -> Bool) throws {
        let scroll = try XCTUnwrap(window.contentView.flatMap { scrollViews(in: $0).first })
        let clip = scroll.contentView
        let document = try XCTUnwrap(scroll.documentView)
        func isVisible() throws -> Bool {
            // Lazy News topics enter/leave the native AX tree as they scroll.
            // Reacquire after every layout instead of retaining a stale AX node
            // or demanding an offscreen lazy item before scrolling to it.
            guard let element = axDescendants(try axWindow(window)).first(where: predicate) else { return false }
            return try viewport(scroll).insetBy(dx: -1, dy: -1).contains(axFrame(element))
        }
        if try isVisible() { return }
        let step = max(1, clip.bounds.height * 0.5)
        var y: CGFloat = 0
        while true {
            clip.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            settle()
            if try isVisible() { return }
            // Reevaluate height as lazy content is realized.
            let maxY = max(0, document.bounds.height - clip.bounds.height)
            if y >= maxY { break }
            y = min(maxY, y + step)
        }
        XCTFail("Rendered control cannot be reached by vertical scrolling: \(name); viewport=\(try viewport(scroll))")
    }

    private func assertSingleDocument(in window: NSWindow) throws -> NSScrollView {
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        let scrolls = try XCTUnwrap(window.contentView).subviews.flatMap(scrollViews)
        XCTAssertEqual(scrolls.count, 1, "Settings must have exactly one scroll owner, including inline AI and News")
        let scroll = try XCTUnwrap(scrolls.first)
        XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).bounds.width, scroll.contentView.bounds.width + 1,
                                 "Settings must not require horizontal scrolling")
        return scroll
    }

    private func assertReachable(_ identifiers: [String], in window: NSWindow) throws {
        let scroll = try assertSingleDocument(in: window)
        for identifier in identifiers {
            try reveal(identifier, in: window)
            let frame = try axFrame(node(identifier, in: window))
            XCTAssertFalse(frame.isEmpty, identifier)
            XCTAssertTrue(try viewport(scroll).insetBy(dx: -1, dy: -1).contains(frame),
                          "\(identifier) must fit fully onscreen after scrolling: \(frame)")
        }
    }

    private func assertNonoverlapping(_ identifiers: [String], in window: NSWindow) throws {
        let frames = try identifiers.map { try axFrame(node($0, in: window)) }
        for i in frames.indices {
            for j in frames.indices where j > i {
                XCTAssertFalse(frames[i].intersects(frames[j]), "\(identifiers[i]) overlaps \(identifiers[j])")
            }
        }
    }

    private func capture(_ name: String, window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("F13 native geometry \(name): content=\(content.bounds.size), pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), backingScale=\(window.backingScaleFactor)")
    }

    func testLocalDataIdleGuidanceReflowsAtAllSettingsSizes() async throws {
        try await assertLocalDataGeometry(.idle, name: "idle")
    }

    func testLocalDataSelectingProgressAndCancelReflowAtAllSettingsSizes() async throws {
        try await assertLocalDataGeometry(.selecting, name: "selecting")
    }

    func testLocalDataPreparingProgressAndCancelReflowAtAllSettingsSizes() async throws {
        try await assertLocalDataGeometry(.preparing, name: "preparing")
    }

    func testLocalDataSavedResultAndActionsReflowAtAllSettingsSizes() async throws {
        try await assertLocalDataGeometry(.saved, name: "saved")
    }

    func testLocalDataCanceledResultAndActionsReflowAtAllSettingsSizes() async throws {
        try await assertLocalDataGeometry(.canceled, name: "canceled")
    }

    func testLocalDataEveryFailureRecoveryAndRetryReflowAtAllSettingsSizes() async throws {
        for (name, failure) in [("selection", ExportService.Failure.selection), ("answer-save", .answerSave),
                                ("capture", .capture), ("preparation", .preparation),
                                ("delivery", .delivery), ("cleanup", .cleanup)] {
            try await assertLocalDataGeometry(.failed(failure), name: name)
        }
    }

    /// Exercise production scene roots, navigation, shared preference resolution
    /// and observable service, not an imposed-height surrogate or a mutable state
    /// override. Injected boundaries hold progress and produce each real outcome.
    /// Compilation is not native evidence; execute this matrix at A13.
    private func assertLocalDataGeometry(_ state: ExportService.State, name: String) async throws {
        try keyboardSession()
        let sizes = [CGSize(width: 520, height: 340), CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)]
        let scales: [(String, DynamicTypeSize, AppTextSize, CGFloat)] = [
            ("100", .large, .system, 1), ("130", .large, .large, 1.3), ("160", .accessibility1, .large, 1.6)
        ]
        for inline in [false, true] {
            // The main-window minimum is 1000x700; compact is native Settings.
            for size in sizes where !inline || size.width >= 1000 {
                var standardSubtitleHeight: CGFloat?
                for (percent, systemSize, preference, expectedScale) in scales {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsExportGeometry-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                    let preferences = SettingsPreferencesSpy()
                    preferences.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 25, textSize: preference), revision: UUID())
                    let panel = SettingsExportPanel()
                    let repository = SettingsExportRepository(container: container)
                    let gate = SettingsExportPreparationGate()
                    let failure: ExportService.Failure?
                    if case .failed(let category) = state { failure = category } else { failure = nil }
                    let writer = SettingsExportWriter(writer: ExportFileWriter(temporaryRoot: root), gate: gate, failure: failure)
                    var failAnswerSaves = false
                    let catalog = SwiftDataCatalogRepository(container: container, beforeSave: {
                        if failAnswerSaves { throw LessonExperienceError.persistenceFailure }
                    })
                    let news = SettingsNewsSpy()
                    let inspector = SettingsFolderInspectorSpy()
                    let graph = AppDependencies(container: container, catalogRepository: catalog,
                        projectInspector: inspector, draftScheduler: { _, _ in {} },
                        appPreferencesRepository: preferences, newsService: news,
                        exportRepository: repository, exportPanel: panel, exportWriter: writer)
                    let launch = LaunchCoordinator(open: { container }, makeDependencies: { _, _ in graph })
                    await launch.start()
                    XCTAssertEqual(launch.state, .ready)
                    var pendingAttempt: UUID?
                    if failure == .answerSave {
                        graph.learningCatalogStore.loadIfNeeded()
                        let lesson = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
                        let detail = try graph.learningCatalogStore.openLesson(lessonID: lesson).detail
                        let attempt = try XCTUnwrap(detail.attempt)
                        graph.lessonDraftStore.observe(detail)
                        graph.lessonDraftStore.edit("  retained geometry answer 🧪\n", attemptID: attempt.id)
                        pendingAttempt = attempt.id
                        failAnswerSaves = true
                    }
                    if failure == .selection { panel.failure = ExportFileWriterError.unsafeDestination }
                    if failure == .capture { repository.failure = ExportFileWriterError.invalidPreparation }
                    if state != .preparing { await gate.release() }
                    let navigation = NavigationStore()
                    navigation.select(.settings)
                    let scene = Group {
                        if inline { MainWindowContent(launch: launch, navigation: navigation) }
                        else { SettingsSceneContent(launch: launch) }
                    }.environment(\.dynamicTypeSize, systemSize)
                    let window = show(scene, size: size)
                    defer { window.orderOut(nil) } // Match existing native hosting lifetime policy.
                    let label = "export-\(name)-\(inline ? "inline" : "native")-\(Int(size.width))x\(Int(size.height))-\(percent)"
                    try press("settings-local-data", in: window)
                    if state != .idle {
                        try press("settings-export-start", in: window)
                        if failure != .selection {
                            var panelOpened = false
                            for _ in 0..<200 {
                                if panel.continuation != nil { panelOpened = true; break }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            XCTAssertTrue(panelOpened, "Injected panel must hold selection: \(label)")
                            if !panelOpened { throw ExportFileWriterError.unsafeDestination }
                            if state == .canceled { panel.finish(.canceled) }
                            else if state != .selecting {
                                panel.finish(.approved(try writer.approveDestination(root.appendingPathComponent("export.json"))))
                            }
                        }
                        if state == .preparing {
                            for _ in 0..<200 {
                                if graph.exportService.state == .preparing { break }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                        } else if state != .selecting { await graph.exportService.waitForCompletion() }
                    }
                    XCTAssertEqual(graph.exportService.state, state, label)
                    settle()
                    let presentation = LocalDataSettingsView.presentation(state)
                    let action = presentation.canCancel ? "settings-export-cancel" : "settings-export-start"
                    let texts = ["settings-export-subtitle", "settings-export-inclusions", "settings-export-exclusions",
                                 "settings-export-answer-guidance", "settings-export-privacy", "settings-export-status", "settings-export-detail"]
                    try assertReachable(texts, in: window)
                    try assertFolderTargets(["settings-back", action], in: window)
                    try assertNonoverlapping(texts + ["settings-back", action], in: window)
                    XCTAssertEqual(try value("settings-export-detail", in: window), presentation.detail)
                    for (identifier, copy) in [("settings-export-inclusions", LocalDataSettingsView.inclusions),
                                               ("settings-export-exclusions", LocalDataSettingsView.exclusions),
                                               ("settings-export-answer-guidance", LocalDataSettingsView.answerGuidance),
                                               ("settings-export-privacy", LocalDataSettingsView.privacyGuidance)] {
                        XCTAssertEqual(try value(identifier, in: window), copy, "Full guidance must survive wrapping")
                        if size.width == 520 {
                            let font = NSFont.monospacedSystemFont(ofSize: AppTypography.Role.body.baseSize * expectedScale, weight: .regular)
                            XCTAssertGreaterThan(try axFrame(node(identifier, in: window)).height,
                                                 font.ascender - font.descender + 2, "Compact guidance must visibly wrap: \(label) / \(identifier)")
                        }
                        try reveal(identifier, in: window)
                        try capture("\(label)-\(identifier)", window: window)
                    }
                    if size.width == 520 {
                        let font = NSFont.monospacedSystemFont(ofSize: AppTypography.Role.body.baseSize * expectedScale, weight: .regular)
                        XCTAssertGreaterThan(try axFrame(node("settings-export-detail", in: window)).height,
                                             font.ascender - font.descender + 2, "Progress/recovery/result copy must wrap")
                    }
                    let subtitleHeight = try axFrame(node("settings-export-subtitle", in: window)).height
                    if expectedScale == 1 { standardSubtitleHeight = subtitleHeight }
                    else {
                        XCTAssertEqual(subtitleHeight / (try XCTUnwrap(standardSubtitleHeight)), expectedScale, accuracy: 0.15,
                                       "Large must scale once; larger system text must neither shrink nor multiply")
                    }
                    try reveal("settings-export-status", in: window)
                    try capture("\(label)-status", window: window)
                    try reveal(action, in: window)
                    try capture("\(label)-result-actions", window: window)
                    _ = try assertSingleDocument(in: window)
                    XCTAssertEqual(window.contentView?.bounds.size, size, "Document must not enlarge the requested viewport")
                    // Actually press the reachable in-document action. Pending
                    // states cancel and retain ownership until the gate releases;
                    // terminal states explicitly retry through the same picker.
                    if presentation.canCancel {
                        try press(action, in: window)
                        panel.finish(.canceled)
                        await gate.release()
                        await graph.exportService.waitForCompletion()
                        XCTAssertEqual(graph.exportService.state, .canceled)
                    } else {
                        panel.failure = nil
                        try press(action, in: window)
                        for _ in 0..<200 {
                            if panel.continuation != nil { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        XCTAssertNotNil(panel.continuation, "Explicit export/retry must remain usable")
                        panel.finish(.canceled)
                        await graph.exportService.waitForCompletion()
                        XCTAssertEqual(graph.exportService.state, .canceled)
                    }
                    if let pendingAttempt {
                        XCTAssertEqual(graph.lessonDraftStore.buffers[pendingAttempt]?.text, "  retained geometry answer 🧪\n")
                        XCTAssertEqual(graph.lessonDraftStore.buffers[pendingAttempt]?.isDirty, true)
                    }
                    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    XCTAssertEqual(files, state == .saved ? ["export.json"] : [], "No private or sibling staging survives")
                    if state == .saved {
                        XCTAssertNoThrow(try LocalDataExport.decode(Data(contentsOf: root.appendingPathComponent("export.json"))))
                    }
                    XCTAssertEqual(preferences.saves, 0)
                    let requests = await news.requests
                    let inspections = await inspector.calls
                    XCTAssertEqual(requests, 0)
                    XCTAssertEqual(inspections, 0)
                    // Only non-store, owned export files after lifecycle completion.
                    try FileManager.default.removeItem(at: root)
                    print("F13 Local Data geometry PASS \(label): wrapped guidance/recovery, reachable >=32pt targets, one document, single scale")
                }
            }
        }
    }

    private enum FolderGeometryState: String {
        case populated, empty, unavailable, stale, removal
    }

    func testFolderPopulatedLongNamesAndActionsReflowAtAllSettingsSizes() async throws {
        try await assertFolderGeometry(.populated)
    }

    func testFolderEmptyGuidanceAndActionsReflowAtAllSettingsSizes() async throws {
        try await assertFolderGeometry(.empty)
    }

    func testFolderUnavailableRecoveryAndRetainedRowsReflowAtAllSettingsSizes() async throws {
        try await assertFolderGeometry(.unavailable)
    }

    func testFolderStaleReviewAndDisabledRemovalReflowAtAllSettingsSizes() async throws {
        try await assertFolderGeometry(.stale)
    }

    func testFolderRemovalConfirmationCancelAndSuccessReflowAtAllSettingsSizes() async throws {
        try await assertFolderGeometry(.removal)
    }

    private func folderDialogButton(_ name: String) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let button = axDescendants(app).first(where: {
                axAttribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                axAttribute($0, kAXDescriptionAttribute) as? String == name
            }) { return button }
            settle()
        } while Date() < deadline
        return try XCTUnwrap(nil as AXUIElement?, "Missing native folder confirmation action: \(name)")
    }

    private func dismissFolderDialog(_ name: String) throws {
        XCTAssertEqual(AXUIElementPerformAction(try folderDialogButton(name), kAXPressAction as CFString), .success)
        settle()
    }

    /// Real scene roots and real local navigation, not a fixed-height rendering
    /// surrogate. A13 executes these hosted fixtures on the reserved AX desktop.
    private func assertFolderGeometry(_ state: FolderGeometryState) async throws {
        try keyboardSession() // Fail before creating windows if the actual host lacks AX/activation.
        let sizes = [CGSize(width: 520, height: 340), CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)]
        // 130% comes from a committed Large preference with a standard system
        // size. A larger system size must win, not shrink or multiply by 1.3.
        let scales: [(String, DynamicTypeSize, AppTextSize, CGFloat)] = [
            ("100", .large, .system, 1), ("130", .large, .large, 1.3), ("160", .accessibility1, .large, 1.6)
        ]
        for inline in [false, true] {
            for size in sizes where !inline || size.width >= 1000 {
                var standardNameHeight: CGFloat?
                for (percent, systemSize, preference, expectedScale) in scales {
                    let long = folderReference(name: "Harbor — research notes and implementation experiments with a very long folder name")
                    let unbroken = folderReference(name: String(repeating: "LongFolderName", count: 6), order: 1)
                    let peer = folderReference(name: "Short peer", order: 2)
                    let references = state == .empty ? [] : [long, unbroken, peer]
                    let folders = SettingsFolderRepository(references)
                    let inspector = SettingsFolderInspectorSpy()
                    let preferences = SettingsPreferencesSpy()
                    preferences.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 25, textSize: preference), revision: UUID())
                    let news = SettingsNewsSpy()
                    let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                    let graph = AppDependencies(container: container,
                        catalogRepository: SwiftDataCatalogRepository(container: container),
                        projectInspector: inspector, projectRepository: folders,
                        appPreferencesRepository: preferences, newsService: news)
                    let launch = LaunchCoordinator(open: { container }, makeDependencies: { _, _ in graph })
                    await launch.start()
                    XCTAssertEqual(launch.state, .ready)
                    let navigation = NavigationStore()
                    navigation.select(.settings)
                    let root = Group {
                        if inline { MainWindowContent(launch: launch, navigation: navigation) }
                        else { SettingsSceneContent(launch: launch) }
                    }.environment(\.dynamicTypeSize, systemSize)
                    let window = show(root, size: size)
                    defer {
                        // A failing geometry assertion must not leave a native
                        // modal blocking the next hosted fixture. Never confirm
                        // during cleanup, and retain the hosting-window policy.
                        if let sheet = window.attachedSheet {
                            window.endSheet(sheet, returnCode: .cancel)
                            sheet.orderOut(nil)
                        }
                        window.orderOut(nil)
                    }
                    let label = "folders-\(state.rawValue)-\(inline ? "inline" : "native")-\(Int(size.width))x\(Int(size.height))-\(percent)"
                    XCTAssertEqual(window.contentView?.bounds.size, size, "Folder layout cannot enlarge the requested viewport")
                    try press("settings-folders", in: window)
                    let sharedActions = ["settings-back", "settings-folders-add", "settings-folders-reload"]
                    try assertFolderTargets(sharedActions, in: window)
                    try assertReachable(["settings-folders-guidance"], in: window)
                    try assertNonoverlapping(["settings-folders-guidance", "settings-folders-add", "settings-folders-reload"], in: window)

                    if state == .empty {
                        try assertReachable(["settings-folders-empty"], in: window)
                        XCTAssertTrue(graph.projectStore.rows.isEmpty)
                        try capture(label, window: window)
                    } else {
                        var rowElements: [String] = []
                        for reference in references {
                            let name = "settings-folder-name-\(reference.id.uuidString)"
                            let status = "settings-folder-status-\(reference.id.uuidString)"
                            let actions = ["settings-folder-reconnect-\(reference.id.uuidString)", "settings-folder-remove-\(reference.id.uuidString)"]
                            rowElements += [name, status] + actions
                            try assertReachable([name, status], in: window)
                            XCTAssertEqual(try value(name, in: window), reference.displayNameHint, "Full names, including unbroken names, remain available")
                            try assertFolderTargets(actions, in: window)
                            try assertNonoverlapping([name, status] + actions, in: window)
                            if size.width == 520 && reference.id != peer.id {
                                let lineHeight = NSFont.monospacedSystemFont(ofSize: AppTypography.Role.section.baseSize * expectedScale, weight: .regular)
                                XCTAssertGreaterThan(try axFrame(node(name, in: window)).height,
                                                     lineHeight.ascender - lineHeight.descender + 2,
                                                     "Long names must visibly wrap, not just retain an offscreen AX value")
                                try reveal(name, in: window)
                                try capture("\(label)-\(reference.id == long.id ? "spaced" : "unbroken")-name", window: window)
                            }
                        }
                        let peerHeight = try axFrame(node("settings-folder-name-\(peer.id.uuidString)", in: window)).height
                        if expectedScale == 1 { standardNameHeight = peerHeight }
                        else {
                            XCTAssertEqual(peerHeight / (try XCTUnwrap(standardNameHeight)), expectedScale, accuracy: 0.15,
                                           "Resolved preference/system text size must scale once and preserve larger system input")
                        }
                        try capture("\(label)-last-row", window: window)
                        let removeID = "settings-folder-remove-\(long.id.uuidString)"
                        switch state {
                        case .unavailable:
                            // Failed local reload must retain usable rows, not
                            // manufacture an empty state or access any folder.
                            folders.loadFailure = ProjectReferencePersistenceError.invalidReference
                            try press("settings-folders-reload", in: window)
                            try assertReachable(["settings-folders-unavailable", "settings-folders-result"] + rowElements, in: window)
                            try assertNonoverlapping(["settings-folders-unavailable", "settings-folders-result"] + rowElements, in: window)
                            try assertFolderTargets(sharedActions, in: window)
                            XCTAssertEqual(graph.projectStore.rows.count, references.count)
                            XCTAssertTrue(try folderOutcome(in: window).contains("could not be loaded"))
                            try reveal("settings-folders-result", in: window)
                            try capture("\(label)-recovery", window: window)
                        case .stale:
                            try press(removeID, in: window)
                            folders.references[0] = folderReference(long.id, name: "Current reference", order: 0)
                            try dismissFolderDialog("Remove from Kontrol")
                            try assertReachable(["settings-folders-result"] + rowElements, in: window)
                            try assertNonoverlapping(["settings-folders-result"] + rowElements, in: window)
                            try assertFolderTargets(sharedActions, in: window)
                            XCTAssertTrue(try folderOutcome(in: window).contains("Reload & review"))
                            XCTAssertEqual((axAttribute(try node(removeID, in: window), kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
                            XCTAssertEqual(folders.removals.count, 1)
                            try reveal("settings-folders-result", in: window)
                            try capture("\(label)-review", window: window)
                        case .removal:
                            try press(removeID, in: window)
                            // The existing native modal remains platform-owned;
                            // its copy/actions must fit its naturally sized sheet,
                            // without an extra Settings scroll host or scaling pass.
                            try assertFolderConfirmationGeometry(long, window: window, label: label)
                            try dismissFolderDialog("Cancel")
                            XCTAssertTrue(folders.removals.isEmpty)
                            try assertReachable(["settings-folders-result"] + rowElements, in: window)
                            XCTAssertTrue(try folderOutcome(in: window).contains("canceled"))
                            try reveal("settings-folders-result", in: window)
                            try capture("\(label)-canceled", window: window)
                            try press(removeID, in: window)
                            try dismissFolderDialog("Remove from Kontrol")
                            XCTAssertEqual(folders.removals.count, 1)
                            XCTAssertEqual(graph.projectStore.rows.count, 2)
                            try assertReachable(["settings-folders-result"] + rowElements.filter { !$0.hasSuffix(long.id.uuidString) }, in: window)
                            try assertFolderTargets(sharedActions, in: window)
                            XCTAssertTrue(try folderOutcome(in: window).contains("removed from Kontrol"))
                            try reveal("settings-folders-result", in: window)
                            try capture("\(label)-removed", window: window)
                        default: break
                        }
                    }
                    _ = try assertSingleDocument(in: window)
                    XCTAssertEqual(window.contentView?.bounds.size, size)
                    XCTAssertEqual(preferences.saves, 0, "Geometry must not persist preferences")
                    let inspections = await inspector.calls
                    let requests = await news.requests
                    XCTAssertEqual(inspections, 0, "Geometry/removal/review must never inspect or authorize folders")
                    XCTAssertEqual(requests, 0)
                    print("F13 folder geometry PASS \(label): one document, wrapped copy, reachable actions, single text scale")
                }
            }
        }
    }

    private func assertFolderTargets(_ identifiers: [String], in window: NSWindow) throws {
        try assertReachable(identifiers, in: window)
        for identifier in identifiers {
            let frame = try axFrame(node(identifier, in: window))
            XCTAssertGreaterThanOrEqual(frame.width, AppMetrics.minimumTarget, identifier)
            XCTAssertGreaterThanOrEqual(frame.height, AppMetrics.minimumTarget, identifier)
        }
    }

    private func assertFolderConfirmationGeometry(_ reference: ProjectReferenceSnapshot, window: NSWindow, label: String) throws {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let confirmation = ProjectFoldersSettingsState.Confirmation(reference)
        for name in ["Cancel", "Remove from Kontrol"] { _ = try folderDialogButton(name) }
        let sheet = try XCTUnwrap(window.attachedSheet, "Removal must use the existing native confirmation sheet")
        let screenRect = sheet.convertToScreen(try XCTUnwrap(sheet.contentView).convert(try XCTUnwrap(sheet.contentView).bounds, to: nil))
        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let bounds = CGRect(x: screenRect.minX, y: screenHeight - screenRect.maxY, width: screenRect.width, height: screenRect.height)
        let texts = try [confirmation.title, confirmation.message].map { text in
            try XCTUnwrap(axDescendants(app).first {
                axAttribute($0, kAXRoleAttribute) as? String == kAXStaticTextRole &&
                ((axAttribute($0, kAXValueAttribute) as? String) ?? (axAttribute($0, kAXDescriptionAttribute) as? String)) == text
            }, "Native confirmation must expose complete captured copy: \(text)")
        }
        let buttons = try ["Cancel", "Remove from Kontrol"].map(folderDialogButton)
        let frames = try (texts + buttons).map(axFrame)
        for frame in frames {
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(frame), "Native confirmation content must not be clipped: \(frame)")
        }
        for button in buttons {
            let frame = try axFrame(button)
            XCTAssertGreaterThanOrEqual(frame.width, AppMetrics.minimumTarget)
            XCTAssertGreaterThanOrEqual(frame.height, AppMetrics.minimumTarget)
        }
        for i in frames.indices {
            for j in frames.indices where j > i { XCTAssertFalse(frames[i].intersects(frames[j]), "Confirmation copy/actions overlap") }
        }
        _ = try assertSingleDocument(in: window)
        try capture("\(label)-native-confirmation", window: sheet)
    }

    func testNativeAndInlineSettingsGeometryAtCompactDesktopAndAccessibilitySizes() async throws {
        let sizes = [CGSize(width: 520, height: 340), CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)]
        let scales: [(String, DynamicTypeSize)] = [("100", .large), ("130", .xxLarge), ("160", .accessibility1)]
        for inline in [false, true] {
            // The main app has a 1000x700 minimum; 520x340 is native Settings only.
            for size in sizes where !inline || size.width >= 1000 {
                for (percent, textSize) in scales {
                    let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                    let repository = SettingsPreferencesSpy()
                    let news = SettingsNewsSpy()
                    let graph = AppDependencies(container: container,
                        catalogRepository: SwiftDataCatalogRepository(container: container),
                        appPreferencesRepository: repository, newsService: news)
                    let launch = LaunchCoordinator(open: { container }, makeDependencies: { _, _ in graph })
                    await launch.start()
                    XCTAssertEqual(launch.state, .ready)
                    let navigation = NavigationStore()
                    navigation.select(.settings)
                    let root = Group {
                        if inline { MainWindowContent(launch: launch, navigation: navigation) }
                        else { SettingsSceneContent(launch: launch) }
                    }.environment(\.dynamicTypeSize, textSize)
                    let window = show(root, size: size)
                    defer { window.orderOut(nil) }
                    let label = "\(inline ? "inline" : "native")-\(Int(size.width))x\(Int(size.height))-\(percent)"
                    XCTAssertEqual(window.contentView?.bounds.size, size, "Layout must not enlarge the requested content viewport")
                    try assertReachable(["settings-general", "settings-ai", "settings-news", "settings-folders", "settings-local-data"], in: window)
                    try capture("\(label)-hub-bottom", window: window)
                    try press("settings-general", in: window)
                    try assertReachable(["preferences-duration", "preferences-text-size", "preferences-motion"], in: window)
                    try capture("\(label)-general-pickers", window: window)
                    try choose("Duration", item: "Custom", in: window)
                    try reveal("preferences-custom-minutes", in: window)
                    try input("1.5", in: window)
                    try press("preferences-save", in: window)
                    XCTAssertEqual(try value("preferences-custom-minutes", in: window), "1.5")
                    XCTAssertEqual(try value("preferences-error", in: window),
                                   GeneralPreferencesView.errorMessage(.preferences(.invalidFocusDuration(.invalidCustomMinutes))))
                    try assertReachable(["preferences-error", "preferences-latest-saved", "preferences-cancel", "preferences-save"], in: window)
                    try assertNonoverlapping(["preferences-focus-guidance", "preferences-appearance-guidance",
                                              "preferences-error", "preferences-latest-saved", "preferences-cancel", "preferences-save"], in: window)
                    try capture("\(label)-general-validation-actions", window: window)
                    try input("37", in: window)
                    repository.saveFailure = .persistenceFailure
                    try press("preferences-save", in: window)
                    try assertReachable(["preferences-error", "preferences-cancel", "preferences-save"], in: window)
                    XCTAssertEqual(try value("preferences-custom-minutes", in: window), "37")
                    try capture("\(label)-general-save-failed", window: window)
                    try press("preferences-cancel", in: window)
                    XCTAssertEqual(graph.appPreferencesStore.committed, .defaults)
                    try press("settings-ai", in: window)
                    try assertReachable(["settings-back", "ai-edit", "ai-enable", "ai-test-connection", "ai-connection-status"], in: window)
                    try capture("\(label)-ai-actions", window: window)
                    try press("ai-edit", in: window)
                    try assertReachable(["ai-save", "ai-cancel"], in: window)
                    try capture("\(label)-ai-editor-actions", window: window)
                    try press("ai-cancel", in: window)
                    try press("settings-back", in: window)
                    try press("settings-news", in: window)
                    try assertReachable(["settings-back", "news-add-feed"], in: window)
                    let snapshot = try XCTUnwrap(graph.newsStore.snapshot)
                    for topic in snapshot.topics { try assertReachable(["news-topic-\(topic.id)"], in: window) }
                    // Inspect every existing feed action, including the last row,
                    // rather than assuming that rendering the section proves reachability.
                    for feed in snapshot.feeds {
                        for verb in [feed.isEnabled ? "Disable" : "Enable", "Edit", "Remove"] {
                            let label = "\(verb) \(feed.name) feed"
                            try reveal(label, in: window, matching: {
                                self.axAttribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                                self.axAttribute($0, kAXDescriptionAttribute) as? String == label
                            })
                        }
                    }
                    try capture("\(label)-news-last-feed", window: window)
                    try press("settings-back", in: window)
                    let requests = await news.requests
                    XCTAssertEqual(requests, 0, "Layout/navigation must not initiate feed requests")
                    XCTAssertEqual(repository.saves, 1, "Only the explicit failed save may reach persistence")
                    print("F13 geometry PASS \(label): hub/general/AI/News, one scroll document, all actions reachable")
                }
            }
        }
    }

    func testSettingsReadFailureRetryAndRetainedEditorGuidanceReflowAtAllNativeSizes() async throws {
        for size in [CGSize(width: 520, height: 340), CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
            for (percent, textSize) in [("100", DynamicTypeSize.large), ("130", .xxLarge), ("160", .accessibility1)] {
                let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                let repository = SettingsPreferencesSpy()
                repository.readFailure = .unsupportedPayloadVersion(99)
                let graph = AppDependencies(container: container,
                    catalogRepository: SwiftDataCatalogRepository(container: container), appPreferencesRepository: repository)
                let launch = LaunchCoordinator(open: { container }, makeDependencies: { _, _ in graph })
                await launch.start()
                let window = show(SettingsSceneContent(launch: launch).environment(\.dynamicTypeSize, textSize), size: size)
                defer { window.orderOut(nil) }
                let label = "native-\(Int(size.width))x\(Int(size.height))-\(percent)-read-failed"
                try assertReachable(["settings-preferences-unavailable", "settings-preferences-retry", "settings-general", "settings-ai", "settings-news", "settings-folders", "settings-local-data"], in: window)
                try press("settings-preferences-retry", in: window)
                try press("settings-general", in: window)
                try assertReachable(["preferences-error", "preferences-review", "preferences-cancel", "preferences-save"], in: window)
                XCTAssertEqual(try value("preferences-error", in: window),
                               GeneralPreferencesView.errorMessage(.preferences(.unsupportedPayloadVersion(99))))
                try assertNonoverlapping(["preferences-error", "preferences-review", "preferences-cancel", "preferences-save"], in: window)
                try capture(label, window: window)
                try choose("Duration", item: "Custom", in: window)
                try reveal("preferences-custom-minutes", in: window)
                try input("00037", in: window)
                repository.readFailure = nil
                try press("preferences-review", in: window)
                XCTAssertEqual(try value("preferences-custom-minutes", in: window), "00037")
                try press("preferences-save", in: window)
                XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 37)
                XCTAssertEqual(repository.saves, 1)
            }
        }
    }

    func testProjectsAndFocusRoutesRenderImplementedActionsNotFoundationPlaceholders() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container))
        let navigation = NavigationStore()
        let window = show(AppShell(navigation: navigation, dependencies: graph))
        defer { window.orderOut(nil) }
        for (destination, label) in [(AppDestination.projects, "Add project"), (.focus, "Start")] {
            navigation.select(destination)
            settle()
            // Projects currently inherits its container identifier on children.
            // Match the real action's role/name, not the superseded placeholder.
            let action = try XCTUnwrap(axDescendants(try axWindow(window)).first {
                axAttribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                axAttribute($0, kAXDescriptionAttribute) as? String == label
            })
            XCTAssertFalse(try axFrame(action).isEmpty)
            XCTAssertEqual((axAttribute(action, kAXEnabledAttribute) as? NSNumber)?.boolValue, true)
            XCTAssertEqual(AppShell.contentKind(for: destination), destination == .projects ? .projects : .focus)
        }
        XCTAssertTrue(graph.projectStore.rows.isEmpty)
        XCTAssertNil(graph.focusService.activeSession)
    }

    func testCompactSettingsRecoveryActionsRemainVisibleAt130Percent() async throws {
        var opens = 0
        let launch = LaunchCoordinator(open: {
            opens += 1
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Enlarged Settings recovery inspection"
        window.contentView = NSHostingView(rootView: SettingsSceneContent(launch: launch)
            .environment(\.appTextScaleOverride, 1.3))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let failed = expectation(description: "Settings entered blocking recovery")
        Task { @MainActor in
            while launch.state == .idle || launch.state == .opening { await Task.yield() }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 10)
        guard case .failed = launch.state else { return XCTFail("Expected failure") }
        settle()
        let bounds = try axFrame(axWindow(window))
        let nodes = axDescendants(try axWindow(window))
        for (identifier, label) in [("recovery-quit", "Quit"), ("recovery-retry", "Try again")] {
            let action = try XCTUnwrap(nodes.first {
                axAttribute($0, kAXIdentifierAttribute) as? String == identifier
            })
            XCTAssertEqual(axAttribute(action, kAXRoleAttribute) as? String, kAXButtonRole)
            XCTAssertEqual(axAttribute(action, kAXDescriptionAttribute) as? String, label)
            XCTAssertTrue(bounds.contains(try axFrame(action)), "\(label) must remain inside compact Settings")
        }
        XCTAssertEqual(opens, 1)
        XCTAssertNil(launch.dependencies)
    }

    func testSettingsOpenedDuringInitializationAndWindowReopenUseOneGraph() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let gate = SettingsCatalogGate()
        let entered = expectation(description: "Settings requested catalog")
        var opens = 0
        var imports = 0
        let launch = LaunchCoordinator(open: {
            opens += 1
            return container
        }, loadCatalog: {
            entered.fulfill()
            await gate.wait()
            return try BundledCatalogLoader.load()
        }, makeRepository: { container in
            SwiftDataCatalogRepository(container: container, beforeSave: { imports += 1 })
        })
        let suite = "SettingsSceneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))

        // Hosting both real scene roots causes each .task to request startup. The
        // Settings scene may be the first window and must not own a separate store.
        func show<V: View>(_ view: V, title: String, size: CGSize = CGSize(width: 1000, height: 700)) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = title
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            return window
        }
        let settingsWindow = show(SettingsSceneContent(launch: launch)
            .environment(\.appTextScaleOverride, 1.3), title: "Settings scene test",
            size: CGSize(width: 520, height: 340))
        // NSHostingView-backed XCTest windows are ordered out, not closed, to
        // avoid the SDK's window-close autorelease checker crash.
        defer { settingsWindow.orderOut(nil) }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(launch.state, .opening)
        XCTAssertNil(launch.dependencies)
        XCTAssertEqual(settingsWindow.contentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                       .darkAqua, "Native Settings root must request the fixed dark appearance")
        let openingSettings = axDescendants(try axWindow(settingsWindow))
        let loading = try XCTUnwrap(openingSettings.first {
            axAttribute($0, kAXDescriptionAttribute) as? String == "Loading: Opening Kontrol" ||
            axAttribute($0, kAXValueAttribute) as? String == "Loading: Opening Kontrol"
        })
        XCTAssertFalse(try axFrame(loading).isEmpty, "Loading label must have rendered bounds")
        XCTAssertFalse(openingSettings.contains { axAttribute($0, kAXIdentifierAttribute) as? String == "settings-content" })
        let mainWindow = show(MainWindowContent(launch: launch, navigation: navigation), title: "Main window test")
        defer { mainWindow.orderOut(nil) }
        XCTAssertEqual(mainWindow.contentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                       .darkAqua, "Main root must request the fixed dark appearance")
        let openingMain = axDescendants(try axWindow(mainWindow))
        XCTAssertTrue(openingMain.contains {
            axAttribute($0, kAXDescriptionAttribute) as? String == "Loading: Opening Kontrol" ||
            axAttribute($0, kAXValueAttribute) as? String == "Loading: Opening Kontrol"
        }, "Main opening must use the same readable loading state")
        XCTAssertFalse(openingMain.contains { axAttribute($0, kAXIdentifierAttribute) as? String == "settings-content" })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 0)
        XCTAssertNil(launch.dependencies)
        await gate.release()
        // Wait for the observed ready state, then verify both routes use its graph.
        let ready = expectation(description: "shared launch finished")
        Task { @MainActor in
            while launch.state == .opening { await Task.yield() }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(launch.state, .ready)
        let graph = try XCTUnwrap(launch.dependencies)
        XCTAssertTrue(graph.container === container)
        XCTAssertTrue(FoundationSettingsView(dependencies: graph).dependencies === graph)
        XCTAssertFalse(graph.aiSettingsStore.presentation.enabled)
        XCTAssertEqual(graph.aiSettingsStore.credentialStatus, .notConfigured)
        XCTAssertTrue(AppShell(navigation: navigation, dependencies: graph).dependencies === graph)
        navigation.select(.settings)
        XCTAssertEqual(AppShell.contentKind(for: navigation.selectedDestination), .settings)

        let appAX = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func descendants(_ element: AXUIElement) -> [AXUIElement] {
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.flatMap { [$0] + descendants($0) }
        }
        func settingsSurface(_ window: AXUIElement) throws -> AXUIElement {
            try XCTUnwrap(descendants(window).first {
                attribute($0, kAXIdentifierAttribute) as? String == "settings-content"
            })
        }
        func assertHubContent(_ surface: AXUIElement) {
            let nodes = [surface] + descendants(surface)
            XCTAssertEqual(nodes.filter {
                attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
                (attribute($0, kAXValueAttribute) as? String == "Settings" ||
                 attribute($0, kAXDescriptionAttribute) as? String == "Settings")
            }.count, 1)
            for identifier in ["settings-general", "settings-ai", "settings-news", "settings-folders", "settings-local-data", "settings-focus-summary",
                               "settings-appearance-summary", "settings-ai-summary", "settings-news-summary", "settings-folders-summary", "settings-local-data-summary"] {
                XCTAssertTrue(nodes.contains { attribute($0, kAXIdentifierAttribute) as? String == identifier },
                              "Both entries must expose implemented hub capability or saved summary: \(identifier)")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        // The shared hub replaces the superseded AI-only foundation surface.
        // Its first committed summary remains visible; lower sections scroll.
        let settingsAX = try axWindow(settingsWindow)
        let settingsBounds = try axFrame(settingsAX)
        XCTAssertGreaterThanOrEqual(settingsBounds.width, 520)
        XCTAssertGreaterThanOrEqual(settingsBounds.height, 340)
        let settingsNodes = axDescendants(settingsAX)
        let status = try XCTUnwrap(settingsNodes.first {
            axAttribute($0, kAXIdentifierAttribute) as? String == "settings-focus-summary"
        })
        XCTAssertEqual(axAttribute(status, kAXValueAttribute) as? String, "Focus default: 25 minutes")
        XCTAssertTrue(settingsBounds.contains(try axFrame(status)), "130% status must be visible in compact Settings")
        let enlargedHeading = try XCTUnwrap(settingsNodes.first {
            axAttribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
            (axAttribute($0, kAXValueAttribute) as? String == "Settings" ||
             axAttribute($0, kAXDescriptionAttribute) as? String == "Settings")
        })
        let standardWindow = show(SettingsSceneContent(launch: launch), title: "Standard Settings comparison",
                                  size: CGSize(width: 520, height: 340))
        defer { standardWindow.orderOut(nil) }
        let standardHeading = try XCTUnwrap(axDescendants(try axWindow(standardWindow)).first {
            axAttribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
            (axAttribute($0, kAXValueAttribute) as? String == "Settings" ||
             axAttribute($0, kAXDescriptionAttribute) as? String == "Settings")
        })
        XCTAssertGreaterThan(try axFrame(enlargedHeading).height, try axFrame(standardHeading).height)
        // Stress beyond 130% in the same compact viewport: content must be
        // scrollable rather than cut off by a 340-point fixed frame.
        let overflowWindow = show(SettingsSceneContent(launch: launch)
            .environment(\.appTextScaleOverride, 4), title: "Overflow Settings inspection",
            size: CGSize(width: 520, height: 340))
        defer { overflowWindow.orderOut(nil) }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let current = (view as? NSScrollView).map { [$0] } ?? []
            return current + view.subviews.flatMap(scrollViews)
        }
        overflowWindow.contentView?.layoutSubtreeIfNeeded()
        settle()
        let scroll = try XCTUnwrap(overflowWindow.contentView.flatMap { scrollViews(in: $0).first })
        scroll.layoutSubtreeIfNeeded()
        let documentHeight = try XCTUnwrap(scroll.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, scroll.contentView.bounds.height,
                             "Oversized Settings content must overflow into a scroll view")
        XCTAssertEqual(opens, 1, "Appearance/layout changes must not initialize a second graph")
        var windows: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windows), .success)
        let visible = try XCTUnwrap(windows as? [AXUIElement])
        for title in ["Settings scene test", "Main window test"] {
            let window = try XCTUnwrap(visible.first { attribute($0, kAXTitleAttribute) as? String == title })
            assertHubContent(try settingsSurface(window))
        }

        // Exercise the real local routes from both isolated ready scene roots,
        // not just their hub labels or construction-time graph identities.
        for window in [settingsWindow, mainWindow] {
            try press("settings-general", in: window)
            for identifier in ["general-preferences-editor", "preferences-duration", "preferences-text-size",
                               "preferences-motion", "preferences-save", "preferences-cancel"] {
                _ = try node(identifier, in: window)
            }
            try press("preferences-cancel", in: window)
            try press("settings-ai", in: window)
            for identifier in ["ai-settings", "ai-edit", "ai-enable", "ai-test-connection"] {
                _ = try node(identifier, in: window)
            }
            try press("settings-back", in: window)
            try press("settings-news", in: window)
            _ = try node("news-management", in: window)
            try press("settings-back", in: window)
        }
        for window in [settingsWindow, mainWindow] {
            try press("settings-folders", in: window)
            _ = try node("settings-folders-content", in: window)
            _ = try node("settings-folders-empty", in: window)
            try press("settings-back", in: window)
            XCTAssertEqual(try value("settings-folders-summary", in: window), "Project folders: 0 saved references")
            try press("settings-local-data", in: window)
            _ = try node("settings-local-data-content", in: window)
            _ = try node("settings-export-start", in: window)
            try press("settings-back", in: window)
            XCTAssertEqual(try value("settings-local-data-summary", in: window), "Local data: Ready to export")
        }
        XCTAssertEqual(graph.appPreferencesStore.committed, .defaults, "Opening/canceling sections does not save preferences")

        // A native Settings scene supplies the standard application-menu command.
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
        }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let settingsCommand = try XCTUnwrap(menuItems(menu).first {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        })
        XCTAssertTrue(settingsCommand.isEnabled)
        XCTAssertTrue(settingsCommand.title.contains("Settings"))
        XCTAssertTrue(NSApp.sendAction(settingsCommand.action!, to: settingsCommand.target, from: settingsCommand))
        try await Task.sleep(for: .milliseconds(100))
        let nativeSettings = try XCTUnwrap(NSApp.windows.first { $0.title == "Kontrol Settings" && $0.isVisible })
        defer { nativeSettings.orderOut(nil) }
        XCTAssertEqual(nativeSettings.contentView?.frame.width ?? 0, 520, accuracy: 40)
        XCTAssertEqual(nativeSettings.contentView?.frame.height ?? 0, 340, accuracy: 40)
        var nativeWindows: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &nativeWindows), .success)
        let nativeAX = try XCTUnwrap((nativeWindows as? [AXUIElement])?.first {
            attribute($0, kAXTitleAttribute) as? String == nativeSettings.title
        })
        assertHubContent(try settingsSurface(nativeAX))
        XCTAssertTrue(launch.dependencies === graph)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)

        mainWindow.orderOut(nil)
        let reopened = show(MainWindowContent(launch: launch, navigation: navigation), title: "Reopened main window")
        defer { reopened.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(launch.dependencies === graph)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CatalogImportState>()).count, 1)
    }
}
