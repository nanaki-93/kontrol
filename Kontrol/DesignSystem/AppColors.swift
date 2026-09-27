import SwiftUI

/// Opaque sRGB token, retaining the exact 8-bit channels used by the design reference.
/// Contrast is computed from these same channels, rather than from a platform-dependent
/// display-profile conversion of a SwiftUI Color.
struct RGBColor: Equatable {
    let hex: UInt32

    init(_ hex: UInt32) {
        precondition(hex <= 0xFFFFFF, "An RGB token must have exactly three channels")
        self.hex = hex
    }

    private var channels: (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255,
         Double((hex >> 8) & 0xFF) / 255,
         Double(hex & 0xFF) / 255)
    }

    var color: Color {
        let (red, green, blue) = channels
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    private var relativeLuminance: Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let (red, green, blue) = channels
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    func contrast(with other: RGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Fixed-dark Black / Red Terminal roles. New values and aliases are documented in
/// .mockups/design-system/tokens.css and their intended pairings in palette.html.
/// Only the base roles below own channel values; aliases and SwiftUI colors derive from them.
enum AppColors {
    static let backgroundValue = RGBColor(0x0B0B0D)
    static let surfaceValue = RGBColor(0x151214)
    static let raisedSurfaceValue = RGBColor(0x211B1E)
    static let textPrimaryValue = RGBColor(0xE1DCDB)
    static let textSecondaryValue = RGBColor(0xAAA0A0)
    static let borderValue = RGBColor(0x3A2B2D) // Decorative only; not an essential outline.
    static let accentValue = RGBColor(0xD6676B)
    static let successValue = RGBColor(0x8FC5A6)
    static let warningValue = RGBColor(0xE5BC80)

    static let sidebarValue = surfaceValue
    static let errorValue = accentValue
    static let textOnAccentValue = backgroundValue
    static let controlBoundaryValue = textSecondaryValue
    static let focusRingValue = textPrimaryValue

    static let background = backgroundValue.color
    static let sidebar = sidebarValue.color
    static let surface = surfaceValue.color
    static let raisedSurface = raisedSurfaceValue.color
    static let textPrimary = textPrimaryValue.color
    static let textSecondary = textSecondaryValue.color
    static let border = borderValue.color
    static let accent = accentValue.color
    static let success = successValue.color
    static let warning = warningValue.color
    static let error = errorValue.color
    static let textOnAccent = textOnAccentValue.color
    static let controlBoundary = controlBoundaryValue.color
    static let focusRing = focusRingValue.color
}
