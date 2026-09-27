import SwiftUI

/// A genuine empty result. Guidance and actions are optional; only callers can supply behavior.
struct EmptyState: View {
    let title: String
    let guidance: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(_ title: String, guidance: String? = nil) {
        self.title = title
        self.guidance = guidance?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actionTitle = nil
        self.action = nil
    }

    init(_ title: String, guidance: String? = nil, actionTitle: String,
         action: @escaping () -> Void) {
        self.title = title
        self.guidance = guidance?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actionTitle = actionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space3) {
            HStack(alignment: .top, spacing: AppMetrics.space3) {
                Image(systemName: "tray")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppMetrics.space2) {
                    Text(title)
                        .appTypography(.section)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let guidance, !guidance.isEmpty {
                        Text(guidance)
                            .appTypography(.body)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let actionTitle, !actionTitle.isEmpty, let action {
                ActionButton(actionTitle, variant: .primary, action: action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
