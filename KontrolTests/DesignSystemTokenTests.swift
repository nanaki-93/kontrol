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

    func testSwiftUIRolesUseTheTestedChannels() throws {
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
            ("focusRing", AppColors.focusRing, AppColors.focusRingValue)
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

    func testTypographyRolesResolveSelectedScaleAndSystemSizes() {
        let roles: [(AppTypography.Role, CGFloat, Font.Weight)] = [
            (.page, 30, .semibold), (.dialog, 24, .semibold),
            (.section, 18, .regular), (.body, 16, .regular),
            (.metadata, 13, .regular), (.navigation, 16, .regular),
            (.action, 14, .semibold)
        ]
        XCTAssertEqual(AppTypography.Role.allCases.count, roles.count)
        for (role, base, weight) in roles {
            XCTAssertEqual(role.baseSize, base)
            XCTAssertEqual(role.weight, weight)
            XCTAssertEqual(AppTypography.pointSize(role, for: .large), base)
            XCTAssertEqual(AppTypography.pointSize(role, for: .xxLarge), base * 1.3, accuracy: 0.001)
            XCTAssertEqual(AppTypography.pointSize(role, for: .large, override: 1.3), base * 1.3, accuracy: 0.001)
            XCTAssertEqual(AppTypography.pointSize(role, for: .xxLarge, override: 1), base)
            XCTAssertGreaterThan(AppTypography.pointSize(role, for: .accessibility1), base * 1.3)
        }
        XCTAssertEqual(AppTypography.systemScale(for: .large), 1)
        XCTAssertEqual(AppTypography.systemScale(for: .xxLarge), 1.3)
        XCTAssertEqual(AppTypography.scale(for: .large, override: .nan), 1)
        XCTAssertEqual(AppTypography.scale(for: .large, override: 0), 1)
        XCTAssertEqual(AppTypography.scale(for: .large, override: .infinity), 1)
    }

    @MainActor
    func testTypographyEnvironmentEnlargesRenderedGlyphsAndOverrideIsScoped() {
        func measured(_ role: AppTypography.Role, system: DynamicTypeSize = .large,
                      preview: CGFloat? = nil) -> CGSize {
            let view = Text("MMMMMMMMMMMM")
                .appTypography(role)
                .environment(\.dynamicTypeSize, system)
                .environment(\.appTextScaleOverride, preview)
            let host = NSHostingView(rootView: view)
            return host.fittingSize
        }
        for role in AppTypography.Role.allCases {
            let standard = measured(role)
            let systemLarge = measured(role, system: .xxLarge)
            let previewLarge = measured(role, preview: 1.3)
            XCTAssertGreaterThan(systemLarge.width, standard.width * 1.2, "system \(role)")
            XCTAssertGreaterThan(previewLarge.width, standard.width * 1.2, "preview \(role)")
            XCTAssertGreaterThan(systemLarge.height, standard.height, "system \(role)")
            XCTAssertGreaterThan(previewLarge.height, standard.height, "preview \(role)")
            XCTAssertEqual(previewLarge.width, systemLarge.width, accuracy: 1, "\(role)")
            XCTAssertEqual(measured(role, system: .xxLarge, preview: 1).width,
                           standard.width, accuracy: 1, "override replaces system scale")
            XCTAssertEqual(measured(role).width, standard.width, accuracy: 0.01,
                           "a preview does not change another host or persist a preference")
        }
    }

    func testLayoutGridAndInteractiveMinimums() {
        XCTAssertEqual([AppMetrics.space1, AppMetrics.space2, AppMetrics.space3,
                        AppMetrics.space4, AppMetrics.space6, AppMetrics.space8],
                       [4, 8, 12, 16, 24, 32])
        XCTAssertEqual(AppMetrics.horizontalInset, AppMetrics.space8)
        XCTAssertEqual(AppMetrics.contentInset, AppMetrics.space6)
        XCTAssertEqual(AppMetrics.smallRadius, 4)
        XCTAssertEqual(AppMetrics.mediumRadius, 8)
        XCTAssertGreaterThanOrEqual(AppMetrics.minimumTarget, 32)
        XCTAssertGreaterThanOrEqual(AppMetrics.preferredTarget, AppMetrics.minimumTarget)
        XCTAssertEqual(AppMetrics.preferredTarget, 44)
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
