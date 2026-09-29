import SwiftUI

/// A read-only projection of the latest disk inspection. The parent shell owns scrolling,
/// so long source text and enlarged type can grow without clipping in a small window.
struct ProjectDetailsView: View {
    let row: ProjectRowState
    let back: () -> Void
    let refresh: () -> Void
    var reconnect: () -> Void = {}
    var recoveryMessage: String? = nil
    var isReconnecting = false

    /// Inspection diagnostics carry codes and relative paths, never OS error descriptions.
    /// Keep the explanation finite and safe even when the selected source is malformed.
    static func diagnosticReason(_ code: ProjectDiagnosticCode) -> String {
        switch code {
        case .missingManifest: return "Required manifest is missing"
        case .malformedYAML: return "YAML is malformed"
        case .invalidFrontmatter: return "Feature frontmatter is invalid"
        case .unsupportedVersion: return "Schema version is unsupported; upgrade the source externally"
        case .duplicateKey: return "YAML key is repeated"
        case .invalidField: return "Required value is missing or has the wrong type"
        case .duplicateID: return "Feature ID is repeated"
        case .missingDependency: return "Dependency ID is missing"
        case .selfDependency: return "Feature depends on itself"
        case .cyclicDependency: return "Features form a dependency cycle"
        case .invalidDependency: return "Dependency refers to an invalid feature"
        case .unreadableFile: return "File could not be read"
        case .invalidUTF8: return "File is not valid UTF-8"
        case .unsafeEntry: return "Unsafe link or nonregular entry refused"
        case .sizeLimit: return "File or inspection exceeds the read limit"
        case .changedDuringRead: return "File changed during inspection"
        case .enumerationFailed: return "Feature listing could not be completed"
        case .accessDenied: return "Folder access was denied"
        case .staleBookmark: return "Folder permission is stale"
        case .unresolvedBookmark: return "Saved folder could not be found"
        }
    }

    static func safeLabel(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) ||
                (0x202A...0x202E).contains(scalar.value) ||
                (0x2066...0x2069).contains(scalar.value) {
                return String(format: "\\u{%X}", scalar.value)
            }
            return String(scalar)
        }.joined().prefix(512))
    }

    static func diagnosticText(_ diagnostic: ProjectDiagnostic) -> String {
        let path = diagnostic.relativePath.hasPrefix(".kontrol/") || diagnostic.relativePath == ".kontrol"
            ? safeLabel(diagnostic.relativePath) : "Project file"
        let position = diagnostic.line.map { " · line \($0)" } ?? ""
        let ids = diagnostic.affectedIDs.isEmpty ? "" :
            " · IDs: \(diagnostic.affectedIDs.prefix(8).map(safeLabel).joined(separator: ", "))"
        return "\(path)\(position): \(diagnosticReason(diagnostic.code))\(ids) · \(diagnostic.recovery == .reconnect ? "Reconnect" : "Refresh after external repair")"
    }

    static func failureText(_ failure: ProjectRefreshFailure) -> String {
        switch failure {
        case .manifestMismatch:
            return "This folder now contains a different project ID. The saved reference was not changed. Refresh after restoring the original project, or add the other folder separately."
        case .persistence:
            return "The local read receipt could not be saved. Previous project details remain stale; Refresh to retry."
        case .inspection(.inconsistentRead):
            return "Files changed during inspection. Previous details are stale; Refresh to retry."
        case .inspection(.unreadableFolder):
            return "Folder could not be read. Previous details are stale; Refresh to retry."
        case let .inspection(.access(code)):
            return "\(diagnosticReason(code)). Previous details are stale; Reconnect this project to restore folder access."
        case let .inspection(.selectedAccess(code)):
            return "\(diagnosticReason(code)). Refresh after restoring folder access."
        }
    }

    /// Source bytes are already bounded by the reader; cap rendered text as well so an
    /// injected inspection cannot create an unbounded selectable view.
    static func unsupportedText(_ source: ProjectSourceDocument) -> String {
        guard let text = source.text else { return "Source is not valid UTF-8; Refresh after repair." }
        let prefix = String(text.prefix(32_768))
        return prefix + (text.count > 32_768 ? "\n… Preview limited to 32,768 characters" : "")
    }

    static func progress(_ inspection: ProjectInspection) -> String {
        switch inspection.featureCount {
        case let .complete(completed, total):
            return "\(completed) of \(total) features completed (complete enumeration)"
        case let .partial(completed, total, excluded):
            return "\(completed) of \(total) valid features completed (partial; \(excluded) \(excluded == 1 ? "file" : "files") excluded)"
        case .unavailable:
            return "Feature progress unavailable; enumeration or manifest is incomplete"
        }
    }

    static func documentText(_ content: ProjectOptionalDocument) -> String {
        switch content {
        case .absent: return "No file provided"
        case .failed: return "File could not be read; Refresh after repairing it"
        case let .present(document): return document.text ?? "File encoding unavailable; Refresh after repairing it"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            PageHeader(row.inspection?.manifest?.name ?? row.reference.displayNameHint,
                       metadata: ProjectsView.location(row)) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppMetrics.space2) { actions }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) { actions }
                }
            }
            if row.isStale {
                Text("Stale · Last read: \(row.lastReadAt?.formatted(date: .abbreviated, time: .shortened) ?? "unavailable") · Not fully verified now")
                    .appTypography(.body)
                    .accessibilityIdentifier("project-details-stale")
            }
            if let failure = row.refreshFailure {
                Text(Self.failureText(failure))
                    .appTypography(.body)
                    .accessibilityIdentifier("project-details-failure")
            }
            if let recoveryMessage {
                Text(recoveryMessage)
                    .appTypography(.body)
                    .accessibilityIdentifier("project-reconnect-error")
            }
            if let inspection = row.inspection {
                if !inspection.diagnostics.isEmpty || !inspection.excludedFeaturePaths.isEmpty {
                    SectionHeader("Validation details")
                    if !inspection.excludedFeaturePaths.isEmpty {
                        Text("\(inspection.excludedFeaturePaths.count) feature \(inspection.excludedFeaturePaths.count == 1 ? "file" : "files") excluded; counts include only valid features. Repair externally, then Refresh.")
                            .appTypography(.body)
                            .accessibilityIdentifier("project-details-excluded")
                    }
                    ForEach(Array(inspection.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(Self.diagnosticText(diagnostic))
                            .appTypography(.body)
                            .textSelection(.enabled)
                    }
                }
                let unsupportedPaths = Set(inspection.diagnostics.filter { $0.code == .unsupportedVersion }.map(\.relativePath))
                ForEach(inspection.sources.filter { unsupportedPaths.contains($0.relativePath) }, id: \.relativePath) { source in
                    SectionHeader("Unsupported source · \(Self.safeLabel(source.relativePath)) · read-only")
                    Text("Upgrade the source externally. Unsupported content is not interpreted as V1 or used for progress.")
                        .appTypography(.body)
                    Text(Self.unsupportedText(source))
                        .appTypography(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("project-unsupported-source")
                }
                if let manifest = inspection.manifest {
                    VStack(alignment: .leading, spacing: AppMetrics.space4) {
                        Text(manifest.description.isEmpty ? "No description provided" : manifest.description)
                            .appTypography(.body)
                            .textSelection(.enabled)
                        items("Stack", manifest.stack)
                        items("Goals", manifest.goals)
                        items("Current focus", manifest.currentFocus)
                    }
                    SectionHeader("Progress")
                    Text(Self.progress(inspection))
                        .appTypography(.body)
                        .accessibilityIdentifier("project-details-progress")
                    SectionHeader("Roadmap")
                    switch inspection.roadmap {
                    case .absent:
                        Text("No roadmap provided").appTypography(.body)
                    case .failed:
                        Text("Roadmap could not be read; Refresh after repairing it").appTypography(.body)
                    case let .present(roadmap):
                        if roadmap.milestones.isEmpty {
                            Text("No milestones provided").appTypography(.body)
                        } else {
                            ForEach(Array(roadmap.milestones.enumerated()), id: \.offset) { _, milestone in
                                HStack(alignment: .firstTextBaseline, spacing: AppMetrics.space4) {
                                    Text(milestone.title).appTypography(.body)
                                    Text(milestone.status).appTypography(.metadata)
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    document("Context", inspection.context)
                    document("Rules", inspection.rules)
                    document("History (read-only source; not used for progress)", inspection.history)
                } else {
                    Text("Project metadata unavailable. Refresh after repairing the manifest.")
                        .appTypography(.body)
                }
            } else if row.isRefreshing {
                LoadingState("Loading project details")
            } else {
                Text("Project details unavailable. Refresh to read the folder.")
                    .appTypography(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .padding(.bottom, AppMetrics.space8)
        .accessibilityIdentifier("project-details")
    }

    private var actions: some View {
        Group {
            ActionButton("Back to projects", variant: .secondary, action: back)
                .accessibilityIdentifier("project-details-back")
            if row.refreshFailure?.recovery == .reconnect {
                ActionButton("Reconnect project", variant: .secondary, action: reconnect)
                    .disabled(isReconnecting)
                    .accessibilityIdentifier("project-details-reconnect")
            } else {
                ActionButton("Refresh project", variant: .secondary, action: refresh)
                    .accessibilityIdentifier("project-details-refresh")
            }
        }
    }

    private func items(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader(title)
            if values.isEmpty {
                Text("None provided").appTypography(.body)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value).appTypography(.body).textSelection(.enabled)
                }
            }
        }
    }

    private func document(_ title: String, _ content: ProjectOptionalDocument) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader(title)
            Text(Self.documentText(content))
                .appTypography(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
