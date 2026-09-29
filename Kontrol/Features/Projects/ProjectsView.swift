import AppKit
import SwiftUI

/// The folder list stays visible when an individual reference cannot be read.
/// A selected reference remains selected when returning from its read-only details.
struct ProjectsView: View {
    @ObservedObject var store: ProjectStore
    @State private var showingAdd = false
    @State private var detailID: UUID?
    @FocusState private var addFocused: Bool
    @State private var reconnectPicker: NSOpenPanel?
    @State private var reconnectingID: UUID?
    @State private var recoveryMessage: (id: UUID, text: String)?

    static func ordered(_ rows: [ProjectRowState]) -> [ProjectRowState] {
        rows.sorted {
            if $0.reference.displayOrder != $1.reference.displayOrder {
                return $0.reference.displayOrder < $1.reference.displayOrder
            }
            return $0.reference.id.uuidString < $1.reference.id.uuidString
        }
    }

    /// A failed/canceled read retains reference data, not current recommendations.
    /// Newly inspected partial results may also be isStale and remain actionable.
    static func recommendations(_ row: ProjectRowState) -> [FeatureCandidate] {
        guard !row.isRetainedInspection, let inspection = row.inspection else { return [] }
        return FeatureSelector().select(from: inspection).candidates
    }

    static func reason(_ reason: FeatureSelectionReason, dependencies: Int) -> String {
        switch reason {
        case .currentFocus: return "Matches current focus"
        case .dependenciesComplete:
            return dependencies == 1 ? "Ready · dependency complete" : "Ready · dependencies complete"
        case .ready: return "Ready"
        }
    }

    static func cardMetadata(_ feature: ProjectFeature, reason: FeatureSelectionReason) -> String {
        "\(feature.priority.rawValue) priority · \(feature.effort.rawValue) effort · \(Self.reason(reason, dependencies: feature.dependsOn.count))"
    }

    static func location(_ row: ProjectRowState) -> String {
        guard let hint = row.locationHint, !hint.isEmpty else {
            return "Location unavailable · reference \(row.reference.id.uuidString)"
        }
        return row.isStale ? "Last seen: \(hint)" : hint
    }

    static func status(_ row: ProjectRowState) -> String {
        if let failure = row.refreshFailure {
            let lastRead = row.lastReadAt.map { " · Last read: \($0.formatted(date: .abbreviated, time: .shortened)) (stale)" } ?? ""
            switch failure {
            case .inspection(.access): return "Reconnect required · folder access unavailable\(lastRead)"
            case .manifestMismatch: return "Different project ID · previous details stale · Refresh after restoring the original project\(lastRead)"
            case .persistence: return "Local save failed · previous details stale · Refresh to retry\(lastRead)"
            case .inspection: return "Refresh needed · previous details not verified\(lastRead)"
            }
        }
        if row.isRefreshing { return row.inspection == nil ? "Loading project" : "Refreshing project" }
        guard let inspection = row.inspection else { return "Waiting to inspect project" }
        let unsupported = inspection.diagnostics.contains { $0.code == .unsupportedVersion }
        if case let .partial(completed, total, excluded) = inspection.featureCount {
            return "Partial: \(completed) of \(total) valid features · \(excluded) \(excluded == 1 ? "file" : "files") excluded\(unsupported ? " · unsupported source" : "")"
        }
        if unsupported {
            return inspection.manifest == nil ? "Unsupported project format · progress unavailable; upgrade source" :
                "Unsupported document · inspect validation details; upgrade source"
        }
        if row.isStale { return "Incomplete read · Refresh needed" }
        if case let .complete(completed, total) = inspection.featureCount {
            return "Ready · \(completed) of \(total) features completed"
        }
        return "Progress unavailable · Refresh needed"
    }

    var body: some View {
        Group {
            if let identity = store.selectedFeature,
               let row = store.rows.first(where: { $0.reference.id == identity.projectID }),
               let feature = store.selectedFeatureContent {
                featureReference(feature, row: row)
            } else if let detailID, let row = store.rows.first(where: { $0.reference.id == detailID }) {
                ProjectDetailsView(row: row, back: { self.detailID = nil },
                                   refresh: { store.refresh(detailID) },
                                   reconnect: { chooseReconnectFolder(for: detailID) },
                                   recoveryMessage: recoveryMessage?.id == detailID ? recoveryMessage?.text : nil,
                                   isReconnecting: reconnectingID == detailID)
            } else {
                list
            }
        }
        .onAppear { enter() }
        .sheet(isPresented: $showingAdd, onDismiss: { addFocused = true }) {
            ProjectAddView(store: store) { showingAdd = false }
        }
        .accessibilityIdentifier("projects-content")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            PageHeader("Projects") {
                ActionButton("Add project", symbol: "plus", variant: .primary) { showingAdd = true }
                    .focused($addFocused)
                    .accessibilityIdentifier("projects-add")
            }
            if store.loadFailed {
                ErrorBanner(.readFailed, recoveryTitle: "Retry projects") { enter() }
                Text("Project references could not be loaded. Other areas remain available.")
                    .appTypography(.body)
            } else if !store.isLoaded {
                LoadingState("Loading projects")
            } else if store.rows.isEmpty {
                EmptyState("No projects added yet", guidance: "Add a local project folder to inspect it.",
                           actionTitle: "Add project") { showingAdd = true }
            } else {
                SectionHeader("Local folders")
                ForEach(Self.ordered(store.rows), id: \.reference.id) { row in
                    let selected = store.selectedID == row.reference.id
                    AppListRow(row.inspection?.manifest?.name ?? row.reference.displayNameHint,
                               metadata: Self.location(row),
                               status: StatusPill(Self.status(row), kind: row.refreshFailure?.recovery == .reconnect ? .error :
                                                  (row.isRefreshing || row.isStale || row.inspection == nil ? .warning : .success))) {
                        Button(selected ? "Selected" : "Select project") { store.select(row.reference.id) }
                            .accessibilityLabel("Select project \(row.inspection?.manifest?.name ?? row.reference.displayNameHint), \(Self.location(row))")
                            .accessibilityIdentifier("project-select-\(row.reference.id.uuidString)")
                            .disabled(selected)
                        Button("View details") {
                            store.select(row.reference.id)
                            detailID = row.reference.id
                        }
                        .accessibilityLabel("View details for \(row.inspection?.manifest?.name ?? row.reference.displayNameHint), \(Self.location(row))")
                        .accessibilityIdentifier("project-details-open-\(row.reference.id.uuidString)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("project-row-\(row.reference.id.uuidString)")
                    if row.refreshFailure?.recovery == .reconnect {
                        ActionButton("Reconnect \(row.reference.displayNameHint)", variant: .secondary) {
                            chooseReconnectFolder(for: row.reference.id)
                        }
                        .disabled(reconnectingID != nil)
                        .accessibilityIdentifier("project-row-reconnect-\(row.reference.id.uuidString)")
                    } else if row.refreshFailure != nil || row.isStale {
                        ActionButton("Refresh \(row.reference.displayNameHint)", variant: .secondary) {
                            store.refresh(row.reference.id)
                        }
                        .accessibilityIdentifier("project-row-refresh-\(row.reference.id.uuidString)")
                    }
                    if recoveryMessage?.id == row.reference.id, let message = recoveryMessage?.text {
                        Text(message).appTypography(.body)
                            .accessibilityIdentifier("project-row-recovery-error")
                    }
                }
                if let selected = store.rows.first(where: { $0.reference.id == store.selectedID }) {
                    workspace(for: selected)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .padding(.bottom, AppMetrics.space8)
    }

    private func workspace(for row: ProjectRowState) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader(row.inspection?.manifest?.name ?? row.reference.displayNameHint,
                       metadata: Self.location(row)) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppMetrics.space2) { workspaceActions(for: row) }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) { workspaceActions(for: row) }
                }
            }
            .accessibilityIdentifier("projects-selected")
            if row.isRefreshing {
                Text("Refreshing project · showing last inspected information until the read completes")
                    .appTypography(.body)
                    .accessibilityIdentifier("projects-workspace-refreshing")
            }
            if row.isRetainedInspection {
                Text("Previous inspection is stale · recommendations unavailable until a successful Refresh or Reconnect. Project details remain available for reference.")
                    .appTypography(.body)
                    .accessibilityIdentifier("projects-workspace-stale")
            }
            if let inspection = row.inspection {
                SectionHeader("Progress")
                Text(ProjectDetailsView.progress(inspection))
                    .appTypography(.body)
                    .accessibilityIdentifier("projects-workspace-progress")
                if case let .partial(_, _, excluded) = inspection.featureCount {
                    Text("Partial results · \(excluded) \(excluded == 1 ? "feature file" : "feature files") excluded from counts and suggestions. View project details for validation; repair externally, then Refresh.")
                        .appTypography(.body)
                        .accessibilityIdentifier("projects-workspace-partial")
                }
                if !row.isRetainedInspection {
                    let candidates = Self.recommendations(row)
                    if !candidates.isEmpty {
                        SectionHeader("Next features")
                        ForEach(candidates, id: \.id) { candidate in
                            if let feature = inspection.features.first(where: { $0.id == candidate.id }) {
                                NextActionCard(feature.title,
                                               metadata: Self.cardMetadata(feature, reason: candidate.reason),
                                               status: StatusPill(feature.status.rawValue.capitalized, kind: .success)) {
                                    ActionButton("View feature", variant: .primary) {
                                        // Recheck freshness at activation, not just when the card was built.
                                        guard let current = store.rows.first(where: { $0.reference.id == row.reference.id }),
                                              !current.isRetainedInspection else { return }
                                        store.selectFeature(candidate.id, in: row.reference.id)
                                    }
                                    .accessibilityIdentifier("project-feature-open-\(candidate.id)")
                                }
                                .accessibilityIdentifier("project-feature-card-\(candidate.id)")
                            }
                        }
                    }
                }
            } else if row.isRefreshing {
                LoadingState("Loading selected project")
            } else {
                Text("Project inspection unavailable · Refresh or Reconnect to read the folder.")
                    .appTypography(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("projects-workspace")
    }

    private func workspaceActions(for row: ProjectRowState) -> some View {
        Group {
            ActionButton("View project details") {
                detailID = row.reference.id
            }
            .accessibilityIdentifier("projects-workspace-details")
            if row.refreshFailure?.recovery == .reconnect {
                ActionButton("Reconnect project") { chooseReconnectFolder(for: row.reference.id) }
                    .disabled(reconnectingID != nil)
                    .accessibilityIdentifier("projects-workspace-reconnect")
            } else {
                ActionButton("Refresh project") { store.refresh(row.reference.id) }
                    .accessibilityIdentifier("projects-workspace-refresh")
            }
        }
    }

    /// A small read-only reference route until the full F10 feature-detail layout is added.
    /// Content always resolves from the store's current inspection, including retained stale reads.
    private func featureReference(_ feature: ProjectFeature, row: ProjectRowState) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader(feature.title, metadata: "Feature \(feature.id) · \(feature.status.rawValue.capitalized)") {
                ActionButton("Back to projects") { store.closeFeature() }
            }
            if row.isRetainedInspection {
                Text("Stale reference · Last read: \(row.lastReadAt?.formatted(date: .abbreviated, time: .shortened) ?? "unavailable") · Refresh or Reconnect to verify this feature.")
                    .appTypography(.body)
                    .accessibilityIdentifier("project-feature-stale")
            }
            Text(feature.body.isEmpty ? "No description provided" : feature.body)
                .appTypography(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .padding(.bottom, AppMetrics.space8)
        .accessibilityIdentifier("project-feature-reference")
    }

    /// Reconnect is an explicit native selection, never an unscoped path retry. A canceled
    /// picker leaves both the old reference and the visible failure unchanged.
    private func chooseReconnectFolder(for id: UUID) {
        guard reconnectingID == nil, reconnectPicker == nil else { return }
        let panel = ProjectAddView.configuredPicker()
        panel.title = "Reconnect project folder"
        panel.prompt = "Reconnect folder"
        panel.message = "Choose the original project folder. Its manifest ID must match the saved reference."
        reconnectPicker = panel
        panel.begin { response in
            reconnectPicker = nil
            guard response == .OK, let folder = panel.url else { return }
            reconnectingID = id
            recoveryMessage = nil
            Task {
                do {
                    _ = try await store.reconnect(id, to: folder)
                } catch is CancellationError {
                    // Cancellation never claims restored access or a failed validation.
                } catch let error as ProjectStoreError {
                    let text: String
                    switch error {
                    case .manifestMismatch:
                        text = "Different project selected. The saved reference is unchanged; choose the original folder or add this folder separately."
                    case .invalidReconnect:
                        text = "Selected project is invalid or unsupported. The saved reference is unchanged; repair it externally and retry Reconnect."
                    default:
                        text = "Project not reconnected. The saved reference is unchanged; retry Reconnect."
                    }
                    recoveryMessage = (id, text)
                } catch {
                    recoveryMessage = (id, "Project not reconnected. The saved reference is unchanged; retry Reconnect.")
                }
                reconnectingID = nil
            }
        }
    }

    private func enter() {
        do { try store.enterProjects() } catch { /* Store publishes a retryable load failure. */ }
    }
}
