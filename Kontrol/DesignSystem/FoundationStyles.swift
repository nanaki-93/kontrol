import SwiftUI

/// Temporary compatibility forwarding while existing destinations migrate to AppColors.
enum FoundationStyle {
    static let background = AppColors.background
    static let surface = AppColors.surface
    static let primary = AppColors.textPrimary
    static let secondary = AppColors.textSecondary
    static let border = AppColors.border
    static let accent = AppColors.accent

    static let horizontalInset: CGFloat = 32

    static func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 30, weight: .semibold, design: .monospaced))
            .foregroundStyle(primary)
            .accessibilityAddTraits(.isHeader)
    }

    static func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, design: .monospaced))
            .foregroundStyle(primary)
            .accessibilityAddTraits(.isHeader)
    }
}
