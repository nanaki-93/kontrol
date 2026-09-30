import Darwin
import Foundation

/// Category-only failures: never carry underlying errors, content, or paths.
enum ExportFileWriterError: Error, Equatable {
    case invalidPreparation
    case preparationFailed
    case cleanupFailed
    case artifactUnavailable
    case unsafeDestination
    case destinationChanged
    case deliveryFailed
}

/// Transient replacement intent, captured only after native destination approval.
/// Identity is not a persisted grant and is checked again under coordination.
struct ApprovedExportDestination: Sendable {
    fileprivate let url: URL
    fileprivate let identity: ExportDestinationIdentity?
}

private struct ExportDestinationIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
}

enum ExportDeliveryOutcome: Equatable, Sendable { case committed }

protocol ExportFileDelivering: Sendable {
    func approveDestination(_ url: URL) throws -> ApprovedExportDestination
    func deliver(_ artifact: PreparedExportArtifact,
                 to destination: ApprovedExportDestination) async throws -> ExportDeliveryOutcome
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

struct ExportFileWriter: ExportFilePreparing, ExportFileDelivering {
    /// Internal deterministic test seams; production uses the real encoder/IO.
    enum PreparationStage: CaseIterable, Sendable {
        case directoryCreated, encoded, fileWritten, validated
    }
    struct PreparationHooks: Sendable {
        var encode: @Sendable (LocalDataExport) throws -> Data = { try $0.encoded() }
        var checkpoint: @Sendable (PreparationStage, URL) throws -> Void = { _, _ in }
    }

    enum DeliveryStage: CaseIterable, Sendable {
        case authorized, coordinated, staged, beforeCommit, committed
    }
    struct DeliveryHooks: Sendable {
        // False is normal for nonscoped URLs (including temporary test files).
        // Actual access is determined by coordination and filesystem operations.
        var startAccess: @Sendable (URL) throws -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stopAccess: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var checkpoint: @Sendable (DeliveryStage, URL) throws -> Void = { _, _ in }
        var writeStaging: @Sendable (Data, Int32) throws -> Void = {
            try ExportFileWriter.write($0, descriptor: $1, failure: .deliveryFailed)
        }
        var commit: @Sendable (URL, URL, Bool) throws -> Void = { source, target, replacing in
            let result = replacing
                ? rename(source.path, target.path)
                : renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
            guard result == 0 else { throw ExportFileWriterError.deliveryFailed }
        }
    }

    private let temporaryRoot: URL
    private let hooks: PreparationHooks
    private let deliveryHooks: DeliveryHooks

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory,
         hooks: PreparationHooks = .init(), deliveryHooks: DeliveryHooks = .init()) {
        self.temporaryRoot = temporaryRoot
        self.hooks = hooks
        self.deliveryHooks = deliveryHooks
    }

    func approveDestination(_ url: URL) throws -> ApprovedExportDestination {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else {
            throw ExportFileWriterError.unsafeDestination
        }
        do {
            let scoped = try deliveryHooks.startAccess(url)
            defer { if scoped { deliveryHooks.stopAccess(url) } }
            return ApprovedExportDestination(url: url, identity: try Self.identity(at: url))
        } catch let safe as ExportFileWriterError { throw safe }
        catch { throw ExportFileWriterError.deliveryFailed }
    }

    func deliver(_ artifact: PreparedExportArtifact,
                 to destination: ApprovedExportDestination) async throws -> ExportDeliveryOutcome {
        // Always enter the worker, even if already canceled: it owns cleanup.
        let worker = Task.detached(priority: .utility) {
            try deliverAtomically(artifact, to: destination)
        }
        return try await withTaskCancellationHandler {
            // No cancellation check after this await: successful rename is final.
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private func deliverAtomically(_ artifact: PreparedExportArtifact,
                                  to destination: ApprovedExportDestination) throws -> ExportDeliveryOutcome {
        do {
            try Task.checkCancellation()
            let scoped = try deliveryHooks.startAccess(destination.url)
            defer { if scoped { deliveryHooks.stopAccess(destination.url) } }
            try deliveryCheckpoint(.authorized, destination.url)
            var coordinationError: NSError?
            var result: Result<ExportDeliveryOutcome, Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination.url, options: .forReplacing,
                                           error: &coordinationError) { coordinatedURL in
                result = Result {
                    guard coordinatedURL.standardizedFileURL == destination.url.standardizedFileURL else {
                        throw ExportFileWriterError.destinationChanged
                    }
                    return try commitCoordinated(artifact, to: destination)
                }
            }
            // If commit succeeded, even a later coordinator/cancellation error
            // cannot turn the actual saved result into a reported failure.
            if case .success(.committed) = result { return .committed }
            if let result { return try result.get() }
            throw ExportFileWriterError.deliveryFailed
        } catch {
            try artifact.discard()
            if error is CancellationError { throw CancellationError() }
            if let safe = error as? ExportFileWriterError { throw safe }
            throw ExportFileWriterError.deliveryFailed
        }
    }

    private func commitCoordinated(_ artifact: PreparedExportArtifact,
                                   to destination: ApprovedExportDestination) throws -> ExportDeliveryOutcome {
        var staging: URL?
        do {
            try deliveryCheckpoint(.coordinated, destination.url)
            guard try Self.identity(at: destination.url) == destination.identity else {
                throw ExportFileWriterError.destinationChanged
            }
            // Stage on the destination volume; private preparation may be on a
            // different filesystem. Consume cleans private storage BEFORE commit,
            // so cleanup failure cannot mask a successful atomic replacement.
            try artifact.consume { privateFile in
                var template = Array(destination.url.deletingLastPathComponent()
                    .appendingPathComponent(".kontrol-export-XXXXXX").path.utf8CString)
                let descriptor = mkstemp(&template)
                guard descriptor >= 0 else { throw ExportFileWriterError.deliveryFailed }
                let sibling = URL(fileURLWithPath: String(cString: template))
                staging = sibling
                var closed = false
                defer { if !closed { close(descriptor) } }
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                      fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw ExportFileWriterError.deliveryFailed
                }
                let bytes = try Data(contentsOf: privateFile)
                _ = try LocalDataExport.decode(bytes)
                try deliveryHooks.writeStaging(bytes, descriptor)
                guard fsync(descriptor) == 0 else { throw ExportFileWriterError.deliveryFailed }
                let closeResult = close(descriptor)
                closed = true
                guard closeResult == 0, try Data(contentsOf: sibling) == bytes else {
                    throw ExportFileWriterError.deliveryFailed
                }
                try deliveryCheckpoint(.staged, sibling)
            }
            try deliveryCheckpoint(.beforeCommit, destination.url)
            guard try Self.identity(at: destination.url) == destination.identity else {
                throw ExportFileWriterError.destinationChanged
            }
            try Task.checkCancellation() // last check immediately before atomic IO
            // Coordination protects cooperating clients; identity checks cannot
            // exclude every race with an uncoordinated external editor.
            try deliveryHooks.commit(staging!, destination.url, destination.identity != nil)
            staging = nil // rename consumed the owned sibling
            // Test/observation only; never allow late errors to negate commit.
            try? deliveryHooks.checkpoint(.committed, destination.url)
            return .committed
        } catch {
            if let staging {
                do { try FileManager.default.removeItem(at: staging) }
                catch { throw ExportFileWriterError.cleanupFailed }
            }
            throw error
        }
    }

    private func deliveryCheckpoint(_ stage: DeliveryStage, _ url: URL) throws {
        try Task.checkCancellation()
        try deliveryHooks.checkpoint(stage, url)
        try Task.checkCancellation()
    }

    private static func identity(at url: URL) throws -> ExportDestinationIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ExportFileWriterError.deliveryFailed
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ExportFileWriterError.unsafeDestination
        }
        return ExportDestinationIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                                         modifiedSeconds: info.st_mtimespec.tv_sec,
                                         modifiedNanos: info.st_mtimespec.tv_nsec,
                                         changedSeconds: info.st_ctimespec.tv_sec,
                                         changedNanos: info.st_ctimespec.tv_nsec)
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
        try Self.write(bytes, descriptor: descriptor, failure: .preparationFailed)
        let result = close(descriptor)
        closed = true
        guard result == 0 else { throw ExportFileWriterError.preparationFailed }
    }

    private static func write(_ bytes: Data, descriptor: Int32, failure: ExportFileWriterError) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset),
                                         min(65_536, buffer.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure }
                offset += count
            }
        }
    }
}
