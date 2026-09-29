import SwiftUI

/// The folder list stays visible when an individual reference cannot be read.
/// Details and reconnect controls are separate follow-up surfaces.
struct ProjectsView: View {
    @ObservedObject var store: ProjectStore
    @State private var showingAdd = false
    @FocusState private var addFocused: Bool

    static func ordered(_ rows: [ProjectRowState]) -> [ProjectRowState] {
        rows.sorted {
            if $0.reference.displayOrder != $1.reference.displayOrder {
                return $0.reference.displayOrder < $1.reference.displayOrder
            }
            return $0.reference.id.uuidString < $1.reference.id.uuidString
        }
    }

    static func location(_ row: ProjectRowState) -> String {
        guard let hint = row.locationHint, !hint.isEmpty else {
            return "Location unavailable · reference \(row.reference.id.uuidString)"
        }
        return row.isStale ? "Last seen: \(hint)" : hint
    }

    static func status(_ row: ProjectRowState) -> String {
        if let failure = row.refreshFailure {
            switch failure.recovery {
            case .reconnect: return "Reconnect required · folder access unavailable"
            default: return "Refresh needed · last read is stale"
            }
        }
        if row.isRefreshing { return row.inspection == nil ? "Loading project" : "Refreshing project" }
        guard let inspection = row.inspection else { return "Waiting to inspect project" }
        if case let .partial(completed, total, excluded) = inspection.featureCount {
            return "Partial: \(completed) of \(total) valid features · \(excluded) \(excluded == 1 ? "file" : "files") excluded"
        }
        if row.isStale { return "Incomplete read · Refresh needed" }
        if case let .complete(completed, total) = inspection.featureCount {
            return "Ready · \(completed) of \(total) features completed"
        }
        return "Progress unavailable · Refresh needed"
    }

    var body: some View {
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
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("project-row-\(row.reference.id.uuidString)")
                }
                if let selected = store.rows.first(where: { $0.reference.id == store.selectedID }) {
                    Text("Selected: \(selected.inspection?.manifest?.name ?? selected.reference.displayNameHint)")
                        .appTypography(.body)
                        .accessibilityIdentifier("projects-selected")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear { enter() }
        .sheet(isPresented: $showingAdd, onDismiss: { addFocused = true }) {
            ProjectAddView(store: store) { showingAdd = false }
        }
        .accessibilityIdentifier("projects-content")
    }

    private func enter() {
        do { try store.enterProjects() } catch { /* Store publishes a retryable load failure. */ }
    }
}
