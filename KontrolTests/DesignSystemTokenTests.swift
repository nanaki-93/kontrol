import AppKit
import SwiftUI
import XCTest
@testable import Kontrol

private typealias RGBColor = Kontrol.RGBColor

final class DesignSystemTokenTests: XCTestCase {
    func testApprovedValuesAndDocumentedAdditionalRoles() {
        let approved: [(String, RGBColor, UInt32)] = [
            ("background", AppColors.backgroundValue, 0x0B0B0D),
            ("surface", AppColors.surfaceValue, 0x151214),
            ("textPrimary", AppColors.textPrimaryValue, 0xE1DCDB),
            ("textSecondary", AppColors.textSecondaryValue, 0xAAA0A0),
            ("border", AppColors.borderValue, 0x3A2B2D),
            ("accent", AppColors.accentValue, 0xD6676B)
        ]
        for (name, value, expected) in approved {
            XCTAssertEqual(value.hex, expected, name)
        }
        XCTAssertEqual(AppColors.raisedSurfaceValue.hex, 0x211B1E)
        XCTAssertEqual(AppColors.successValue.hex, 0x8FC5A6)
        XCTAssertEqual(AppColors.warningValue.hex, 0xE5BC80)
        XCTAssertEqual(AppColors.sidebarValue, AppColors.surfaceValue)
        XCTAssertEqual(AppColors.errorValue, AppColors.accentValue)
        XCTAssertEqual(AppColors.textOnAccentValue, AppColors.backgroundValue)
        XCTAssertEqual(AppColors.controlBoundaryValue, AppColors.textSecondaryValue)
        XCTAssertEqual(AppColors.focusRingValue, AppColors.textPrimaryValue)
    }

    func testSwiftUIRolesAndLegacyConsumersUseTheTestedChannels() throws {
        let roles: [(String, Color, RGBColor)] = [
            ("background", AppColors.background, AppColors.backgroundValue),
            ("sidebar", AppColors.sidebar, AppColors.sidebarValue),
            ("surface", AppColors.surface, AppColors.surfaceValue),
            ("raisedSurface", AppColors.raisedSurface, AppColors.raisedSurfaceValue),
            ("textPrimary", AppColors.textPrimary, AppColors.textPrimaryValue),
            ("textSecondary", AppColors.textSecondary, AppColors.textSecondaryValue),
            ("border", AppColors.border, AppColors.borderValue),
            ("accent", AppColors.accent, AppColors.accentValue),
            ("success", AppColors.success, AppColors.successValue),
            ("warning", AppColors.warning, AppColors.warningValue),
            ("error", AppColors.error, AppColors.errorValue),
            ("textOnAccent", AppColors.textOnAccent, AppColors.textOnAccentValue),
            ("controlBoundary", AppColors.controlBoundary, AppColors.controlBoundaryValue),
            ("focusRing", AppColors.focusRing, AppColors.focusRingValue),
            ("legacy background", FoundationStyle.background, AppColors.backgroundValue),
            ("legacy surface", FoundationStyle.surface, AppColors.surfaceValue),
            ("legacy primary", FoundationStyle.primary, AppColors.textPrimaryValue),
            ("legacy secondary", FoundationStyle.secondary, AppColors.textSecondaryValue),
            ("legacy border", FoundationStyle.border, AppColors.borderValue),
            ("legacy accent", FoundationStyle.accent, AppColors.accentValue)
        ]
        for (name, color, value) in roles {
            let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB), name)
            XCTAssertEqual(resolved.redComponent, CGFloat((value.hex >> 16) & 0xFF) / 255, accuracy: 0.002, name)
            XCTAssertEqual(resolved.greenComponent, CGFloat((value.hex >> 8) & 0xFF) / 255, accuracy: 0.002, name)
            XCTAssertEqual(resolved.blueComponent, CGFloat(value.hex & 0xFF) / 255, accuracy: 0.002, name)
            XCTAssertEqual(resolved.alphaComponent, 1, accuracy: 0.002, name)
        }
    }

    func testTextPairingsAndAccentFilledButtonMeetNormalTextContrast() {
        XCTAssertEqual(RGBColor(0xFFFFFF).contrast(with: RGBColor(0)), 21, accuracy: 0.0001)
        XCTAssertEqual(AppColors.backgroundValue.contrast(with: AppColors.backgroundValue), 1)

        let surfaces: [(String, RGBColor)] = [
            ("background", AppColors.backgroundValue),
            ("sidebar", AppColors.sidebarValue),
            ("surface", AppColors.surfaceValue),
            ("raised", AppColors.raisedSurfaceValue)
        ]
        let text: [(String, RGBColor)] = [
            ("primary", AppColors.textPrimaryValue),
            ("secondary", AppColors.textSecondaryValue),
            ("accent text / error", AppColors.errorValue),
            ("success", AppColors.successValue),
            ("warning", AppColors.warningValue)
        ]
        for (surfaceName, surface) in surfaces {
            for (textName, foreground) in text {
                XCTAssertGreaterThanOrEqual(foreground.contrast(with: surface), 4.5,
                                            "\(textName) on \(surfaceName)")
            }
        }
        XCTAssertGreaterThanOrEqual(AppColors.textOnAccentValue.contrast(with: AppColors.accentValue), 4.5,
                                    "Filled primary/destructive action label")
        // The light primary label is not suitable for an accent-filled button.
        XCTAssertLessThan(AppColors.textPrimaryValue.contrast(with: AppColors.accentValue), 4.5)
    }

    func testFocusAndEssentialBoundariesAgainstAdjacentSurfaces() {
        for (name, surface) in [
            ("background", AppColors.backgroundValue),
            ("sidebar", AppColors.sidebarValue),
            ("surface", AppColors.surfaceValue),
            ("raised", AppColors.raisedSurfaceValue)
        ] {
            XCTAssertGreaterThanOrEqual(AppColors.focusRingValue.contrast(with: surface), 3,
                                            "External focus outline on \(name)")
            XCTAssertGreaterThanOrEqual(AppColors.controlBoundaryValue.contrast(with: surface), 3,
                                            "Essential secondary control outline on \(name)")
            XCTAssertGreaterThanOrEqual(AppColors.accentValue.contrast(with: surface), 3,
                                            "Filled primary control boundary on \(name)")
        }
        // The approved muted border is for decorative separators only.
        XCTAssertLessThan(AppColors.borderValue.contrast(with: AppColors.surfaceValue), 3)
    }
}
