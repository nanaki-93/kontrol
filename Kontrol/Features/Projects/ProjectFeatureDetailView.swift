import SwiftUI

/// Local Markdown remains plain selectable text; completion is delegated to the store.
/// Resolve by ID on each render so refresh/reconnect never leaves a second content cache.
struct ProjectFeatureDetailView: View {
    let row: ProjectRowState
    let featureID: String
    let backToRoadmap: Bool
    let back: () -> Void
    var canMarkComplete = false
    var markComplete: () -> Void = {}
    var navigationFocus: FocusState<ProjectsView.NavigationFocus?>.Binding? = nil
    @FocusState private var localFocus: ProjectsView.NavigationFocus?

    var backLabel: String {
        "Back to \(backToRoadmap ? "roadmap" : "projects") from feature \(feature?.title ?? featureID)"
    }

    var feature: ProjectFeature? {
        row.inspection?.features.first { $0.id == featureID }
    }

    static func completionTitle(for featureID: String, state: ProjectCompletionState?) -> String {
        if case .writing(featureID) = state { return "Saving…" }
        if case .refreshing(featureID) = state { return "Saving…" }
        return "Mark complete"
    }

    static func completionLabel(for feature: ProjectFeature, state: ProjectCompletionState?) -> String {
        let title = ProjectDetailsView.safeLabel(feature.title)
        return completionTitle(for: feature.id, state: state) == "Saving…" ?
            "Saving \(title)…" : "Mark \(title) complete"
    }

    static func dependencyLabels(for feature: ProjectFeature, in inspection: ProjectInspection) -> [String] {
        feature.dependsOn.map { id in
            guard let target = inspection.features.first(where: { $0.id == id }) else {
                return "\(id) · status unavailable"
            }
            return "\(target.title) (\(target.id)) · \(target.status.rawValue.capitalized)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            if let feature, let inspection = row.inspection {
                PageHeader(feature.title, metadata: "Feature \(feature.id) · Read-only") {
                    ActionButton(backToRoadmap ? "Back to roadmap" : "Back to projects", variant: .secondary, action: back)
                        .accessibilityLabel(backLabel)
                        .accessibilityIdentifier("project-feature-back")
                }
                .focusable()
                .focused(navigationFocus ?? $localFocus, equals: .featureHeading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("project-feature-heading")
                if row.isRetainedInspection {
                    Text("Stale reference · Last read: \(row.lastReadAt?.formatted(date: .abbreviated, time: .shortened) ?? "unavailable") · Refresh or Reconnect to verify this feature.")
                        .appTypography(.body)
                        .accessibilityIdentifier("project-feature-stale")
                }
                if feature.status != .completed {
                    ActionButton(Self.completionTitle(for: featureID, state: row.completion),
                                 isEnabled: canMarkComplete && !row.isRefreshing && !row.isRetainedInspection) {
                        markComplete()
                    }
                    .accessibilityLabel(Self.completionLabel(for: feature, state: row.completion))
                    .accessibilityIdentifier("project-feature-complete-\(featureID)")
                }
                SectionHeader("Feature details")
                detail("Stable ID", feature.id)
                detail("Status", feature.status.rawValue.capitalized)
                detail("Priority", feature.priority.rawValue.capitalized)
                detail("Effort", feature.effort.rawValue.capitalized)
                detail("Areas", feature.areas.isEmpty ? "No areas provided" : feature.areas.joined(separator: ", "))
                SectionHeader("Dependencies")
                if feature.dependsOn.isEmpty {
                    Text("No dependencies")
                        .appTypography(.body)
                        .accessibilityIdentifier("project-feature-no-dependencies")
                } else {
                    ForEach(Array(Self.dependencyLabels(for: feature, in: inspection).enumerated()), id: \.offset) { _, label in
                        Text(label).appTypography(.body).textSelection(.enabled)
                    }
                }
                SectionHeader("Description · local Markdown")
                Text(feature.body.isEmpty ? "No description provided" : feature.body)
                    .appTypography(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("project-feature-body")
            } else {
                ActionButton(backToRoadmap ? "Back to roadmap" : "Back to projects", variant: .secondary, action: back)
                    .accessibilityLabel(backLabel)
                    .accessibilityIdentifier("project-feature-back")
                Text("Feature details unavailable. Return to the project for validation or Refresh.")
                    .appTypography(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .padding(.bottom, AppMetrics.space8)
        .accessibilityIdentifier("project-feature-detail")
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppMetrics.space4) {
            Text(title).appTypography(.metadata).foregroundStyle(AppColors.textSecondary)
            Text(value).appTypography(.body).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
