import SwiftUI

/// Shared honest placeholder for destinations whose features have not shipped yet.
struct FoundationView: View {
    let destination: AppDestination

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader(destination.title)
            EmptyState(destination.foundationMessage)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .background(AppColors.background)
        .foregroundStyle(AppColors.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(destination.rawValue)-content")
    }
}
