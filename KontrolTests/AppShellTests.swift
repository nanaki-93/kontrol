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

    func testOneStorePerDependencyGraphAcrossRoutesAndWindows() throws {
        let dependencies = try makeDependencies()
        let shared = dependencies.taskStore
        let sharedSchedule = dependencies.scheduleStore
        let first = AppShell(navigation: NavigationStore(), dependencies: dependencies)
        let second = AppShell(navigation: NavigationStore(), dependencies: dependencies)
        XCTAssertTrue(first.dependencies.taskStore === shared)
        XCTAssertTrue(second.dependencies.taskStore === shared)
        XCTAssertTrue(first.dependencies.scheduleStore === sharedSchedule)
        XCTAssertTrue(second.dependencies.scheduleStore === sharedSchedule)
        XCTAssertTrue(first.dependencies.container === second.dependencies.container)
        XCTAssertTrue((shared.repository as AnyObject) === (dependencies.taskStore.repository as AnyObject))
        XCTAssertTrue((sharedSchedule.repository as AnyObject) === (dependencies.scheduleStore.repository as AnyObject))
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let block = try first.dependencies.scheduleStore.create(input: ScheduleInput(
            title: "Shared block", startAt: start, endAt: start.addingTimeInterval(3600)))
        XCTAssertEqual(second.dependencies.scheduleStore.snapshots.map(\.id), [block.id])
        XCTAssertEqual(try SwiftDataScheduleRepository(container: dependencies.container).fetchAll(), [block])

        let other = try makeDependencies()
        XCTAssertFalse(other.taskStore === shared)
        XCTAssertFalse(other.scheduleStore === sharedSchedule)
        XCTAssertFalse(other.container === dependencies.container)
        XCTAssertFalse((other.taskStore.repository as AnyObject) === (shared.repository as AnyObject))
        XCTAssertFalse((other.scheduleStore.repository as AnyObject) === (sharedSchedule.repository as AnyObject))
    }

    func testWindowCloseGuardVetoesFailedFlushAndAllowsRetry() {
        var canClose = false
        let guardView = WindowCloseGuard(flush: { canClose })
        let coordinator = guardView.makeCoordinator()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        coordinator.install(window)
        XCTAssertFalse(coordinator.windowShouldClose(window))
        XCTAssertTrue(window.delegate === coordinator)
        canClose = true
        coordinator.flush = { canClose }
        XCTAssertTrue(coordinator.windowShouldClose(window))
        coordinator.uninstall()
    }

    func testShellUsesAppOwnedDraftsAndStableIDRouteAcrossSlotRotation() throws {
        let dependencies = try makeDependencies()
        let repository = dependencies.catalogRepository
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        dependencies.learningCatalogStore.loadIfNeeded()
        let slot = try XCTUnwrap(dependencies.learningCatalogStore.state.snapshot?.slots.first)
        let navigation = NavigationStore()
        let shell = AppShell(navigation: navigation, dependencies: dependencies)
        XCTAssertTrue(shell.dependencies.lessonDraftStore === dependencies.lessonDraftStore)
        navigation.attachDrafts(shell.dependencies.lessonDraftStore)
        navigation.showLesson(id: slot.lessonID)
        _ = try dependencies.learningCatalogStore.dismiss(lessonID: slot.lessonID, expectedSlot: slot)
        XCTAssertFalse(dependencies.learningCatalogStore.state.snapshot?.slots.contains { $0.lessonID == slot.lessonID } ?? true)
        XCTAssertEqual(navigation.learningRoute, .detail(slot.lessonID))
        navigation.backToChoices()
        XCTAssertEqual(navigation.learningRoute, .choices)
    }

    func testNavigationMetadataAndRouting() throws {
        let destinations = AppDestination.allCases
        XCTAssertEqual(destinations.map(\.title), ["Today", "Learning", "Projects", "Focus", "Tasks", "News", "Settings"])
        XCTAssertEqual(destinations.map(\.symbol), ["house", "book", "folder", "timer", "checkmark.square", "newspaper", "gearshape"])
        for destination in destinations {
            XCTAssertNotNil(NSImage(systemSymbolName: destination.symbol, accessibilityDescription: destination.title))
            XCTAssertEqual(AppShell.navigationTraits(for: destination, selected: destination), .isSelected)
            XCTAssertEqual(AppShell.navigationTraits(for: destination, selected: .today).contains(.isSelected), destination == .today)
            if destination == .today {
                XCTAssertEqual(AppShell.contentKind(for: destination), .today)
            } else if destination == .learning {
                XCTAssertEqual(AppShell.contentKind(for: destination), .learning)
            } else if destination == .focus {
                XCTAssertEqual(AppShell.contentKind(for: destination), .focus)
            } else if destination == .tasks {
                XCTAssertEqual(AppShell.contentKind(for: destination), .tasks)
            } else if destination == .settings {
                XCTAssertEqual(AppShell.contentKind(for: destination), .settings)
            } else {
                XCTAssertEqual(AppShell.contentKind(for: destination), .foundation(destination))
                XCTAssertFalse(destination.foundationMessage.isEmpty)
            }
        }
        // The shell consumes the same coherent destination + ID route published
        // by the guarded entry operation. Rendering the detail only reads it.
        let dependencies = try makeDependencies()
        _ = try dependencies.catalogRepository.importIfNeeded(BundledCatalogLoader.load())
        dependencies.learningCatalogStore.loadIfNeeded()
        let id = try XCTUnwrap(dependencies.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let suite = "AppShellRouting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let shell = AppShell(navigation: navigation, dependencies: dependencies)
        navigation.attachDrafts(shell.dependencies.lessonDraftStore)
        XCTAssertEqual(AppShell.contentKind(for: navigation.selectedDestination), .today)
        navigation.enterLesson(id: id)
        XCTAssertEqual(AppShell.contentKind(for: navigation.selectedDestination), .learning)
        XCTAssertEqual(navigation.learningRoute, .detail(id))
        XCTAssertNil(try dependencies.catalogRepository.loadLesson(lessonID: id).attempt)
    }

    func testRenderedNavigationAccessibilityAndKeyboardOrder() throws {
        let suite = "AppShellAXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unchanged", forKey: "unrelated-preference")
        defaults.set(AppDestination.today.rawValue, forKey: UserDefaultsDestinationPreferences.key)
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let host = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: try makeDependencies())
            .environment(\.appTextScaleOverride, CGFloat(1)))
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
            // AX can register a newly ordered hosting window asynchronously. Keep
            // the bounded wait and report host trust on failure: an untrusted test
            // host cannot supply the window tree, regardless of AppKit visibility.
            let deadline = Date().addingTimeInterval(2)
            repeat {
                var windows: CFTypeRef?
                if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windows) == .success,
                   let match = (windows as? [AXUIElement])?.first(where: {
                       attribute($0, kAXTitleAttribute) as? String == window.title
                   }) {
                    return match
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            } while Date() < deadline
            var windows: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windows)
            let titles = (windows as? [AXUIElement] ?? []).compactMap { attribute($0, kAXTitleAttribute) as? String }
            throw NSError(domain: "AppShellAX", code: Int(status.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "AX window missing; AX titles=\(titles), AppKit titles=\(NSApp.windows.map(\.title)), active=\(NSApp.isActive), running=\(NSApp.isRunning), trusted=\(AXIsProcessTrusted()), key=\(window.isKeyWindow), visible=\(window.isVisible), frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), hostPID=\(ProcessInfo.processInfo.processIdentifier)"
            ])
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
        func frame(of button: AXUIElement) throws -> CGRect {
            let positionValue = try XCTUnwrap(attribute(button, kAXPositionAttribute))
            let sizeValue = try XCTUnwrap(attribute(button, kAXSizeAttribute))
            XCTAssertEqual(CFGetTypeID(positionValue), AXValueGetTypeID())
            XCTAssertEqual(CFGetTypeID(sizeValue), AXValueGetTypeID())
            var position = CGPoint.zero
            var size = CGSize.zero
            XCTAssertTrue(AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position))
            XCTAssertTrue(AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size))
            return CGRect(origin: position, size: size)
        }

        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
          for scale: CGFloat in [1, 1.3, 1.6, 2.4] {
            if scale != 1 || size.width == 1440 {
                host.rootView = AppShell(navigation: navigation, dependencies: try makeDependencies())
                    .environment(\.appTextScaleOverride, scale)
            }
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            navigation.select(.today)
            host.layoutSubtreeIfNeeded()
            settle()
            let expected = AppDestination.allCases
            let initialButtons = try navButtons()
            XCTAssertEqual(initialButtons.count, expected.count)
            let frames = try initialButtons.map(frame)
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.width, AppMetrics.minimumTarget)
                XCTAssertGreaterThanOrEqual(frame.height, AppMetrics.minimumTarget)
                XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, window.frame.minY - 1)
                XCTAssertLessThanOrEqual(frame.maxY, window.frame.maxY + 1)
            }
            for (destination, frame) in zip(expected, frames) {
                let font = NSFont.monospacedSystemFont(ofSize: AppTypography.pointSize(.navigation, for: .large, override: scale), weight: .regular)
                let textWidth = (destination.title as NSString).size(withAttributes: [.font: font]).width
                // The symbol, gap and full-size glyphs must fit without scale-to-fit.
                XCTAssertGreaterThan(frame.width, textWidth + AppMetrics.space2 + font.pointSize)
            }
            // AX children must be in the same row-major order as their screen positions.
            let rowStarts: Set<Int> = scale >= 2 ? [2, 4, 6] : scale >= 1.6 ? [3, 5] : scale >= 1.3 ? [4] : []
            for index in 1..<frames.count {
                if rowStarts.contains(index) {
                    XCTAssertGreaterThan(frames[index].minY, frames[index - 1].minY + 32)
                    XCTAssertLessThan(frames[index].minX, frames[index - 1].minX)
                } else {
                    XCTAssertEqual(frames[index].minY, frames[index - 1].minY, accuracy: 4)
                    XCTAssertGreaterThan(frames[index].minX, frames[index - 1].minX)
                }
            }
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
            window.makeFirstResponder(nil)
            settle()
            func renderedPixels() throws -> Data {
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            }
            if scale == 1 || scale == 1.3 {
                navigation.select(.today)
                settle()
                let directory = URL(fileURLWithPath: "/tmp/kontrol-f01-evidence/fixtures", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try renderedPixels().write(to: directory.appendingPathComponent(
                    "today-\(Int(size.width))x\(Int(size.height))-\(scale == 1 ? "standard" : "130pct").png"))
                navigation.select(.settings) // No content action interrupts wraparound tab order.
                settle()
            }
            let unfocused = try renderedPixels()
            window.selectNextKeyView(nil)
            settle()
            XCTAssertEqual(try focusedIdentifier(), "navigation-today", "size \(size), scale \(scale)")
            XCTAssertNotEqual(try renderedPixels(), unfocused, "Keyboard focus must have a visible treatment")
            for destination in expected.dropFirst() {
                window.selectNextKeyView(nil)
                settle()
                XCTAssertEqual(try focusedIdentifier(), "navigation-\(destination.rawValue)", "size \(size), scale \(scale)")
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
                XCTAssertEqual(defaults.string(forKey: UserDefaultsDestinationPreferences.key), destination.rawValue)
                XCTAssertEqual(defaults.string(forKey: "unrelated-preference"), "unchanged")
                XCTAssertEqual(defaults.persistentDomain(forName: suite).map { Set($0.keys) } ?? [],
                               Set(["unrelated-preference", UserDefaultsDestinationPreferences.key]))
                XCTAssertEqual(NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
                    .selectedDestination, destination)
                XCTAssertEqual((attribute(try XCTUnwrap(navButtons().first {
                    attribute($0, kAXIdentifierAttribute) as? String == "navigation-\(destination.rawValue)"
                }), kAXSelectedAttribute) as? NSNumber)?.boolValue, true)
            }
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
