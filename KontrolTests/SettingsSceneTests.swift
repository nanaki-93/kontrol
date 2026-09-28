import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

private actor SettingsCatalogGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class SettingsSceneTests: XCTestCase {
    private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func axDescendants(_ element: AXUIElement) -> [AXUIElement] {
        let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + axDescendants($0) }
    }

    private func axWindow(_ window: NSWindow) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var match: AXUIElement?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            match = (axAttribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
                axAttribute($0, kAXTitleAttribute) as? String == window.title
            }
        } while match == nil && Date() < deadline
        return try XCTUnwrap(match, "Hosted Settings window did not enter the AX tree")
    }

    private func axFrame(_ element: AXUIElement) throws -> CGRect {
        let position = try XCTUnwrap(axAttribute(element, kAXPositionAttribute))
        let size = try XCTUnwrap(axAttribute(element, kAXSizeAttribute))
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions))
        return CGRect(origin: origin, size: dimensions)
    }

    func testUnfinishedDestinationsShowHonestNoninteractiveFoundationStates() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Foundation destination inspection"
        let host = NSHostingView(rootView: FoundationView(destination: .projects)
            .environment(\.appTextScaleOverride, 1.3))
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let appAX = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func descendants(_ element: AXUIElement) -> [AXUIElement] {
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.flatMap { [$0] + descendants($0) }
        }
        for destination in [AppDestination.projects, .focus, .news] {
            host.rootView = FoundationView(destination: destination)
                .environment(\.appTextScaleOverride, 1.3)
            host.layoutSubtreeIfNeeded()
            var destinationWindow: AXUIElement?
            let deadline = Date().addingTimeInterval(2)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let windows = attribute(appAX, kAXWindowsAttribute) as? [AXUIElement] ?? []
                destinationWindow = windows.first { attribute($0, kAXTitleAttribute) as? String == window.title }
            } while destinationWindow == nil && Date() < deadline
            let axWindow = try XCTUnwrap(destinationWindow)
            let surface = try XCTUnwrap(descendants(axWindow).first {
                attribute($0, kAXIdentifierAttribute) as? String == "\(destination.rawValue)-content"
            })
            let nodes = [surface] + descendants(surface)
            func hasText(_ text: String, role: String? = nil) -> Bool {
                nodes.contains {
                    (role == nil || attribute($0, kAXRoleAttribute) as? String == role) &&
                    (attribute($0, kAXValueAttribute) as? String == text ||
                     attribute($0, kAXDescriptionAttribute) as? String == text)
                }
            }
            XCTAssertTrue(hasText(destination.title, role: kAXHeadingRole), "\(destination) heading")
            XCTAssertTrue(hasText(destination.foundationMessage), "\(destination) honest empty state")
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole },
                           "\(destination) has no action until its feature ships")
        }
    }

    func testCompactSettingsRecoveryActionsRemainVisibleAt130Percent() async throws {
        var opens = 0
        let launch = LaunchCoordinator(open: {
            opens += 1
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Enlarged Settings recovery inspection"
        window.contentView = NSHostingView(rootView: SettingsSceneContent(launch: launch)
            .environment(\.appTextScaleOverride, 1.3))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let failed = expectation(description: "Settings entered blocking recovery")
        Task { @MainActor in
            while launch.state == .idle || launch.state == .opening { await Task.yield() }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 10)
        guard case .failed = launch.state else { return XCTFail("Expected failure") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bounds = try axFrame(axWindow(window))
        let nodes = axDescendants(try axWindow(window))
        for (identifier, label) in [("recovery-quit", "Quit"), ("recovery-retry", "Try again")] {
            let action = try XCTUnwrap(nodes.first {
                axAttribute($0, kAXIdentifierAttribute) as? String == identifier
            })
            XCTAssertEqual(axAttribute(action, kAXRoleAttribute) as? String, kAXButtonRole)
            XCTAssertEqual(axAttribute(action, kAXDescriptionAttribute) as? String, label)
            XCTAssertTrue(bounds.contains(try axFrame(action)), "\(label) must remain inside compact Settings")
        }
        XCTAssertEqual(opens, 1)
        XCTAssertNil(launch.dependencies)
    }

    func testSettingsOpenedDuringInitializationAndWindowReopenUseOneGraph() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let gate = SettingsCatalogGate()
        let entered = expectation(description: "Settings requested catalog")
        var opens = 0
        var imports = 0
        let launch = LaunchCoordinator(open: {
            opens += 1
            return container
        }, loadCatalog: {
            entered.fulfill()
            await gate.wait()
            return try BundledCatalogLoader.load()
        }, makeRepository: { container in
            SwiftDataCatalogRepository(container: container, beforeSave: { imports += 1 })
        })
        let suite = "SettingsSceneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))

        // Hosting both real scene roots causes each .task to request startup. The
        // Settings scene may be the first window and must not own a separate store.
        func show<V: View>(_ view: V, title: String, size: CGSize = CGSize(width: 1000, height: 700)) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = title
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            return window
        }
        let settingsWindow = show(SettingsSceneContent(launch: launch)
            .environment(\.appTextScaleOverride, 1.3), title: "Settings scene test",
            size: CGSize(width: 520, height: 340))
        // NSHostingView-backed XCTest windows are ordered out, not closed, to
        // avoid the SDK's window-close autorelease checker crash.
        defer { settingsWindow.orderOut(nil) }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(launch.state, .opening)
        XCTAssertNil(launch.dependencies)
        XCTAssertEqual(settingsWindow.contentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                       .darkAqua, "Native Settings root must request the fixed dark appearance")
        let openingSettings = axDescendants(try axWindow(settingsWindow))
        let loading = try XCTUnwrap(openingSettings.first {
            axAttribute($0, kAXDescriptionAttribute) as? String == "Loading: Opening Kontrol" ||
            axAttribute($0, kAXValueAttribute) as? String == "Loading: Opening Kontrol"
        })
        XCTAssertFalse(try axFrame(loading).isEmpty, "Loading label must have rendered bounds")
        XCTAssertFalse(openingSettings.contains { axAttribute($0, kAXIdentifierAttribute) as? String == "settings-content" })
        let mainWindow = show(MainWindowContent(launch: launch, navigation: navigation), title: "Main window test")
        defer { mainWindow.orderOut(nil) }
        XCTAssertEqual(mainWindow.contentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                       .darkAqua, "Main root must request the fixed dark appearance")
        let openingMain = axDescendants(try axWindow(mainWindow))
        XCTAssertTrue(openingMain.contains {
            axAttribute($0, kAXDescriptionAttribute) as? String == "Loading: Opening Kontrol" ||
            axAttribute($0, kAXValueAttribute) as? String == "Loading: Opening Kontrol"
        }, "Main opening must use the same readable loading state")
        XCTAssertFalse(openingMain.contains { axAttribute($0, kAXIdentifierAttribute) as? String == "settings-content" })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 0)
        XCTAssertNil(launch.dependencies)
        await gate.release()
        // Wait for the observed ready state, then verify both routes use its graph.
        let ready = expectation(description: "shared launch finished")
        Task { @MainActor in
            while launch.state == .opening { await Task.yield() }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(launch.state, .ready)
        let graph = try XCTUnwrap(launch.dependencies)
        XCTAssertTrue(graph.container === container)
        XCTAssertTrue(FoundationSettingsView(dependencies: graph).dependencies === graph)
        XCTAssertTrue(AppShell(navigation: navigation, dependencies: graph).dependencies === graph)
        navigation.select(.settings)
        XCTAssertEqual(AppShell.contentKind(for: navigation.selectedDestination), .settings)

        let appAX = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func descendants(_ element: AXUIElement) -> [AXUIElement] {
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.flatMap { [$0] + descendants($0) }
        }
        func settingsSurface(_ window: AXUIElement) throws -> AXUIElement {
            try XCTUnwrap(descendants(window).first {
                attribute($0, kAXIdentifierAttribute) as? String == "settings-content"
            })
        }
        func assertFoundationContent(_ surface: AXUIElement) {
            let nodes = [surface] + descendants(surface)
            XCTAssertEqual(nodes.filter {
                attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
                (attribute($0, kAXValueAttribute) as? String == "Settings" ||
                 attribute($0, kAXDescriptionAttribute) as? String == "Settings")
            }.count, 1)
            XCTAssertTrue(nodes.contains {
                attribute($0, kAXValueAttribute) as? String == "No settings available yet." ||
                attribute($0, kAXDescriptionAttribute) as? String == "No settings available yet."
            })
            XCTAssertFalse(nodes.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole },
                           "Foundation Settings must not advertise controls before F13")
        }
        try await Task.sleep(for: .milliseconds(100))
        // At 130% the Settings scene retains a compact window and its entire
        // foundation message remains visible. It has no phantom F13 actions.
        let settingsAX = try axWindow(settingsWindow)
        let settingsBounds = try axFrame(settingsAX)
        XCTAssertGreaterThanOrEqual(settingsBounds.width, 520)
        XCTAssertGreaterThanOrEqual(settingsBounds.height, 340)
        let settingsNodes = axDescendants(settingsAX)
        let emptyMessage = try XCTUnwrap(settingsNodes.first {
            axAttribute($0, kAXValueAttribute) as? String == "No settings available yet." ||
            axAttribute($0, kAXDescriptionAttribute) as? String == "No settings available yet."
        })
        let messageBounds = try axFrame(emptyMessage)
        XCTAssertTrue(settingsBounds.contains(messageBounds), "130% message must be visible in compact Settings")
        let enlargedHeading = try XCTUnwrap(settingsNodes.first {
            axAttribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
            (axAttribute($0, kAXValueAttribute) as? String == "Settings" ||
             axAttribute($0, kAXDescriptionAttribute) as? String == "Settings")
        })
        let standardWindow = show(SettingsSceneContent(launch: launch), title: "Standard Settings comparison",
                                  size: CGSize(width: 520, height: 340))
        defer { standardWindow.orderOut(nil) }
        let standardHeading = try XCTUnwrap(axDescendants(try axWindow(standardWindow)).first {
            axAttribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
            (axAttribute($0, kAXValueAttribute) as? String == "Settings" ||
             axAttribute($0, kAXDescriptionAttribute) as? String == "Settings")
        })
        XCTAssertGreaterThan(try axFrame(enlargedHeading).height, try axFrame(standardHeading).height)
        // Stress beyond 130% in the same compact viewport: content must be
        // scrollable rather than cut off by a 340-point fixed frame.
        let overflowWindow = show(SettingsSceneContent(launch: launch)
            .environment(\.appTextScaleOverride, 4), title: "Overflow Settings inspection",
            size: CGSize(width: 520, height: 340))
        defer { overflowWindow.orderOut(nil) }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let current = (view as? NSScrollView).map { [$0] } ?? []
            return current + view.subviews.flatMap(scrollViews)
        }
        overflowWindow.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let scroll = try XCTUnwrap(overflowWindow.contentView.flatMap { scrollViews(in: $0).first })
        scroll.layoutSubtreeIfNeeded()
        let documentHeight = try XCTUnwrap(scroll.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, scroll.contentView.bounds.height,
                             "Oversized Settings content must overflow into a scroll view")
        XCTAssertEqual(opens, 1, "Appearance/layout changes must not initialize a second graph")
        var windows: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windows), .success)
        let visible = try XCTUnwrap(windows as? [AXUIElement])
        for title in ["Settings scene test", "Main window test"] {
            let window = try XCTUnwrap(visible.first { attribute($0, kAXTitleAttribute) as? String == title })
            assertFoundationContent(try settingsSurface(window))
        }

        // A native Settings scene supplies the standard application-menu command.
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
        }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let settingsCommand = try XCTUnwrap(menuItems(menu).first {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        })
        XCTAssertTrue(settingsCommand.isEnabled)
        XCTAssertTrue(settingsCommand.title.contains("Settings"))
        XCTAssertTrue(NSApp.sendAction(settingsCommand.action!, to: settingsCommand.target, from: settingsCommand))
        try await Task.sleep(for: .milliseconds(100))
        let nativeSettings = try XCTUnwrap(NSApp.windows.first { $0.title == "Kontrol Settings" && $0.isVisible })
        defer { nativeSettings.orderOut(nil) }
        XCTAssertEqual(nativeSettings.contentView?.frame.width ?? 0, 520, accuracy: 40)
        XCTAssertEqual(nativeSettings.contentView?.frame.height ?? 0, 340, accuracy: 40)
        var nativeWindows: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &nativeWindows), .success)
        let nativeAX = try XCTUnwrap((nativeWindows as? [AXUIElement])?.first {
            attribute($0, kAXTitleAttribute) as? String == nativeSettings.title
        })
        assertFoundationContent(try settingsSurface(nativeAX))
        XCTAssertTrue(launch.dependencies === graph)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)

        mainWindow.orderOut(nil)
        let reopened = show(MainWindowContent(launch: launch, navigation: navigation), title: "Reopened main window")
        defer { reopened.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(launch.dependencies === graph)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CatalogImportState>()).count, 1)
    }
}
