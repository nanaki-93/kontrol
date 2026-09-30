import AppKit
import SwiftUI

/// Per-client presentation only. The graph-owned ProjectStore remains the sole
/// reference/IO owner. Confirmation values never follow subsequent publications.
@MainActor
final class ProjectFoldersSettingsState: ObservableObject {
    struct Confirmation: Equatable {
        let id: UUID
        let revision: UUID
        let name: String

        init(_ reference: ProjectReferenceSnapshot) {
            id = reference.id
            revision = reference.revision
            name = reference.displayNameHint
        }

        var title: String { "Remove \(name)?" }
        var message: String {
            "Disconnect \(name) from Kontrol. Project files remain on disk, including .kontrol and Git files. Only the local reference and its transient app state are removed. Re-adding requires selecting the folder again."
        }
    }

    enum Outcome: Equatable {
        case canceled(String), removed(String), stale(String), busy, failed(String), unavailable, reviewed

        var message: String {
            switch self {
            case let .canceled(name): return "Removal canceled for \(name). Nothing was removed."
            case let .removed(name): return "\(name) removed from Kontrol. Project files remain on disk. Re-add using Add folder and select the folder again."
            case let .stale(name): return "\(name) changed or was already removed. Nothing was removed by this attempt. Reload & review folders, then confirm the current reference separately."
            case .busy: return "Project operation in progress. Nothing was removed or queued. Wait for it to finish, then review the folder and confirm again."
            case let .failed(name): return "\(name) was not removed. The local reference is unchanged. Review the folder and confirm again to retry."
            case .unavailable: return "Saved folder references could not be loaded. Existing rows remain available. Reload & review folders to retry; no folder access is needed."
            case .reviewed: return "Local references reloaded. Review the current folder before choosing Remove and confirming again. No project files were inspected."
            }
        }
    }

    let store: ProjectStore
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var outcome: Outcome?
    @Published private(set) var requiresReview = false

    init(store: ProjectStore) { self.store = store }

    func load() {
        do {
            try store.loadReferencesIfNeeded()
            if !store.loadFailed, outcome == .unavailable { outcome = nil }
        } catch { outcome = .unavailable }
    }

    func review() {
        // A reload never submits a deletion or rebases an open confirmation.
        confirmation = nil
        do {
            try store.reloadReferences()
            requiresReview = false
            outcome = .reviewed
        } catch ProjectStoreError.busy { outcome = .busy }
        catch { outcome = .unavailable }
    }

    func requestRemoval(_ id: UUID) {
        guard !requiresReview, confirmation == nil, !store.loadFailed,
              let reference = store.rows.first(where: { $0.reference.id == id })?.reference else { return }
        confirmation = Confirmation(reference)
        outcome = nil
    }

    func cancel() {
        guard let target = confirmation else { return }
        confirmation = nil
        outcome = .canceled(target.name)
    }

    func confirm() {
        guard let target = confirmation else { return }
        confirmation = nil
        do {
            try store.disconnect(id: target.id, expectedRevision: target.revision)
            outcome = .removed(target.name)
        } catch ProjectReferencePersistenceError.staleRevision {
            requiresReview = true
            outcome = .stale(target.name)
        } catch ProjectReferencePersistenceError.notFound {
            requiresReview = true
            outcome = .stale(target.name)
        } catch ProjectStoreError.busy { outcome = .busy }
        catch { outcome = .failed(target.name) }
    }
}

/// Embedded in the hub's single scroll document. Add uses the existing preview
/// sheet; Reconnect uses its folder-only picker and the shared store's validation.
struct ProjectFoldersSettingsView: View {
    @ObservedObject var store: ProjectStore
    @StateObject private var management: ProjectFoldersSettingsState
    @State private var showingAdd = false
    @State private var showingRemoval = false
    @State private var reconnectPicker: NSOpenPanel?
    @State private var reconnectingID: UUID?
    @State private var reconnectWork: Task<Void, Never>?
    @State private var reconnectFeedback: String?
    @State private var presented = false

    init(store: ProjectStore, management: ProjectFoldersSettingsState? = nil) {
        self.store = store
        _management = StateObject(wrappedValue: management ?? ProjectFoldersSettingsState(store: store))
    }

    static func summary(_ store: ProjectStore) -> String {
        guard store.isLoaded, !store.loadFailed else { return "Project folders: saved references unavailable" }
        return "Project folders: \(store.rows.count) saved \(store.rows.count == 1 ? "reference" : "references")"
    }

    static func status(_ row: ProjectRowState) -> String {
        if let failure = row.refreshFailure {
            return failure.recovery == .reconnect
                ? "Folder access unavailable · saved local reference still exists"
                : "Project read unavailable · saved local reference still exists"
        }
        return row.inspection == nil ? "Saved local reference · folder not inspected here" : ProjectsView.status(row)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            SectionHeader("Project folders")
            Text("List and remove local references without opening project folders. Removing a reference does not delete or change project files. Add and Reconnect require choosing a folder.")
                .appTypography(.body)
            ActionButton("Add folder", symbol: "plus", variant: .primary) { showingAdd = true }
                .accessibilityIdentifier("settings-folders-add")
            ActionButton("Reload & review folders") { management.review() }
                .accessibilityIdentifier("settings-folders-reload")
            if store.loadFailed {
                Label("Saved folder references unavailable · reload to retry", systemImage: "exclamationmark.triangle")
                    .appTypography(.body)
                    .accessibilityIdentifier("settings-folders-unavailable")
            }
            if let outcome = management.outcome {
                Label(outcome.message, systemImage: outcomeSymbol(outcome))
                    .appTypography(.body)
                    .accessibilityIdentifier("settings-folders-result")
            }
            if let reconnectFeedback {
                Text(reconnectFeedback).appTypography(.body)
                    .accessibilityIdentifier("settings-folders-reconnect-result")
            }
            if store.isLoaded && !store.loadFailed && store.rows.isEmpty {
                EmptyState("No project folders connected", guidance: "Add a folder using the picker to authorize access. Files remain on disk after removal.")
                    .accessibilityIdentifier("settings-folders-empty")
            }
            ForEach(ProjectsView.ordered(store.rows), id: \.reference.id) { row in
                VStack(alignment: .leading, spacing: AppMetrics.space2) {
                    Text(row.reference.displayNameHint).appTypography(.section)
                    Text(Self.status(row)).appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                    ActionButton("Reconnect folder") { chooseReconnectFolder(row.reference.id) }
                        .disabled(reconnectPicker != nil || reconnectingID != nil)
                        .accessibilityLabel("Reconnect folder \(row.reference.displayNameHint)")
                        .accessibilityIdentifier("settings-folder-reconnect-\(row.reference.id.uuidString)")
                    ActionButton("Remove…", variant: .destructive) {
                        management.requestRemoval(row.reference.id)
                        showingRemoval = management.confirmation != nil
                    }
                    .disabled(management.requiresReview || store.loadFailed)
                    .accessibilityLabel("Remove \(row.reference.displayNameHint) from Kontrol")
                    .accessibilityIdentifier("settings-folder-remove-\(row.reference.id.uuidString)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppMetrics.space4)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppMetrics.mediumRadius))
                .accessibilityElement(children: .contain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .confirmationAffordance(isPresented: $showingRemoval,
            title: management.confirmation?.title ?? "Remove folder?",
            message: management.confirmation?.message,
            confirmTitle: "Remove from Kontrol", cancelTitle: "Cancel", isDestructive: true) {
                management.confirm()
            }
        .onChange(of: showingRemoval) { _, showing in
            // The native confirm action consumes the snapshot first. Cancel/Escape
            // only discard it; neither can invoke disconnect.
            if !showing { management.cancel() }
        }
        .sheet(isPresented: $showingAdd) {
            ProjectAddView(store: store) { showingAdd = false }
        }
        .onAppear { presented = true; management.load() }
        .onDisappear {
            presented = false
            management.cancel()
            reconnectPicker?.cancel(nil)
            reconnectWork?.cancel()
            if let reconnectingID { store.cancelReconnect(reconnectingID) }
        }
        .accessibilityIdentifier("settings-folders-content")
    }

    private func outcomeSymbol(_ outcome: ProjectFoldersSettingsState.Outcome) -> String {
        switch outcome {
        case .removed, .reviewed: return "checkmark.circle"
        case .canceled: return "info.circle"
        default: return "exclamationmark.triangle"
        }
    }

    private func chooseReconnectFolder(_ id: UUID) {
        guard reconnectPicker == nil, reconnectingID == nil else { return }
        let panel = ProjectAddView.configuredPicker()
        panel.title = "Reconnect project folder"
        panel.prompt = "Reconnect folder"
        panel.message = "Choose the original project folder. Its manifest ID must match the saved reference."
        reconnectPicker = panel
        panel.begin { response in
            reconnectPicker = nil
            guard presented else { return }
            guard response == .OK, let folder = panel.url else {
                reconnectFeedback = "Reconnect canceled. The saved reference is unchanged."
                return
            }
            reconnectingID = id
            reconnectFeedback = "Reconnecting selected folder…"
            reconnectWork = Task {
                do {
                    _ = try await store.reconnect(id, to: folder)
                    reconnectFeedback = "Folder reconnected. Project inspection requested."
                } catch is CancellationError {
                    reconnectFeedback = "Reconnect canceled. No restored access is claimed."
                } catch ProjectStoreError.manifestMismatch {
                    reconnectFeedback = "Different project selected. The saved reference is unchanged; choose the original folder or add this folder separately."
                } catch ProjectStoreError.invalidReconnect {
                    reconnectFeedback = "Selected project is invalid or unsupported. The saved reference is unchanged; repair it externally and retry Reconnect."
                } catch ProjectStoreError.busy {
                    reconnectFeedback = "Project operation in progress. Reconnect was not queued; wait and try again."
                } catch {
                    reconnectFeedback = "Project not reconnected. The saved reference is unchanged; retry Reconnect."
                }
                reconnectingID = nil
                reconnectWork = nil
            }
        }
    }
}
