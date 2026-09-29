import Darwin
import Foundation

/// Raw, detached results only. Call `read` *inside* ProjectFolderAccess's active scope;
/// the URL itself is not an authorization token. No source bytes are ever written back.
struct ProjectFileRead {
    let manifest: ProjectOptionalDocument
    let roadmap: ProjectOptionalDocument
    let context: ProjectOptionalDocument
    let rules: ProjectOptionalDocument
    let history: ProjectOptionalDocument
    let features: [ProjectSourceDocument]
    let featureEnumeration: ProjectFeatureEnumeration
    let diagnostics: [ProjectDiagnostic]

    var sources: [ProjectSourceDocument] {
        [manifest, roadmap, context, rules, history].compactMap {
            if case let .present(source) = $0 { return source }
            return nil
        } + features
    }
}

/// All path components below the scoped root are fixed names or single directory entries.
/// Descriptors, not prechecked URL strings, anchor opening and verification. No symlink is
/// followed (including a substituted intermediate directory). No Foundation Data(contentsOf:).
struct ProjectFileReader {
    static let fileLimit = 1_048_576
    static let inspectionLimit = 16_777_216
    static let featureLimit = 1_000

    // Test seam for deterministic substitution/change races; invoked after bytes were read.
    private let beforeVerification: ((String) -> Void)?
    // Test seam: observe matching directory entries visited by enumeration.
    private let onFeatureEntry: ((String) -> Void)?
    init(beforeVerification: ((String) -> Void)? = nil, onFeatureEntry: ((String) -> Void)? = nil) {
        self.beforeVerification = beforeVerification
        self.onFeatureEntry = onFeatureEntry
    }

    func read(folder: URL) throws -> ProjectFileRead {
        try Task.checkCancellation()
        guard folder.isFileURL else { throw ProjectFolderAccessError.invalidFolder }
        // Coordinate the scoped folder as a unit with file presenters. Coordination does
        // not confer access or prove containment: the descriptor-based reader below still
        // rejects substituted paths, and never follows a relocated coordinator URL.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<ProjectFileRead, Error>?
        coordinator.coordinate(readingItemAt: folder, options: [], error: &coordinationError) { coordinated in
            result = Result {
                guard coordinated.standardizedFileURL == folder.standardizedFileURL else {
                    throw ProjectFolderAccessError.invalidFolder
                }
                return try readAnchored(folder: folder)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectFolderAccessError.invalidFolder }
        return try result.get()
    }

    private func readAnchored(folder: URL) throws -> ProjectFileRead {
        try Task.checkCancellation()
        let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ProjectFolderAccessError.invalidFolder }
        defer { close(root) }
        var diagnostics: [ProjectDiagnostic] = []
        var observations: [Observation] = []
        var total = 0
        var manifest: ProjectOptionalDocument = .absent
        var roadmap: ProjectOptionalDocument = .absent
        var context: ProjectOptionalDocument = .absent
        var rules: ProjectOptionalDocument = .absent
        var history: ProjectOptionalDocument = .absent
        var features: [ProjectSourceDocument] = []
        var enumeration: ProjectFeatureEnumeration = .complete
        var featureDescriptor: Int32?
        var featureIdentity: Identity?
        defer { if let featureDescriptor { close(featureDescriptor) } }

        func failure(_ code: ProjectDiagnosticCode, _ path: String) {
            diagnostics.append(ProjectDiagnostic(code: code, severity: .error, relativePath: path,
                                                 recovery: .refresh))
        }
        func document(_ directory: Int32, _ name: String, _ path: String) throws -> ProjectOptionalDocument {
            try Task.checkCancellation()
            do {
                let (source, identity) = try readFile(directory, name, path, total: &total)
                observations.append(Observation(directory: directory, name: name, path: path, identity: identity))
                return .present(source)
            } catch let error as ReadFailure {
                if error == .missing { return .absent }
                failure(error.code, path)
                if error == .changed && path.hasPrefix(".kontrol/features/") { enumeration = .failed }
                return .failed
            }
        }

        do {
            let kontrol = try openDirectory(root, ".kontrol")
            defer { close(kontrol) }
            let kontrolIdentity = try metadata(kontrol)
            manifest = try document(kontrol, "project.yaml", ".kontrol/project.yaml")
            roadmap = try document(kontrol, "roadmap.yaml", ".kontrol/roadmap.yaml")
            context = try document(kontrol, "context.md", ".kontrol/context.md")
            rules = try document(kontrol, "rules.md", ".kontrol/rules.md")
            history = try document(kontrol, "history.yaml", ".kontrol/history.yaml")

            do {
                let featureFD = try openDirectory(kontrol, "features")
                featureDescriptor = featureFD
                let initial = try metadata(featureFD)
                featureIdentity = initial
                let names = try featureNames(featureFD)
                for name in names {
                    let path = ".kontrol/features/" + name
                    let item = try document(featureFD, name, path)
                    switch item {
                    case let .present(source): features.append(source)
                    case .absent:
                        // An entry disappearing after enumeration is a changed inspection,
                        // not an optional missing file or a successful empty enumeration.
                        failure(.changedDuringRead, path)
                        enumeration = .failed
                    case .failed: break
                    }
                }
                if try metadata(featureFD) != initial {
                    failure(.changedDuringRead, ".kontrol/features")
                    enumeration = .failed
                }
                // Verify while the directory descriptor is still open; substitution of its
                // name in .kontrol cannot turn the old directory into a trusted snapshot.
                if try !sameEntry(kontrol, "features", initial) {
                    failure(.changedDuringRead, ".kontrol/features")
                    enumeration = .failed
                }
            } catch let error as ReadFailure {
                if error != .missing {
                    failure(error.code, ".kontrol/features")
                    enumeration = .failed
                }
            }
            // Revalidate all opened paths against their anchored parents, including the
            // .kontrol directory itself; changed content never survives as a successful read.
            for observation in observations {
                try Task.checkCancellation()
                beforeVerification?(observation.path)
                if try !sameEntry(observation.directory, observation.name, observation.identity) {
                    failure(.changedDuringRead, observation.path)
                    if observation.path.hasPrefix(".kontrol/features/") { enumeration = .failed }
                }
            }
            if let featureDescriptor, let featureIdentity,
               try metadata(featureDescriptor) != featureIdentity || !sameEntry(kontrol, "features", featureIdentity) {
                failure(.changedDuringRead, ".kontrol/features")
                enumeration = .failed
            }
            if try metadata(kontrol) != kontrolIdentity || !sameEntry(root, ".kontrol", kontrolIdentity) {
                failure(.changedDuringRead, ".kontrol")
                enumeration = .failed
            }
        } catch let error as ReadFailure {
            if error == .missing {
                failure(.missingManifest, ".kontrol/project.yaml")
            } else {
                failure(error.code, ".kontrol")
            }
            manifest = .failed
            roadmap = .failed
            context = .failed
            rules = .failed
            history = .failed
            enumeration = .failed
        }
        if case .absent = manifest { failure(.missingManifest, ".kontrol/project.yaml") }
        // A changed source must not be exposed as a verified document, even if bytes were
        // captured earlier. Inspector will also treat changedDuringRead as retryable failure.
        let changed = Set(diagnostics.filter { $0.code == .changedDuringRead }.map(\.relativePath))
        func verified(_ doc: ProjectOptionalDocument, _ path: String) -> ProjectOptionalDocument {
            changed.contains(path) || changed.contains(".kontrol") ? .failed : doc
        }
        features.removeAll { changed.contains($0.relativePath) || changed.contains(".kontrol") || changed.contains(".kontrol/features") }
        if diagnostics.contains(where: { $0.relativePath == ".kontrol" && $0.code == .changedDuringRead }) {
            enumeration = .failed
        }
        return ProjectFileRead(manifest: verified(manifest, ".kontrol/project.yaml"),
                               roadmap: verified(roadmap, ".kontrol/roadmap.yaml"),
                               context: verified(context, ".kontrol/context.md"),
                               rules: verified(rules, ".kontrol/rules.md"),
                               history: verified(history, ".kontrol/history.yaml"),
                               features: features, featureEnumeration: enumeration,
                               diagnostics: diagnostics.sorted { $0.relativePath == $1.relativePath
                                   ? $0.code.rawValue < $1.code.rawValue : $0.relativePath < $1.relativePath })
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec
        let changed: timespec
        init(_ stat: stat) {
            device = stat.st_dev; inode = stat.st_ino; size = stat.st_size
            modified = stat.st_mtimespec; changed = stat.st_ctimespec
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size &&
            lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
            lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }
    private struct Observation {
        let directory: Int32
        let name: String
        let path: String
        let identity: Identity
    }
    private enum ReadFailure: Error, Equatable {
        case missing, unsafe, unreadable, size, encoding, changed, enumeration
        var code: ProjectDiagnosticCode {
            switch self {
            case .missing, .unreadable: return .unreadableFile
            case .unsafe: return .unsafeEntry
            case .size: return .sizeLimit
            case .encoding: return .invalidUTF8
            case .changed: return .changedDuringRead
            case .enumeration: return .enumerationFailed
            }
        }
    }
    private func classified(_ error: Int32) -> ReadFailure {
        if error == ENOENT { return .missing }
        if error == ELOOP || error == ENOTDIR { return .unsafe }
        return .unreadable
    }
    private func openDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw classified(errno) }
        return fd
    }
    private func metadata(_ fd: Int32) throws -> Identity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReadFailure.unreadable }
        return Identity(info)
    }
    private func sameEntry(_ parent: Int32, _ name: String, _ expected: Identity) throws -> Bool {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return Identity(info) == expected
    }
    private func featureNames(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw ReadFailure.enumeration }
        guard let dir = fdopendir(copy) else { close(copy); throw ReadFailure.enumeration }
        defer { closedir(dir) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw ReadFailure.enumeration }
            if name != "." && name != ".." && name.hasSuffix(".md") {
                onFeatureEntry?(name)
                // Stop at the first excess match: never materialize or sort an unbounded list.
                guard names.count < Self.featureLimit else { throw ReadFailure.size }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw ReadFailure.enumeration }
        return names.sorted()
    }
    private func readFile(_ parent: Int32, _ name: String, _ path: String,
                          total: inout Int) throws -> (ProjectSourceDocument, Identity) {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw classified(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReadFailure.unreadable }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw ReadFailure.unsafe }
        let identity = Identity(info)
        guard info.st_size >= 0, info.st_size <= Self.fileLimit,
              total <= Self.inspectionLimit - Int(info.st_size) else { throw ReadFailure.size }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, min(buffer.count, Self.fileLimit + 1 - bytes.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadFailure.unreadable
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer[..<count])
            if bytes.count > Self.fileLimit || total > Self.inspectionLimit - bytes.count { throw ReadFailure.size }
        }
        guard try metadata(fd) == identity, bytes.count == Int(info.st_size),
              try sameEntry(parent, name, identity) else { throw ReadFailure.changed }
        total += bytes.count
        guard String(data: bytes, encoding: .utf8) != nil else { throw ReadFailure.encoding }
        return (ProjectSourceDocument(relativePath: path, bytes: bytes), identity)
    }
}
