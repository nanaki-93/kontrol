import SwiftUI

/// Presentation only: both Settings clients observe the graph-owned lifecycle.
/// The enclosing scene/shell remains the sole scroll-document owner.
struct LocalDataSettingsView: View {
    @ObservedObject var service: ExportService

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
            Text("One point-in-time JSON file").appTypography(.body)
            guidance(Self.inclusions, identifier: "settings-export-inclusions")
            guidance(Self.exclusions, identifier: "settings-export-exclusions")
            guidance(Self.answerGuidance, identifier: "settings-export-answer-guidance")
            guidance(Self.privacyGuidance, identifier: "settings-export-privacy")
            Divider()
            Label(presentation.status, systemImage: presentation.symbol)
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-export-status")
            guidance(presentation.detail, identifier: "settings-export-detail")
            if presentation.canCancel {
                ActionButton("Cancel export") { service.cancel() }
                    .accessibilityIdentifier("settings-export-cancel")
            } else {
                ActionButton(presentation.actionTitle, symbol: "square.and.arrow.up", variant: .primary,
                             isEnabled: !service.isBusy) { service.startExport() }
                    .accessibilityIdentifier("settings-export-start")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-local-data-content")
    }

    private func guidance(_ text: String, identifier: String) -> some View {
        Text(text).appTypography(.body)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}
