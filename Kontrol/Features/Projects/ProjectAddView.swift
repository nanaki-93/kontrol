import AppKit
import SwiftUI

/// The picker returns a transient folder URL. No project files or reference are written
/// until the user explicitly confirms a current, eligible inspection.
struct ProjectAddView: View {
    @ObservedObject var store: ProjectStore
    let close: () -> Void
    @State private var selectedFolder: URL?
    @State private var isPicking = false
    @State private var presented = false
    @State private var picker: NSOpenPanel?
    @State private var isWorking = false
    @State private var failure: String?
    @State private var work: Task<Void, Never>?
    @FocusState private var chooseFocused: Bool

    static func configuredPicker() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose project folder"
        panel.prompt = "Choose folder"
        panel.message = "Select the folder containing .kontrol/project.yaml. No files will be changed."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel
    }

    static func summary(_ inspection: ProjectInspection) -> String {
        let errors = inspection.diagnostics.filter { $0.severity == .error }.count
        if errors > 0 { return "Validation: \(errors) \(errors == 1 ? "issue" : "issues") · Project cannot be added" }
        guard inspection.manifest?.schemaVersion == 1 else { return "No supported manifest · Project cannot be added" }
        if inspection.featureEnumeration == .failed { return "Feature listing incomplete · Project cannot be added" }
        switch inspection.featureCount {
        case let .complete(completed, total): return "Valid · \(completed) of \(total) features completed"
        case let .partial(completed, total, excluded):
            return "Partial: \(completed) of \(total) valid features · \(excluded) files excluded · Project cannot be added"
        case .unavailable: return "Validation incomplete · Project cannot be added"
        }
    }

    private var currentPreview: ProjectAddPreview? {
        guard let preview = store.preview, preview.folder == selectedFolder else { return nil }
        return preview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.space4) {
                PageHeader("Add project")
                Text("Choose a local project folder. Preview its files before adding a reference; Kontrol will not create or change .kontrol files.")
                    .appTypography(.body)
                if let folder = selectedFolder {
                    Text("Selected location: \(folder.path)")
                        .appTypography(.body)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("project-add-location")
                    if let preview = currentPreview {
                        Text("Manifest: .kontrol/project.yaml")
                            .appTypography(.body)
                        if let manifest = preview.inspection.manifest {
                            Text("Discovered: \(manifest.name) · ID: \(manifest.id)")
                                .appTypography(.body)
                                .textSelection(.enabled)
                        } else {
                            Text("No supported project manifest discovered")
                                .appTypography(.body)
                        }
                        Text(Self.summary(preview.inspection))
                            .appTypography(.body)
                            .accessibilityIdentifier("project-add-validation")
                        ForEach(Array(preview.inspection.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text("\(diagnostic.relativePath): \(diagnostic.code.rawValue)\(diagnostic.line.map { " · line \($0)" } ?? "")")
                                .appTypography(.body)
                                .textSelection(.enabled)
                        }
                    } else if isWorking {
                        LoadingState("Inspecting selected folder")
                    } else {
                        Text("Inspection unavailable. Refresh or choose another folder.")
                            .appTypography(.body)
                    }
                } else {
                    Text("No folder selected")
                        .appTypography(.body)
                }
                if let message = failure ?? store.addMessage {
                    Text(message)
                        .appTypography(.body)
                        .accessibilityIdentifier("project-add-error")
                }
                HStack(spacing: AppMetrics.space4) {
                    ActionButton(selectedFolder == nil ? "Choose folder" : "Choose another folder", variant: .secondary) {
                        chooseFolder()
                    }
                    .disabled(isPicking || isWorking)
                    .focused($chooseFocused)
                    .accessibilityIdentifier("project-add-choose")
                    if selectedFolder != nil {
                        ActionButton("Refresh preview", variant: .secondary) { inspectSelection() }
                            .disabled(isPicking || isWorking)
                            .accessibilityIdentifier("project-add-refresh")
                    }
                    ActionButton("Cancel", variant: .secondary) { dismiss() }
                        .accessibilityIdentifier("project-add-cancel")
                    ActionButton("Add project", variant: .primary) { add() }
                        .disabled(isPicking || isWorking || currentPreview?.canAdd != true)
                        .accessibilityIdentifier("project-add-confirm")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppMetrics.space8)
        }
        .frame(minWidth: 540, minHeight: 320)
        .onAppear { presented = true; chooseFocused = true }
        .onDisappear {
            presented = false
            picker?.cancel(nil)
            work?.cancel()
            store.cancelAdd()
        }
    }

    private func dismiss() {
        work?.cancel()
        store.cancelAdd()
        close()
    }

    private func chooseFolder() {
        guard !isPicking && !isWorking else { return }
        isPicking = true
        let panel = Self.configuredPicker()
        picker = panel
        // Cancellation is deliberately a no-op on the store: not even a preview is requested.
        panel.begin { response in
            picker = nil
            isPicking = false
            guard presented else { return }
            chooseFocused = true
            guard response == .OK, let folder = panel.url else { return }
            work?.cancel()
            store.cancelAdd()
            selectedFolder = folder
            inspectSelection()
        }
    }

    private func inspectSelection() {
        guard let folder = selectedFolder, !isWorking else { return }
        isWorking = true
        failure = nil
        work = Task {
            do { _ = try await store.previewFolder(folder) }
            catch is CancellationError { }
            catch { failure = "Could not inspect this folder. Choose another folder or try Refresh preview." }
            isWorking = false
        }
    }

    private func add() {
        guard !isWorking, currentPreview?.canAdd == true else { return }
        isWorking = true
        failure = nil
        work = Task {
            do {
                _ = try await store.addPreviewedProject()
                close()
            } catch is CancellationError { }
            catch { failure = store.addMessage ?? "Project not added. Refresh preview or choose another folder." }
            isWorking = false
        }
    }
}
