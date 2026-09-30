import SwiftUI

/// The store owns committed values; this editor owns its input and revision for
/// its entire lifetime. Publications from another window never replace the draft.
struct GeneralPreferencesView: View {
    @ObservedObject var store: AppPreferencesStore
    @StateObject private var editor: AppPreferencesEditorDraft
    @State private var durationChoice: String
    @State private var customMinutes: String
    let onClose: (_ saved: Bool) -> Void

    init(store: AppPreferencesStore, onClose: @escaping (Bool) -> Void) {
        self.store = store
        self.onClose = onClose
        let minutes = String((store.editableSnapshot?.preferences ?? .defaults).focusDefaultMinutes)
        let preset = ["15", "25", "50"].contains(minutes)
        _durationChoice = State(initialValue: preset ? minutes : "custom")
        _customMinutes = State(initialValue: preset ? "" : minutes)
        _editor = StateObject(wrappedValue: AppPreferencesEditorDraft(snapshot: store.editableSnapshot))
    }

    private var needsReview: Bool {
        editor.baseline == nil || editor.error == .preferences(.staleRevision) ||
            (store.editableSnapshot != nil && editor.baseline != store.editableSnapshot)
    }

    static func summary(_ preferences: AppPreferences) -> String {
        "\(preferences.focusDefaultMinutes) minutes · \(preferences.textSize == .large ? "Large text" : "System text") · \(preferences.reduceMotion == .reduce ? "Reduced motion" : "System motion")"
    }

    static func errorMessage(_ error: AppPreferencesEditorError) -> String {
        switch error {
        case .preferences(.invalidFocusDuration(.durationOverflow)):
            return "Duration is too large. Enter whole minutes that can be converted to seconds. Your draft has not been saved."
        case .preferences(.invalidFocusDuration):
            return "Enter positive whole minutes using digits 0–9, without signs, fractions or exponents. Your draft has not been saved."
        case .preferences(.staleRevision):
            return "Preferences changed elsewhere. Your draft has not been saved. Review the latest saved values before saving again."
        case .preferencesUnavailable:
            return "Saved preferences are unavailable. Retry loading and review before saving. Your input is retained."
        case .preferences(.unsupportedPayloadVersion), .preferences(.unsupportedTextSize),
             .preferences(.unsupportedReduceMotion):
            return "Saved preferences use an unsupported format. Try a compatible app version or retry loading. Your input is retained; stored data has not been replaced."
        case .preferences(.invalidStoredData), .preferences(.duplicateRecords):
            return "Saved preferences could not be read. Retry loading without resetting stored data. Your input is retained."
        default:
            return "Preferences could not be saved or loaded. Your draft and previously saved values are retained. Try again."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text("General & appearance")
                .appTypography(.section)
                .accessibilityAddTraits(.isHeader)
            Text("Changes apply only after Save.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)

            Text("Focus default").appTypography(.section).accessibilityAddTraits(.isHeader)
            responsivePicker("Duration", selection: Binding(
                get: { durationChoice },
                set: {
                    durationChoice = $0
                    editor.draft.focusDefaultMinutes = $0 == "custom" ? customMinutes : $0
                }),
                options: [("15 minutes", "15"), ("25 minutes", "25"), ("50 minutes", "50"), ("Custom", "custom")])
                .accessibilityIdentifier("preferences-duration")
            if durationChoice == "custom" {
                TextField("Custom minutes", text: Binding(
                    get: { editor.draft.focusDefaultMinutes },
                    set: { customMinutes = $0; editor.draft.focusDefaultMinutes = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .appTypography(.body)
                    .accessibilityLabel("Custom focus default in minutes")
                    .accessibilityIdentifier("preferences-custom-minutes")
            }
            Text("New default-following ready drafts update after Save. Explicit drafts and existing sessions stay unchanged.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preferences-focus-guidance")

            Text("Appearance").appTypography(.section).accessibilityAddTraits(.isHeader)
            Text("Black / Red Terminal · fixed theme")
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
            responsivePicker("Text size", selection: $editor.draft.textSize,
                          options: [("System", .system), ("Large · at least 130%", .large)])
                .accessibilityIdentifier("preferences-text-size")
            responsivePicker("Motion", selection: $editor.draft.reduceMotion,
                          options: [("System", .system), ("Reduce", .reduce)])
                .accessibilityIdentifier("preferences-motion")
            Text("Large never shrinks a larger system size. System reduced motion always remains respected.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preferences-appearance-guidance")

            if case .failed(let error) = store.state {
                failure(Self.errorMessage(.preferences(error)))
                reviewAction("Retry loading & review")
            } else {
                if let error = editor.error { failure(Self.errorMessage(error)) }
                if needsReview {
                    if editor.error != .preferences(.staleRevision) {
                        failure("Preferences changed or need loading. Your input is retained. Review the latest saved values before saving.")
                    }
                    reviewAction("Review latest saved values")
                }
            }
            if let latest = store.editableSnapshot {
                Text("Latest saved: \(Self.summary(latest.preferences))")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("preferences-latest-saved")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space2) { editorActions }
                VStack(alignment: .leading, spacing: AppMetrics.space2) { editorActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("general-preferences-editor")
    }

    /// Measure ideal label/control widths before choosing a row. Enlarged native
    /// popup titles must not be squeezed beside their labels into ellipses.
    private func responsivePicker<Value: Hashable>(_ title: String, selection: Binding<Value>,
                                                   options: [(String, Value)]) -> some View {
        ViewThatFits(in: .horizontal) {
            AppMenuPicker(title, selection: selection, options: options)
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                Text(title)
                AppMenuPicker(title, selection: selection, options: options, showsLabel: false)
            }
        }
    }

    @ViewBuilder
    private var editorActions: some View {
        ActionButton("Cancel") {
            editor.cancel()
            onClose(false)
        }
        .accessibilityIdentifier("preferences-cancel")
        ActionButton("Save", variant: .primary, isEnabled: store.state == .loaded && !needsReview) {
            do {
                try editor.save(using: store)
                onClose(true)
            } catch { /* The editor retains the draft and publishes the actionable error. */ }
        }
        .accessibilityIdentifier("preferences-save")
    }

    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .appTypography(.body)
            .foregroundStyle(AppColors.error)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("preferences-error")
    }

    private func reviewAction(_ title: String) -> some View {
        ActionButton(title) {
            do { try editor.reviewLatest(using: store) }
            catch { /* Read failure never authorizes a save or discards input. */ }
        }
        .accessibilityIdentifier("preferences-review")
    }
}
