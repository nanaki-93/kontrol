import SwiftUI

/// Presentation only: both Settings clients observe the graph-owned lifecycle.
/// The enclosing scene/shell remains the sole scroll-document owner.
struct LocalDataSettingsView: View {
    @ObservedObject var service: ExportService
    var onBack: () -> Void = {}
    @FocusState private var focusedAction: FocusTarget?
    @State private var presented = false
    @State private var returnAfterPanel = false
    @State private var focusReturnTask: Task<Void, Never>?

    // The same native action survives every state, including explicit retry.
    // Its label/identifier change, but restoration never targets a removed branch.
    private enum FocusTarget: Hashable { case operation }
    private struct FocusReturnRequest: Equatable {
        let state: ExportService.State
        let requested: Bool
    }

    static let inclusions = "Includes saved tasks, schedule blocks, all persisted Focus sessions, local Learning content and exact saved answers, News topics and feeds, general preferences and nonsecret AI configuration."
    static let exclusions = "Excludes credentials and credential references, project folder permissions, paths and contents, cached News articles, diagnostics and unsaved editor drafts."
    static let answerGuidance = "Pending lesson answers must save successfully before capture. A failed answer save stops the export and retains those answers. Canceling the destination picker does not save pending answers or create an export."
    static let privacyGuidance = "No import or restore is available. This is not an encrypted backup. Protect the JSON file: it contains personal notes and answers."

    struct Presentation: Equatable {
        let status: String
        let symbol: String
        let detail: String
        let actionTitle: String
        let canCancel: Bool

        var controlTitle: String { canCancel ? "Cancel export" : actionTitle }
        var controlIdentifier: String { canCancel ? "settings-export-cancel" : "settings-export-start" }
        var controlHint: String {
            canCancel
                ? "Request cancellation before commit. Wait for the actual result; a completed save cannot be undone."
                : "Open the JSON destination picker. No export starts until you approve a destination."
        }
    }

    static func presentation(_ state: ExportService.State) -> Presentation {
        switch state {
        case .idle:
            return Presentation(status: "Ready to export", symbol: "square.and.arrow.up",
                detail: "Export opens the native JSON destination picker. Replacing a file requires native confirmation.",
                actionTitle: "Export…", canCancel: false)
        case .selecting:
            return Presentation(status: "Choosing export destination…", symbol: "folder",
                detail: "No export saved yet. Complete or cancel the native destination picker. Only one export runs across Settings windows.",
                actionTitle: "Export…", canCancel: true)
        case .preparing:
            return Presentation(status: "Preparing local data…", symbol: "hourglass",
                detail: "No success yet. Cancel requests a pre-commit stop; wait for the actual result. A completed save cannot be undone by cancellation.",
                actionTitle: "Export…", canCancel: true)
        case .saved:
            return Presentation(status: "Export saved", symbol: "checkmark.circle",
                detail: "The validated JSON was saved to the selected destination. It represents the captured saved data, not subsequent edits.",
                actionTitle: "Export another snapshot…", canCancel: false)
        case .canceled:
            return Presentation(status: "Export canceled · no file saved", symbol: "minus.circle",
                detail: "The export ended before commit. Any existing destination remains unchanged. Answers already saved before cancellation remain saved.",
                actionTitle: "Export again…", canCancel: false)
        case .failed(let failure):
            let detail: String
            switch failure {
            case .selection:
                detail = "The destination could not be approved. Choose a writable JSON destination and explicitly retry."
            case .answerSave:
                detail = "Pending lesson answers could not be saved. Export stopped and unsaved answers are retained. Resolve the answer save failure, then explicitly retry."
            case .capture:
                detail = "Saved local data could not be captured. Export stopped without omitting damaged records. Review your saved data, then explicitly retry."
            case .preparation:
                detail = "The JSON export could not be prepared and validated. No destination was changed. Check available space, then explicitly retry."
            case .delivery:
                detail = "The export could not be saved before commit. Any existing destination remains unchanged. Check available space and folder permission, then explicitly retry."
            case .cleanup:
                // Do not promise cleanup when that boundary itself failed.
                detail = "Export stopped before commit, but temporary personal-data cleanup could not be confirmed. Any existing destination remains unchanged. Check available space and permissions before retrying."
            }
            return Presentation(status: "Export not saved", symbol: "exclamationmark.triangle",
                detail: detail, actionTitle: "Retry export…", canCancel: false)
        }
    }

    static func summary(_ state: ExportService.State) -> String {
        "Local data: \(presentation(state).status)"
    }

    var body: some View {
        let presentation = Self.presentation(service.state)
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text("Local data").appTypography(.section).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Text("One point-in-time JSON file").appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-export-subtitle")
            guidance(Self.inclusions, identifier: "settings-export-inclusions")
            guidance(Self.exclusions, identifier: "settings-export-exclusions")
            guidance(Self.answerGuidance, identifier: "settings-export-answer-guidance")
            guidance(Self.privacyGuidance, identifier: "settings-export-privacy")
            Divider()
            // Give the status text the remaining document width rather than
            // an ideal-width label. The symbol stays beside the wrapped text
            // at compact/enlarged sizes.
            Label {
                Text(presentation.status)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: presentation.symbol).accessibilityHidden(true)
            }
                .appTypography(.body)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Export status")
                .accessibilityValue(presentation.status)
                .accessibilityIdentifier("settings-export-status")
            guidance(presentation.detail, identifier: "settings-export-detail")
            ActionButton(presentation.controlTitle,
                         symbol: presentation.canCancel ? nil : "square.and.arrow.up",
                         variant: presentation.canCancel ? .secondary : .primary,
                         isEnabled: presentation.canCancel || !service.isBusy) {
                if presentation.canCancel { cancelExport() }
                else if service.startExport() {
                    returnAfterPanel = true
                    // Let the native panel own keyboard focus until dismissal.
                    focusedAction = nil
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .focused($focusedAction, equals: .operation)
            .accessibilityHint(presentation.controlHint)
            .accessibilityIdentifier(presentation.controlIdentifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // No animation or live-region announcements: progress has no ticking
        // updates, and inherited reduced motion needs no additional resolution.
        .onAppear { presented = true }
        .onDisappear {
            presented = false
            returnAfterPanel = false
            focusReturnTask?.cancel()
        }
        .onChange(of: FocusReturnRequest(state: service.state, requested: returnAfterPanel)) { _, request in
            focusReturnTask?.cancel()
            guard request.state != .selecting, request.requested else { return }
            focusReturnTask = Task { @MainActor in
                // Include the local request in observation: a fast retry can
                // finish with the same failure before SwiftUI renders selecting.
                await Task.yield()
                guard !Task.isCancelled, presented, service.state == request.state else { return }
                focusedAction = .operation
                returnAfterPanel = false
            }
        }
        .onExitCommand {
            // Never leave a hidden cancellation request running or report a
            // terminal result early. The service retains ownership until done.
            if Self.presentation(service.state).canCancel { cancelExport() }
            else { onBack() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-local-data-content")
    }

    private func cancelExport() {
        returnAfterPanel = true
        service.cancel()
    }

    private func guidance(_ text: String, identifier: String) -> some View {
        Text(text).appTypography(.body)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}
