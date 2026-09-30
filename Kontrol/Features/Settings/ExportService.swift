import Foundation

/// One transient lifecycle owner. Destination grants and raw errors never become
/// observable state; only detached snapshots cross the writer boundary.
@MainActor
final class ExportService: ObservableObject {
    enum Failure: Equatable {
        case selection, answerSave, capture, preparation, delivery, cleanup
    }

    enum State: Equatable {
        case idle, selecting, preparing, saved, canceled
        case failed(Failure)
    }

    @Published private(set) var state: State = .idle
    var isBusy: Bool { active != nil }

    private struct Operation {
        let id: UUID
        var task: Task<Void, Never>?
        var canceled = false
    }

    private let repository: any ExportRepository
    private let panel: any ExportDestinationSelecting
    private let writer: any ExportFilePreparing & ExportFileDelivering
    private let clock: () -> Date
    private let appVersion: () -> String
    private let flushAnswers: () throws -> Void
    private var active: Operation?

    init(repository: any ExportRepository, panel: any ExportDestinationSelecting,
         writer: any ExportFilePreparing & ExportFileDelivering,
         clock: @escaping () -> Date = Date.init,
         appVersion: @escaping () -> String,
         flushAnswers: @escaping () throws -> Void) {
        self.repository = repository
        self.panel = panel
        self.writer = writer
        self.clock = clock
        self.appVersion = appVersion
        // The graph supplies its existing LessonDraftStore.flushAll, not another
        // draft owner. The synchronous barrier must finish before snapshot reads.
        self.flushAnswers = flushAnswers
    }

    /// Duplicate requests are rejected, including while canceled work is still
    /// finishing. Terminal outcomes require a new, explicit request to retry.
    @discardableResult
    func startExport() -> Bool {
        guard active == nil else { return false }
        let id = UUID()
        active = Operation(id: id)
        state = .selecting
        let task = Task { await run(id: id) }
        active?.task = task
        // Also honor a cancellation made by a synchronous state subscriber.
        if active?.canceled == true { task.cancel() }
        return true
    }

    func cancel() {
        guard active != nil else { return }
        active?.canceled = true
        active?.task?.cancel()
        // Do not release ownership or publish a terminal result here: the native
        // callback/worker may be noncooperative, or already have committed.
    }

    /// Await the currently owned operation, without starting work or transferring
    /// its cancellation ownership to the waiter (e.g. a closing Settings client).
    func waitForCompletion() async {
        await active?.task?.value
    }

    private func publish(_ value: State, id: UUID) {
        guard active?.id == id else { return }
        state = value
    }

    private func checkCancellation(id: UUID) throws {
        guard active?.id == id, active?.canceled == false else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func discard(_ artifact: PreparedExportArtifact) async throws {
        // Cleanup remains owned and awaited even when the operation is canceled.
        try await Task.detached(priority: .utility) { try artifact.discard() }.value
    }

    private func run(id: UUID) async {
        defer { if active?.id == id { active = nil } }
        var stage: Failure = .selection
        var artifact: PreparedExportArtifact?
        do {
            try checkCancellation(id: id)
            let selection = try await panel.selectDestination(suggestedAt: clock())
            try checkCancellation(id: id)
            guard case .approved(let destination) = selection else {
                publish(.canceled, id: id)
                return
            }
            publish(.preparing, id: id)
            try checkCancellation(id: id)
            stage = .answerSave
            try flushAnswers()
            try checkCancellation(id: id)
            stage = .capture
            // No suspension between the synchronous flush and persisted capture.
            let snapshot = try repository.snapshot(exportedAt: clock(), appVersion: appVersion())
            try checkCancellation(id: id)
            stage = .preparation
            let prepared = try await writer.prepare(snapshot)
            artifact = prepared
            try checkCancellation(id: id)
            stage = .delivery
            let outcome = try await writer.deliver(prepared, to: destination)
            switch outcome {
            case .committed:
                // Actual commit is final, including cancellation racing the
                // worker's return. Never check cancellation after this receipt.
                // The writer normally already consumed/cleaned the artifact.
                try? await discard(prepared)
                publish(.saved, id: id)
            }
        } catch {
            var result: State = error is CancellationError ? .canceled : .failed(stage)
            if let artifact {
                do { try await discard(artifact) }
                catch { result = .failed(.cleanup) }
            }
            publish(result, id: id)
        }
    }
}
