import SwiftUI

/// Section-level heading, with optional context and caller-provided actions.
struct SectionHeader<Actions: View>: View {
    let title: String
    let metadata: String?
    private let actions: Actions
    private let hasActions: Bool

    init(_ title: String, metadata: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.metadata = metadata
        self.actions = actions()
        self.hasActions = true
    }

    var body: some View {
        Group {
            if hasActions {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppMetrics.space4) {
                        heading.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        actions.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space4) {
                        heading
                        actions
                    }
                }
            } else {
                heading
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space1) {
            Text(title)
                .appTypography(.section)
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            if let metadata, !metadata.isEmpty {
                Text(metadata)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SectionHeader where Actions == EmptyView {
    init(_ title: String, metadata: String? = nil) {
        self.title = title
        self.metadata = metadata
        self.actions = EmptyView()
        self.hasActions = false
    }
}
