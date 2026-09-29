import SwiftUI

/// The same app-owned store is observed by the main destination and native Settings.
/// Only this view holds temporary key input; it never reads a saved key back into a field.
struct AISettingsView: View {
    @ObservedObject var store: AISettingsStore
    @State private var editing = false
    @State private var model = "gpt-4o-mini"
    @State private var key = ""
    @State private var editRevision: UUID?
    @State private var actionError: String?
    @State private var connectionOwner: UUID?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case model, key, edit }
    private let models = ["gpt-4o-mini", "gpt-4o-mini-2024-07-18", "gpt-4o-2024-08-06"]

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text("AI lessons")
                .appTypography(.section)
                .accessibilityAddTraits(.isHeader)
            Text("Optional OpenAI generation. Saving a key does not enable AI or contact OpenAI. Generated lessons already saved remain available offline.")
                .appTypography(.body)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(store.presentation.enabled ? "AI lessons: On" : "AI lessons: Off")
                .appTypography(.body)
                .accessibilityIdentifier("ai-enabled-status")
            Text("Provider: OpenAI")
                .appTypography(.body)
            Text("Model: \(store.presentation.modelID ?? "Not configured")")
                .appTypography(.body)
            Text(Self.credentialMessage(store.credentialStatus))
                .appTypography(.body)
                .accessibilityIdentifier("ai-key-status")

            if editing {
                VStack(alignment: .leading, spacing: AppMetrics.space3) {
                    Text("Provider: OpenAI (only supported provider)")
                        .appTypography(.metadata)
                    Picker("Model", selection: $model) {
                        if !models.contains(model) {
                            Text("Unsupported saved model — choose another").tag(model)
                        }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityLabel("OpenAI model")
                    .focused($focusedField, equals: .model)
                    SecureField("New API key", text: $key)
                        .textContentType(.password)
                        .accessibilityLabel("New OpenAI API key")
                        .focused($focusedField, equals: .key)
                    Text("Leave the key blank to keep the saved key. A replacement is stored on this device only.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: AppMetrics.space2) {
                        ActionButton("Save", variant: .primary, isEnabled: models.contains(model)) { save() }
                            .accessibilityIdentifier("ai-save")
                        ActionButton("Cancel") { cancelEdit() }
                            .accessibilityIdentifier("ai-cancel")
                    }
                }
            } else {
                ActionButton(store.presentation.modelID == nil ? "Configure AI lessons" : "Edit configuration") {
                    editRevision = store.presentation.revision
                    model = store.presentation.modelID ?? "gpt-4o-mini"
                    actionError = nil
                    editing = true
                    focusedField = .model
                }
                .focused($focusedField, equals: .edit)
                .accessibilityIdentifier("ai-edit")
            }

            if let message = actionError ?? store.error.map(Self.errorMessage) {
                Text(message)
                    .appTypography(.body)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai-settings-error")
            }
            if store.error == .staleRevision {
                ActionButton("Reload settings") {
                    key = ""
                    editing = false
                    actionError = nil
                    store.refresh()
                    focusedField = .edit
                }
                .accessibilityIdentifier("ai-reload")
            }
            if store.error == .stagedCleanupFailed || store.error == .credentialFailure {
                ActionButton("Retry key cleanup") { perform { try store.retryCleanup() } }
                    .accessibilityIdentifier("ai-retry-cleanup")
            }

            HStack(spacing: AppMetrics.space2) {
                if store.presentation.enabled {
                    ActionButton("Disable AI lessons") {
                        perform { try store.disable(expectedRevision: store.presentation.revision) }
                    }
                    .accessibilityIdentifier("ai-disable")
                } else {
                    ActionButton("Enable AI lessons", variant: .primary,
                                 isEnabled: !editing && canUseKey) {
                        perform { try store.enable(expectedRevision: store.presentation.revision) }
                    }
                    .accessibilityIdentifier("ai-enable")
                }
                ActionButton("Test connection", isEnabled: !editing && canUseKey && !store.operationGate.isBusy,
                             isBusy: store.connectionStatus == .testing) { testConnection() }
                    .accessibilityIdentifier("ai-test-connection")
            }
            if !canUseKey {
                Text("Enable and Test connection require a supported model and a readable saved key.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.connectionMessage(store.connectionStatus))
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ai-connection-status")

            if store.presentation.hasCredential {
                ActionButton(store.error == .removalFailed || store.error == .removalFinalizationFailed
                             ? "Retry Remove key" : "Remove key", variant: .destructive) {
                    perform { try store.removeKey(expectedRevision: store.presentation.revision) }
                }
                .accessibilityIdentifier("ai-remove-key")
                Text("Removing a key disables AI. Saved lessons are not deleted.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.space4)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppMetrics.mediumRadius))
        .onChange(of: store.presentation.revision) { _, revision in
            if !editing { model = store.presentation.modelID ?? "gpt-4o-mini"; editRevision = revision }
        }
        .onDisappear {
            key = ""
            editing = false
            if let connectionOwner { store.cancelConnection(owner: connectionOwner) }
            connectionOwner = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-settings")
    }

    private var canUseKey: Bool {
        store.credentialStatus == .available &&
        store.presentation.modelID.map { models.contains($0) } == true
    }

    private func save() {
        // No secret is published to the store; clear even when Keychain or disk fails.
        let credential = key.isEmpty ? nil : Data(key.utf8)
        key = ""
        perform {
            try store.saveConfiguration(modelID: model, credential: credential, expectedRevision: editRevision)
        }
        if actionError == nil {
            editing = false
            focusedField = .edit
        }
    }

    private func cancelEdit() {
        key = ""
        editing = false
        actionError = nil
        focusedField = .edit
    }

    private func perform(_ action: () throws -> Void) {
        actionError = nil
        do { try action() }
        catch { actionError = Self.errorMessage(error) }
    }

    private func testConnection() {
        let owner = UUID()
        connectionOwner = owner
        actionError = nil
        Task {
            do { try await store.testConnection(owner: owner) }
            catch let error as LessonGenerationError where error == .cancelled { /* Dismissal is not a failure. */ }
            catch is LessonGenerationError { /* The published sanitized connection status describes this failure. */ }
            catch { actionError = Self.errorMessage(error) }
            if connectionOwner == owner { connectionOwner = nil }
        }
    }

    static func credentialMessage(_ status: AICredentialStatus) -> String {
        switch status {
        case .notConfigured: "Key: Not saved"
        case .available: "Key: Saved on this device (hidden)"
        case .missing: "Key: Missing from this device — replace or remove the reference"
        case .inaccessible: "Key: Unavailable — unlock Keychain and try again"
        }
    }

    static func connectionMessage(_ status: AIConnectionStatus) -> String {
        switch status {
        case .notTested: "Connection: Not tested. Testing is optional and does not generate a lesson."
        case .testing: "Connection: Testing authentication and model availability…"
        case .modelAvailable: "Connection: Authentication and model availability confirmed; inference access is not guaranteed."
        case .failed(let error): "Connection: \(connectionFailure(error))"
        }
    }

    private static func connectionFailure(_ error: LessonGenerationError) -> String {
        switch error {
        case .authentication, .authorization: "Authentication or model access was denied. Check the key and model, then test again."
        case .offline: "Offline. Check your connection, then test again."
        case .timeout: "Timed out. Test again when ready."
        case .rateLimited: "Rate limited. Test again later."
        default: "Could not confirm model availability. Check the connection and test again."
        }
    }

    static func errorMessage(_ error: Error) -> String {
        guard let error = error as? AISettingsStoreError else { return "Connection could not be confirmed. No settings were changed." }
        return switch error {
        case .staleRevision: "Settings changed in another window. Reload settings before editing again."
        case .invalidConfiguration: "Choose a supported model and save a key before enabling or testing."
        case .missingCredential: "The saved key is missing. Save a new key or remove the old reference."
        case .inaccessibleCredential: "Keychain is unavailable. Unlock it and try again."
        case .storageFailure: "Configuration not saved. Check local storage and try again; prior settings remain in use."
        case .credentialFailure: "Keychain operation failed. Retry key cleanup or try again."
        case .stagedCleanupFailed: "Configuration not saved; temporary key cleanup failed. Retry key cleanup."
        case .removalFailed: "Key removal failed. AI is disabled, but the key is still saved. Retry Remove key."
        case .removalFinalizationFailed: "Key deleted but removal could not be finalized. AI is disabled; retry Remove key."
        case .connectionInProgress: "An AI operation is already running. Try again after it finishes."
        }
    }
}
