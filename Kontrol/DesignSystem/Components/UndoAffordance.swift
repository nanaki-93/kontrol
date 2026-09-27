import SwiftUI

/// Caller-provided success copy and availability, not a history stack or a success publisher.
/// Only the caller's Undo callback can change data or the availability of this control.
struct UndoAffordance: View {
    let successMessage: String
    let isAvailable: Bool
    let isBusy: Bool
    let onUndo: () -> Void

    init(_ successMessage: String, isAvailable: Bool = true, isBusy: Bool = false,
         onUndo: @escaping () -> Void) {
        self.successMessage = successMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isAvailable = isAvailable
        self.isBusy = isBusy
        self.onUndo = onUndo
    }

    var body: some View {
        if !successMessage.isEmpty {
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                HStack(alignment: .top, spacing: AppMetrics.space2) {
                    Image(systemName: "checkmark.circle").accessibilityHidden(true)
                    Text(successMessage).fixedSize(horizontal: false, vertical: true)
                }
                .appTypography(.body)
                .foregroundStyle(AppColors.success)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Success: \(successMessage)")

                ActionButton("Undo", symbol: "arrow.uturn.backward", isEnabled: isAvailable,
                             isBusy: isBusy, action: onUndo)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
