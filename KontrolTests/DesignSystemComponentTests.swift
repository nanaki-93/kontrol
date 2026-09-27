import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Kontrol

@MainActor
final class DesignSystemComponentTests: XCTestCase {
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func descendants(_ element: AXUIElement) -> [AXUIElement] {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + descendants($0) }
    }

    private func inspect<V: View>(_ view: V, width: CGFloat, _ check: (NSHostingView<V>, [AXUIElement]) throws -> Void) throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Design system inspection \(UUID().uuidString)"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let inspected = try XCTUnwrap((attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
            attribute($0, kAXTitleAttribute) as? String == window.title
        })
        try check(host, descendants(inspected))
    }

    private func frame(_ element: AXUIElement) throws -> CGRect {
        let position = try XCTUnwrap(attribute(element, kAXPositionAttribute))
        let size = try XCTUnwrap(attribute(element, kAXSizeAttribute))
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions))
        return CGRect(origin: origin, size: dimensions)
    }

    func testActionVariantsAreNativeNamedButtonsWithTargetsAndSingleCallbacks() throws {
        var calls = [String]()
        let view = VStack {
            ActionButton("Add task", symbol: "plus", variant: .primary) { calls.append("primary") }
                .accessibilityIdentifier("action-primary")
                .keyboardShortcut("a", modifiers: .command)
            ActionButton("Open", variant: .secondary) { calls.append("secondary") }
                .accessibilityIdentifier("action-secondary")
            ActionButton("Remove", symbol: "trash", variant: .destructive) { calls.append("destructive") }
                .accessibilityIdentifier("action-destructive")
        }.padding(AppMetrics.space4)
        try inspect(view, width: 340) { _, nodes in
            for (identifier, name) in [("action-primary", "Add task"),
                                       ("action-secondary", "Open"),
                                       ("action-destructive", "Remove")] {
                let button = try XCTUnwrap(nodes.first { attribute($0, kAXIdentifierAttribute) as? String == identifier })
                XCTAssertEqual(attribute(button, kAXRoleAttribute) as? String, kAXButtonRole)
                XCTAssertEqual(attribute(button, kAXDescriptionAttribute) as? String, name)
                XCTAssertEqual((attribute(button, kAXEnabledAttribute) as? NSNumber)?.boolValue, true)
                let bounds = try frame(button)
                XCTAssertGreaterThanOrEqual(bounds.width, AppMetrics.minimumTarget)
                XCTAssertGreaterThanOrEqual(bounds.height, AppMetrics.minimumTarget)
                XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
            }
            XCTAssertFalse(nodes.contains { (attribute($0, kAXDescriptionAttribute) as? String) == "plus" ||
                (attribute($0, kAXDescriptionAttribute) as? String) == "trash" })
            XCTAssertEqual(calls, ["primary", "secondary", "destructive"])
        }
    }

    func testDisabledAndBusyActionsSuppressEvenAccessibilityPressAndKeepBusyName() throws {
        var calls = 0
        let view = VStack {
            ActionButton("Unavailable", isEnabled: false) { calls += 1 }
                .accessibilityIdentifier("action-disabled")
            ActionButton("Save changes", symbol: "checkmark", variant: .primary, isBusy: true) { calls += 1 }
                .accessibilityIdentifier("action-busy")
        }.padding()
        try inspect(view, width: 340) { _, nodes in
            for identifier in ["action-disabled", "action-busy"] {
                let button = try XCTUnwrap(nodes.first { attribute($0, kAXIdentifierAttribute) as? String == identifier })
                XCTAssertEqual(attribute(button, kAXRoleAttribute) as? String, kAXButtonRole)
                XCTAssertEqual((attribute(button, kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
                let bounds = try frame(button)
                XCTAssertGreaterThanOrEqual(bounds.width, AppMetrics.minimumTarget)
                XCTAssertGreaterThanOrEqual(bounds.height, AppMetrics.minimumTarget)
                _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            let busy = try XCTUnwrap(nodes.first { attribute($0, kAXIdentifierAttribute) as? String == "action-busy" })
            XCTAssertEqual(attribute(busy, kAXDescriptionAttribute) as? String, "Save changes")
            XCTAssertEqual(attribute(busy, kAXValueAttribute) as? String, "In progress")
            XCTAssertEqual(calls, 0)
        }
    }

    func testFocusAndCallerKeyboardShortcutWorkWithoutHover() throws {
        var calls = 0
        let view = ActionButton("Run", symbol: "play.fill", variant: .primary) { calls += 1 }
            .accessibilityIdentifier("shortcut-action")
            .keyboardShortcut("r", modifiers: .command)
            .padding(AppMetrics.space4)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Action focus inspection \(UUID().uuidString)"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let axWindow = try XCTUnwrap((attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
            attribute($0, kAXTitleAttribute) as? String == window.title
        })
        let button = try XCTUnwrap(descendants(axWindow).first {
            attribute($0, kAXIdentifierAttribute) as? String == "shortcut-action"
        })
        XCTAssertEqual(attribute(button, kAXRoleAttribute) as? String, kAXButtonRole)
        XCTAssertEqual(AXUIElementSetAttributeValue(button, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let focused = try XCTUnwrap(attribute(app, kAXFocusedUIElementAttribute))
        XCTAssertEqual(attribute(unsafeBitCast(focused, to: AXUIElement.self), kAXIdentifierAttribute) as? String,
                       "shortcut-action")
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                          modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                          context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        XCTAssertTrue(window.performKeyEquivalent(with: key))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(calls, 1)
    }

    func testEnlargedLongActionHasContentDrivenHeightAndFullName() throws {
        let title = "A long action name that must wrap in a narrow panel instead of clipping"
        try inspect(ActionButton(title, variant: .primary) {}.frame(width: 175).padding()
            .environment(\.appTextScaleOverride, 1.3)
            .accessibilityIdentifier("long-action"), width: 220) { _, nodes in
            let button = try XCTUnwrap(nodes.first { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
            XCTAssertEqual(attribute(button, kAXDescriptionAttribute) as? String, title)
            let bounds = try frame(button)
            XCTAssertGreaterThan(bounds.height, AppMetrics.minimumTarget)
            XCTAssertGreaterThanOrEqual(bounds.width, AppMetrics.minimumTarget)
            // AX includes the 3-point external focus-ring allowance on each side.
            XCTAssertLessThanOrEqual(bounds.width, 175 + 6)
        }
    }

    func testStatusKindsConveyMeaningWithoutColorOrDuplicateSymbolNarration() throws {
        XCTAssertEqual(Set([StatusPill.Kind.success.symbol, StatusPill.Kind.warning.symbol, StatusPill.Kind.error.symbol]).count, 3)
        let view = VStack(alignment: .leading) {
            StatusPill("Complete", kind: .success)
            StatusPill("Due", kind: .warning)
            StatusPill("Failed", kind: .error)
            StatusPill("   ", kind: .warning)
        }.padding()
        try inspect(view, width: 300) { _, nodes in
            for name in ["Success: Complete", "Warning: Due", "Error: Failed"] {
                XCTAssertEqual(nodes.filter {
                    attribute($0, kAXDescriptionAttribute) as? String == name ||
                    attribute($0, kAXValueAttribute) as? String == name
                }.count, 1, "status name is announced once: \(name)")
            }
            XCTAssertFalse(nodes.contains { (attribute($0, kAXDescriptionAttribute) as? String)?.contains("triangle") == true ||
                (attribute($0, kAXDescriptionAttribute) as? String)?.contains("octagon") == true })
            XCTAssertFalse(nodes.contains { attribute($0, kAXDescriptionAttribute) as? String == "Warning: " })
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
        }
    }

    func testRowsAndCardsOmitAbsentMetadataStatusAndAction() throws {
        try inspect(VStack {
            AppListRow("Fixture task", metadata: "  \n ", status: StatusPill(" ", kind: .warning))
            NextActionCard("Fixture lesson")
        }.frame(width: 280).padding(), width: 320) { _, nodes in
            for text in ["Fixture task", "Fixture lesson"] {
                XCTAssertTrue(nodes.contains { attribute($0, kAXValueAttribute) as? String == text ||
                    attribute($0, kAXDescriptionAttribute) as? String == text })
            }
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
            XCTAssertFalse(nodes.contains { (attribute($0, kAXDescriptionAttribute) as? String)?.contains("Warning") == true })
            XCTAssertFalse(nodes.contains { attribute($0, kAXValueAttribute) as? String == "" })
        }
    }

    func testLongRowsAndCardsWrapAt130PercentWithCallerOwnedActions() throws {
        let title = "Investigate cancellation propagation through nested requests before the next review"
        let metadata = "Context cancellation · 15 min · additional details of the review that must wrap before clipping"
        var rowCalls = 0
        var cardCalls = 0
        func fixture() -> some View {
            VStack(alignment: .leading, spacing: AppMetrics.space4) {
                AppListRow(title, metadata: metadata, status: StatusPill("Due", kind: .warning)) {
                    ActionButton("Open task") { rowCalls += 1 }.accessibilityIdentifier("row-action")
                }
                NextActionCard(title, metadata: metadata, status: StatusPill("Next", kind: .success)) {
                    ActionButton("Open lesson") { cardCalls += 1 }.accessibilityIdentifier("card-action")
                }
            }.frame(width: 240).padding(AppMetrics.space4)
        }
        var standardMetadataHeight: CGFloat = 0
        try inspect(fixture(), width: 280) { _, nodes in
            let metadataNodes = nodes.filter { attribute($0, kAXValueAttribute) as? String == metadata ||
                attribute($0, kAXDescriptionAttribute) as? String == metadata }
            XCTAssertEqual(metadataNodes.count, 2)
            standardMetadataHeight = try frame(XCTUnwrap(metadataNodes.first)).height
        }
        try inspect(fixture().environment(\.appTextScaleOverride, 1.3), width: 280) { _, nodes in
            let metadataNodes = nodes.filter { attribute($0, kAXValueAttribute) as? String == metadata ||
                attribute($0, kAXDescriptionAttribute) as? String == metadata }
            XCTAssertEqual(metadataNodes.count, 2)
            for node in metadataNodes {
                let bounds = try frame(node)
                XCTAssertGreaterThan(bounds.height, standardMetadataHeight, "enlarged metadata must reflow")
                XCTAssertLessThanOrEqual(bounds.width, 240)
            }
            let titles = nodes.filter { attribute($0, kAXValueAttribute) as? String == title ||
                attribute($0, kAXDescriptionAttribute) as? String == title }
            XCTAssertEqual(titles.count, 2)
            for titleNode in titles {
                let bounds = try frame(titleNode)
                XCTAssertGreaterThan(bounds.height, 20, "long titles grow with content")
                XCTAssertLessThanOrEqual(bounds.width, 240)
            }
            for (index, name) in ["Warning: Due", "Success: Next"].enumerated() {
                let status = try XCTUnwrap(nodes.first { attribute($0, kAXDescriptionAttribute) as? String == name ||
                    attribute($0, kAXValueAttribute) as? String == name })
                XCTAssertGreaterThanOrEqual(try frame(status).minY, try frame(metadataNodes[index]).maxY,
                                            "status must follow the fully wrapped metadata")
            }
            let buttons = nodes.filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }
            XCTAssertEqual(buttons.count, 2, "rows and cards are not buttons around their trailing actions")
            for identifier in ["row-action", "card-action"] {
                let button = try XCTUnwrap(buttons.first { attribute($0, kAXIdentifierAttribute) as? String == identifier })
                XCTAssertGreaterThanOrEqual(try frame(button).height, AppMetrics.minimumTarget)
                XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
            }
            XCTAssertEqual(rowCalls, 1)
            XCTAssertEqual(cardCalls, 1)
        }
    }

    func testEmptyStateOmitsBlankGuidanceAndHasNoImplicitAction() throws {
        try inspect(VStack {
            EmptyState("No tasks yet")
            EmptyState("No topics yet", guidance: "  \n ")
        }.frame(width: 240).padding(), width: 280) { _, nodes in
            for title in ["No tasks yet", "No topics yet"] {
                XCTAssertEqual(nodes.filter { attribute($0, kAXValueAttribute) as? String == title ||
                    attribute($0, kAXDescriptionAttribute) as? String == title }.count, 1)
            }
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
            XCTAssertFalse(nodes.contains { attribute($0, kAXValueAttribute) as? String == "" })
            XCTAssertFalse(nodes.contains { attribute($0, kAXDescriptionAttribute) as? String == "tray" })
        }
    }

    func testEmptyStateOmitsWhitespaceOnlyActionEvenWithCallback() throws {
        var calls = 0
        try inspect(EmptyState("No tasks yet", actionTitle: "  \n\t ") { calls += 1 }
            .padding(), width: 280) { _, nodes in
            XCTAssertTrue(nodes.contains { attribute($0, kAXValueAttribute) as? String == "No tasks yet" ||
                attribute($0, kAXDescriptionAttribute) as? String == "No tasks yet" })
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
            XCTAssertEqual(calls, 0)
        }
    }

    func testEmptyGuidanceAndCallerActionWrapAtEnlargedText() throws {
        var calls = 0
        let guidance = "Add one to keep track of the next important thing you need to finish."
        try inspect(EmptyState("No tasks yet", guidance: guidance, actionTitle: "  Add task  ") { calls += 1 }
            .frame(width: 230).padding()
            .environment(\.appTextScaleOverride, 1.3), width: 270) { _, nodes in
            let text = try XCTUnwrap(nodes.first { attribute($0, kAXValueAttribute) as? String == guidance })
            XCTAssertGreaterThan(try frame(text).height, 40, "enlarged guidance wraps")
            let buttons = nodes.filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }
            XCTAssertEqual(buttons.count, 1)
            let button = try XCTUnwrap(buttons.first)
            XCTAssertEqual(attribute(button, kAXDescriptionAttribute) as? String, "Add task")
            XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
            XCTAssertEqual(calls, 1)
        }
    }

    func testErrorBannerExposesSafeErrorMeaningAndOnlyCallerRecovery() throws {
        var calls = 0
        // The API takes a closed set of user-facing messages, not an Error or arbitrary path.
        try inspect(VStack {
            ErrorBanner(.readFailed)
            ErrorBanner(.saveFailed, recoveryTitle: "  Try again  ") { calls += 1 }
        }.frame(width: 280).padding(), width: 320) { _, nodes in
            for message in [ErrorBanner.Message.readFailed, .saveFailed] {
                let name = "Error: \(message.rawValue)"
                XCTAssertEqual(nodes.filter { attribute($0, kAXDescriptionAttribute) as? String == name ||
                    attribute($0, kAXValueAttribute) as? String == name }.count, 1)
                XCTAssertFalse(name.contains("/Users/"))
            }
            XCTAssertFalse(nodes.contains { (attribute($0, kAXDescriptionAttribute) as? String)?.contains("triangle") == true })
            let buttons = nodes.filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }
            XCTAssertEqual(buttons.count, 1, "no recovery action without a callback")
            let button = try XCTUnwrap(buttons.first)
            XCTAssertEqual(attribute(button, kAXDescriptionAttribute) as? String, "Try again")
            XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
            XCTAssertEqual(calls, 1)
        }
    }

    func testErrorBannerOmitsWhitespaceOnlyRecoveryEvenWithCallback() throws {
        var calls = 0
        try inspect(ErrorBanner(.readFailed, recoveryTitle: "  \n\t ") { calls += 1 }
            .padding(), width: 320) { _, nodes in
            let error = "Error: \(ErrorBanner.Message.readFailed.rawValue)"
            XCTAssertEqual(nodes.filter { attribute($0, kAXDescriptionAttribute) as? String == error ||
                attribute($0, kAXValueAttribute) as? String == error }.count, 1)
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
            XCTAssertEqual(calls, 0)
        }
    }

    func testLoadingLabelRemainsAccessibleWithAndWithoutReducedMotion() throws {
        var rendered = [Data]()
        for reduced in [false, true] {
            try inspect(LoadingState("Opening Kontrol…")
                .environment(\.loadingReduceMotionOverride, reduced).padding(), width: 300) { host, nodes in
                XCTAssertEqual(nodes.filter { attribute($0, kAXDescriptionAttribute) as? String == "Loading: Opening Kontrol…" ||
                    attribute($0, kAXValueAttribute) as? String == "Loading: Opening Kontrol…" }.count, 1)
                XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                rendered.append(try XCTUnwrap(image.representation(using: .png, properties: [:])))
            }
        }
        XCTAssertEqual(rendered.count, 2)
        XCTAssertNotEqual(rendered[0], rendered[1], "static track must render differently from animated spinner")
    }

    func testIconLabelHasOneNameWithoutSymbolAnnouncement() throws {
        try inspect(IconLabel(title: "Learning", symbol: "book"), width: 300) { _, nodes in
            let named = nodes.filter { attribute($0, kAXDescriptionAttribute) as? String == "Learning" ||
                attribute($0, kAXValueAttribute) as? String == "Learning" }
            XCTAssertEqual(named.count, 1)
            XCTAssertFalse(nodes.contains { (attribute($0, kAXDescriptionAttribute) as? String)?.localizedCaseInsensitiveContains("book") == true })
        }
    }

    func testPopulatedAndOmittedPageAndSectionHeadings() throws {
        let populated = VStack {
            PageHeader("Today", metadata: "Monday") {
                Button("Add task") {}.accessibilityIdentifier("page-action")
            }
            SectionHeader("Tasks", metadata: "Due now") {
                Button("Show all") {}.accessibilityIdentifier("section-action")
            }
        }
        try inspect(populated, width: 700) { _, nodes in
            for title in ["Today", "Tasks"] {
                let headings = nodes.filter { attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
                    (attribute($0, kAXValueAttribute) as? String == title || attribute($0, kAXDescriptionAttribute) as? String == title) }
                XCTAssertEqual(headings.count, 1, "heading semantics for \(title)")
            }
            for label in ["Monday", "Due now"] {
                XCTAssertTrue(nodes.contains { attribute($0, kAXValueAttribute) as? String == label ||
                    attribute($0, kAXDescriptionAttribute) as? String == label })
            }
            XCTAssertEqual(nodes.filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }.count, 2)
            XCTAssertTrue(nodes.contains { attribute($0, kAXIdentifierAttribute) as? String == "page-action" })
            XCTAssertTrue(nodes.contains { attribute($0, kAXIdentifierAttribute) as? String == "section-action" })
        }
        try inspect(VStack {
            PageHeader("Today")
            SectionHeader("Tasks", metadata: "")
        }, width: 350) { _, nodes in
            XCTAssertEqual(nodes.filter { attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole }.count, 2)
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
            XCTAssertFalse(nodes.contains { attribute($0, kAXValueAttribute) as? String == "" })
        }
    }

    func testLongEnlargedHeadersReflowActionsBelowWithoutClipping() throws {
        let title = "A very long page heading that must wrap rather than truncate in a narrow window"
        let section = "An equally long section heading that must wrap instead of clipping"
        let view = VStack(alignment: .leading, spacing: 20) {
            PageHeader(title, metadata: "Long optional metadata that should also wrap across lines") {
                Button("Page action") {}.accessibilityIdentifier("page-action")
            }
            SectionHeader(section) {
                Button("Section action") {}.accessibilityIdentifier("section-action")
            }
        }
        .padding()
        .environment(\.appTextScaleOverride, 1.3)
        try inspect(view, width: 340) { _, nodes in
            for (heading, action) in [(title, "page-action"), (section, "section-action")] {
                let headingNode = try XCTUnwrap(nodes.first { attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
                    (attribute($0, kAXValueAttribute) as? String == heading || attribute($0, kAXDescriptionAttribute) as? String == heading) })
                let actionNode = try XCTUnwrap(nodes.first { attribute($0, kAXIdentifierAttribute) as? String == action })
                @MainActor func rect(_ node: AXUIElement) throws -> CGRect {
                    let origin = try XCTUnwrap(attribute(node, kAXPositionAttribute))
                    let size = try XCTUnwrap(attribute(node, kAXSizeAttribute))
                    var point = CGPoint.zero
                    var dimensions = CGSize.zero
                    XCTAssertTrue(AXValueGetValue(unsafeBitCast(origin, to: AXValue.self), .cgPoint, &point))
                    XCTAssertTrue(AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions))
                    return CGRect(origin: point, size: dimensions)
                }
                let headingFrame = try rect(headingNode)
                let buttonFrame = try rect(actionNode)
                XCTAssertGreaterThan(buttonFrame.minY, headingFrame.minY + headingFrame.height - 1)
                XCTAssertGreaterThan(headingFrame.height, action == "page-action" ? 40 : 22,
                                     "long heading should occupy multiple lines")
                XCTAssertLessThanOrEqual(headingFrame.width, 340)
                XCTAssertLessThanOrEqual(buttonFrame.width, 340)
            }
        }
    }
}
