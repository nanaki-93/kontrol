import Combine
import Darwin
import SwiftData
import Foundation
import XCTest
import UniformTypeIdentifiers
@testable import Kontrol

final class ExportServiceTests: XCTestCase {
    @MainActor
    private final class PanelSpy: ExportSavePanelPresenting {
        var configurations: [ExportSavePanelConfiguration] = []
        var completion: (@MainActor (Bool, URL?) -> Void)?
        var onBegin: (() -> Void)?
        var onCancel: (() -> Void)?
        private(set) var begins = 0
        private(set) var cancels = 0
        func configure(_ configuration: ExportSavePanelConfiguration) { configurations.append(configuration) }
        func begin(_ completion: @escaping @MainActor (Bool, URL?) -> Void) {
            XCTAssertTrue(Thread.isMainThread)
            begins += 1
            self.completion = completion
            onBegin?()
        }
        func cancel() {
            XCTAssertTrue(Thread.isMainThread)
            cancels += 1
            onCancel?()
        }
    }

    func testPanelConfigurationRestrictsJSONAndNamesInjectedDateInUTCGregorianCalendar() throws {
        for (timestamp, filename) in [
            ("2026-09-30T23:59:59.999Z", "kontrol-export-2026-09-30.json"),
            ("2027-01-01T00:00:00.000Z", "kontrol-export-2027-01-01.json"),
            ("2028-02-29T12:00:00.000Z", "kontrol-export-2028-02-29.json")
        ] {
            let configuration = ExportSavePanelConfiguration(date: try ExportTimestamp(value: timestamp).date)
            XCTAssertEqual(configuration.suggestedFilename, filename)
            XCTAssertEqual(configuration.allowedContentTypes, [.json])
            XCTAssertFalse(configuration.allowsOtherFileTypes)
            XCTAssertFalse(configuration.isExtensionHidden)
            XCTAssertTrue(configuration.canCreateDirectories)
        }
    }

    @MainActor
    func testPanelCancelIgnoresAnyURLAndCreatesNoDestinationOrArtifact() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = PanelSpy()
        let target = root.appendingPathComponent("destination.json")
        spy.onBegin = { [weak spy] in spy?.completion?(false, target) }
        var approvals = 0
        let panel: any ExportDestinationSelecting = ExportSavePanel(makePanel: { spy }, approve: {
            approvals += 1
            return try ExportFileWriter().approveDestination($0)
        })
        let date = try ExportTimestamp(value: "2026-09-30T00:00:00.000Z").date
        let result = try await panel.selectDestination(suggestedAt: date)
        guard case .canceled = result else { return XCTFail("Canceled panel returned destination") }
        XCTAssertEqual(approvals, 0)
        XCTAssertEqual(spy.begins, 1)
        XCTAssertEqual(spy.configurations, [ExportSavePanelConfiguration(date: date)])
        try assertEmpty(root)
    }

    @MainActor
    func testAlreadyCanceledSelectionNeverConstructsOrApprovesPanel() async throws {
        var creations = 0
        var approvals = 0
        let panel = ExportSavePanel(makePanel: { creations += 1; return PanelSpy() }, approve: {
            approvals += 1
            return try ExportFileWriter().approveDestination($0)
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await panel.selectDestination(suggestedAt: Date())
        }
        let result = try await task.value
        guard case .canceled = result else { return XCTFail("Canceled caller selected destination") }
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(approvals, 0)
    }

    @MainActor
    func testPanelApprovedNewAndExistingDestinationsCaptureIntentWithoutWritingUntilDelivery() async throws {
        for replacing in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("native-approved replacement bytes".utf8)
            if replacing { try original.write(to: target) }
            let ledger = AccessLedger()
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: .init(
                startAccess: { _ in ledger.start(); return true }, stopAccess: { _ in ledger.stop() }))
            let spy = PanelSpy()
            spy.onBegin = { [weak spy] in spy?.completion?(true, target) }
            var approvals = 0
            let panel = ExportSavePanel(makePanel: { spy }, approve: { url in
                XCTAssertEqual(url, target)
                approvals += 1
                return try writer.approveDestination(url)
            })
            let result = try await panel.selectDestination(suggestedAt: Date())
            guard case .approved(let destination) = result else { return XCTFail("Approved panel canceled") }
            XCTAssertEqual(approvals, 1)
            XCTAssertEqual(ledger.counts, [1, 1], "Approval never retains acquired authorization")
            try assertDeliveryClean(root, destinationExists: replacing)
            if replacing { XCTAssertEqual(try Data(contentsOf: target), original) }
            let snapshot = try snapshot()
            let artifact = try await writer.prepare(snapshot)
            let outcome = try await writer.deliver(artifact, to: destination)
            XCTAssertEqual(outcome, .committed)
            XCTAssertEqual(try Data(contentsOf: target), try snapshot.encoded())
            XCTAssertEqual(ledger.counts, [2, 2])
            try assertDeliveryClean(root)
        }
    }

    @MainActor
    func testPanelMissingAndUnsafeApprovedDestinationsFailWithoutArtifactsAndAllowExplicitRetry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = PanelSpy()
        let panel = ExportSavePanel(makePanel: { spy })
        spy.onBegin = { [weak spy] in spy?.completion?(true, nil) }
        do { _ = try await panel.selectDestination(suggestedAt: Date()); XCTFail("Missing URL approved") }
        catch { XCTAssertEqual(error as? ExportSavePanelError, .missingDestination) }
        spy.onBegin = { [weak spy] in spy?.completion?(true, root) }
        do { _ = try await panel.selectDestination(suggestedAt: Date()); XCTFail("Directory approved") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .unsafeDestination) }
        spy.onBegin = { [weak spy] in spy?.completion?(false, nil) }
        let retried = try await panel.selectDestination(suggestedAt: Date())
        guard case .canceled = retried else { return XCTFail("Explicit retry failed") }
        XCTAssertEqual(spy.begins, 3)
        try assertEmpty(root)
    }

    @MainActor
    func testPanelCancellationWaitsForDismissalRejectsOverlapAndIgnoresDuplicateOldCallbacks() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = PanelSpy()
        let begun = expectation(description: "Panel started")
        let canceled = expectation(description: "Native cancel requested")
        spy.onBegin = { begun.fulfill() }
        spy.onCancel = { canceled.fulfill() }
        var approvals = 0
        let panel = ExportSavePanel(makePanel: { spy }, approve: {
            approvals += 1
            return try ExportFileWriter().approveDestination($0)
        })
        var completed = false
        let task = Task {
            let result = try await panel.selectDestination(suggestedAt: Date())
            completed = true
            return result
        }
        await fulfillment(of: [begun], timeout: 5)
        task.cancel()
        await fulfillment(of: [canceled], timeout: 5)
        XCTAssertFalse(completed, "Cancellation retains ownership until the real callback")
        do { _ = try await panel.selectDestination(suggestedAt: Date()); XCTFail("Overlapping panel admitted") }
        catch { XCTAssertEqual(error as? ExportSavePanelError, .selectionInProgress) }
        XCTAssertEqual(spy.begins, 1)
        XCTAssertEqual(spy.cancels, 1)
        let oldCallback = try XCTUnwrap(spy.completion)
        oldCallback(true, root.appendingPathComponent("destination.json"))
        let result = try await task.value
        guard case .canceled = result else { return XCTFail("Late approval defeated cancellation") }
        XCTAssertEqual(approvals, 0)
        let retried = expectation(description: "Explicit retry started")
        spy.onBegin = { retried.fulfill() }
        let retry = Task { try await panel.selectDestination(suggestedAt: Date()) }
        await fulfillment(of: [retried], timeout: 5)
        oldCallback(true, root.appendingPathComponent("obsolete.json"))
        oldCallback(false, nil)
        spy.completion?(false, nil)
        let retryResult = try await retry.value
        guard case .canceled = retryResult else { return XCTFail("Old callback affected retry") }
        XCTAssertEqual(approvals, 0)
        XCTAssertEqual(spy.begins, 2)
        try assertEmpty(root)
    }

    @MainActor
    func testCallerCancellationRacingAcceptedCallbackNeverApprovesDestination() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = PanelSpy()
        let begun = expectation(description: "Panel started")
        spy.onBegin = { begun.fulfill() }
        var approvals = 0
        let panel = ExportSavePanel(makePanel: { spy }, approve: {
            approvals += 1
            return try ExportFileWriter().approveDestination($0)
        })
        let task = Task { try await panel.selectDestination(suggestedAt: Date()) }
        await fulfillment(of: [begun], timeout: 5)
        // Same main-actor turn: callback wins dismissal but caller cancellation
        // precedes continuation resumption, before the cancel-handler task runs.
        spy.completion?(true, root.appendingPathComponent("destination.json"))
        task.cancel()
        let result = try await task.value
        guard case .canceled = result else { return XCTFail("Racing cancellation approved URL") }
        XCTAssertEqual(approvals, 0)
        try assertEmpty(root)
    }

    @MainActor
    private final class LifecycleRepository: ExportRepository {
        var calls: [(Date, String)] = []
        var fail = false
        var onCapture: (() -> Void)?
        func snapshot(exportedAt: Date, appVersion: String) throws -> LocalDataExport {
            XCTAssertTrue(Thread.isMainThread)
            calls.append((exportedAt, appVersion))
            onCapture?()
            if fail { throw NSError(domain: "private capture details", code: 1) }
            return LocalDataExport(exportedAt: try ExportTimestamp(exportedAt), appVersion: appVersion)
        }
    }

    private actor LifecycleWriter: ExportFilePreparing, ExportFileDelivering {
        let real: ExportFileWriter
        var snapshots: [LocalDataExport] = []
        var deliveries = 0
        var failPreparation = false
        var failDelivery = false
        var prepared: XCTestExpectation?
        var continuation: CheckedContinuation<Void, Never>?

        init(root: URL) { real = ExportFileWriter(temporaryRoot: root) }
        nonisolated func approveDestination(_ url: URL) throws -> ApprovedExportDestination {
            try real.approveDestination(url)
        }
        func setFailure(preparation: Bool = false, delivery: Bool = false) {
            failPreparation = preparation
            failDelivery = delivery
        }
        func suspendAfterPreparation(_ entered: XCTestExpectation) { prepared = entered }
        func resumePreparation() { continuation?.resume(); continuation = nil }
        func counts() -> [Int] { [snapshots.count, deliveries] }
        func prepare(_ snapshot: LocalDataExport) async throws -> PreparedExportArtifact {
            snapshots.append(snapshot)
            if failPreparation { throw NSError(domain: "private encoding details", code: 2) }
            let artifact = try await real.prepare(snapshot)
            if let prepared {
                // Deliberately noncooperative: cancellation must not relinquish
                // lifecycle ownership, and the late artifact must be discarded.
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    prepared.fulfill()
                }
            }
            return artifact
        }
        func deliver(_ artifact: PreparedExportArtifact,
                     to destination: ApprovedExportDestination) async throws -> ExportDeliveryOutcome {
            deliveries += 1
            if failDelivery { throw NSError(domain: "private destination details", code: 3) }
            return try await real.deliver(artifact, to: destination)
        }
    }

    private func versionBundle(in root: URL, version: String) throws -> Bundle {
        let url = root.appendingPathComponent("ExportMetadata.bundle")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.kontrol.export.\(UUID().uuidString)",
                    "CFBundleShortVersionString": version, "CFBundleVersion": "456"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: url))
    }

    @MainActor
    func testGraphSettingsClientsShareExportOwnerAndRejectOverlapDuringSelectionAndPreparation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleRoot = try self.root()
        defer { try? FileManager.default.removeItem(at: bundleRoot) }
        let bundle = try versionBundle(in: bundleRoot, version: "9.8.7")
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = LifecycleRepository()
        let writer = LifecycleWriter(root: root)
        let spy = PanelSpy()
        let selected = expectation(description: "Shared panel started")
        spy.onBegin = { selected.fulfill() }
        let prepared = expectation(description: "Shared writer preparing")
        await writer.suspendAfterPreparation(prepared)
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        var clockReads = 0
        let graph = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container),
            exportRepository: repository, exportPanel: ExportSavePanel(makePanel: { spy }),
            exportWriter: writer, exportClock: { clockReads += 1; return date }, exportBundle: bundle)
        let mainSettings = FoundationSettingsView(dependencies: graph)
        let nativeSettings = FoundationSettingsView(dependencies: graph)
        let mainService = mainSettings.dependencies.exportService
        let nativeService = nativeSettings.dependencies.exportService
        XCTAssertTrue(mainService === nativeService)
        XCTAssertTrue(mainSettings.dependencies.lessonDraftStore === nativeSettings.dependencies.lessonDraftStore)
        XCTAssertTrue(mainSettings.dependencies.container === container)
        XCTAssertTrue(nativeSettings.dependencies.container === container)
        XCTAssertEqual(mainService.state, .idle)
        XCTAssertFalse(mainService.isBusy)
        XCTAssertEqual(clockReads, 0)
        XCTAssertEqual(spy.begins, 0)
        XCTAssertTrue(repository.calls.isEmpty)
        let constructionCounts = await writer.counts()
        XCTAssertEqual(constructionCounts, [0, 0])
        try assertEmpty(root)
        XCTAssertTrue(mainService.startExport())
        XCTAssertFalse(nativeService.startExport())
        await fulfillment(of: [selected], timeout: 5)
        XCTAssertEqual(spy.begins, 1)
        XCTAssertEqual(nativeService.state, .selecting)
        XCTAssertFalse(nativeService.startExport())
        spy.completion?(true, root.appendingPathComponent("destination.json"))
        await fulfillment(of: [prepared], timeout: 5)
        XCTAssertEqual(nativeService.state, .preparing)
        XCTAssertFalse(mainService.startExport())
        XCTAssertFalse(nativeService.startExport())
        XCTAssertEqual(repository.calls.count, 1)
        XCTAssertEqual(repository.calls.first?.0, date)
        XCTAssertEqual(repository.calls.first?.1, "9.8.7", "Use marketing version, not build number or a constant")
        let preparingCounts = await writer.counts()
        XCTAssertEqual(preparingCounts, [1, 0])
        await writer.resumePreparation()
        await nativeService.waitForCompletion()
        XCTAssertEqual(mainService.state, .saved)
        XCTAssertEqual(nativeService.state, .saved)
        XCTAssertFalse(mainService.isBusy)
        XCTAssertEqual(clockReads, 2)
        XCTAssertEqual(spy.begins, 1)
        let savedCounts = await writer.counts()
        XCTAssertEqual(savedCounts, [1, 1])
        let exported = try LocalDataExport.decode(Data(contentsOf: root.appendingPathComponent("destination.json")))
        XCTAssertEqual(exported.appVersion, "9.8.7")
        XCTAssertEqual(exported.exportedAt, try ExportTimestamp(date))
        try assertDeliveryClean(root)
    }

    @MainActor
    func testServicePanelCancelAndSelectionFailureNeverFlushCapturePrepareOrWrite() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = PanelSpy()
        let repository = LifecycleRepository()
        let writer = LifecycleWriter(root: root)
        var flushes = 0
        var versions = 0
        let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
            writer: writer, appVersion: { versions += 1; return "1.0" }, flushAnswers: { flushes += 1 })
        XCTAssertEqual(service.state, .idle)
        for missingURL in [false, true] {
            spy.onBegin = { [weak spy] in spy?.completion?(missingURL, nil) }
            XCTAssertTrue(service.startExport())
            await service.waitForCompletion()
            XCTAssertEqual(service.state, missingURL ? .failed(.selection) : .canceled)
            XCTAssertFalse(service.isBusy)
            XCTAssertEqual(flushes, 0)
            XCTAssertEqual(versions, 0)
            XCTAssertTrue(repository.calls.isEmpty)
            let counts = await writer.counts()
            XCTAssertEqual(counts, [0, 0])
            try assertEmpty(root)
        }
    }

    @MainActor
    func testServiceSuccessfulSequenceUsesInjectedCaptureMetadataAndOnlyCommitPublishesSaved() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let repository = LifecycleRepository()
        let writer = LifecycleWriter(root: root)
        let spy = PanelSpy()
        var events: [String] = []
        spy.onBegin = { [weak spy] in events.append("panel"); spy?.completion?(true, target) }
        repository.onCapture = { events.append("capture") }
        let selectingDate = Date(timeIntervalSince1970: 1_000)
        let captureDate = Date(timeIntervalSince1970: 2_000)
        var clocks = 0
        let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
            writer: writer, clock: { clocks += 1; return clocks == 1 ? selectingDate : captureDate },
            appVersion: { events.append("version"); return "9.8.7" },
            flushAnswers: { events.append("flush") })
        var states: [ExportService.State] = []
        let subscription = service.$state.sink { states.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(service.startExport())
        XCTAssertEqual(service.state, .selecting)
        XCTAssertFalse(service.startExport())
        await service.waitForCompletion()
        XCTAssertEqual(events, ["panel", "flush", "version", "capture"])
        XCTAssertEqual(states, [.idle, .selecting, .preparing, .saved])
        XCTAssertEqual(repository.calls.count, 1)
        XCTAssertEqual(repository.calls.first?.0, captureDate)
        XCTAssertEqual(repository.calls.first?.1, "9.8.7")
        XCTAssertEqual(spy.configurations, [ExportSavePanelConfiguration(date: selectingDate)])
        let counts = await writer.counts()
        XCTAssertEqual(counts, [1, 1])
        let exported = try LocalDataExport.decode(Data(contentsOf: target))
        XCTAssertEqual(exported.exportedAt, try ExportTimestamp(captureDate))
        XCTAssertEqual(exported.appVersion, "9.8.7")
        XCTAssertFalse(service.isBusy)
        service.cancel()
        XCTAssertEqual(service.state, .saved)
        try assertDeliveryClean(root)
    }

    @MainActor
    func testServiceFailuresAbortAtBoundaryCleanArtifactsAndRequireExplicitRetry() async throws {
        for failure in [ExportService.Failure.answerSave, .capture, .preparation, .delivery] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("unchanged precommit bytes".utf8)
            try original.write(to: target)
            let spy = PanelSpy()
            spy.onBegin = { [weak spy] in spy?.completion?(true, target) }
            let repository = LifecycleRepository()
            repository.fail = failure == .capture
            let writer = LifecycleWriter(root: root)
            await writer.setFailure(preparation: failure == .preparation, delivery: failure == .delivery)
            var failFlush = failure == .answerSave
            var flushes = 0
            let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
                writer: writer, appVersion: { "1.0" }, flushAnswers: {
                    flushes += 1
                    if failFlush { throw NSError(domain: "private answer details", code: 4) }
                })
            XCTAssertTrue(service.startExport())
            await service.waitForCompletion()
            XCTAssertEqual(service.state, .failed(failure))
            XCTAssertFalse(service.isBusy)
            XCTAssertEqual(flushes, 1)
            XCTAssertEqual(repository.calls.count, failure == .answerSave ? 0 : 1)
            let counts = await writer.counts()
            XCTAssertEqual(counts, failure == .delivery ? [1, 1] : failure == .preparation ? [1, 0] : [0, 0])
            XCTAssertEqual(try Data(contentsOf: target), original)
            try assertDeliveryClean(root)
            // No automatic re-entry even after unrelated actor work.
            await Task.yield()
            XCTAssertEqual(spy.begins, 1)
            failFlush = false
            repository.fail = false
            await writer.setFailure()
            XCTAssertTrue(service.startExport())
            await service.waitForCompletion()
            XCTAssertEqual(service.state, .saved)
            XCTAssertEqual(spy.begins, 2)
            XCTAssertEqual(flushes, 2)
            _ = try LocalDataExport.decode(Data(contentsOf: target))
            try assertDeliveryClean(root)
        }
    }

    @MainActor
    func testServiceRealFlushFailureRetainsDirtyAnswersAndEarlierDurableSavesThenExplicitRetryExportsThem() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var failOnSecondSave = false
        var saves = 0
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if failOnSecondSave {
                saves += 1
                if saves == 2 { throw NSError(domain: "injected save failure", code: 1) }
            }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let bundleRoot = try self.root()
        defer { try? FileManager.default.removeItem(at: bundleRoot) }
        let bundle = try versionBundle(in: bundleRoot, version: "2.3.4")
        let writer = LifecycleWriter(root: root)
        let spy = PanelSpy()
        let graph = AppDependencies(container: container, catalogRepository: repository,
            draftScheduler: { _, _ in {} }, exportPanel: ExportSavePanel(makePanel: { spy }),
            exportWriter: writer, exportBundle: bundle)
        let service = graph.exportService
        graph.learningCatalogStore.loadIfNeeded()
        let slots = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots)
        for slot in slots.prefix(3) {
            let opened = try graph.learningCatalogStore.openLesson(lessonID: slot.lessonID)
            graph.lessonDraftStore.observe(opened.detail)
            let attempt = try XCTUnwrap(opened.detail.attempt)
            graph.lessonDraftStore.edit("  pending \(attempt.id) 🔐\n", attemptID: attempt.id)
        }
        let buffers = graph.lessonDraftStore.buffers.values.sorted { $0.attemptID.uuidString < $1.attemptID.uuidString }
        XCTAssertEqual(buffers.count, 3)
        let target = root.appendingPathComponent("destination.json")
        // Cancel must leave even real pending buffers untouched. The graph's
        // default repository reads this container after its own draft owner saves.
        spy.onBegin = { [weak spy] in spy?.completion?(false, nil) }
        XCTAssertTrue(service.startExport())
        await service.waitForCompletion()
        XCTAssertEqual(service.state, .canceled)
        XCTAssertEqual(graph.lessonDraftStore.buffers.values.filter(\.isDirty).count, 3)
        failOnSecondSave = true
        spy.onBegin = { [weak spy] in spy?.completion?(true, target) }
        XCTAssertTrue(service.startExport())
        await service.waitForCompletion()
        XCTAssertEqual(service.state, .failed(.answerSave))
        for (index, buffer) in buffers.enumerated() {
            let current = try XCTUnwrap(graph.lessonDraftStore.buffers[buffer.attemptID])
            XCTAssertEqual(current.text, buffer.text)
            XCTAssertEqual(current.isDirty, index != 0)
            let durable = try repository.loadLesson(lessonID: buffer.lessonID)
            XCTAssertEqual(durable.attempt?.answerDraft, index == 0 ? buffer.text : "")
        }
        XCTAssertEqual(graph.lessonDraftStore.buffers[buffers[1].attemptID]?.status, .notSaved(.persistenceFailure))
        let failedCounts = await writer.counts()
        XCTAssertEqual(failedCounts, [0, 0])
        try assertEmpty(root)
        failOnSecondSave = false
        XCTAssertTrue(service.startExport())
        await service.waitForCompletion()
        XCTAssertEqual(service.state, .saved)
        let exported = try LocalDataExport.decode(Data(contentsOf: target))
        XCTAssertEqual(exported.appVersion, "2.3.4")
        for buffer in buffers {
            XCTAssertEqual(exported.learning.attempts.first { $0.id == buffer.attemptID }?.answerDraft, buffer.text)
            XCTAssertFalse(try XCTUnwrap(graph.lessonDraftStore.buffers[buffer.attemptID]).isDirty)
        }
        try assertDeliveryClean(root)
    }

    @MainActor
    func testServiceCancelRetainsPanelOwnershipAndFencesOldCallbacksAcrossExplicitRetry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = PanelSpy()
        let begun = expectation(description: "First panel begun")
        let dismissed = expectation(description: "Native cancel requested")
        spy.onBegin = { begun.fulfill() }
        spy.onCancel = { dismissed.fulfill() }
        let repository = LifecycleRepository()
        let writer = LifecycleWriter(root: root)
        var flushes = 0
        let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
            writer: writer, appVersion: { "1.0" }, flushAnswers: { flushes += 1 })
        XCTAssertTrue(service.startExport())
        await fulfillment(of: [begun], timeout: 5)
        let oldCallback = try XCTUnwrap(spy.completion)
        service.cancel()
        service.cancel()
        await fulfillment(of: [dismissed], timeout: 5)
        XCTAssertTrue(service.isBusy)
        XCTAssertEqual(service.state, .selecting)
        XCTAssertFalse(service.startExport())
        oldCallback(true, root.appendingPathComponent("obsolete.json"))
        await service.waitForCompletion()
        XCTAssertEqual(service.state, .canceled)
        XCTAssertFalse(service.isBusy)
        let retryBegun = expectation(description: "Retry panel begun")
        spy.onBegin = { retryBegun.fulfill() }
        XCTAssertTrue(service.startExport())
        await fulfillment(of: [retryBegun], timeout: 5)
        oldCallback(true, root.appendingPathComponent("obsolete.json"))
        oldCallback(false, nil)
        XCTAssertEqual(service.state, .selecting)
        XCTAssertTrue(service.isBusy)
        spy.completion?(false, nil)
        await service.waitForCompletion()
        XCTAssertEqual(service.state, .canceled)
        XCTAssertEqual(spy.begins, 2)
        XCTAssertEqual(flushes, 0)
        XCTAssertTrue(repository.calls.isEmpty)
        let counts = await writer.counts()
        XCTAssertEqual(counts, [0, 0])
        try assertEmpty(root)
    }

    @MainActor
    func testServiceCancellationBeforeStartAndRacingApprovalNeverFlushesOrCaptures() async throws {
        for beforeStart in [true, false] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let spy = PanelSpy()
            let begun = beforeStart ? nil : expectation(description: "Panel begun")
            spy.onBegin = { begun?.fulfill() }
            let repository = LifecycleRepository()
            let writer = LifecycleWriter(root: root)
            var flushes = 0
            let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
                writer: writer, appVersion: { "1.0" }, flushAnswers: { flushes += 1 })
            XCTAssertTrue(service.startExport())
            if !beforeStart {
                await fulfillment(of: [try XCTUnwrap(begun)], timeout: 5)
                spy.completion?(true, root.appendingPathComponent("destination.json"))
            }
            service.cancel()
            await service.waitForCompletion()
            XCTAssertEqual(service.state, .canceled)
            XCTAssertEqual(spy.begins, beforeStart ? 0 : 1)
            XCTAssertEqual(flushes, 0)
            XCTAssertTrue(repository.calls.isEmpty)
            let counts = await writer.counts()
            XCTAssertEqual(counts, [0, 0])
            try assertEmpty(root)
        }
    }

    @MainActor
    func testServiceCancellationDuringSynchronousBarriersStopsBeforeNextBoundary() async throws {
        for boundary in ["selecting", "preparing", "flush", "capture"] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let spy = PanelSpy()
            spy.onBegin = { [weak spy] in spy?.completion?(true, root.appendingPathComponent("destination.json")) }
            let repository = LifecycleRepository()
            let writer = LifecycleWriter(root: root)
            weak var owner: ExportService?
            var flushes = 0
            let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
                writer: writer, appVersion: { "1.0" }, flushAnswers: {
                    flushes += 1
                    if boundary == "flush" { owner?.cancel() }
                })
            owner = service
            repository.onCapture = { if boundary == "capture" { owner?.cancel() } }
            let subscription = service.$state.sink { state in
                if (boundary == "selecting" && state == .selecting) ||
                    (boundary == "preparing" && state == .preparing) { owner?.cancel() }
            }
            defer { subscription.cancel() }
            XCTAssertTrue(service.startExport())
            await service.waitForCompletion()
            XCTAssertEqual(service.state, .canceled)
            XCTAssertFalse(service.isBusy)
            XCTAssertEqual(flushes, ["flush", "capture"].contains(boundary) ? 1 : 0)
            XCTAssertEqual(repository.calls.count, boundary == "capture" ? 1 : 0)
            let counts = await writer.counts()
            XCTAssertEqual(counts, [0, 0])
            try assertEmpty(root)
        }
    }

    @MainActor
    func testServiceCanceledNoncooperativePreparationRetainsOwnershipAndDiscardsLateArtifact() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let original = Data("preserve pending preparation bytes".utf8)
        try original.write(to: target)
        let spy = PanelSpy()
        spy.onBegin = { [weak spy] in spy?.completion?(true, target) }
        let repository = LifecycleRepository()
        let writer = LifecycleWriter(root: root)
        let prepared = expectation(description: "Private artifact prepared")
        await writer.suspendAfterPreparation(prepared)
        let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
            writer: writer, appVersion: { "1.0" }, flushAnswers: {})
        XCTAssertTrue(service.startExport())
        await fulfillment(of: [prepared], timeout: 5)
        service.cancel()
        await Task.yield()
        XCTAssertTrue(service.isBusy)
        XCTAssertEqual(service.state, .preparing)
        XCTAssertFalse(service.startExport())
        XCTAssertEqual(spy.begins, 1)
        await writer.resumePreparation()
        await service.waitForCompletion()
        XCTAssertEqual(service.state, .canceled)
        XCTAssertFalse(service.isBusy)
        let counts = await writer.counts()
        XCTAssertEqual(counts, [1, 0])
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertDeliveryClean(root)
    }

    @MainActor
    func testServiceCancellationAtEveryDeliveryStageKeepsOwnershipPreservesBytesOrReportsActualCommit() async throws {
        for stoppingStage in ExportFileWriter.DeliveryStage.allCases {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("preserve until atomic commit".utf8)
            try original.write(to: target)
            let entered = expectation(description: "Delivery stage reached")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: .init(checkpoint: { stage, _ in
                if stage == stoppingStage {
                    XCTAssertFalse(Thread.isMainThread)
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        XCTFail("Service did not release delivery worker")
                        throw ExportFileWriterError.deliveryFailed
                    }
                }
            }))
            let spy = PanelSpy()
            spy.onBegin = { [weak spy] in spy?.completion?(true, target) }
            let repository = LifecycleRepository()
            let service = ExportService(repository: repository, panel: ExportSavePanel(makePanel: { spy }),
                writer: writer, appVersion: { "1.0" }, flushAnswers: {})
            XCTAssertTrue(service.startExport())
            await fulfillment(of: [entered], timeout: 5)
            service.cancel()
            await Task.yield()
            XCTAssertTrue(service.isBusy)
            XCTAssertEqual(service.state, .preparing)
            XCTAssertFalse(service.startExport())
            release.signal()
            await service.waitForCompletion()
            XCTAssertFalse(service.isBusy)
            XCTAssertEqual(service.state, stoppingStage == .committed ? .saved : .canceled)
            if stoppingStage == .committed {
                _ = try LocalDataExport.decode(Data(contentsOf: target))
            } else {
                XCTAssertEqual(try Data(contentsOf: target), original)
            }
            try assertDeliveryClean(root)
        }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kontrol-export-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func snapshot() throws -> LocalDataExport {
        let time = try ExportTimestamp(value: "2026-09-30T12:00:00.123Z")
        var snapshot = LocalDataExport(exportedAt: time, appVersion: "1.0")
        snapshot.tasks = [.init(id: UUID(), title: " \tAPI_KEY=keep me 🔐 e\u{301}\r\n ",
                               notes: " exact notes\n", dueAt: nil, plannedDay: nil,
                               createdAt: time, completedAt: nil)]
        return snapshot
    }

    private func assertEmpty(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], file: file, line: line)
    }

    func testPreparationRoundTripsPrivatePermissionsAndConsumesExactlyOnceWithoutDestinationAccess() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("unrelated.json")
        let existing = Data("existing destination bytes".utf8)
        try existing.write(to: destination)
        let snapshot = try snapshot()
        let writer: any ExportFilePreparing = ExportFileWriter(temporaryRoot: root)
        let artifact = try await writer.prepare(snapshot)
        let bytes = try artifact.consume { url in
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(fileAttributes[.type] as? FileAttributeType, .typeRegular)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(try LocalDataExport.decode(bytes), snapshot.canonicalized())
            XCTAssertEqual(bytes, try snapshot.encoded())
            return bytes
        }
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertThrowsError(try artifact.consume { _ in XCTFail("Consumed artifact reused") }) {
            XCTAssertEqual($0 as? ExportFileWriterError, .artifactUnavailable)
        }
        try artifact.discard()
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated.json"])
    }

    func testInvalidSnapshotAndEncoderFailuresAreSafeAndCleanOwnedArtifacts() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var invalid = try snapshot()
        invalid.schemaVersion = 2
        do {
            _ = try await ExportFileWriter(temporaryRoot: root).prepare(invalid)
            XCTFail("Invalid snapshot prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
        try assertEmpty(root)
        let hooks = ExportFileWriter.PreparationHooks(encode: { _ in
            throw NSError(domain: "sensitive path/content must not escape", code: 1)
        })
        do {
            _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
            XCTFail("Encoder failure prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
        try assertEmpty(root)
    }

    func testMalformedUnsupportedAndValidButWrongPreparedJSONCannotProceed() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        var wrong = snapshot
        wrong.appVersion = "different valid snapshot"
        var unsupported = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        unsupported["schemaVersion"] = 2
        let badBytes = [Data("not JSON".utf8), try JSONSerialization.data(withJSONObject: unsupported), try wrong.encoded()]
        for bytes in badBytes {
            let hooks = ExportFileWriter.PreparationHooks(encode: { _ in bytes })
            do {
                _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot)
                XCTFail("Invalid prepared bytes accepted")
            } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
            try assertEmpty(root)
        }
    }

    func testValidationReadsBackActualFileAndRejectsChangedStoredBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, directory in
            if stage == .fileWritten {
                try Data("corrupt storage".utf8).write(to: directory.appendingPathComponent("export.json"))
            }
        })
        do {
            _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
            XCTFail("Corrupt file prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
        try assertEmpty(root)
    }

    func testInjectedFailuresAtEveryPreparationStageCleanOnlyOwnedDirectory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: sentinel)
        for failingStage in ExportFileWriter.PreparationStage.allCases {
            let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, _ in
                if stage == failingStage { throw NSError(domain: "private raw IO failure", code: 1) }
            })
            do {
                _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
                XCTFail("Injected failure prepared")
            } catch { XCTAssertEqual(error as? ExportFileWriterError, .preparationFailed) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated"])
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        }
    }

    func testPrivateFileCreationFailurePreservesUnrelatedBytesAndCleansStaging() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated")
        let original = Data("untouched unrelated bytes".utf8)
        try original.write(to: unrelated)
        let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, directory in
            if stage == .encoded {
                // Force a real exclusive-create failure; never follow an existing link.
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("export.json"),
                                                          withDestinationURL: unrelated)
            }
        })
        do {
            _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
            XCTFail("Existing private file overwritten")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .preparationFailed) }
        XCTAssertEqual(try Data(contentsOf: unrelated), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated"])
    }

    func testUnavailableTemporaryRootFailsWithoutCreatingAnything() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await ExportFileWriter(temporaryRoot: root.appendingPathComponent("absent")).prepare(snapshot())
            XCTFail("Unavailable storage prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .preparationFailed) }
        try assertEmpty(root)
    }

    func testCancellationBeforePreparationCreatesNoArtifact() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExportFileWriter(temporaryRoot: root).prepare(snapshot)
        }
        do { _ = try await task.value; XCTFail("Canceled preparation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertEmpty(root)
    }

    @MainActor
    func testCancellationAtEveryStageWaitsForWorkerAndCleansBeforeReturning() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        for cancellationStage in ExportFileWriter.PreparationStage.allCases {
            let reached = expectation(description: "Worker reached stage")
            let release = DispatchSemaphore(value: 0)
            let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, _ in
                if stage == cancellationStage {
                    XCTAssertFalse(Thread.isMainThread)
                    reached.fulfill()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw ExportFileWriterError.preparationFailed
                    }
                }
            })
            let task = Task { try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot) }
            await fulfillment(of: [reached], timeout: 5)
            task.cancel()
            // The noncooperative checkpoint still owns its directory at this point.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
            release.signal()
            do { _ = try await task.value; XCTFail("Canceled worker returned artifact") }
            catch { XCTAssertTrue(error is CancellationError) }
            try assertEmpty(root)
        }
    }

    @MainActor
    func testEncodingAndIOLeaveUnrelatedMainActorWorkResponsive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = try snapshot()
        snapshot.tasks[0].notes = String(repeating: "long exact saved answer\n", count: 100_000)
        let enteredEncoder = expectation(description: "Off-main encoder entered")
        let responsive = expectation(description: "Unrelated main-actor work ran")
        let release = DispatchSemaphore(value: 0)
        let hooks = ExportFileWriter.PreparationHooks(encode: { snapshot in
            XCTAssertFalse(Thread.isMainThread)
            enteredEncoder.fulfill()
            guard release.wait(timeout: .now() + 10) == .success else {
                throw ExportFileWriterError.preparationFailed
            }
            return try snapshot.encoded()
        }, checkpoint: { _, _ in XCTAssertFalse(Thread.isMainThread) })
        let task = Task { try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot) }
        await fulfillment(of: [enteredEncoder], timeout: 5)
        Task { @MainActor in
            XCTAssertTrue(Thread.isMainThread)
            responsive.fulfill()
            release.signal()
        }
        await fulfillment(of: [responsive], timeout: 5)
        let artifact = try await task.value
        try artifact.consume { url in XCTAssertEqual(try LocalDataExport.decode(Data(contentsOf: url)), snapshot) }
        try assertEmpty(root)
    }

    func testConcurrentArtifactAliasesAdmitExactlyOneConsumerAndCleanOnce() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        let artifact = try await ExportFileWriter(temporaryRoot: root).prepare(snapshot)
        let consumed = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        try artifact.consume { url in
                            XCTAssertEqual(try LocalDataExport.decode(Data(contentsOf: url)), snapshot)
                        }
                        return true
                    } catch {
                        XCTAssertEqual(error as? ExportFileWriterError, .artifactUnavailable)
                        return false
                    }
                }
            }
            var successes = 0
            for await success in group { if success { successes += 1 } }
            return successes
        }
        XCTAssertEqual(consumed, 1)
        try artifact.discard()
        try assertEmpty(root)
    }

    private final class AccessLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0
        private var stops = 0
        func start() { lock.lock(); defer { lock.unlock() }; starts += 1 }
        func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
        var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [starts, stops] }
    }

    private func assertDeliveryClean(_ root: URL, destinationExists: Bool = true,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       destinationExists ? ["destination.json"] : [], file: file, line: line)
    }

    func testAtomicCreationAndReplacementRoundTripAndBalanceTransientAuthorization() async throws {
        for replacing in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            if replacing { try Data("previous bytes".utf8).write(to: target) }
            let ledger = AccessLedger()
            let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                       stopAccess: { _ in ledger.stop() }, checkpoint: { _, _ in
                XCTAssertFalse(Thread.isMainThread)
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let destination = try writer.approveDestination(target)
            let snapshot = try snapshot()
            let artifact = try await writer.prepare(snapshot)
            let outcome = try await writer.deliver(artifact, to: destination)
            XCTAssertEqual(outcome, .committed)
            XCTAssertEqual(try Data(contentsOf: target), try snapshot.encoded())
            XCTAssertEqual(try LocalDataExport.decode(Data(contentsOf: target)), snapshot)
            XCTAssertEqual(ledger.counts, [2, 2])
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try assertDeliveryClean(root)
            XCTAssertThrowsError(try artifact.consume { _ in XCTFail("Delivered artifact reused") }) {
                XCTAssertEqual($0 as? ExportFileWriterError, .artifactUnavailable)
            }
        }
    }

    func testOrdinaryNonscopedDestinationDoesNotStopUnacquiredAuthorization() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return false },
                                                   stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let destination = try writer.approveDestination(root.appendingPathComponent("destination.json"))
        let artifact = try await writer.prepare(snapshot())
        let outcome = try await writer.deliver(artifact, to: destination)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(ledger.counts, [2, 0])
        try assertDeliveryClean(root)
    }

    func testApprovalRejectsDirectoriesSymlinksAndDanglingSymlinksWithoutChangingBytes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("untouched".utf8)
        let target = root.appendingPathComponent("destination.json")
        try original.write(to: target)
        let link = root.appendingPathComponent("link")
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                   stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        for unsafe in [root, link, dangling, URL(string: "https://example.com/export.json")!] {
            XCTAssertThrowsError(try writer.approveDestination(unsafe)) {
                XCTAssertEqual($0 as? ExportFileWriterError, .unsafeDestination)
            }
        }
        XCTAssertEqual(ledger.counts, [3, 3])
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
    }

    func testChangedReplacementInodeAndInPlaceEditAreRejectedAndPreserveCurrentBytes() async throws {
        for replaceInode in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            try Data("original".utf8).write(to: target)
            let writer = ExportFileWriter(temporaryRoot: root)
            let approved = try writer.approveDestination(target)
            let current = Data("externally changed bytes".utf8)
            try current.write(to: target, options: replaceInode ? .atomic : [])
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Changed identity replaced") }
            catch { XCTAssertEqual(error as? ExportFileWriterError, .destinationChanged) }
            XCTAssertEqual(try Data(contentsOf: target), current)
            try assertDeliveryClean(root)
        }
    }

    func testIdentityIsRecheckedImmediatelyBeforeCommitAndCleansSibling() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        try Data("original".utf8).write(to: target)
        let current = Data("external replacement during staging".utf8)
        let hooks = ExportFileWriter.DeliveryHooks(checkpoint: { stage, _ in
            if stage == .beforeCommit { try current.write(to: target, options: .atomic) }
        })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Changed target replaced") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .destinationChanged) }
        XCTAssertEqual(try Data(contentsOf: target), current)
        try assertDeliveryClean(root)
    }

    func testAppearedAndRemovedDestinationsAndNewUnsafeTargetsFailSafely() async throws {
        for change in 0..<4 {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let existing = Data("current bytes".utf8)
            if change == 1 { try existing.write(to: target) }
            let writer = ExportFileWriter(temporaryRoot: root)
            let approved = try writer.approveDestination(target)
            switch change {
            case 0: try existing.write(to: target)
            case 1: try FileManager.default.removeItem(at: target)
            case 2: try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
            }
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Changed target accepted") }
            catch {
                XCTAssertEqual(error as? ExportFileWriterError, change < 2 ? .destinationChanged : .unsafeDestination)
            }
            if change == 0 { XCTAssertEqual(try Data(contentsOf: target), existing) }
            if change == 2 { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), []) }
            if change == 3 { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), root.appendingPathComponent("missing").path) }
            try assertDeliveryClean(root, destinationExists: change != 1)
        }
    }

    func testDeniedAuthorizationCleansArtifactWithoutStoppingUnacquiredScope() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let original = Data("preserve denied destination".utf8)
        try original.write(to: target)
        let approved = try ExportFileWriter().approveDestination(target)
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in
            ledger.start()
            throw NSError(domain: "private access denied", code: Int(EACCES))
        }, stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Denied access saved") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        XCTAssertEqual(ledger.counts, [1, 0])
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertDeliveryClean(root)
    }

    func testEveryPrecommitFailurePreservesDestinationAndBalancesAuthorization() async throws {
        for failingStage in ExportFileWriter.DeliveryStage.allCases where failingStage != .committed {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("preserve failure destination".utf8)
            try original.write(to: target)
            let ledger = AccessLedger()
            let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                       stopAccess: { _ in ledger.stop() }, checkpoint: { stage, _ in
                if stage == failingStage { throw NSError(domain: "private disk failure", code: Int(ENOSPC)) }
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let approved = try writer.approveDestination(target)
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Failed delivery saved") }
            catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
            XCTAssertEqual(ledger.counts, [2, 2])
            XCTAssertEqual(try Data(contentsOf: target), original)
            try assertDeliveryClean(root)
        }
    }

    func testDiskAndAtomicReplacementFailuresPreserveOriginalAndCleanAllStaging() async throws {
        for code in [ENOSPC, EACCES, EIO] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("original replacement bytes".utf8)
            try original.write(to: target)
            let hooks = ExportFileWriter.DeliveryHooks(commit: { _, _, replacing in
                XCTAssertTrue(replacing)
                throw NSError(domain: "sensitive filesystem path", code: Int(code))
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let approved = try writer.approveDestination(target)
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Commit failure saved") }
            catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
            XCTAssertEqual(try Data(contentsOf: target), original)
            try assertDeliveryClean(root)
        }
    }

    func testPartialStagingWriteAndDiskFullFailureNeverChangeDestination() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let original = Data("original disk-full destination".utf8)
        try original.write(to: target)
        let hooks = ExportFileWriter.DeliveryHooks(writeStaging: { bytes, descriptor in
            // Model ENOSPC after a real partial write, not just before staging.
            let partial = bytes.prefix(32)
            try partial.withUnsafeBytes {
                guard Darwin.write(descriptor, $0.baseAddress!, $0.count) == $0.count else {
                    throw ExportFileWriterError.deliveryFailed
                }
            }
            throw NSError(domain: "private disk-full path", code: Int(ENOSPC))
        })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Partial write saved") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertDeliveryClean(root)
    }

    func testSiblingIsPrivateAndOnDestinationVolumeAndPrivateArtifactIsRemovedBeforeCommit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateRoot = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("destination.json")
        let snapshot = try snapshot()
        let bytes = try snapshot.encoded()
        let hooks = ExportFileWriter.DeliveryHooks(checkpoint: { stage, url in
            if stage == .staged {
                XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: privateRoot.path).count, 1)
            }
            if stage == .beforeCommit || stage == .committed {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: privateRoot.path), [])
            }
            if stage == .committed {
                throw NSError(domain: "late noncancellation failure cannot negate saved", code: 1)
            }
        })
        let writer = ExportFileWriter(temporaryRoot: privateRoot, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot)
        let outcome = try await writer.deliver(artifact, to: approved)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["destination.json", "private"])
        try assertEmpty(privateRoot)
    }

    func testRealMissingParentAndExclusiveCreationRaceDoNotOverwriteUnrelatedBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingTarget = root.appendingPathComponent("absent/destination.json")
        let writer = ExportFileWriter(temporaryRoot: root)
        let approved = try writer.approveDestination(missingTarget)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Missing parent saved") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        try assertEmpty(root)
        let target = root.appendingPathComponent("destination.json")
        let current = Data("created just before rename".utf8)
        let hooks = ExportFileWriter.DeliveryHooks(commit: { sibling, destination, replacing in
            XCTAssertFalse(replacing)
            try current.write(to: destination)
            guard renamex_np(sibling.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ExportFileWriterError.deliveryFailed
            }
        })
        let raceWriter = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let newApproved = try raceWriter.approveDestination(target)
        let raceArtifact = try await raceWriter.prepare(snapshot())
        do { _ = try await raceWriter.deliver(raceArtifact, to: newApproved); XCTFail("Exclusive creation overwrote target") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        XCTAssertEqual(try Data(contentsOf: target), current)
        try assertDeliveryClean(root)
    }

    func testCancellationBeforeDeliveryCleansArtifactWithoutAcquiringAuthorization() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let original = Data("preserve canceled destination".utf8)
        try original.write(to: target)
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                   stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await writer.deliver(artifact, to: approved)
        }
        do { _ = try await task.value; XCTFail("Canceled delivery saved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ledger.counts, [1, 1])
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertDeliveryClean(root)
    }

    @MainActor
    func testCancellationAtEveryDeliveryStagePreservesPrecommitBytesButReportsPostcommitSaved() async throws {
        for cancellationStage in ExportFileWriter.DeliveryStage.allCases {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("original before cancellation".utf8)
            try original.write(to: target)
            let ledger = AccessLedger()
            let reached = expectation(description: "Delivery reached \(cancellationStage)")
            let release = DispatchSemaphore(value: 0)
            let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                       stopAccess: { _ in ledger.stop() }, checkpoint: { stage, _ in
                XCTAssertFalse(Thread.isMainThread)
                if stage == cancellationStage {
                    reached.fulfill()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw ExportFileWriterError.deliveryFailed
                    }
                    if stage == .committed { throw CancellationError() }
                }
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let approved = try writer.approveDestination(target)
            let snapshot = try snapshot()
            let artifact = try await writer.prepare(snapshot)
            let task = Task { try await writer.deliver(artifact, to: approved) }
            await fulfillment(of: [reached], timeout: 5)
            task.cancel()
            // A blocked noncooperative worker still owns the operation/scope.
            XCTAssertEqual(ledger.counts, [2, 1])
            release.signal()
            if cancellationStage == .committed {
                let outcome = try await task.value
                XCTAssertEqual(outcome, .committed)
                XCTAssertEqual(try Data(contentsOf: target), try snapshot.encoded())
            } else {
                do { _ = try await task.value; XCTFail("Precommit cancellation saved") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertEqual(try Data(contentsOf: target), original)
            }
            XCTAssertEqual(ledger.counts, [2, 2])
            try assertDeliveryClean(root)
        }
    }

    func testExplicitDiscardAbandonmentAndThrowingConsumptionCleanArtifacts() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ExportFileWriter(temporaryRoot: root)
        let discarded = try await writer.prepare(snapshot())
        try discarded.discard()
        try discarded.discard()
        try assertEmpty(root)
        var abandoned: PreparedExportArtifact? = try await writer.prepare(snapshot())
        weak let weakArtifact = abandoned
        XCTAssertNotNil(abandoned)
        abandoned = nil
        XCTAssertNil(weakArtifact)
        try assertEmpty(root)
        let consumed = try await writer.prepare(snapshot())
        XCTAssertThrowsError(try consumed.consume { _ -> Void in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
        try assertEmpty(root)
        XCTAssertThrowsError(try consumed.consume { _ in XCTFail("Consumed twice") }) {
            XCTAssertEqual($0 as? ExportFileWriterError, .artifactUnavailable)
        }
    }
}
