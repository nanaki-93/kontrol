import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Kontrol

@MainActor
final class AppShellTests: XCTestCase {
    private func makeDependencies() throws -> AppDependencies {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        return AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container))
    }
    func testNavigationMetadataAndRouting() {
        let destinations = AppDestination.allCases
        XCTAssertEqual(destinations.map(\.title), ["Today", "Learning", "Projects", "Focus", "Tasks", "News", "Settings"])
        XCTAssertEqual(destinations.map(\.symbol), ["house", "book", "folder", "timer", "checkmark.square", "newspaper", "gearshape"])
        for destination in destinations {
            XCTAssertNotNil(NSImage(systemSymbolName: destination.symbol, accessibilityDescription: destination.title))
            XCTAssertEqual(AppShell.navigationTraits(for: destination, selected: destination), .isSelected)
            XCTAssertEqual(AppShell.navigationTraits(for: destination, selected: .today).contains(.isSelected), destination == .today)
            if destination == .today {
                XCTAssertEqual(AppShell.contentKind(for: destination), .today)
            } else if destination == .tasks {
                XCTAssertEqual(AppShell.contentKind(for: destination), .tasks)
            } else if destination == .settings {
                XCTAssertEqual(AppShell.contentKind(for: destination), .settings)
            } else {
                XCTAssertEqual(AppShell.contentKind(for: destination), .foundation(destination))
                XCTAssertFalse(destination.foundationMessage.isEmpty)
            }
        }
    }

    func testRenderedNavigationAccessibilityAndKeyboardOrder() throws {
        let suite = "AppShellAXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let host = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: try makeDependencies()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "AppShell accessibility inspection"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        // Do not close the test window: XCTest's autorelease checker crashes when an
        // NSHostingView-backed test window is closed during the test on this SDK.
        defer { window.orderOut(nil) }
        let appAX = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func descendants(of element: AXUIElement) -> [AXUIElement] {
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.flatMap { [$0] + descendants(of: $0) }
        }
        func inspectedWindow() throws -> AXUIElement {
            var windows: CFTypeRef?
            XCTAssertEqual(AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windows), .success)
            return try XCTUnwrap((windows as? [AXUIElement])?.first {
                attribute($0, kAXTitleAttribute) as? String == window.title
            })
        }
        func navButtons() throws -> [AXUIElement] {
            descendants(of: try inspectedWindow()).filter {
                (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("navigation-") == true
            }
        }
        func focusedIdentifier() throws -> String {
            let value = try XCTUnwrap(attribute(appAX, kAXFocusedUIElementAttribute))
            XCTAssertEqual(CFGetTypeID(value), AXUIElementGetTypeID())
            return try XCTUnwrap(attribute(unsafeBitCast(value, to: AXUIElement.self), kAXIdentifierAttribute) as? String)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }

        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            navigation.select(.today)
            host.layoutSubtreeIfNeeded()
            settle()
            let expected = AppDestination.allCases
            XCTAssertEqual(try navButtons().count, expected.count)
            for selected in expected {
                navigation.select(selected)
                settle()
                let buttons = try navButtons()
                XCTAssertEqual(buttons.compactMap { attribute($0, kAXIdentifierAttribute) as? String },
                               expected.map { "navigation-\($0.rawValue)" })
                for (destination, button) in zip(expected, buttons) {
                    XCTAssertEqual(attribute(button, kAXRoleAttribute) as? String, kAXButtonRole)
                    XCTAssertEqual(attribute(button, kAXDescriptionAttribute) as? String, destination.title)
                    // macOS omits AXSelected for unselected buttons; it is true only on the active one.
                    XCTAssertEqual((attribute(button, kAXSelectedAttribute) as? NSNumber)?.boolValue == true,
                                   destination == selected)
                }
            }
            // Native Tab traversal uses the window's next-key-view chain. Verify the
            // actually focused AX elements, not the enum order or SwiftUI focus helpers.
            XCTAssertEqual(try focusedIdentifier(), "navigation-today")
            for destination in expected.dropFirst() {
                window.selectNextKeyView(nil)
                settle()
                XCTAssertEqual(try focusedIdentifier(), "navigation-\(destination.rawValue)")
            }
            window.selectNextKeyView(nil)
            settle()
            XCTAssertEqual(try focusedIdentifier(), "navigation-today")

            // Invoke the rendered accessibility buttons, not NavigationStore directly.
            for destination in expected {
                let button = try XCTUnwrap(navButtons().first {
                    attribute($0, kAXIdentifierAttribute) as? String == "navigation-\(destination.rawValue)"
                })
                XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
                settle()
                XCTAssertEqual(navigation.selectedDestination, destination)
                XCTAssertEqual((attribute(try XCTUnwrap(navButtons().first {
                    attribute($0, kAXIdentifierAttribute) as? String == "navigation-\(destination.rawValue)"
                }), kAXSelectedAttribute) as? NSNumber)?.boolValue, true)
            }
        }
    }

    func testSelectionUpdatesRouteAtBothReferenceSizes() throws {
        let suite = "AppShellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let host = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: try makeDependencies()))
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
            navigation.select(.today)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            // Render the real SwiftUI view, not a fixture with invented records.
            let captureDirectory = URL(fileURLWithPath: "/tmp/kontrol-shell-captures", isDirectory: true)
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            let image = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            host.cacheDisplay(in: host.bounds, to: image)
            let capture = captureDirectory.appendingPathComponent("today-\(Int(size.width))x\(Int(size.height)).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: capture)
            XCTAssertEqual(host.frame.size, size)
            for destination in AppDestination.allCases {
                navigation.select(destination)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(navigation.selectedDestination, destination)
                if let saved = defaults.string(forKey: UserDefaultsDestinationPreferences.key) {
                    XCTAssertEqual(saved, destination.rawValue)
                } else {
                    XCTAssertEqual(destination, .today) // Initial selection is not rewritten.
                }
            }
        }
    }
}
