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

private actor SettingsNewsSpy: NewsRefreshing {
    private(set) var requests = 0
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] { requests += 1; return [] }
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        requests += 1
        throw FeedServiceError(code: .offline, retryNotBefore: nil)
    }
}

@MainActor
private final class SettingsPreferencesSpy: AppPreferencesRepository {
    var value: AppPreferencesSnapshot = .defaults
    var readFailure: AppPreferencesError?
    var saveFailure: AppPreferencesError?
    private(set) var saves = 0
    private(set) var loads = 0
    func load() throws -> AppPreferencesSnapshot {
        loads += 1
        if let readFailure { throw readFailure }
        return value
    }
    func save(_ draft: AppPreferencesDraft, expectedRevision: UUID?) throws -> AppPreferencesSnapshot {
        saves += 1
        if let saveFailure { throw saveFailure }
        guard expectedRevision == value.revision else { throw AppPreferencesError.staleRevision }
        value = AppPreferencesSnapshot(preferences: try draft.validated(), revision: UUID())
        return value
    }
}

@MainActor
final class SettingsSceneTests: XCTestCase {
    private func show<V: View>(_ view: V, size: CGSize = CGSize(width: 1000, height: 1000)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Settings behavior \(UUID().uuidString)"
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func node(_ identifier: String, in window: NSWindow) throws -> AXUIElement {
        let root = try axWindow(window)
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let found = axDescendants(root).first(where: {
                axAttribute($0, kAXIdentifierAttribute) as? String == identifier
            }) { return found }
            settle()
        } while Date() < deadline
        let identifiers = axDescendants(root).compactMap { axAttribute($0, kAXIdentifierAttribute) as? String }
        throw NSError(domain: "SettingsSceneTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing rendered control: \(identifier); present: \(identifiers)"])
    }

    private func press(_ identifier: String, in window: NSWindow) throws {
        try reveal(identifier, in: window)
        XCTAssertEqual(AXUIElementPerformAction(try node(identifier, in: window), kAXPressAction as CFString), .success)
        settle()
    }

    private func input(_ text: String, in window: NSWindow) throws {
        try reveal("preferences-custom-minutes", in: window)
        window.makeKeyAndOrderFront(nil)
        XCTAssertEqual(AXUIElementSetAttributeValue(try node("preferences-custom-minutes", in: window),
                                                  kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle()
    }

    private func value(_ identifier: String, in window: NSWindow) throws -> String {
        try XCTUnwrap(axAttribute(try node(identifier, in: window), kAXValueAttribute) as? String)
    }

    /// Dispatch the real native popup's target/action, not an editor/test binding.
    private func choose(_ title: String, item: String, in window: NSWindow) throws {
        func popups(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
        }
        let popup = try XCTUnwrap(window.contentView.flatMap { popups($0).first { $0.accessibilityLabel() == title } })
        _ = popup.scrollToVisible(popup.bounds)
        settle()
        let index = popup.indexOfItem(withTitle: item)
        XCTAssertGreaterThanOrEqual(index, 0)
        popup.selectItem(at: index)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        settle()
    }

    func testNativeGeneralEditorPresetsCustomValidationSaveCancelAndCommittedSummaries() async throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SettingsPreferencesSpy()
        let news = SettingsNewsSpy()
        var generators = 0
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
            appPreferencesRepository: repository, aiGenerator: { model, reference, credentials in
                generators += 1
                return OpenAILessonGenerator(model: model, credentialReference: reference, credentials: credentials)
            }, newsService: news)
        let window = show(FoundationSettingsView(dependencies: graph))
        defer { window.orderOut(nil) }
        try press("settings-general", in: window)
        try choose("Duration", item: "15 minutes", in: window)
        try press("preferences-save", in: window)
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 15 minutes")
        XCTAssertEqual(repository.saves, 1)
        try press("settings-general", in: window)
        try choose("Duration", item: "50 minutes", in: window)
        try press("preferences-cancel", in: window)
        XCTAssertEqual(repository.saves, 1, "Cancel must not persist")
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 15 minutes")
        try press("settings-general", in: window)
        try choose("Duration", item: "Custom", in: window)
        try input("1.5", in: window)
        try choose("Text size", item: "Large · at least 130%", in: window)
        try choose("Motion", item: "Reduce", in: window)
        try press("preferences-save", in: window)
        _ = try node("preferences-error", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "1.5")
        XCTAssertEqual(repository.saves, 1, "Invalid input never reaches persistence")
        XCTAssertEqual(graph.appPreferencesStore.committed?.preferences.focusDefaultMinutes, 15)
        try input("25", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "25", "Typing a preset must not collapse Custom")
        try input("00037", in: window)
        try press("preferences-save", in: window)
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 37 minutes")
        XCTAssertEqual(try value("settings-appearance-summary", in: window), "37 minutes · Large text · Reduced motion")
        XCTAssertEqual(repository.saves, 2)
        _ = try node("settings-preferences-saved", in: window)
        try press("settings-ai", in: window)
        for identifier in ["ai-settings", "ai-edit", "ai-enable", "ai-test-connection"] { _ = try node(identifier, in: window) }
        try press("settings-back", in: window)
        try press("settings-news", in: window)
        _ = try node("news-management", in: window)
        try press("settings-back", in: window)
        let snapshot = try XCTUnwrap(graph.newsStore.snapshot)
        let enabled = snapshot.feeds.filter(\.isEnabled).count
        XCTAssertEqual(try value("settings-news-summary", in: window),
                       "News: \(NewsManagementView.selectedCountText(snapshot)) · \(enabled) of \(snapshot.feeds.count) feeds enabled")
        let requests = await news.requests
        XCTAssertEqual(requests, 0, "Opening every Settings section and saving general preferences must not refresh/validate feeds")
        XCTAssertEqual(generators, 0, "Opening Settings must not construct a lesson generator")
        XCTAssertNoThrow(try graph.lessonDraftStore.flushAll())
    }

    func testNativeSaveFailureAndCrossWindowStaleReviewRetainDraftUntilExplicitSave() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SettingsPreferencesSpy()
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
                                    appPreferencesRepository: repository)
        let first = show(FoundationSettingsView(dependencies: graph))
        let second = show(FoundationSettingsView(dependencies: graph))
        defer { first.orderOut(nil); second.orderOut(nil) }
        try press("settings-general", in: first)
        try press("settings-general", in: second)
        try choose("Duration", item: "50 minutes", in: first)
        try choose("Duration", item: "Custom", in: second)
        try input("00037", in: second)
        try choose("Text size", item: "Large · at least 130%", in: second)
        try choose("Motion", item: "Reduce", in: second)
        repository.saveFailure = .persistenceFailure
        try press("preferences-save", in: second)
        _ = try node("preferences-error", in: second)
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        XCTAssertEqual(graph.appPreferencesStore.committed, .defaults)
        repository.saveFailure = nil
        try press("preferences-save", in: first)
        _ = try node("preferences-review", in: second)
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        let beforeReview = repository.saves
        try press("preferences-review", in: second)
        XCTAssertEqual(repository.saves, beforeReview, "Review reads/rebases only; never saves")
        XCTAssertEqual(try value("preferences-latest-saved", in: second), "Latest saved: 50 minutes · System text · System motion")
        repository.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 15), revision: UUID())
        try press("preferences-save", in: second)
        _ = try node("preferences-error", in: second)
        _ = try node("preferences-review", in: second)
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 15, "External stale baseline cannot be overwritten")
        try press("preferences-review", in: second)
        XCTAssertEqual(try value("preferences-latest-saved", in: second), "Latest saved: 15 minutes · System text · System motion")
        XCTAssertEqual(try value("preferences-custom-minutes", in: second), "00037")
        try press("preferences-save", in: second)
        XCTAssertEqual(repository.value.preferences, try AppPreferences(focusDefaultMinutes: 37, textSize: .large, reduceMotion: .reduce))
        for window in [first, second] {
            XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 37 minutes")
        }
    }

    func testUnreadablePreferencesHaveExplicitRetryAndReviewWithoutAuthorizingFallbackSave() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SettingsPreferencesSpy()
        repository.readFailure = .invalidStoredData
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container),
                                    appPreferencesRepository: repository)
        let window = show(FoundationSettingsView(dependencies: graph))
        defer { window.orderOut(nil) }
        _ = try node("settings-preferences-unavailable", in: window)
        try press("settings-preferences-retry", in: window)
        XCTAssertEqual(repository.loads, 2)
        XCTAssertEqual(repository.saves, 0)
        try press("settings-general", in: window)
        XCTAssertEqual((axAttribute(try node("preferences-save", in: window), kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
        try choose("Duration", item: "Custom", in: window)
        try input("37", in: window)
        try press("preferences-review", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "37")
        XCTAssertEqual(repository.saves, 0)
        repository.readFailure = nil
        try press("preferences-review", in: window)
        XCTAssertEqual(try value("preferences-custom-minutes", in: window), "37")
        try press("preferences-save", in: window)
        XCTAssertEqual(try value("settings-focus-summary", in: window), "Focus default: 37 minutes")
        XCTAssertEqual(repository.saves, 1)
        XCTAssertNil(graph.focusService.activeSession)
    }

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

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }

    private func viewport(_ scroll: NSScrollView) throws -> CGRect {
        let window = try XCTUnwrap(scroll.window)
        let screenRect = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        return CGRect(x: screenRect.minX, y: screenHeight - screenRect.maxY,
                      width: screenRect.width, height: screenRect.height)
    }

    /// Native clip-view scrolling, followed by an actual onscreen AX press. Finding
    /// an offscreen AX node alone is not evidence that a compact user can reach it.
    private func reveal(_ identifier: String, in window: NSWindow) throws {
        guard window.contentView.flatMap({ scrollViews(in: $0).first }) != nil else { return }
        try reveal(identifier, in: window, matching: {
            self.axAttribute($0, kAXIdentifierAttribute) as? String == identifier
        })
    }

    private func reveal(_ name: String, in window: NSWindow,
                        matching predicate: (AXUIElement) -> Bool) throws {
        let scroll = try XCTUnwrap(window.contentView.flatMap { scrollViews(in: $0).first })
        let clip = scroll.contentView
        let document = try XCTUnwrap(scroll.documentView)
        func isVisible() throws -> Bool {
            // Lazy News topics enter/leave the native AX tree as they scroll.
            // Reacquire after every layout instead of retaining a stale AX node
            // or demanding an offscreen lazy item before scrolling to it.
            guard let element = axDescendants(try axWindow(window)).first(where: predicate) else { return false }
            return try viewport(scroll).insetBy(dx: -1, dy: -1).contains(axFrame(element))
        }
        if try isVisible() { return }
        let step = max(1, clip.bounds.height * 0.5)
        var y: CGFloat = 0
        while true {
            clip.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            settle()
            if try isVisible() { return }
            // Reevaluate height as lazy content is realized.
            let maxY = max(0, document.bounds.height - clip.bounds.height)
            if y >= maxY { break }
            y = min(maxY, y + step)
        }
        XCTFail("Rendered control cannot be reached by vertical scrolling: \(name); viewport=\(try viewport(scroll))")
    }

    private func assertSingleDocument(in window: NSWindow) throws -> NSScrollView {
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        let scrolls = try XCTUnwrap(window.contentView).subviews.flatMap(scrollViews)
        XCTAssertEqual(scrolls.count, 1, "Settings must have exactly one scroll owner, including inline AI and News")
        let scroll = try XCTUnwrap(scrolls.first)
        XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).bounds.width, scroll.contentView.bounds.width + 1,
                                 "Settings must not require horizontal scrolling")
        return scroll
    }

    private func assertReachable(_ identifiers: [String], in window: NSWindow) throws {
        let scroll = try assertSingleDocument(in: window)
        for identifier in identifiers {
            try reveal(identifier, in: window)
            let frame = try axFrame(node(identifier, in: window))
            XCTAssertFalse(frame.isEmpty, identifier)
            XCTAssertTrue(try viewport(scroll).insetBy(dx: -1, dy: -1).contains(frame),
                          "\(identifier) must fit fully onscreen after scrolling: \(frame)")
        }
    }

    private func assertNonoverlapping(_ identifiers: [String], in window: NSWindow) throws {
        let frames = try identifiers.map { try axFrame(node($0, in: window)) }
        for i in frames.indices {
            for j in frames.indices where j > i {
                XCTAssertFalse(frames[i].intersects(frames[j]), "\(identifiers[i]) overlaps \(identifiers[j])")
            }
        }
    }

    private func capture(_ name: String, window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("F13 native geometry \(name): content=\(content.bounds.size), pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), backingScale=\(window.backingScaleFactor)")
    }

    func testNativeAndInlineSettingsGeometryAtCompactDesktopAndAccessibilitySizes() async throws {
        let sizes = [CGSize(width: 520, height: 340), CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)]
        let scales: [(String, DynamicTypeSize)] = [("100", .large), ("130", .xxLarge), ("160", .accessibility1)]
        for inline in [false, true] {
            // The main app has a 1000x700 minimum; 520x340 is native Settings only.
            for size in sizes where !inline || size.width >= 1000 {
                for (percent, textSize) in scales {
                    let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                    let repository = SettingsPreferencesSpy()
                    let news = SettingsNewsSpy()
                    let graph = AppDependencies(container: container,
                        catalogRepository: SwiftDataCatalogRepository(container: container),
                        appPreferencesRepository: repository, newsService: news)
                    let launch = LaunchCoordinator(open: { container }, makeDependencies: { _, _ in graph })
                    await launch.start()
                    XCTAssertEqual(launch.state, .ready)
                    let navigation = NavigationStore()
                    navigation.select(.settings)
                    let root = Group {
                        if inline { MainWindowContent(launch: launch, navigation: navigation) }
                        else { SettingsSceneContent(launch: launch) }
                    }.environment(\.dynamicTypeSize, textSize)
                    let window = show(root, size: size)
                    defer { window.orderOut(nil) }
                    let label = "\(inline ? "inline" : "native")-\(Int(size.width))x\(Int(size.height))-\(percent)"
                    XCTAssertEqual(window.contentView?.bounds.size, size, "Layout must not enlarge the requested content viewport")
                    try assertReachable(["settings-general", "settings-ai", "settings-news"], in: window)
                    try capture("\(label)-hub-bottom", window: window)
                    try press("settings-general", in: window)
                    try assertReachable(["preferences-duration", "preferences-text-size", "preferences-motion"], in: window)
                    try capture("\(label)-general-pickers", window: window)
                    try choose("Duration", item: "Custom", in: window)
                    try reveal("preferences-custom-minutes", in: window)
                    try input("1.5", in: window)
                    try press("preferences-save", in: window)
                    XCTAssertEqual(try value("preferences-custom-minutes", in: window), "1.5")
                    XCTAssertEqual(try value("preferences-error", in: window),
                                   GeneralPreferencesView.errorMessage(.preferences(.invalidFocusDuration(.invalidCustomMinutes))))
                    try assertReachable(["preferences-error", "preferences-latest-saved", "preferences-cancel", "preferences-save"], in: window)
                    try assertNonoverlapping(["preferences-focus-guidance", "preferences-appearance-guidance",
                                              "preferences-error", "preferences-latest-saved", "preferences-cancel", "preferences-save"], in: window)
                    try capture("\(label)-general-validation-actions", window: window)
                    try input("37", in: window)
                    repository.saveFailure = .persistenceFailure
                    try press("preferences-save", in: window)
                    try assertReachable(["preferences-error", "preferences-cancel", "preferences-save"], in: window)
                    XCTAssertEqual(try value("preferences-custom-minutes", in: window), "37")
                    try capture("\(label)-general-save-failed", window: window)
                    try press("preferences-cancel", in: window)
                    XCTAssertEqual(graph.appPreferencesStore.committed, .defaults)
                    try press("settings-ai", in: window)
                    try assertReachable(["settings-back", "ai-edit", "ai-enable", "ai-test-connection", "ai-connection-status"], in: window)
                    try capture("\(label)-ai-actions", window: window)
                    try press("ai-edit", in: window)
                    try assertReachable(["ai-save", "ai-cancel"], in: window)
                    try capture("\(label)-ai-editor-actions", window: window)
                    try press("ai-cancel", in: window)
                    try press("settings-back", in: window)
                    try press("settings-news", in: window)
                    try assertReachable(["settings-back", "news-add-feed"], in: window)
                    let snapshot = try XCTUnwrap(graph.newsStore.snapshot)
                    for topic in snapshot.topics { try assertReachable(["news-topic-\(topic.id)"], in: window) }
                    // Inspect every existing feed action, including the last row,
                    // rather than assuming that rendering the section proves reachability.
                    for feed in snapshot.feeds {
                        for verb in [feed.isEnabled ? "Disable" : "Enable", "Edit", "Remove"] {
                            let label = "\(verb) \(feed.name) feed"
                            try reveal(label, in: window, matching: {
                                self.axAttribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                                self.axAttribute($0, kAXDescriptionAttribute) as? String == label
                            })
                        }
                    }
                    try capture("\(label)-news-last-feed", window: window)
                    try press("settings-back", in: window)
                    let requests = await news.requests
                    XCTAssertEqual(requests, 0, "Layout/navigation must not initiate feed requests")
                    XCTAssertEqual(repository.saves, 1, "Only the explicit failed save may reach persistence")
                    print("F13 geometry PASS \(label): hub/general/AI/News, one scroll document, all actions reachable")
                }
            }
        }
    }

    func testSettingsReadFailureRetryAndRetainedEditorGuidanceReflowAtAllNativeSizes() async throws {
        for size in [CGSize(width: 520, height: 340), CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
            for (percent, textSize) in [("100", DynamicTypeSize.large), ("130", .xxLarge), ("160", .accessibility1)] {
                let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                let repository = SettingsPreferencesSpy()
                repository.readFailure = .unsupportedPayloadVersion(99)
                let graph = AppDependencies(container: container,
                    catalogRepository: SwiftDataCatalogRepository(container: container), appPreferencesRepository: repository)
                let launch = LaunchCoordinator(open: { container }, makeDependencies: { _, _ in graph })
                await launch.start()
                let window = show(SettingsSceneContent(launch: launch).environment(\.dynamicTypeSize, textSize), size: size)
                defer { window.orderOut(nil) }
                let label = "native-\(Int(size.width))x\(Int(size.height))-\(percent)-read-failed"
                try assertReachable(["settings-preferences-unavailable", "settings-preferences-retry", "settings-general", "settings-ai", "settings-news"], in: window)
                try press("settings-preferences-retry", in: window)
                try press("settings-general", in: window)
                try assertReachable(["preferences-error", "preferences-review", "preferences-cancel", "preferences-save"], in: window)
                XCTAssertEqual(try value("preferences-error", in: window),
                               GeneralPreferencesView.errorMessage(.preferences(.unsupportedPayloadVersion(99))))
                try assertNonoverlapping(["preferences-error", "preferences-review", "preferences-cancel", "preferences-save"], in: window)
                try capture(label, window: window)
                try choose("Duration", item: "Custom", in: window)
                try reveal("preferences-custom-minutes", in: window)
                try input("00037", in: window)
                repository.readFailure = nil
                try press("preferences-review", in: window)
                XCTAssertEqual(try value("preferences-custom-minutes", in: window), "00037")
                try press("preferences-save", in: window)
                XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 37)
                XCTAssertEqual(repository.saves, 1)
            }
        }
    }

    func testProjectsAndFocusRoutesRenderImplementedActionsNotFoundationPlaceholders() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let graph = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container))
        let navigation = NavigationStore()
        let window = show(AppShell(navigation: navigation, dependencies: graph))
        defer { window.orderOut(nil) }
        for (destination, label) in [(AppDestination.projects, "Add project"), (.focus, "Start")] {
            navigation.select(destination)
            settle()
            // Projects currently inherits its container identifier on children.
            // Match the real action's role/name, not the superseded placeholder.
            let action = try XCTUnwrap(axDescendants(try axWindow(window)).first {
                axAttribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                axAttribute($0, kAXDescriptionAttribute) as? String == label
            })
            XCTAssertFalse(try axFrame(action).isEmpty)
            XCTAssertEqual((axAttribute(action, kAXEnabledAttribute) as? NSNumber)?.boolValue, true)
            XCTAssertEqual(AppShell.contentKind(for: destination), destination == .projects ? .projects : .focus)
        }
        XCTAssertTrue(graph.projectStore.rows.isEmpty)
        XCTAssertNil(graph.focusService.activeSession)
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
        settle()
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
        XCTAssertFalse(graph.aiSettingsStore.presentation.enabled)
        XCTAssertEqual(graph.aiSettingsStore.credentialStatus, .notConfigured)
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
        func assertHubContent(_ surface: AXUIElement) {
            let nodes = [surface] + descendants(surface)
            XCTAssertEqual(nodes.filter {
                attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
                (attribute($0, kAXValueAttribute) as? String == "Settings" ||
                 attribute($0, kAXDescriptionAttribute) as? String == "Settings")
            }.count, 1)
            for identifier in ["settings-general", "settings-ai", "settings-news", "settings-focus-summary",
                               "settings-appearance-summary", "settings-ai-summary", "settings-news-summary"] {
                XCTAssertTrue(nodes.contains { attribute($0, kAXIdentifierAttribute) as? String == identifier },
                              "Both entries must expose implemented hub capability or saved summary: \(identifier)")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        // The shared hub replaces the superseded AI-only foundation surface.
        // Its first committed summary remains visible; lower sections scroll.
        let settingsAX = try axWindow(settingsWindow)
        let settingsBounds = try axFrame(settingsAX)
        XCTAssertGreaterThanOrEqual(settingsBounds.width, 520)
        XCTAssertGreaterThanOrEqual(settingsBounds.height, 340)
        let settingsNodes = axDescendants(settingsAX)
        let status = try XCTUnwrap(settingsNodes.first {
            axAttribute($0, kAXIdentifierAttribute) as? String == "settings-focus-summary"
        })
        XCTAssertEqual(axAttribute(status, kAXValueAttribute) as? String, "Focus default: 25 minutes")
        XCTAssertTrue(settingsBounds.contains(try axFrame(status)), "130% status must be visible in compact Settings")
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
        settle()
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
            assertHubContent(try settingsSurface(window))
        }

        // Exercise the real local routes from both isolated ready scene roots,
        // not just their hub labels or construction-time graph identities.
        for window in [settingsWindow, mainWindow] {
            try press("settings-general", in: window)
            for identifier in ["general-preferences-editor", "preferences-duration", "preferences-text-size",
                               "preferences-motion", "preferences-save", "preferences-cancel"] {
                _ = try node(identifier, in: window)
            }
            try press("preferences-cancel", in: window)
            try press("settings-ai", in: window)
            for identifier in ["ai-settings", "ai-edit", "ai-enable", "ai-test-connection"] {
                _ = try node(identifier, in: window)
            }
            try press("settings-back", in: window)
            try press("settings-news", in: window)
            _ = try node("news-management", in: window)
            try press("settings-back", in: window)
        }
        XCTAssertEqual(graph.appPreferencesStore.committed, .defaults, "Opening/canceling sections does not save preferences")

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
        assertHubContent(try settingsSurface(nativeAX))
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
