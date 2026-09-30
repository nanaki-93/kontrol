import Darwin
import Foundation

/// Category-only failures: never carry underlying errors, content, or paths.
enum ExportFileWriterError: Error, Equatable {
    case invalidPreparation
    case preparationFailed
    case cleanupFailed
    case artifactUnavailable
}

protocol ExportFilePreparing: Sendable {
    func prepare(_ snapshot: LocalDataExport) async throws -> PreparedExportArtifact
}

/// Single-use ownership of a validated private file. Only the writer can create
/// one. A consumer borrows the URL synchronously; it must not retain it. Cleanup
/// is serialized with consumption/discard, including when aliases cross tasks.
final class PreparedExportArtifact: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?

    fileprivate init(directory: URL) { self.directory = directory }

    func consume<T>(_ body: (URL) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let directory else { throw ExportFileWriterError.artifactUnavailable }
        let result: Result<T, Error>
        do { result = .success(try body(directory.appendingPathComponent("export.json"))) }
        catch { result = .failure(error) }
        try cleanupLocked()
        return try result.get()
    }

    /// Idempotent; a failed removal retains ownership so cleanup can be retried.
    func discard() throws {
        lock.lock()
        defer { lock.unlock() }
        try cleanupLocked()
    }

    private func cleanupLocked() throws {
        guard let directory else { return }
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw ExportFileWriterError.cleanupFailed }
        self.directory = nil
    }

    deinit {
        // Fallback for abandoned results. Normal paths use explicit, throwable
        // cleanup; deinitialization cannot report filesystem failures.
        try? cleanupLocked()
    }
}

struct ExportFileWriter: ExportFilePreparing {
    /// Internal deterministic test seams; production uses the real encoder/IO.
    enum PreparationStage: CaseIterable, Sendable {
        case directoryCreated, encoded, fileWritten, validated
    }
    struct PreparationHooks: Sendable {
        var encode: @Sendable (LocalDataExport) throws -> Data = { try $0.encoded() }
        var checkpoint: @Sendable (PreparationStage, URL) throws -> Void = { _, _ in }
    }

    private let temporaryRoot: URL
    private let hooks: PreparationHooks

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory,
         hooks: PreparationHooks = .init()) {
        self.temporaryRoot = temporaryRoot
        self.hooks = hooks
    }

    func prepare(_ snapshot: LocalDataExport) async throws -> PreparedExportArtifact {
        try Task.checkCancellation()
        // Detached explicitly: a main-actor caller never encodes or performs IO.
        // Await the worker even on cancellation; its artifact remains owned until
        // it actually finishes, including a noncooperative encoder/test seam.
        let worker = Task.detached(priority: .utility) {
            try preparePrivately(snapshot)
        }
        return try await withTaskCancellationHandler {
            let artifact = try await worker.value
            do { try Task.checkCancellation() }
            catch {
                try artifact.discard()
                throw CancellationError()
            }
            return artifact
        } onCancel: {
            worker.cancel()
        }
    }

    private func preparePrivately(_ snapshot: LocalDataExport) throws -> PreparedExportArtifact {
        try Task.checkCancellation()
        // mkdtemp creates exclusively with 0700, never a shared predictable file.
        var template = Array(temporaryRoot.appendingPathComponent("kontrol-export-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw ExportFileWriterError.preparationFailed }
        let directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let artifact = PreparedExportArtifact(directory: directory)
        let file = directory.appendingPathComponent("export.json")
        do {
            try checkpoint(.directoryCreated, directory)
            let bytes: Data
            do {
                try snapshot.validate()
                bytes = try hooks.encode(snapshot)
            } catch is CancellationError { throw CancellationError() }
            catch { throw ExportFileWriterError.invalidPreparation }
            try checkpoint(.encoded, directory)
            try writePrivate(bytes, to: file)
            try checkpoint(.fileWritten, directory)
            do {
                // Validate the bytes read back from storage, not only the input.
                let stored = try Data(contentsOf: file)
                let decoded = try LocalDataExport.decode(stored)
                guard stored == bytes, try decoded.encoded() == snapshot.encoded() else {
                    throw ExportFileWriterError.invalidPreparation
                }
            } catch { throw ExportFileWriterError.invalidPreparation }
            try checkpoint(.validated, directory)
            return artifact
        } catch {
            try artifact.discard()
            if error is CancellationError { throw CancellationError() }
            if let safe = error as? ExportFileWriterError { throw safe }
            throw ExportFileWriterError.preparationFailed
        }
    }

    private func checkpoint(_ stage: PreparationStage, _ directory: URL) throws {
        try Task.checkCancellation()
        try hooks.checkpoint(stage, directory)
        try Task.checkCancellation()
    }

    private func writePrivate(_ bytes: Data, to file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ExportFileWriterError.preparationFailed }
        var closed = false
        defer { if !closed { close(descriptor) } }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset),
                                         min(65_536, buffer.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ExportFileWriterError.preparationFailed }
                offset += count
            }
        }
        let result = close(descriptor)
        closed = true
        guard result == 0 else { throw ExportFileWriterError.preparationFailed }
    }
}
