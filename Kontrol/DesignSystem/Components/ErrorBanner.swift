import SwiftUI

/// Only reviewed, user-facing copy is accepted. Never pass an Error, its description,
/// user content, or a filesystem path through a presentation component.
struct ErrorBanner: View {
    enum Message: String {
        case readFailed = "Content could not be loaded."
        case saveFailed = "Changes could not be saved."
        case openingFailed = "Kontrol could not be opened."
    }

    let message: Message
    private let recoveryTitle: String?
    private let recovery: (() -> Void)?

    init(_ message: Message) {
        self.message = message
        self.recoveryTitle = nil
        self.recovery = nil
    }

    init(_ message: Message, recoveryTitle: String, recovery: @escaping () -> Void) {
        self.message = message
        self.recoveryTitle = recoveryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recovery = recovery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space3) {
            HStack(alignment: .top, spacing: AppMetrics.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityHidden(true)
                Text(message.rawValue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appTypography(.body)
            .foregroundStyle(AppColors.error)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Error: \(message.rawValue)")

            if let recoveryTitle, !recoveryTitle.isEmpty, let recovery {
                ActionButton(recoveryTitle, action: recovery)
            }
        }
        .padding(AppMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.raisedSurface, in: RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                .strokeBorder(AppColors.error, lineWidth: 1)
        }
    }
}
