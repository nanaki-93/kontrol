import SwiftUI

/// A read-only projection of the latest disk inspection. The parent shell owns scrolling,
/// so long source text and enlarged type can grow without clipping in a small window.
struct ProjectDetailsView: View {
    let row: ProjectRowState
    let back: () -> Void
    let refresh: () -> Void

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
                Text("Last read: \(row.lastReadAt?.formatted(date: .abbreviated, time: .shortened) ?? "unavailable") · Not verified now; Refresh to inspect again")
                    .appTypography(.body)
                    .accessibilityIdentifier("project-details-stale")
            }
            if let inspection = row.inspection {
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
            ActionButton("Refresh project", variant: .secondary, action: refresh)
                .accessibilityIdentifier("project-details-refresh")
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
