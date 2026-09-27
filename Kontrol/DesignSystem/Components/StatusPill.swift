import SwiftUI

/// A presentation-only status: meaning is stated in the accessible name and conveyed
/// visually by both an SF Symbol and a word. Callers supply the actual status text.
struct StatusPill: View {
    enum Kind {
        case success, warning, error

        var name: String {
            switch self {
            case .success: "Success"
            case .warning: "Warning"
            case .error: "Error"
            }
        }

        var symbol: String {
            switch self {
            case .success: "checkmark.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }

        var color: Color {
            switch self {
            case .success: AppColors.success
            case .warning: AppColors.warning
            case .error: AppColors.error
            }
        }
    }

    let text: String
    let kind: Kind

    init(_ text: String, kind: Kind) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
    }

    var body: some View {
        if !text.isEmpty {
            HStack(spacing: AppMetrics.space2) {
                Image(systemName: kind.symbol).accessibilityHidden(true)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .appTypography(.metadata)
            .foregroundStyle(kind.color)
            .padding(.horizontal, AppMetrics.space2)
            .padding(.vertical, AppMetrics.space1)
            .overlay {
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                    .strokeBorder(kind.color, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind.name): \(text)")
        }
    }
}
