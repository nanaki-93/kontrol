import CryptoKit
import Foundation

// Detached, read-only inspection values. None of these types is a SwiftData model or
// an alternative persistence format for the project's authoritative .kontrol files.
struct ProjectManifest: Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let description: String
    let stack: [String]
    let goals: [String]
    let currentFocus: [String]
}

struct RoadmapMilestone: Equatable {
    let id: String
    let title: String
    let status: String // Open-ended in V1; the parser validates nonempty strings.
}

struct ProjectRoadmap: Equatable {
    let schemaVersion: Int
    let milestones: [RoadmapMilestone] // Source order matters.
}

enum ProjectFeatureStatus: String, Equatable {
    case planned, ready, active, blocked, completed
}

enum ProjectFeaturePriority: String, Equatable {
    case high, medium, low
}

enum ProjectFeatureEffort: String, Equatable {
    case small, medium, large
}

struct ProjectFeature: Equatable {
    let id: String
    let title: String
    let status: ProjectFeatureStatus
    let priority: ProjectFeaturePriority
    let effort: ProjectFeatureEffort
    let dependsOn: [String]
    let areas: [String]
    let completedAt: Date?
    let body: String // Verbatim Markdown after the frontmatter; never reserialized.
    let sourcePath: String // Relative to the selected project root, not derived from id.
}

/// The exact bytes read from disk, including comments, unknown fields and line endings.
/// Only the bounded reader constructs these in memory; the digest is for detecting
/// changes, not a replacement for the bytes or a durable content cache.
struct ProjectSourceDocument: Equatable {
    let relativePath: String
    let bytes: Data
    let sha256: String

    init(relativePath: String, bytes: Data) {
        self.relativePath = relativePath
        self.bytes = bytes
        self.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    var text: String? { String(data: bytes, encoding: .utf8) }
}

/// Absent optional content is not a read error; a failed read must never become empty text.
enum ProjectOptionalContent<Value: Equatable>: Equatable {
    case absent
    case present(Value)
    case failed
}

typealias ProjectOptionalDocument = ProjectOptionalContent<ProjectSourceDocument>

/// Stable machine codes; UI text can change without invalidating diagnostic identity.
enum ProjectDiagnosticCode: String, Equatable {
    case missingManifest, malformedYAML, invalidFrontmatter, unsupportedVersion
    case duplicateKey, invalidField, duplicateID, missingDependency, selfDependency
    case cyclicDependency, invalidDependency
    case unreadableFile, invalidUTF8, unsafeEntry, sizeLimit, changedDuringRead
    case enumerationFailed, accessDenied, staleBookmark, unresolvedBookmark
}

enum ProjectDiagnosticSeverity: String, Equatable {
    case warning, error
}

enum ProjectRecovery: String, Equatable {
    case refresh, reconnect, reselectFolder, upgradeSource, editSource
}

struct ProjectDiagnostic: Equatable {
    let code: ProjectDiagnosticCode
    let severity: ProjectDiagnosticSeverity
    let relativePath: String // Never an absolute or unscoped filesystem URL.
    let line: Int?
    let column: Int?
    let affectedIDs: [String]
    let recovery: ProjectRecovery

    init(code: ProjectDiagnosticCode, severity: ProjectDiagnosticSeverity,
         relativePath: String, line: Int? = nil, column: Int? = nil,
         affectedIDs: [String] = [], recovery: ProjectRecovery) {
        self.code = code
        self.severity = severity
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.affectedIDs = affectedIDs
        self.recovery = recovery
    }
}

/// Enumeration failure is distinct from a successfully enumerated empty directory.
/// Excluded files affect count completeness even if enumeration itself succeeded.
enum ProjectFeatureEnumeration: Equatable {
    case complete
    case failed
}

enum ProjectFeatureCount: Equatable {
    case complete(completed: Int, total: Int)
    case partial(completed: Int, total: Int, excludedFiles: Int)
    case unavailable
}

struct ProjectInspection: Equatable {
    let manifest: ProjectManifest?
    let roadmap: ProjectOptionalContent<ProjectRoadmap>
    let features: [ProjectFeature] // Only validated, eligible records.
    let excludedFeaturePaths: [String]
    let featureEnumeration: ProjectFeatureEnumeration
    let context: ProjectOptionalDocument
    let rules: ProjectOptionalDocument
    let history: ProjectOptionalDocument // Never used for feature completion.
    let diagnostics: [ProjectDiagnostic]
    let sources: [ProjectSourceDocument] // Includes unparseable/unsupported readable files.
    let readAt: Date

    var featureCount: ProjectFeatureCount {
        guard manifest?.schemaVersion == 1, featureEnumeration == .complete else { return .unavailable }
        let completed = features.filter { $0.status == .completed }.count
        if !excludedFeaturePaths.isEmpty {
            return .partial(completed: completed, total: features.count,
                            excludedFiles: excludedFeaturePaths.count)
        }
        return .complete(completed: completed, total: features.count)
    }
}
