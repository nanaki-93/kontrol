import SwiftUI

/// The store owns committed values; this editor owns its input and revision for
/// its entire lifetime. Publications from another window never replace the draft.
struct GeneralPreferencesView: View {
    @ObservedObject var store: AppPreferencesStore
    @StateObject private var editor: AppPreferencesEditorDraft
    @State private var durationChoice: String
    @State private var customMinutes: String
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case duration, custom, textSize, motion, review, cancel, save }

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
            responsivePicker("Duration", field: .duration, selection: Binding(
                get: { durationChoice },
                set: {
                    durationChoice = $0
                    editor.draft.focusDefaultMinutes = $0 == "custom" ? customMinutes : $0
                    if $0 == "custom" { focusedField = .custom }
                }),
                options: [("15 minutes", "15"), ("25 minutes", "25"), ("50 minutes", "50"), ("Custom", "custom")])
                .accessibilityIdentifier("preferences-duration")
            if durationChoice == "custom" {
                TextField("Custom minutes", text: Binding(
                    get: { editor.draft.focusDefaultMinutes },
                    set: { customMinutes = $0; editor.draft.focusDefaultMinutes = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .appTypography(.body)
                    .frame(minHeight: AppMetrics.minimumTarget)
                    .focused($focusedField, equals: .custom)
                    .accessibilityHint(editor.error.map(Self.errorMessage) ?? "Positive whole minutes using digits 0–9")
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
            responsivePicker("Text size", field: .textSize, selection: $editor.draft.textSize,
                          options: [("System", .system), ("Large · at least 130%", .large)])
                .accessibilityIdentifier("preferences-text-size")
            responsivePicker("Motion", field: .motion, selection: $editor.draft.reduceMotion,
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
        .onAppear { focusedField = .duration }
        .onChange(of: needsReview) { _, requiresReview in
            // A cross-window save can disable the currently focused Save button.
            if requiresReview && focusedField == .save { focusedField = .review }
        }
    }

    /// Measure ideal label/control widths before choosing a row. Enlarged native
    /// popup titles must not be squeezed beside their labels into ellipses.
    private func responsivePicker<Value: Hashable>(_ title: String, field: Field, selection: Binding<Value>,
                                                   options: [(String, Value)]) -> some View {
        let focus = Binding(get: { focusedField == field }, set: { if $0 { focusedField = field } })
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                PreferencesPopup(title: title, selection: selection, options: options, focused: focus)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                Text(title)
                PreferencesPopup(title: title, selection: selection, options: options, focused: focus)
            }
        }
    }

    @ViewBuilder
    private var editorActions: some View {
        ActionButton("Cancel") {
            editor.cancel()
            onClose(false)
        }
        .keyboardShortcut(.cancelAction)
        .focused($focusedField, equals: .cancel)
        .accessibilityHint("Discard only this editor’s unsaved preferences")
        .accessibilityIdentifier("preferences-cancel")
        ActionButton("Save", variant: .primary, isEnabled: store.state == .loaded && !needsReview) {
            do {
                try editor.save(using: store)
                onClose(true)
            } catch {
                // Put the keyboard at the recovery step, never on a vanished or
                // disabled action. The error remains text + icon, not color alone.
                if needsReview || store.state != .loaded { focusedField = .review }
                else if case .preferences(.invalidFocusDuration) = editor.error { focusedField = .custom }
                else { focusedField = .save }
            }
        }
        .keyboardShortcut("s", modifiers: .command)
        .focused($focusedField, equals: .save)
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
            do {
                try editor.reviewLatest(using: store)
                // Review removes itself. Preserve all input and return to a
                // surviving control; Save is still a separate explicit action.
                focusedField = .duration
            } catch { focusedField = .review }
        }
        .focused($focusedField, equals: .review)
        .accessibilityHint("Keep your draft and read the latest saved revision; this does not save")
        .accessibilityIdentifier("preferences-review")
    }
}

/// The general editor needs a real 32-point native hit target and explicit
/// first-responder handoff. A frame around AppMenuPicker's HStack does not enlarge
/// its native popup, and a SwiftUI focus binding alone cannot focus that HStack.
/// Keep the same typography/menu semantics as AppMenuPicker, scoped to this form.
private struct PreferencesPopup<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    @Binding var focused: Bool
    @Environment(\.dynamicTypeSize) private var systemSize
    @Environment(\.appAccessibilityPreferences) private var effective
    @Environment(\.isEnabled) private var isEnabled

    final class Button: NSPopUpButton {
        var didFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { didFocus?() }
            return accepted
        }
    }

    final class Coordinator: NSObject {
        var parent: PreferencesPopup
        var requestedFocus = false
        init(_ parent: PreferencesPopup) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            guard sender.isEnabled, parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.options[sender.indexOfSelectedItem].1
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Button {
        let button = Button(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.didFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.focused = true }
        return button
    }

    func updateNSView(_ button: Button, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if button.itemTitles != options.map(\.0) {
            button.removeAllItems()
            for (name, _) in options {
                button.menu?.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: ""))
            }
        }
        button.selectItem(at: options.firstIndex { $0.1 == selection } ?? -1)
        let font = AppTypography.nativeNSControlFont(for: effective?.textSize ?? systemSize)
        button.font = font
        button.menu?.font = font
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
        button.invalidateIntrinsicContentSize()
        if focused && !coordinator.requestedFocus {
            coordinator.requestedFocus = true
            // SwiftUI inserts the native control after this update. Scope to its
            // own window and recheck the request so navigation cannot steal focus.
            DispatchQueue.main.async { [weak button, weak coordinator] in
                guard let button, let coordinator, coordinator.parent.focused,
                      let window = button.window else { return }
                _ = button.scrollToVisible(button.bounds)
                window.makeFirstResponder(button)
            }
        } else if !focused { coordinator.requestedFocus = false }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let font = nsView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return CGSize(width: min(proposal.width ?? intrinsic.width, max(AppMetrics.minimumTarget, intrinsic.width)),
                      height: max(AppMetrics.minimumTarget, intrinsic.height,
                                  ceil(font.ascender - font.descender + AppMetrics.space2)))
    }
}
