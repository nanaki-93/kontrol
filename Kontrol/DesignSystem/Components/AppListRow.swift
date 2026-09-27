import SwiftUI

/// Read-only row container. The caller owns all values and any trailing action;
/// the row itself is not a button, so a supplied button is never nested.
struct AppListRow<Action: View>: View {
    let title: String
    let metadata: String?
    let status: StatusPill?
    private let action: Action
    private let hasAction: Bool
    private let isNextAction: Bool

    init(_ title: String, metadata: String? = nil, status: StatusPill? = nil,
         @ViewBuilder action: () -> Action) {
        self.init(title, metadata: metadata, status: status, isNextAction: false, action: action)
    }

    // Used by NextActionCard to share row anatomy and reflow without an extra surface.
    init(_ title: String, metadata: String?, status: StatusPill?, isNextAction: Bool,
         @ViewBuilder action: () -> Action) {
        self.title = title
        self.metadata = metadata
        self.status = status
        self.action = action()
        self.hasAction = true
        self.isNextAction = isNextAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            Text(title)
                .appTypography(.body)
                .fontWeight(isNextAction ? .semibold : .regular)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let metadata, !metadata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(metadata)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasAction || status?.text.isEmpty == false {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppMetrics.space3) {
                        controls
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        controls
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: AppMetrics.preferredTarget, alignment: .leading)
        .padding(.vertical, isNextAction ? AppMetrics.space4 : AppMetrics.space3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.border).frame(height: 1).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var controls: some View {
        if let status, !status.text.isEmpty { status }
        if hasAction { action }
    }
}

extension AppListRow where Action == EmptyView {
    init(_ title: String, metadata: String? = nil, status: StatusPill? = nil) {
        self.title = title
        self.metadata = metadata
        self.status = status
        self.action = EmptyView()
        self.hasAction = false
        self.isNextAction = false
    }

    init(_ title: String, metadata: String?, status: StatusPill?, isNextAction: Bool) {
        self.title = title
        self.metadata = metadata
        self.status = status
        self.action = EmptyView()
        self.hasAction = false
        self.isNextAction = isNextAction
    }
}
