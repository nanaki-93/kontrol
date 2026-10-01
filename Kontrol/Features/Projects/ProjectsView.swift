import AppKit
import SwiftUI

/// The folder list stays visible when an individual reference cannot be read.
/// A selected reference remains selected when returning from its read-only details.
struct ProjectsView: View {
    @ObservedObject var store: ProjectStore
    @State private var showingAdd = false
    @State private var detailID: UUID?
    @State private var previewSelection = ProjectPreviewSelection()
    @FocusState private var addFocused: Bool
    @FocusState private var navigationFocus: NavigationFocus?
    @State private var featureOrigin: NavigationFocus?
    @State private var pendingReturnFocus: NavigationFocus?
    @State private var pendingCompletionFocus: (projectID: UUID, target: NavigationFocus)?
    @State private var reconnectPicker: NSOpenPanel?
    @State private var reconnectingID: UUID?
    @State private var recoveryMessage: (id: UUID, text: String)?
    @State private var presentedConflict: ProjectFeatureIdentity?

    enum CompletionRecovery: Equatable { case refresh, reconnect }

    static func undoActionTitle(feature: String, project: String) -> String {
        "Undo completion of \(feature) in \(project)"
    }

    /// These messages never infer a completed status from an in-flight or uncertain write.
    /// Only the store's verified `.saved` receipt may feed UndoAffordance.
    static func completionMessage(_ state: ProjectCompletionState, feature: String, project: String) -> String {
        let target = "\(feature) in \(project)"
        switch state {
        case .writing: return "Saving \(target)… No completion has been verified yet."
        case .refreshing: return "File saved for \(target); verifying project progress from disk…"
        case .undoing: return "Undoing completion of \(target)… Verifying the restored file."
        case .saved: return "\(target) saved and verified. Project progress refreshed from disk."
        case .undone: return "Completion of \(target) undone and verified. Project progress refreshed from disk."
        case let .failed(_, failure), let .undoFailed(_, failure):
            let undo = { if case .undoFailed = state { return true }; return false }()
            let prefix = undo ? "Undo not verified for \(target). " : "Completion not verified for \(target). "
            switch failure {
            case .conflict, .undoConflict, .missingTarget, .changedIdentity:
                return prefix + "Feature changed on disk. Your changes were not overwritten. Refresh to review the current file; this does not retry the action."
            case .unpatchableSource:
                return prefix + "The frontmatter cannot be edited safely. Repair the source externally, then Refresh."
            case .accessDenied:
                return prefix + "Folder access is unavailable. Reconnect the original project folder."
            case .unverifiedWrite:
                return prefix + "The file outcome is uncertain; progress is stale. Refresh to check the disk before any new action."
            case .manifestMismatch, .unsafePath:
                return prefix + "The saved project or file identity could not be verified. Refresh to review the project."
            case .canceled:
                return prefix + "The operation was canceled before replacement. Refresh before retrying."
            default:
                return prefix + "The file could not be written or verified. Refresh to check its current state before retrying."
            }
        case let .savedButRefreshFailed(_, failure), let .undoneButRefreshFailed(_, failure):
            let saved = { if case .savedButRefreshFailed = state { return true }; return false }()
            let prefix = saved ? "File saved and verified for \(target)" : "Undo saved and verified for \(target)"
            let cause = failure == .persistence ? "the local read receipt could not be saved" : "project refresh failed"
            return "\(prefix), but \(cause). Progress and detail are unavailable until \(failure.recovery == .reconnect ? "Reconnect" : "Refresh") succeeds."
        }
    }

    /// A later explicit Refresh can recover a saved file without changing the store's
    /// historical IO outcome. Use the newly accepted inspection to retire stale copy.
    static func displayedCompletion(_ row: ProjectRowState) -> ProjectCompletionState? {
        guard let state = row.completion, row.refreshFailure == nil,
              row.inspection != nil, !row.isRetainedInspection else { return row.completion }
        switch state {
        case let .savedButRefreshFailed(id, _): return .saved(id)
        case let .undoneButRefreshFailed(id, _): return .undone(id)
        default: return state
        }
    }

    static func completionRecovery(_ state: ProjectCompletionState) -> CompletionRecovery? {
        switch state {
        case let .failed(_, failure), let .undoFailed(_, failure):
            return failure == .accessDenied ? .reconnect : .refresh
        case let .savedButRefreshFailed(_, failure), let .undoneButRefreshFailed(_, failure):
            return failure.recovery == .reconnect ? .reconnect : .refresh
        default: return nil
        }
    }

    /// Refresh only reads the project. Return focus to the visible detail heading when
    /// detail is open; the workspace heading is not rendered in that branch.
    static func conflictRefreshFocus(projectID: UUID, selectedFeature: ProjectFeatureIdentity?,
                                     detailAvailable: Bool) -> NavigationFocus {
        selectedFeature?.projectID == projectID && detailAvailable ? .featureHeading : .projectHeading(projectID)
    }

    static func conflict(_ state: ProjectCompletionState?, projectID: UUID) -> ProjectFeatureIdentity? {
        switch state {
        case let .failed(id, failure), let .undoFailed(id, failure):
            switch failure {
            case .conflict, .undoConflict, .missingTarget, .changedIdentity:
                return ProjectFeatureIdentity(projectID: projectID, featureID: id)
            default: return nil
            }
        default: return nil
        }
    }

    private var selectedRow: ProjectRowState? {
        store.rows.first { $0.reference.id == store.selectedID }
    }

    /// A window-local browse identity; never aliases the store's full-detail route.
    struct ProjectPreviewSelection: Equatable {
        var projectID: UUID? = nil
        var featureID: String? = nil

        func resolved(for projectID: UUID, candidates: [FeatureCandidate]) -> Self {
            let retained = self.projectID == projectID && candidates.contains { $0.id == featureID }
            return Self(projectID: projectID, featureID: retained ? featureID : candidates.first?.id)
        }

        func selecting(_ id: String, from projection: PreviewProjection) -> Self {
            guard projectID == projection.selection.projectID,
                  projection.candidates.contains(where: { $0.id == id }) else { return self }
            return Self(projectID: projectID, featureID: id)
        }
    }

    struct PreviewProjection {
        let selection: ProjectPreviewSelection
        let candidates: [FeatureCandidate]
        /// Nil for a retained/failed or in-flight inspection, even if recovery identity exists.
        var currentIdentity: ProjectFeatureIdentity? {
            guard let id = selection.projectID, let featureID = selection.featureID,
                  candidates.contains(where: { $0.id == featureID }) else { return nil }
            return ProjectFeatureIdentity(projectID: id, featureID: featureID)
        }
    }

    static func preview(for projectID: UUID?, selection: ProjectPreviewSelection,
                        row: ProjectRowState?) -> PreviewProjection? {
        guard let projectID else { return nil }
        // A failed read is not an authoritative empty candidate list. Do not reconcile
        // away an eligible ID until a new inspection has actually been accepted.
        guard let row, row.reference.id == projectID, !row.isRefreshing,
              row.refreshFailure == nil, !row.isRetainedInspection,
              row.inspection != nil else {
            return PreviewProjection(selection: selection.projectID == projectID ? selection :
                ProjectPreviewSelection(projectID: projectID), candidates: [])
        }
        let candidates = recommendations(row)
        return PreviewProjection(selection: selection.resolved(for: projectID, candidates: candidates),
                                 candidates: candidates)
    }

    /// Admit a browse event only for the project that rendered its button and a
    /// candidate still present in that project's current accepted inspection.
    static func selectingPreview(_ captured: ProjectFeatureIdentity, selectedProjectID: UUID?,
                                 selection: ProjectPreviewSelection, row: ProjectRowState?) -> ProjectPreviewSelection? {
        guard selectedProjectID == captured.projectID,
              let projection = preview(for: selectedProjectID, selection: selection, row: row),
              projection.currentIdentity != nil,
              projection.candidates.contains(where: { $0.id == captured.featureID }) else { return nil }
        return projection.selection.selecting(captured.featureID, from: projection)
    }

    /// The candidate and its body both come from the same accepted inspection.
    /// Browsing this projection does not inspect files, enter detail, or mutate the store.
    static func previewFeature(in projection: PreviewProjection, row: ProjectRowState) -> ProjectFeature? {
        guard projection.currentIdentity?.projectID == row.reference.id,
              !row.isRefreshing, row.refreshFailure == nil, !row.isRetainedInspection,
              let inspection = row.inspection, let id = projection.currentIdentity?.featureID,
              recommendations(row).contains(where: { $0.id == id }) else { return nil }
        return inspection.features.first { $0.id == id }
    }

    static func previewExcerpt(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 600 ? trimmed : String(trimmed.prefix(599)) + "…"
    }

    private var previewProjection: PreviewProjection? {
        Self.preview(for: store.selectedID, selection: previewSelection, row: selectedRow)
    }

    private var selectedConflict: ProjectFeatureIdentity? {
        guard let row = selectedRow, row.isRetainedInspection else { return nil }
        return Self.conflict(row.completion, projectID: row.reference.id)
    }

    enum NavigationFocus: Hashable {
        case projectHeading(UUID)
        case featureHeading
        case card(UUID, String)
        case cardCompletion(UUID, String)
        case detailCompletion(UUID, String)
        case recovery(UUID, String)
        case roadmap(UUID, String)
    }

    /// An origin may disappear after refresh. Never focus a stale recommendation or an
    /// excluded roadmap record; the selected project's heading is the stable fallback.
    static func returnFocus(origin: NavigationFocus?, row: ProjectRowState?, roadmap: Bool) -> NavigationFocus? {
        guard let row else { return nil }
        let heading: NavigationFocus = .projectHeading(row.reference.id)
        guard let origin, let inspection = row.inspection else { return heading }
        switch origin {
        case let .card(id, featureID) where !roadmap && id == row.reference.id:
            return recommendations(row).contains(where: { $0.id == featureID }) ? origin : heading
        case let .roadmap(id, featureID) where roadmap && id == row.reference.id:
            return inspection.featureEnumeration == .complete &&
                inspection.features.contains(where: { $0.id == featureID }) ? origin : heading
        default: return heading
        }
    }

    /// The completion control may vanish after disk reconciliation. Never return to a
    /// different project's card or a disabled/stale control; retained detail keeps its
    /// heading (and Back) even after the Mark complete button is removed.
    static func completionReturnFocus(origin: NavigationFocus, row: ProjectRowState?,
                                      detailVisible: Bool, canComplete: Bool) -> NavigationFocus? {
        guard let row else { return nil }
        let id = row.reference.id
        switch origin {
        case let .cardCompletion(projectID, featureID) where projectID == id:
            return !detailVisible && canComplete && recommendations(row).contains(where: { $0.id == featureID })
                ? origin : .projectHeading(id)
        case let .detailCompletion(projectID, _) where projectID == id:
            return detailVisible ? (canComplete ? origin : .featureHeading) : .projectHeading(id)
        default: return .projectHeading(id)
        }
    }

    static func folderLabel(_ row: ProjectRowState) -> String {
        "Select project \(row.inspection?.manifest?.name ?? row.reference.displayNameHint), \(status(row))"
    }

    static func cardLabel(_ feature: ProjectFeature) -> String {
        "View feature \(feature.title), \(feature.status.rawValue), \(feature.priority.rawValue) priority, \(feature.effort.rawValue) effort"
    }

    static func completionEnabled(_ featureID: String, row: ProjectRowState,
                                  store: ProjectStore, isReconnecting: Bool = false) -> Bool {
        guard !isReconnecting, !row.isRefreshing, !row.isRetainedInspection else { return false }
        switch row.completion {
        case .writing, .undoing, .refreshing: return false
        default: return store.canMarkComplete(featureID, in: row.reference.id)
        }
    }
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

    static func statusSummary(_ counts: FeatureStatusCounts) -> String {
        "Inspected valid features · planned: \(counts.planned) · active: \(counts.active) · blocked: \(counts.blocked) · ready awaiting prerequisites: \(counts.ready) · completed: \(counts.completed)"
    }

    static func unresolvedLabels(_ selection: FeatureSelection, inspection: ProjectInspection) -> [String] {
        let features = Dictionary(uniqueKeysWithValues: inspection.features.map { ($0.id, $0) })
        func label(_ id: String) -> String {
            guard let feature = features[id] else { return ProjectDetailsView.safeLabel(id) }
            return "\(ProjectDetailsView.safeLabel(feature.title)) (\(ProjectDetailsView.safeLabel(id)))"
        }
        return selection.unresolvedDependencies.map { entry in
            let dependencies = entry.dependencyIDs.map { id in
                "\(label(id)) · \(features[id]?.status.rawValue ?? "unavailable")"
            }
            return "\(label(entry.featureID)) awaits: \(dependencies.joined(separator: ", "))"
        }
    }

    static func unavailableGuidance(_ inspection: ProjectInspection?, recovery: ProjectRecovery = .refresh) -> String {
        if recovery == .reconnect {
            return "Folder access is unavailable. Reconnect the saved project folder, then view project details for validation."
        }
        guard let inspection else { return "No current inspection. Refresh to read this folder." }
        if inspection.manifest?.schemaVersion != 1 {
            return "Project manifest missing or unsupported. View project details for validation; repair or upgrade externally, then Refresh."
        }
        return "Feature listing could not be completed. Progress and suggestions are unavailable; view project details for validation, then Refresh."
    }

    static func selectionNoticeText(_ notice: ProjectFeatureSelectionNotice) -> String {
        switch notice.reason {
        case .removed:
            return "Feature \(ProjectDetailsView.safeLabel(notice.featureID)) was removed from this project. Detail closed; Refresh to inspect current work."
        case .validationExcluded:
            return "Feature \(ProjectDetailsView.safeLabel(notice.featureID)) failed validation and was excluded. Detail closed; view project details for validation, repair externally, then Refresh."
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
               store.selectedFeatureContent != nil {
                ProjectFeatureDetailView(row: row, featureID: identity.featureID,
                                         backToRoadmap: detailID == row.reference.id, back: closeFeature,
                                         canMarkComplete: Self.completionEnabled(identity.featureID, row: row,
                                             store: store, isReconnecting: reconnectingID == row.reference.id),
                                         markComplete: {
                                             complete(identity.featureID, in: identity.projectID,
                                                      origin: .detailCompletion(identity.projectID, identity.featureID))
                                         }, navigationFocus: $navigationFocus)
                .onAppear {
                    Task { @MainActor in
                        await Task.yield()
                        if store.selectedFeature == identity { navigationFocus = .featureHeading }
                    }
                }
            } else if let detailID, let row = store.rows.first(where: { $0.reference.id == detailID }) {
                ProjectDetailsView(row: row, back: { self.detailID = nil; restoreFocus(in: detailID, roadmap: false) },
                                   refresh: { store.refresh(detailID) },
                                   viewFeature: { featureID in
                                       featureOrigin = .roadmap(detailID, featureID)
                                       store.selectFeature(featureID, in: detailID)
                                   },
                                   reconnect: { chooseReconnectFolder(for: detailID) },
                                   recoveryMessage: recoveryMessage?.id == detailID ? recoveryMessage?.text : nil,
                                   isReconnecting: reconnectingID == detailID,
                                   navigationFocus: $navigationFocus)
                .onAppear { applyReturnFocus() }
            } else {
                list.onAppear { applyReturnFocus() }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                if let notice = store.selectionNotice, notice.projectID == store.selectedID {
                    Text(Self.selectionNoticeText(notice))
                        .appTypography(.body)
                        .accessibilityIdentifier("project-feature-selection-notice")
                }
                if let row = selectedRow, let state = Self.displayedCompletion(row) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        completionFeedback(row: row, state: state)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppMetrics.horizontalInset)
        }
        .onChange(of: selectedConflict) { _, conflict in
            if let conflict { presentedConflict = conflict }
        }
        .onChange(of: store.selectedID) { _, newID in
            // Reset synchronously with the accepted folder switch, including when two
            // projects happen to use the same feature ID.
            previewSelection = Self.preview(for: newID, selection: .init(), row: selectedRow)?.selection ?? .init()
            presentedConflict = selectedConflict
            pendingCompletionFocus = nil
            pendingReturnFocus = nil
            // A selection switch must not return focus to the previous project.
            featureOrigin = nil
        }
        .onChange(of: previewProjection?.selection) { _, resolved in
            if let resolved { previewSelection = resolved }
        }
        .onChange(of: presentedConflict) { _, conflict in
            if conflict == nil, let pending = pendingCompletionFocus {
                pendingCompletionFocus = nil
                focusCompletion(pending.target, in: pending.projectID)
            }
        }
        .alert("Feature changed on disk", isPresented: Binding(
            get: { presentedConflict != nil && presentedConflict?.projectID == store.selectedID },
            set: { if !$0 { presentedConflict = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                if let conflict = presentedConflict {
                    pendingCompletionFocus = (conflict.projectID, .recovery(conflict.projectID, conflict.featureID))
                }
                presentedConflict = nil
            }
            Button("Refresh") {
                if let conflict = presentedConflict {
                    pendingCompletionFocus = (conflict.projectID, Self.conflictRefreshFocus(
                        projectID: conflict.projectID, selectedFeature: store.selectedFeature,
                        detailAvailable: store.selectedFeatureContent != nil))
                    store.refresh(conflict.projectID)
                }
                presentedConflict = nil
            }
        } message: {
            Text("This feature changed since it was inspected. No newer content was overwritten. Refresh only reads the project; review the current file before choosing another action.")
        }
        .onAppear {
            enter()
            if let resolved = previewProjection?.selection { previewSelection = resolved }
            if let conflict = selectedConflict { presentedConflict = conflict }
        }
        .onChange(of: store.selectedFeature) { old, new in
            if let old, new == nil {
                if store.selectedID == old.projectID {
                    restoreFocus(in: old.projectID, roadmap: detailID == old.projectID)
                }
            }
        }
        .sheet(isPresented: $showingAdd, onDismiss: { addFocused = true }) {
            ProjectAddView(store: store) { showingAdd = false }
        }
        .accessibilityIdentifier("projects-content")
    }

    @ViewBuilder
    private func completionFeedback(row: ProjectRowState, state: ProjectCompletionState) -> some View {
        let id = row.reference.id
        let featureID = state.featureID
        let title = ProjectDetailsView.safeLabel(row.inspection?.features.first { $0.id == featureID }?.title ?? featureID)
        let project = ProjectDetailsView.safeLabel(row.inspection?.manifest?.name ?? row.reference.displayNameHint)
        let message = Self.completionMessage(state, feature: title, project: project)
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            if case .saved = state, let expiry = store.undoExpiration(in: id),
               store.canUndoCompletion(in: id) {
                UndoAffordance(message, undoTitle: Self.undoActionTitle(feature: title, project: project)) {
                    Task { await store.undoCompletion(in: id) }
                }
                .accessibilityIdentifier("project-completion-undo-\(featureID)")
                Text("Undo available until \(expiry.formatted(date: .omitted, time: .standard))")
                    .appTypography(.metadata)
                    .accessibilityIdentifier("project-completion-undo-expiry")
            } else {
                Text(message)
                    .appTypography(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .accessibilityIdentifier("project-completion-status")
                if case .saved = state {
                    Text("Undo unavailable or expired. Refresh to review current project data.")
                        .appTypography(.body)
                        .accessibilityIdentifier("project-completion-expired")
                }
            }
            // A failed attempt at a different feature does not consume the project's
            // earlier verified token. Do not label that token with the failed feature.
            if case .failed = state, store.canUndoCompletion(in: id),
               let undoID = store.undoFeatureID(in: id) {
                let undoTitle = ProjectDetailsView.safeLabel(row.inspection?.features.first {
                    $0.id == undoID
                }?.title ?? undoID)
                UndoAffordance("Completion of \(undoTitle) in \(project) was saved and verified and remains undoable.",
                               undoTitle: Self.undoActionTitle(feature: undoTitle, project: project)) {
                    Task { await store.undoCompletion(in: id) }
                }
                .accessibilityIdentifier("project-completion-previous-undo-\(undoID)")
            }
            if case .undoFailed = state, store.canUndoCompletion(in: id) {
                ActionButton("Retry Undo", variant: .secondary) {
                    Task { await store.undoCompletion(in: id) }
                }
                .accessibilityLabel("Retry Undo for \(title) in \(project)")
                .accessibilityIdentifier("project-completion-retry-undo")
            }
            if let recovery = Self.completionRecovery(state) {
                ActionButton(recovery == .reconnect ? "Reconnect project" : "Refresh project", variant: .secondary) {
                    if recovery == .reconnect { chooseReconnectFolder(for: id) }
                    else { store.refresh(id) }
                }
                .accessibilityLabel("\(recovery == .reconnect ? "Reconnect" : "Refresh") \(project) after completion result for \(title)")
                .focused($navigationFocus, equals: .recovery(id, featureID))
                .accessibilityIdentifier("project-completion-recovery")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-completion-feedback-\(id.uuidString)-\(featureID)")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            PageHeader("Projects") {
                ActionButton("Add project", symbol: "plus", variant: .primary) { showingAdd = true }
                    .focused($addFocused)
                    .accessibilityIdentifier("projects-add")
            }
            if store.loadFailed {
                ErrorBanner(.readFailed)
                ActionButton("Retry projects") { enter() }
                    .accessibilityLabel("Retry loading saved project folders")
                    .accessibilityIdentifier("projects-retry-load")
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
                            .accessibilityLabel(Self.folderLabel(row))
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
                        .accessibilityLabel("Reconnect folder \(row.reference.displayNameHint) to restore access")
                        .accessibilityIdentifier("project-row-reconnect-\(row.reference.id.uuidString)")
                    } else if row.refreshFailure != nil || row.isStale {
                        ActionButton("Refresh \(row.reference.displayNameHint)", variant: .secondary) {
                            store.refresh(row.reference.id)
                        }
                        .accessibilityLabel("Refresh folder \(row.reference.displayNameHint) after a failed or partial read")
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
            .focusable()
            .focused($navigationFocus, equals: .projectHeading(row.reference.id))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("projects-selected")
            Text(Self.status(row))
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityIdentifier("projects-selected-status")
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
            if row.isRetainedInspection {
                recoveryAction(for: row)
                    .accessibilityIdentifier("projects-workspace-unavailable")
            } else if let inspection = row.inspection {
                let selection = FeatureSelector().select(from: inspection)
                if selection.state != .unavailable {
                    SectionHeader("Progress")
                    Text(ProjectDetailsView.progress(inspection))
                        .appTypography(.body)
                        .accessibilityIdentifier("projects-workspace-progress")
                }
                if case let .partial(_, _, excluded) = selection.progress {
                    Text("Partial results · \(excluded) \(excluded == 1 ? "feature file" : "feature files") excluded from counts and suggestions. View project details for validation; repair externally, then Refresh.")
                        .appTypography(.body)
                        .accessibilityIdentifier("projects-workspace-partial")
                }
                switch selection.state {
                case .unavailable:
                    unavailableState(row, guidance: Self.unavailableGuidance(inspection))
                case .candidatesAvailable:
                    if let projection = Self.preview(for: row.reference.id, selection: previewSelection, row: row) {
                        SectionHeader("Next features")
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: AppMetrics.space6) {
                                candidateList(projection, inspection: inspection, projectID: row.reference.id)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let feature = Self.previewFeature(in: projection, row: row),
                                   let candidate = projection.candidates.first(where: { $0.id == feature.id }) {
                                    candidatePreview(feature, candidate: candidate, row: row)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(minWidth: 820)
                            VStack(alignment: .leading, spacing: AppMetrics.space4) {
                                candidateList(projection, inspection: inspection, projectID: row.reference.id)
                                if let feature = Self.previewFeature(in: projection, row: row),
                                   let candidate = projection.candidates.first(where: { $0.id == feature.id }) {
                                    candidatePreview(feature, candidate: candidate, row: row)
                                }
                            }
                        }
                    }
                case .validationExclusions:
                    EmptyState("No validated next features",
                               guidance: "\(inspection.excludedFeaturePaths.count) invalid feature \(inspection.excludedFeaturePaths.count == 1 ? "file was" : "files were") excluded. Excluded files have unknown status and are not counted as completed; view project details for validation, repair externally, then Refresh.")
                        .accessibilityIdentifier("projects-workspace-exclusions")
                case .noFeatures:
                    EmptyState("No features in this project",
                               guidance: "Feature listing completed with no files. Add features externally, then Refresh.")
                        .accessibilityIdentifier("projects-workspace-empty")
                case .allComplete:
                    EmptyState("All features completed",
                               guidance: "Every validated feature is complete. View project details to review the roadmap.")
                        .accessibilityIdentifier("projects-workspace-complete")
                case .noReadyFeatures:
                    noReadyState(selection, inspection: inspection)
                }
            } else if row.isRefreshing {
                LoadingState("Loading selected project")
            } else {
                unavailableState(row, guidance: Self.unavailableGuidance(nil, recovery: row.refreshFailure?.recovery ?? .refresh))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("projects-workspace")
    }

    private func candidateList(_ projection: PreviewProjection, inspection: ProjectInspection,
                               projectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            ForEach(projection.candidates, id: \.id) { candidate in
                if let feature = inspection.features.first(where: { $0.id == candidate.id }) {
                    let selected = projection.selection.featureID == candidate.id
                    let captured = ProjectFeatureIdentity(projectID: projectID, featureID: candidate.id)
                    Button {
                        // Pure browse selection; never routes, reads a file, or writes progress.
                        guard let next = Self.selectingPreview(captured, selectedProjectID: store.selectedID,
                                                               selection: previewSelection, row: selectedRow) else { return }
                        previewSelection = next
                    } label: {
                        VStack(alignment: .leading, spacing: AppMetrics.space1) {
                            Text(feature.title).appTypography(.body)
                            Text("\(feature.priority.rawValue) priority · \(feature.effort.rawValue) effort · \(feature.status.rawValue)")
                                .appTypography(.metadata)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: AppMetrics.preferredTarget, alignment: .leading)
                        .padding(AppMetrics.space3)
                        .background(selected ? AppColors.raisedSurface : AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview feature \(feature.title)")
                    .accessibilityValue("\(selected ? "Selected" : "Not selected") · \(Self.cardMetadata(feature, reason: candidate.reason)) · \(feature.status.rawValue)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("project-feature-choice-\(candidate.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidatePreview(_ feature: ProjectFeature, candidate: FeatureCandidate,
                                  row: ProjectRowState) -> some View {
        let id = row.reference.id
        return VStack(alignment: .leading, spacing: AppMetrics.space3) {
            SectionHeader("Preview")
            Text(feature.title).appTypography(.section)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(feature.status.rawValue.capitalized) · \(Self.cardMetadata(feature, reason: candidate.reason))")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            if let excerpt = Self.previewExcerpt(feature.body) {
                Text(verbatim: excerpt).appTypography(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("project-feature-excerpt")
            }
            // Existing guarded commands remain available until exact command admission
            // and placement are updated in Step 1.2.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space2) { previewActions(feature, row: row, projectID: id) }
                VStack(alignment: .leading, spacing: AppMetrics.space2) {
                    previewActions(feature, row: row, projectID: id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.space4)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
        .accessibilityIdentifier("project-feature-preview-\(feature.id)")
    }

    private func previewActions(_ feature: ProjectFeature, row: ProjectRowState, projectID: UUID) -> some View {
        Group {
            ActionButton("View feature", variant: .primary) {
                guard let current = store.rows.first(where: { $0.reference.id == projectID }),
                      !current.isRetainedInspection else { return }
                featureOrigin = .card(projectID, feature.id)
                store.selectFeature(feature.id, in: projectID)
            }
            .focused($navigationFocus, equals: .card(projectID, feature.id))
            .accessibilityLabel(Self.cardLabel(feature))
            .accessibilityIdentifier("project-feature-open-\(feature.id)")
            ActionButton(ProjectFeatureDetailView.completionTitle(for: feature.id, state: row.completion),
                         isEnabled: Self.completionEnabled(feature.id, row: row, store: store,
                             isReconnecting: reconnectingID == projectID)) {
                complete(feature.id, in: projectID, origin: .cardCompletion(projectID, feature.id))
            }
            .focused($navigationFocus, equals: .cardCompletion(projectID, feature.id))
            .accessibilityLabel(ProjectFeatureDetailView.completionLabel(for: feature, state: row.completion))
            .accessibilityIdentifier("project-feature-complete-\(feature.id)")
        }
    }

    private func noReadyState(_ selection: FeatureSelection, inspection: ProjectInspection) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space3) {
            EmptyState("No ready next features",
                       guidance: "Planned and active work is not suggested; blocked status is an explicit blocker. Any ready work awaiting prerequisites is listed below. View project details for validation and the roadmap.")
            if let counts = selection.statusCounts {
                Text(Self.statusSummary(counts))
                    .appTypography(.body)
                    .accessibilityIdentifier("projects-workspace-status-counts")
            }
            ForEach(Self.unresolvedLabels(selection, inspection: inspection), id: \.self) { label in
                Text(label).appTypography(.body).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("projects-workspace-no-ready")
    }

    private func unavailableState(_ row: ProjectRowState, guidance: String) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space3) {
            recoveryAction(for: row)
                .accessibilityIdentifier("projects-workspace-recovery")
            Text(guidance).appTypography(.body)
            Text("Progress unavailable · View project details for validation and recovery information.")
                .appTypography(.body)
        }
        .accessibilityIdentifier("projects-workspace-unavailable")
    }

    private func recoveryAction(for row: ProjectRowState) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space3) {
            ErrorBanner(.readFailed)
            ActionButton(recoveryTitle(for: row)) { recover(row) }
                .accessibilityLabel("\(recoveryTitle(for: row)) \(row.reference.displayNameHint) to verify project information")
                .accessibilityIdentifier("projects-workspace-recovery-action-\(row.reference.id.uuidString)")
        }
    }

    private func recoveryTitle(for row: ProjectRowState) -> String {
        row.refreshFailure?.recovery == .reconnect ? "Reconnect project" : "Refresh project"
    }

    private func recover(_ row: ProjectRowState) {
        if row.refreshFailure?.recovery == .reconnect {
            chooseReconnectFolder(for: row.reference.id)
        } else {
            store.refresh(row.reference.id)
        }
    }

    private func workspaceActions(for row: ProjectRowState) -> some View {
        Group {
            ActionButton("View project details") {
                detailID = row.reference.id
            }
            .accessibilityLabel("View project details and validated roadmap for \(row.reference.displayNameHint)")
            .accessibilityIdentifier("projects-workspace-details")
            if row.refreshFailure?.recovery == .reconnect {
                ActionButton("Reconnect project") { chooseReconnectFolder(for: row.reference.id) }
                    .disabled(reconnectingID != nil)
                    .accessibilityLabel("Reconnect \(row.reference.displayNameHint) to restore folder access")
                    .accessibilityIdentifier("projects-workspace-reconnect")
            } else {
                ActionButton("Refresh project") { store.refresh(row.reference.id) }
                    .accessibilityLabel("Refresh \(row.reference.displayNameHint) from disk")
                    .accessibilityIdentifier("projects-workspace-refresh")
            }
        }
    }

    private func complete(_ featureID: String, in projectID: UUID, origin: NavigationFocus) {
        Task {
            await store.markComplete(featureID, in: projectID)
            guard store.selectedID == projectID,
                  let row = store.rows.first(where: { $0.reference.id == projectID }) else { return }
            let detailVisible = store.selectedFeature == ProjectFeatureIdentity(projectID: projectID,
                                                                                 featureID: featureID) &&
                store.selectedFeatureContent != nil
            // Do not steal focus if the user navigated away while IO was in flight.
            switch origin {
            case .cardCompletion where detailID != nil || store.selectedFeature != nil: return
            case .detailCompletion where store.selectedFeature !=
                ProjectFeatureIdentity(projectID: projectID, featureID: featureID): return
            default: break
            }
            let target = Self.completionReturnFocus(origin: origin, row: row,
                detailVisible: detailVisible,
                canComplete: Self.completionEnabled(featureID, row: row, store: store,
                                                    isReconnecting: reconnectingID == projectID))
            guard let target else { return }
            if presentedConflict?.projectID == projectID || selectedConflict?.projectID == projectID {
                pendingCompletionFocus = (projectID, target)
            } else {
                focusCompletion(target, in: projectID)
            }
        }
    }

    private func focusCompletion(_ target: NavigationFocus, in projectID: UUID) {
        Task { @MainActor in
            await Task.yield()
            guard store.selectedID == projectID, presentedConflict == nil else { return }
            // Refresh can remove the detail between dismissal and this deferred focus.
            // Never focus a heading that has disappeared from the active branch.
            if target == .featureHeading {
                navigationFocus = Self.conflictRefreshFocus(projectID: projectID,
                    selectedFeature: store.selectedFeature, detailAvailable: store.selectedFeatureContent != nil)
            } else {
                navigationFocus = target
            }
        }
    }

    private func closeFeature() {
        store.closeFeature()
        // The selection observer also handles automatic closure after deletion/validation.
    }

    private func restoreFocus(in projectID: UUID, roadmap: Bool) {
        let row = store.rows.first { $0.reference.id == projectID }
        pendingReturnFocus = Self.returnFocus(origin: featureOrigin, row: row, roadmap: roadmap)
        featureOrigin = nil
        // Refresh publication can remove detail before the destination's onAppear runs.
        // Also retry when that branch has already appeared in the same update cycle.
        Task { @MainActor in
            await Task.yield()
            applyReturnFocus()
        }
    }

    private func applyReturnFocus() {
        guard let target = pendingReturnFocus else { return }
        pendingReturnFocus = nil
        // Focus only after the destination branch has appeared.
        Task { @MainActor in
            await Task.yield()
            navigationFocus = target
        }
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
