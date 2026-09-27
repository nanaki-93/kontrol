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
