import SwiftUI

/// The selected local monospaced scale in .mockups/design-system/typography.html.
/// Font resolution is presentation-only: neither the system input nor a preview override is persisted.
enum AppTypography {
    enum Role: CaseIterable {
        case page, dialog, section, body, metadata, navigation, action

        var baseSize: CGFloat {
            switch self {
            case .page: 30
            case .dialog: 24
            case .section: 18
            case .body, .navigation: 16
            case .metadata: 13
            case .action: 14
            }
        }

        var weight: Font.Weight {
            switch self {
            case .page, .dialog, .action: .semibold
            case .section, .body, .metadata, .navigation: .regular
            }
        }
    }

    /// SwiftUI's available system text-size input on macOS. The baseline is `.large`;
    /// `.xxLarge` provides the documented 130% reference when the system offers it.
    static func systemScale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 0.95
        case .large: 1
        case .xLarge: 1.15
        case .xxLarge: 1.3
        case .xxxLarge: 1.45
        case .accessibility1: 1.6
        case .accessibility2: 1.8
        case .accessibility3: 2
        case .accessibility4: 2.2
        case .accessibility5: 2.4
        @unknown default: 1
        }
    }

    /// A valid explicit override replaces (rather than compounds) the system scale.
    /// Invalid preview input falls back to the system size so fonts cannot collapse.
    static func scale(for size: DynamicTypeSize, override: CGFloat? = nil) -> CGFloat {
        if let override, override.isFinite, override > 0 { return override }
        return systemScale(for: size)
    }

    static func pointSize(_ role: Role, for size: DynamicTypeSize, override: CGFloat? = nil) -> CGFloat {
        role.baseSize * scale(for: size, override: override)
    }

    static func font(_ role: Role, for size: DynamicTypeSize, override: CGFloat? = nil) -> Font {
        .system(size: pointSize(role, for: size, override: override),
                weight: role.weight, design: .monospaced)
    }
}

/// Preview/test injection only. Use `dynamicTypeSize` for the system value; do not
/// install an app-wide preference or store this override in UserDefaults.
private struct AppTextScaleOverrideKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var appTextScaleOverride: CGFloat? {
        get { self[AppTextScaleOverrideKey.self] }
        set { self[AppTextScaleOverrideKey.self] = newValue }
    }
}

private struct AppTypographyModifier: ViewModifier {
    let role: AppTypography.Role
    @Environment(\.dynamicTypeSize) private var systemSize
    @Environment(\.appTextScaleOverride) private var previewScale

    func body(content: Content) -> some View {
        content.font(AppTypography.font(role, for: systemSize, override: previewScale))
    }
}

extension View {
    /// Resolves the font on every environment update, changing the rendered glyph size.
    func appTypography(_ role: AppTypography.Role) -> some View {
        modifier(AppTypographyModifier(role: role))
    }
}
