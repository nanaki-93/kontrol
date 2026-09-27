import SwiftUI

/// Small, semantic subset of the approved Black / Red Terminal direction.
enum FoundationStyle {
    static let background = Color(red: 0.045, green: 0.045, blue: 0.052)
    static let surface = Color(red: 0.075, green: 0.068, blue: 0.076)
    static let primary = Color(red: 0.87, green: 0.85, blue: 0.85)
    static let secondary = Color(red: 0.68, green: 0.65, blue: 0.66)
    static let border = Color(red: 0.18, green: 0.14, blue: 0.16)
    static let accent = Color(red: 0.95, green: 0.36, blue: 0.39)

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
