import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

private actor PresentationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class RecoveryPresentationTests: XCTestCase {
    private enum Injected: Error { case unavailable }

    private func window<V: View>(for view: V, size: CGSize = CGSize(width: 1000, height: 700)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Recovery presentation test \(UUID().uuidString)"
        window.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func descendants(_ element: AXUIElement) -> [AXUIElement] {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + descendants($0) }
    }

    private func elements(in window: NSWindow) throws -> [AXUIElement] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        // The test host registers windows asynchronously. Use the unique test
        // title and fall back to the focused window during scene transitions.
        AXUIElementSetMessagingTimeout(app, 2)
        let deadline = Date().addingTimeInterval(3)
        var lastError: AXError = .success
        repeat {
            var windows: CFTypeRef?
            lastError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            var roots = windows as? [AXUIElement] ?? []
            if let focused = attribute(app, kAXFocusedWindowAttribute) {
                roots.append(unsafeBitCast(focused, to: AXUIElement.self))
            }
            if let root = roots.first(where: {
                attribute($0, kAXTitleAttribute) as? String == window.title
            }) {
                return descendants(root)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        XCTFail("Recovery window \(window.windowNumber) missing from AX tree (AXWindows: \(lastError.rawValue), visible: \(window.isVisible))")
        return []
    }

    private func identified(_ id: String, in window: NSWindow) throws -> AXUIElement {
        try XCTUnwrap(elements(in: window).first {
            attribute($0, kAXIdentifierAttribute) as? String == id
        })
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }

    func testStoreFailureBlocksShellAndRetryIsDisabledDuringSerializedOpening() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let gate = PresentationGate()
        let entered = expectation(description: "retry reached catalog")
        var opens = 0
        let launch = LaunchCoordinator(open: {
            opens += 1
            if opens == 1 { throw Injected.unavailable }
            return container
        }, loadCatalog: {
            entered.fulfill()
            await gate.wait()
            return try BundledCatalogLoader.load()
        })
        let suite = "RecoveryPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let main = window(for: MainWindowContent(launch: launch, navigation: navigation))
        defer { main.orderOut(nil) }
        await launch.start()
        settle()
        XCTAssertEqual(launch.state, .failed(.store))
        XCTAssertNil(launch.dependencies)
        let visible = try elements(in: main)
        XCTAssertFalse(visible.contains { (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("navigation-") == true })
        XCTAssertEqual(attribute(try identified("recovery-title", in: main), kAXDescriptionAttribute) as? String,
                       "Cannot open local data")
        let guidance = attribute(try identified("recovery-guidance", in: main), kAXValueAttribute) as? String ?? ""
        XCTAssertTrue(guidance.contains("not been reset"))
        XCTAssertEqual(attribute(try identified("recovery-quit", in: main), kAXRoleAttribute) as? String, kAXButtonRole)
        let retry = try identified("recovery-retry", in: main)
        XCTAssertEqual(attribute(retry, kAXRoleAttribute) as? String, kAXButtonRole)
        XCTAssertEqual(attribute(retry, kAXEnabledAttribute) as? NSNumber, true)
        XCTAssertEqual(AXUIElementPerformAction(retry, kAXPressAction as CFString), .success)
        await fulfillment(of: [entered], timeout: 10)
        settle()
        XCTAssertEqual(launch.state, .opening)
        XCTAssertNil(launch.dependencies)
        XCTAssertEqual(attribute(try identified("recovery-retry", in: main), kAXEnabledAttribute) as? NSNumber, false)
        XCTAssertFalse(try elements(in: main).contains {
            (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("navigation-") == true
        })
        await launch.retry() // ignored while opening
        XCTAssertEqual(opens, 2)
        await gate.release()
        let ready = expectation(description: "ready after explicit retry")
        Task { @MainActor in
            while launch.state == .opening { await Task.yield() }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 10)
        settle()
        XCTAssertEqual(launch.state, .ready)
        XCTAssertTrue(launch.dependencies?.container === container)
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(try elements(in: main).filter {
            (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("navigation-") == true
        }.count, 7)
    }

    func testRecoveryLayoutAtReferenceSizes() async throws {
        let launch = LaunchCoordinator(open: { throw Injected.unavailable })
        await launch.start()
        XCTAssertEqual(launch.state, .failed(.store))
        let directory = URL(fileURLWithPath: "/tmp/kontrol-recovery-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
            let host = NSHostingView(rootView: RecoveryView(failure: .store, launch: launch))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            host.cacheDisplay(in: host.bounds, to: image)
            let path = directory.appendingPathComponent("store-\(Int(size.width))x\(Int(size.height)).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: path)
            XCTAssertEqual(host.frame.size, size)
            // Check the cues by region rather than a single layout-dependent pixel.
            let accentPixels = (20..<Int(size.width - 20)).filter { x in
                (65..<135).contains { y in
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return c.redComponent > c.greenComponent + 0.12 && c.redComponent > 0.3
                }
            }
            XCTAssertGreaterThan(accentPixels.count, 20, "Frozen shell retains the Today accent")
            let dimInk = (30..<min(350, Int(size.width / 2))).contains { x in
                (155..<min(300, Int(size.height / 2))).contains { y in
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return c.redComponent > 0.055 && c.redComponent < 0.3
                }
            }
            XCTAssertTrue(dimInk, "Frozen shell context must remain visible")
        }
    }

    private func assertActionsVisible(in window: NSWindow) throws {
        let screenTop = try XCTUnwrap(window.screen).frame.maxY
        let windowFrame = CGRect(x: window.frame.minX, y: screenTop - window.frame.maxY,
                                 width: window.frame.width, height: window.frame.height)
        for id in ["recovery-quit", "recovery-retry"] {
            let action = try identified(id, in: window)
            let position = unsafeBitCast(try XCTUnwrap(attribute(action, kAXPositionAttribute)), to: AXValue.self)
            let size = unsafeBitCast(try XCTUnwrap(attribute(action, kAXSizeAttribute)), to: AXValue.self)
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            XCTAssertTrue(AXValueGetValue(position, .cgPoint, &origin))
            XCTAssertTrue(AXValueGetValue(size, .cgSize, &dimensions))
            let frame = CGRect(origin: origin, size: dimensions)
            XCTAssertGreaterThanOrEqual(frame.width, AppMetrics.minimumTarget)
            XCTAssertGreaterThanOrEqual(frame.height, AppMetrics.minimumTarget)
            XCTAssertTrue(windowFrame.contains(frame), "\(id) clipped: \(frame), window: \(windowFrame)")
        }
    }

    func testEnlargedRecoveryKeepsBothActionsVisibleAndFocusable() async throws {
        let launch = LaunchCoordinator(open: { throw Injected.unavailable })
        await launch.start()
        for size in [CGSize(width: 520, height: 340), CGSize(width: 1000, height: 700),
                     CGSize(width: 1440, height: 940)] {
            let recovery = window(for: RecoveryView(failure: .store, launch: launch)
                .environment(\.appTextScaleOverride, 1.3), size: size)
            defer { recovery.orderOut(nil) }
            settle()
            try assertActionsVisible(in: recovery)
            XCTAssertFalse(try elements(in: recovery).contains {
                (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("navigation-") == true
            })
            XCTAssertEqual(attribute(try identified("recovery-retry", in: recovery), kAXEnabledAttribute) as? NSNumber, true)
            // Tab visits only Quit and Retry; frozen shell cannot take focus.
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let initial = attribute(app, kAXFocusedUIElementAttribute)
            XCTAssertEqual(attribute(unsafeBitCast(try XCTUnwrap(initial), to: AXUIElement.self),
                                     kAXIdentifierAttribute) as? String, "recovery-quit")
            recovery.selectNextKeyView(nil)
            settle()
            let first = attribute(app, kAXFocusedUIElementAttribute)
            XCTAssertEqual(attribute(unsafeBitCast(try XCTUnwrap(first), to: AXUIElement.self),
                                     kAXIdentifierAttribute) as? String, "recovery-retry")
            recovery.selectNextKeyView(nil)
            settle()
            let second = attribute(app, kAXFocusedUIElementAttribute)
            XCTAssertEqual(attribute(unsafeBitCast(try XCTUnwrap(second), to: AXUIElement.self),
                                     kAXIdentifierAttribute) as? String, "recovery-quit")
            recovery.orderOut(nil)
        }
    }

    func testCatalogFailureGuidanceAndAccessibleQuitAction() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var opens = 0
        let launch = LaunchCoordinator(open: { opens += 1; return container }, loadCatalog: {
            throw Injected.unavailable
        })
        await launch.start()
        XCTAssertEqual(launch.state, .failed(.catalog))
        var quits = 0
        let recovery = window(for: RecoveryView(failure: .catalog, launch: launch, onQuit: { quits += 1 }),
                              size: CGSize(width: 520, height: 340))
        defer { recovery.orderOut(nil) }
        settle()
        let host = try XCTUnwrap(recovery.contentView)
        let compactImage = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 520, pixelsHigh: 340,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        host.cacheDisplay(in: host.bounds, to: compactImage)
        let capture = URL(fileURLWithPath: "/tmp/kontrol-recovery-captures/catalog-520x340.png")
        try FileManager.default.createDirectory(at: capture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(compactImage.representation(using: .png, properties: [:])).write(to: capture)
        XCTAssertEqual(attribute(try identified("recovery-title", in: recovery), kAXDescriptionAttribute) as? String,
                       "Cannot load starter lessons")
        let guidance = attribute(try identified("recovery-guidance", in: recovery), kAXValueAttribute) as? String ?? ""
        XCTAssertTrue(guidance.contains("Starter lessons"))
        XCTAssertTrue(guidance.contains("not been reset"))
        // Both actions participate in native keyboard focus, in visible order.
        recovery.makeKeyAndOrderFront(nil)
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var focused: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused), .success)
        XCTAssertEqual(attribute(unsafeBitCast(try XCTUnwrap(focused), to: AXUIElement.self),
                                 kAXIdentifierAttribute) as? String, "recovery-quit")
        recovery.selectNextKeyView(nil)
        settle()
        focused = nil
        XCTAssertEqual(AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused), .success)
        XCTAssertEqual(attribute(unsafeBitCast(try XCTUnwrap(focused), to: AXUIElement.self),
                                 kAXIdentifierAttribute) as? String, "recovery-retry")
        recovery.selectNextKeyView(nil)
        settle()
        focused = nil
        XCTAssertEqual(AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused), .success)
        XCTAssertEqual(attribute(unsafeBitCast(try XCTUnwrap(focused), to: AXUIElement.self),
                                 kAXIdentifierAttribute) as? String, "recovery-quit")
        let quit = try identified("recovery-quit", in: recovery)
        XCTAssertEqual(attribute(quit, kAXRoleAttribute) as? String, kAXButtonRole)
        try assertActionsVisible(in: recovery)
        XCTAssertEqual(AXUIElementPerformAction(quit, kAXPressAction as CFString), .success)
        settle()
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(opens, 1)
        XCTAssertNil(launch.dependencies)
        XCTAssertFalse(try elements(in: recovery).contains {
            (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("navigation-") == true
        })
    }
}
