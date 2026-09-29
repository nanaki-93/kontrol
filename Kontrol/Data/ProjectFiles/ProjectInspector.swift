import Foundation

/// IO can be replaced without a picker, sandbox entitlement, or a persistent store.
/// The reader is only invoked while the selected/resolved folder's scope is active.
protocol ProjectFileReading {
    func read(folder: URL) throws -> ProjectFileRead
}

extension ProjectFileReader: ProjectFileReading {}

protocol ProjectInspecting {
    func inspect(selectedFolder: URL) async throws -> ProjectInspection
    func inspect(bookmarkData: Data) async throws -> ProjectInspection
    func makeBookmark(selectedFolder: URL) async throws -> Data
}

/// A retryable inconsistent snapshot is not a partially successful enumeration.
/// Access failures are classified without carrying an OS error, URL, or bookmark blob
/// across the IO boundary. Validation failures instead live in ProjectInspection.
enum ProjectInspectionFailure: Error, Equatable {
    case inconsistentRead
    case access(ProjectDiagnosticCode)
    case selectedAccess(ProjectDiagnosticCode)
    case unreadableFolder

    var recovery: ProjectRecovery {
        switch self {
        case .inconsistentRead, .unreadableFolder: return .refresh
        case .access: return .reconnect
        case .selectedAccess: return .reselectFolder
        }
    }
}

struct ProjectInspector: ProjectInspecting {
    private let access: ProjectFolderAccess
    private let reader: any ProjectFileReading
    private let parser: ManifestParser
    private let validator: ProjectValidator
    private let now: () -> Date

    init(access: ProjectFolderAccess = ProjectFolderAccess(),
         reader: any ProjectFileReading = ProjectFileReader(),
         parser: ManifestParser = ManifestParser(), validator: ProjectValidator = ProjectValidator(),
         now: @escaping () -> Date = Date.init) {
        self.access = access
        self.reader = reader
        self.parser = parser
        self.validator = validator
        self.now = now
    }

    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        try await perform(selected: true) { try await access.withSelectedFolder(selectedFolder, perform: $0) }
    }

    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        try await perform { try await access.withBookmark(bookmarkData, perform: $0) }
    }

    func makeBookmark(selectedFolder: URL) async throws -> Data {
        try Task.checkCancellation()
        let task = Task.detached { try await access.makeBookmark(selectedFolder: selectedFolder) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func perform(selected: Bool = false, _ scoped: @escaping ((URL) async throws -> ProjectInspection) async throws -> ProjectInspection) async throws -> ProjectInspection {
        // NSFileCoordinator and descriptor reads are synchronous. Never run them on the
        // caller's (often main-actor) executor, including when scope resolution is fast.
        try Task.checkCancellation()
        let task = Task.detached {
            do {
                try Task.checkCancellation()
                return try await scoped { folder in
                    try Task.checkCancellation()
                    let files = try reader.read(folder: folder)
                    try Task.checkCancellation()
                    return try compose(files)
                }
            } catch let error as ProjectFolderAccessError {
                let classified = Self.classify(error)
                if selected, error == .invalidFolder {
                    throw ProjectInspectionFailure.selectedAccess(.accessDenied)
                }
                if selected, case let .access(code) = classified {
                    throw ProjectInspectionFailure.selectedAccess(code)
                }
                throw classified
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProjectInspectionFailure {
                throw error
            } catch {
                // Do not return or log unrestricted filesystem/coordinator errors.
                throw ProjectInspectionFailure.unreadableFolder
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func compose(_ files: ProjectFileRead) throws -> ProjectInspection {
        try Task.checkCancellation()
        if files.diagnostics.contains(where: { $0.code == .changedDuringRead }) {
            throw ProjectInspectionFailure.inconsistentRead
        }
        var diagnostics = files.diagnostics
        var manifest: ProjectManifest?
        var roadmap: ProjectOptionalContent<ProjectRoadmap> = .absent

        func report(_ error: ProjectParseError) {
            diagnostics.append(ProjectDiagnostic(code: error.code, severity: .error,
                                                 relativePath: error.path, line: error.line,
                                                 column: error.column, recovery: .editSource))
        }
        func unsupported(_ path: String) {
            diagnostics.append(ProjectDiagnostic(code: .unsupportedVersion, severity: .error,
                                                 relativePath: path, recovery: .upgradeSource))
        }
        if case let .present(source) = files.manifest {
            do {
                switch try parser.project(source) {
                case let .supported(value): manifest = value
                case .unsupported: unsupported(source.relativePath)
                }
            } catch let error as ProjectParseError { report(error) }
        }
        try Task.checkCancellation()
        // Feature files without an explicit version inherit the *project* schema, not
        // V1 unconditionally. With no trusted V1 manifest, leave all peer documents as
        // bounded raw sources; even an apparently V1 roadmap/feature is not trusted.
        if manifest != nil {
            switch files.roadmap {
            case .absent: roadmap = .absent
            case .failed: roadmap = .failed
            case let .present(source):
                do {
                    switch try parser.roadmap(source) {
                    case let .supported(value): roadmap = .present(value)
                    case .unsupported: roadmap = .failed; unsupported(source.relativePath)
                    }
                } catch let error as ProjectParseError { roadmap = .failed; report(error) }
            }
        } else {
            switch files.roadmap {
            case .absent: roadmap = .absent
            case .present, .failed: roadmap = .failed
            }
        }
        var records: [ProjectFeature] = []
        var excluded: [String] = []
        for source in files.features {
            try Task.checkCancellation()
            guard manifest != nil else {
                excluded.append(source.relativePath)
                continue
            }
            do {
                switch try parser.feature(source) {
                case let .supported(value): records.append(value)
                case .unsupported: excluded.append(source.relativePath); unsupported(source.relativePath)
                }
            } catch let error as ProjectParseError {
                excluded.append(source.relativePath)
                report(error)
            }
        }
        // Include files refused by the reader (unsafe, unreadable, oversized, invalid
        // encoding). An enumeration failure has unknown additional members and makes
        // the entire count unavailable, never a complete 0 of 0.
        excluded += files.diagnostics.filter { $0.relativePath.hasPrefix(".kontrol/features/") }
            .map(\.relativePath)
        let validated = validator.validate(records, excludedPaths: excluded, diagnostics: diagnostics)
        try Task.checkCancellation()
        return ProjectInspection(manifest: manifest, roadmap: roadmap, features: validated.features,
                                 excludedFeaturePaths: validated.excludedFeaturePaths,
                                 featureEnumeration: files.featureEnumeration,
                                 context: files.context, rules: files.rules, history: files.history,
                                 diagnostics: validated.diagnostics.map(Self.sanitized),
                                 sources: files.sources, readAt: now())
    }

    /// Add requires a supported, valid manifest and no failed/unsafe/unsupported peer.
    /// Absent optional documents and an empty successfully enumerated directory are fine.
    static func canAdd(_ inspection: ProjectInspection) -> Bool {
        inspection.manifest?.schemaVersion == 1 && inspection.featureEnumeration == .complete &&
            !inspection.diagnostics.contains(where: { $0.severity == .error })
    }

    private static func classify(_ error: ProjectFolderAccessError) -> ProjectInspectionFailure {
        switch error {
        case .stale: return .access(.staleBookmark)
        case .unresolved: return .access(.unresolvedBookmark)
        case .revoked, .denied: return .access(.accessDenied)
        case .invalidFolder: return .access(.unresolvedBookmark)
        case .bookmarkCreationFailed: return .unreadableFolder
        }
    }

    private static func sanitized(_ diagnostic: ProjectDiagnostic) -> ProjectDiagnostic {
        // Preserve relative identity while escaping terminal controls and bidi overrides.
        // Never interpolate parser/OS errors or source text into diagnostic messages.
        func safe(_ input: String) -> String {
            let value = input.unicodeScalars.map { scalar -> String in
                if CharacterSet.controlCharacters.contains(scalar) ||
                    (0x202A...0x202E).contains(scalar.value) ||
                    (0x2066...0x2069).contains(scalar.value) {
                    return String(format: "\\u{%X}", scalar.value)
                }
                return String(scalar)
            }.joined()
            return String(value.prefix(512))
        }
        return ProjectDiagnostic(code: diagnostic.code, severity: diagnostic.severity,
                                 relativePath: safe(diagnostic.relativePath), line: diagnostic.line,
                                 column: diagnostic.column, affectedIDs: diagnostic.affectedIDs.map(safe),
                                 recovery: diagnostic.recovery)
    }
}
