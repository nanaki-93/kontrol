import Darwin
import Foundation

protocol FeatureFileWriting {
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt
}

/// Coordination does not grant filesystem access. Never use the coordinator's returned URL
/// as an alternative path: descriptor traversal below remains anchored to the scoped root.
protocol FeatureWriteCoordinating {
    func coordinate(_ target: URL, _ body: (URL) throws -> FeatureMutationReceipt) throws -> FeatureMutationReceipt
}

struct SystemFeatureWriteCoordinator: FeatureWriteCoordinating {
    func coordinate(_ target: URL, _ body: (URL) throws -> FeatureMutationReceipt) throws -> FeatureMutationReceipt {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var result: Result<FeatureMutationReceipt, Error>?
        coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &error) { url in
            result = Result { try body(url) }
        }
        if error != nil { throw FeatureMutationFailure.writeFailed }
        guard let result else { throw FeatureMutationFailure.writeFailed }
        return try result.get()
    }
}

/// Narrow syscall seam for deterministic IO/race injection. All names are relative to an
/// already opened features directory; the seam never receives an unscoped absolute path.
protocol FeatureWriteIO {
    func create(_ parent: Int32, _ name: String) -> Int32
    func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int
    func flush(_ fd: Int32) -> Int32
    func replace(_ parent: Int32, _ temporary: String, _ target: String) -> Int32
    func beforeReplacement()
    func beforeVerification()
}

struct SystemFeatureWriteIO: FeatureWriteIO {
    func create(_ parent: Int32, _ name: String) -> Int32 {
        openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Darwin.write(fd, buffer, count)
    }
    func flush(_ fd: Int32) -> Int32 { fsync(fd) }
    func replace(_ parent: Int32, _ temporary: String, _ target: String) -> Int32 {
        renameat(parent, temporary, parent, target)
    }
    func beforeReplacement() {}
    func beforeVerification() {}
}

struct FeatureFileWriter: FeatureFileWriting {
    let access: ProjectFolderAccess
    let coordinator: any FeatureWriteCoordinating
    let io: any FeatureWriteIO
    private let parser = ManifestParser()
    private let patcher = FeatureFrontmatterPatcher()

    init(access: ProjectFolderAccess = ProjectFolderAccess(),
         coordinator: any FeatureWriteCoordinating = SystemFeatureWriteCoordinator(),
         io: any FeatureWriteIO = SystemFeatureWriteIO()) {
        self.access = access
        self.coordinator = coordinator
        self.io = io
    }

    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        do {
            let name = try Self.filename(request.source.relativePath)
            return try await access.withMutationBookmark(request.reference.bookmarkData) { root in
                try Task.checkCancellation()
                let target = root.appendingPathComponent(request.source.relativePath)
                return try coordinator.coordinate(target) { coordinated in
                    guard coordinated.standardizedFileURL == target.standardizedFileURL else {
                        throw FeatureMutationFailure.unsafePath
                    }
                    return try completeAnchored(root, name: name, request: request)
                }
            }
        } catch let failure as FeatureMutationFailure { throw failure }
          catch is ProjectFolderAccessError {
            throw FeatureMutationFailure.accessDenied
        } catch is CancellationError { throw FeatureMutationFailure.canceled }
          catch { throw FeatureMutationFailure.writeFailed }
    }

    // Undo is implemented in Step 2.4; no revision-unsafe fallback is permitted.
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        throw FeatureMutationFailure.unpatchableSource
    }

    private static func filename(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == ".kontrol", parts[1] == "features",
              !parts[2].isEmpty, parts[2] != ".", parts[2] != "..",
              parts[2].hasSuffix(".md"), parts[2].count > 3,
              !parts[2].utf8.contains(0) else { throw FeatureMutationFailure.unsafePath }
        return String(parts[2])
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let modified: timespec
        let changed: timespec
        init(_ s: stat) {
            device = s.st_dev; inode = s.st_ino; size = s.st_size; mode = s.st_mode
            owner = s.st_uid; group = s.st_gid
            modified = s.st_mtimespec; changed = s.st_ctimespec
        }
        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size &&
            a.mode == b.mode && a.owner == b.owner && a.group == b.group &&
            a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
        func sameDirectory(_ other: Self) -> Bool { device == other.device && inode == other.inode }
        func sameFile(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    }

    private func info(_ fd: Int32) throws -> Identity {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw FeatureMutationFailure.changedIdentity }
        return Identity(s)
    }
    private func entry(_ parent: Int32, _ name: String, _ expected: Identity) -> Bool {
        var s = stat()
        return fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 && Identity(s) == expected
    }
    private func directory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FeatureMutationFailure.unsafePath }
        return fd
    }
    private func regular(_ parent: Int32, _ name: String) throws -> (Int32, Identity) {
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ENOENT ? FeatureMutationFailure.missingTarget : .unsafePath
        }
        do {
            let id = try info(fd)
            guard id.mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw FeatureMutationFailure.unsafePath }
            guard id.size >= 0, id.size <= ProjectFileReader.fileLimit else {
                throw FeatureMutationFailure.unpatchableSource
            }
            return (fd, id)
        } catch { close(fd); throw error }
    }
    private func bytes(_ fd: Int32, _ size: off_t) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, min(buffer.count, ProjectFileReader.fileLimit + 1 - output.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw FeatureMutationFailure.writeFailed
            }
            if count == 0 { break }
            output.append(contentsOf: buffer[..<count])
            guard output.count <= ProjectFileReader.fileLimit else { throw FeatureMutationFailure.unpatchableSource }
        }
        guard output.count == Int(size) else { throw FeatureMutationFailure.changedIdentity }
        return output
    }
    private func completeAnchored(_ folder: URL, name: String,
                                  request: FeatureCompletionRequest) throws -> FeatureMutationReceipt {
        try Task.checkCancellation()
        let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw FeatureMutationFailure.unsafePath }
        defer { close(root) }
        let rootID = try info(root)
        let kontrol = try directory(root, ".kontrol")
        defer { close(kontrol) }
        let kontrolID = try info(kontrol)
        let features = try directory(kontrol, "features")
        defer { close(features) }
        let featuresID = try info(features)
        let (manifest, manifestID) = try regular(kontrol, "project.yaml")
        defer { close(manifest) }
        let manifestBytes = try bytes(manifest, manifestID.size)
        guard try info(manifest) == manifestID, entry(kontrol, "project.yaml", manifestID) else {
            throw FeatureMutationFailure.changedIdentity
        }
        let manifestSource = ProjectSourceDocument(relativePath: ".kontrol/project.yaml", bytes: manifestBytes)
        guard case let .supported(project) = try? parser.project(manifestSource),
              project.schemaVersion == 1, project.id == request.reference.manifestID else {
            throw FeatureMutationFailure.manifestMismatch
        }
        let (target, originalID) = try regular(features, name)
        defer { close(target) }
        let originalBytes = try bytes(target, originalID.size)
        guard try info(target) == originalID, entry(features, name, originalID) else {
            throw FeatureMutationFailure.changedIdentity
        }
        let current = ProjectSourceDocument(relativePath: request.source.relativePath, bytes: originalBytes)
        guard current.sha256 == request.source.sha256, current.bytes == request.source.bytes else {
            throw FeatureMutationFailure.conflict
        }
        guard case let .supported(feature) = try? parser.feature(current) else {
            throw FeatureMutationFailure.unpatchableSource
        }
        guard feature.id == request.featureID else { throw FeatureMutationFailure.changedIdentity }
        guard feature.status != .completed else { throw FeatureMutationFailure.unpatchableSource }
        let patched = try patcher.completeWithInverse(current, featureID: request.featureID, at: request.completedAt)
        guard patched.source.bytes.count <= ProjectFileReader.fileLimit else {
            throw FeatureMutationFailure.unpatchableSource
        }
        let temporary = ".kontrol-write-\(UUID().uuidString).tmp"
        let temp = io.create(features, temporary)
        guard temp >= 0 else { throw FeatureMutationFailure.writeFailed }
        let tempID = try? info(temp)
        guard let tempID else { close(temp); throw FeatureMutationFailure.writeFailed }
        var owned = true
        defer {
            // Never unlink a substituted entry under our temporary name.
            if owned && sameFileEntry(features, temporary, tempID) { _ = unlinkat(features, temporary, 0) }
            close(temp)
        }
        // Copy ACLs and extended attributes before changing mode. Failure is safer than
        // silently broadening or dropping access controls on the replacement inode.
        guard fcopyfile(target, temp, nil, UInt32(COPYFILE_ACL | COPYFILE_XATTR)) == 0,
              fchown(temp, originalID.owner, originalID.group) == 0,
              fchmod(temp, originalID.mode & 0o7777) == 0 else {
            throw FeatureMutationFailure.writeFailed
        }
        try patched.source.bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw FeatureMutationFailure.writeFailed }
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let count = io.write(temp, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, count <= raw.count - offset else { throw FeatureMutationFailure.writeFailed }
                offset += count
            }
        }
        guard io.flush(temp) == 0 else { throw FeatureMutationFailure.writeFailed }
        io.beforeReplacement()
        try Task.checkCancellation()
        let currentRoot = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentRoot >= 0 else { throw FeatureMutationFailure.changedIdentity }
        defer { close(currentRoot) }
        guard try info(currentRoot).sameDirectory(rootID),
              try info(root).sameDirectory(rootID),
              try info(kontrol).sameDirectory(kontrolID) else {
            throw FeatureMutationFailure.changedIdentity
        }
        // Directory ctime/mtime change on sibling temp creation; compare dev/inode instead.
        guard try info(features).sameDirectory(featuresID),
              sameDirectoryEntry(kontrol, "features", featuresID),
              sameDirectoryEntry(root, ".kontrol", kontrolID),
              try info(manifest) == manifestID, entry(kontrol, "project.yaml", manifestID),
              try info(target) == originalID, entry(features, name, originalID),
              sameFileEntry(features, temporary, tempID),
              try info(temp).sameFile(tempID) else {
            throw FeatureMutationFailure.changedIdentity
        }
        guard io.replace(features, temporary, name) == 0 else { throw FeatureMutationFailure.writeFailed }
        owned = false
        // From here on cancellation cannot disguise a committed write. Verification reads
        // the actual destination; no fallback to intended bytes or compensating overwrite.
        io.beforeVerification()
        do {
            let verifiedRoot = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard verifiedRoot >= 0 else { throw FeatureMutationFailure.unverifiedWrite }
            defer { close(verifiedRoot) }
            guard try info(verifiedRoot).sameDirectory(rootID),
                  sameDirectoryEntry(root, ".kontrol", kontrolID),
                  sameDirectoryEntry(kontrol, "features", featuresID) else {
                throw FeatureMutationFailure.unverifiedWrite
            }
            let (destination, destID) = try regular(features, name)
            defer { close(destination) }
            let written = try bytesAfterCommit(destination, destID.size)
            guard try info(destination) == destID, entry(features, name, destID),
                  written == patched.source.bytes,
                  case let .supported(verified) = try parser.feature(
                    ProjectSourceDocument(relativePath: current.relativePath, bytes: written)),
                  verified.id == request.featureID, verified.status == .completed else {
                throw FeatureMutationFailure.unverifiedWrite
            }
            let source = ProjectSourceDocument(relativePath: current.relativePath, bytes: written)
            return FeatureMutationReceipt(projectID: request.reference.id, featureID: request.featureID,
                                          verifiedSource: source, inverse: patched.inverse)
        } catch { throw FeatureMutationFailure.unverifiedWrite }
    }
    private func sameFileEntry(_ parent: Int32, _ name: String, _ expected: Identity) -> Bool {
        var s = stat()
        return fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 &&
            (s.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            s.st_dev == expected.device && s.st_ino == expected.inode
    }
    private func sameDirectoryEntry(_ parent: Int32, _ name: String, _ expected: Identity) -> Bool {
        var s = stat()
        return fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 &&
            (s.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
            s.st_dev == expected.device && s.st_ino == expected.inode
    }
    private func bytesAfterCommit(_ fd: Int32, _ size: off_t) throws -> Data {
        guard size >= 0, size <= ProjectFileReader.fileLimit else { throw FeatureMutationFailure.unverifiedWrite }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buffer, min(buffer.count, ProjectFileReader.fileLimit + 1 - output.count))
            if n < 0 {
                if errno == EINTR { continue }
                throw FeatureMutationFailure.unverifiedWrite
            }
            if n == 0 { break }
            output.append(contentsOf: buffer[..<n])
            guard output.count <= ProjectFileReader.fileLimit else { throw FeatureMutationFailure.unverifiedWrite }
        }
        guard output.count == Int(size) else { throw FeatureMutationFailure.unverifiedWrite }
        return output
    }
}
