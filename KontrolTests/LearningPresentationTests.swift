import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

@MainActor
final class LearningPresentationTests: XCTestCase {
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func descendants(of element: AXUIElement) -> [AXUIElement] {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + descendants(of: $0) }
    }

    private func inspect<Content: View>(_ view: Content, width: CGFloat = 1000, scale: CGFloat = 1,
                         _ check: (NSWindow, [AXUIElement]) throws -> Void) throws {
        let host = NSHostingView(rootView: view.environment(\.appTextScaleOverride, scale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Learning inspection \(UUID().uuidString)"
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var learningWindow: AXUIElement?
        var availableTitles: [String] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            availableTitles = windows.compactMap { attribute($0, kAXTitleAttribute) as? String }
            learningWindow = windows.first { attribute($0, kAXTitleAttribute) as? String == window.title }
        } while learningWindow == nil && Date() < deadline
        try check(window, descendants(of: try XCTUnwrap(learningWindow,
            "AX could not find \(window.title); visible titles: \(availableTitles); active: \(NSApplication.shared.isActive); ordered: \(window.isVisible); trusted: \(AXIsProcessTrusted()); policy: \(NSApplication.shared.activationPolicy().rawValue); pid: \(ProcessInfo.processInfo.processIdentifier)")))
    }

    private func text(_ elements: [AXUIElement]) -> [String] {
        elements.compactMap { attribute($0, kAXValueAttribute) as? String } +
            elements.compactMap { attribute($0, kAXDescriptionAttribute) as? String }
    }

    private func identifiers(_ elements: [AXUIElement]) -> [String] {
        elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
    }

    /// Always inspect the live window rather than retaining AX elements across renders.
    private func liveElements(in window: NSWindow) throws -> [AXUIElement] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let current = try XCTUnwrap(windows.first {
            attribute($0, kAXTitleAttribute) as? String == window.title
        }, "Learning test host window is unavailable to Accessibility")
        return descendants(of: current)
    }

    private func topicPresentation(_ id: String, snapshot: LearningCatalogSnapshot,
                                   in elements: [AXUIElement]) -> Bool {
        guard let topic = snapshot.topics.first(where: { $0.id == id }),
              let selected = elements.first(where: {
                  attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-\(id)"
              }), attribute(selected, kAXValueAttribute) as? String == "Selected" else { return false }
        let choices = LearningView.choices(for: id, in: snapshot)
        let ids = identifiers(elements)
        let headings = elements.filter { attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole }
        return headings.contains { (attribute($0, kAXValueAttribute) as? String) == topic.name ||
            (attribute($0, kAXDescriptionAttribute) as? String) == topic.name } &&
            text(elements).contains("\(choices.count) available") &&
            ids.filter { $0.hasPrefix("learning-lesson-") } == choices.map { "learning-lesson-\($0.id)" } &&
            ids.filter { $0.hasPrefix("learning-open-") } == choices.prefix(1).map { "learning-open-\($0.id)" } &&
            ids.filter { $0.hasPrefix("learning-preview-") } == choices.prefix(1).map { "learning-preview-\($0.id)" }
    }

    private func assertTopic(_ id: String, snapshot: LearningCatalogSnapshot, in window: NSWindow,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(2)
        var elements: [AXUIElement] = []
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            elements = try liveElements(in: window)
            if topicPresentation(id, snapshot: snapshot, in: elements) { return }
        } while Date() < deadline
        XCTFail("Topic \(id) did not render on the mounted host: ids=\(identifiers(elements)), text=\(text(elements))",
                file: file, line: line)
    }

    private func pressSpace(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.sendEvent(release)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testPersistedChoicesReadOfflineInSlotOrderWithoutCreatingProgressOrActions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let dependencies = AppDependencies(container: container, catalogRepository: repository)
        let snapshot = try repository.loadSnapshot()
        let topics = LearningView.orderedTopics(in: snapshot)
        XCTAssertEqual(topics.map(\.id), ["go", "java", "design", "perf", "security"])
        XCTAssertEqual(snapshot.slots.count, 20)
        for topic in topics {
            let choices = LearningView.choices(for: topic.id, in: snapshot)
            let indices = snapshot.slots.filter { $0.topicID == topic.id }.sorted { $0.slotIndex < $1.slotIndex }
            XCTAssertEqual(choices.map(\.id), indices.map(\.lessonID))
            XCTAssertEqual(choices.count, 4)
            XCTAssertTrue(choices.allSatisfy { !$0.objective.isEmpty })
        }
        XCTAssertEqual(AppShell.contentKind(for: .learning), .learning)
        let suite = "LearningPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        navigation.select(.learning)
        let host = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: dependencies)
            .environment(\.appTextScaleOverride, CGFloat(1)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Learning choices inspection"
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var learningWindow: AXUIElement?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            learningWindow = windows.first { attribute($0, kAXTitleAttribute) as? String == window.title }
        } while learningWindow == nil && Date() < deadline
        let elements = descendants(of: try XCTUnwrap(learningWindow))
        let ids = identifiers(elements)
        XCTAssertEqual(ids.filter { $0.hasPrefix("learning-topic-") }, topics.map { "learning-topic-\($0.id)" })
        let go = LearningView.choices(for: "go", in: snapshot)
        XCTAssertEqual(ids.filter { $0.hasPrefix("learning-lesson-") }, go.map { "learning-lesson-\($0.id)" })
        XCTAssertTrue(text(elements).contains { $0.contains("4 available") })
        for lesson in go {
            let row = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-lesson-\(lesson.id)" })
            let name = (attribute(row, kAXDescriptionAttribute) as? String ?? "") +
                (attribute(row, kAXValueAttribute) as? String ?? "")
            XCTAssertTrue(name.contains(lesson.title))
            XCTAssertFalse(name.contains(lesson.displayObjective))
        }
        let inspected = try XCTUnwrap(go.first)
        XCTAssertTrue(ids.contains("learning-preview-\(inspected.id)"))
        XCTAssertTrue(text(elements).joined(separator: " ").contains(inspected.displayObjective))
        XCTAssertEqual(ids.filter { $0.hasPrefix("learning-open-") }, ["learning-open-\(inspected.id)"])
        XCTAssertFalse(text(elements).joined(separator: "\n").contains(inspected.referenceAnswer))
        XCTAssertFalse(ids.contains { $0.hasPrefix("learning-inspect-") || $0.hasPrefix("learning-answer-") })
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        // Topic controls change this window's projection, not the shared assignments.
        let javaButton = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java" })
        XCTAssertEqual(AXUIElementPerformAction(javaButton, kAXPressAction as CFString), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let javaIDs = identifiers(descendants(of: try XCTUnwrap(learningWindow)))
        XCTAssertEqual(javaIDs.filter { $0.hasPrefix("learning-lesson-") },
                       LearningView.choices(for: "java", in: snapshot).map { "learning-lesson-\($0.id)" })
        XCTAssertEqual(javaIDs.filter { $0.hasPrefix("learning-open-") },
                       LearningView.choices(for: "java", in: snapshot).prefix(1).map { "learning-open-\($0.id)" })
        XCTAssertFalse(text(descendants(of: try XCTUnwrap(learningWindow))).contains(inspected.referenceAnswer),
                       "Changing topics must not reveal a reference answer")
        let captureDirectory = URL(fileURLWithPath: "/tmp/kontrol-f01-evidence/fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
            for scale: CGFloat in [1, 1.3] {
                host.rootView = AppShell(navigation: navigation, dependencies: dependencies)
                    .environment(\.appTextScaleOverride, scale)
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let path = captureDirectory.appendingPathComponent(
                    "learning-\(Int(size.width))x\(Int(size.height))-\(scale == 1 ? "standard" : "130pct").png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
            }
        }
        XCTAssertEqual(dependencies.learningCatalogStore.state.snapshot?.slots, snapshot.slots)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }

    func testMountedLearningRouteTracksEverySingleTopicActivation() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let snapshot = try repository.loadSnapshot()
        let dependencies = AppDependencies(container: container, catalogRepository: repository)
        let suite = "LearningTopicRoute.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        navigation.select(.learning)
        try inspect(AppShell(navigation: navigation, dependencies: dependencies)) { window, _ in
            try assertTopic("go", snapshot: snapshot, in: window)
            for id in ["java", "design", "perf", "security", "go"] {
                let button = try XCTUnwrap(liveElements(in: window).first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-\(id)"
                })
                XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
                XCTAssertEqual(navigation.selectedTopicID, id)
                try assertTopic(id, snapshot: snapshot, in: window)
                XCTAssertEqual(navigation.learningRoute, .choices)
            }
        }
        XCTAssertEqual(dependencies.learningCatalogStore.state.snapshot?.slots, snapshot.slots)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }

    func testMountedLearningViewObservesProgrammaticTopicChangesWithoutParent() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let snapshot = try repository.loadSnapshot()
        let store = LearningCatalogStore(repository: repository)
        let suite = "LearningTopicDirect.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        try inspect(LearningView(store: store, navigation: navigation)) { window, _ in
            try assertTopic("go", snapshot: snapshot, in: window)
            for id in ["java", "security", "design"] {
                navigation.selectTopic(id)
                try assertTopic(id, snapshot: snapshot, in: window)
            }
        }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }

    func testStandaloneLearningViewStillBrowsesTopics() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let snapshot = try repository.loadSnapshot()
        let store = LearningCatalogStore(repository: repository)
        try inspect(LearningView(store: store)) { window, _ in
            let deadline = Date().addingTimeInterval(2)
            var current: [AXUIElement] = []
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                current = try liveElements(in: window)
                if let go = current.first(where: {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-go"
                }), attribute(go, kAXValueAttribute) as? String == "Selected" { break }
            } while Date() < deadline
            let button = try XCTUnwrap(current.first {
                attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java"
            })
            XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
            let choices = LearningView.choices(for: "java", in: snapshot)
            let updatedDeadline = Date().addingTimeInterval(2)
            var updated: [AXUIElement] = []
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                updated = try liveElements(in: window)
                if let java = updated.first(where: {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java"
                }), attribute(java, kAXValueAttribute) as? String == "Selected" &&
                    identifiers(updated).filter({ $0.hasPrefix("learning-lesson-") }) ==
                        choices.map({ "learning-lesson-\($0.id)" }) { break }
            } while Date() < updatedDeadline
            let selectedJava = try XCTUnwrap(updated.first {
                attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java"
            })
            XCTAssertEqual(attribute(selectedJava, kAXValueAttribute) as? String, "Selected")
            XCTAssertEqual(identifiers(updated).filter { $0.hasPrefix("learning-lesson-") },
                           choices.map { "learning-lesson-\($0.id)" })
            XCTAssertTrue(text(updated).contains("4 available"))
            XCTAssertTrue(updated.contains { attribute($0, kAXRoleAttribute) as? String == kAXHeadingRole &&
                (attribute($0, kAXValueAttribute) as? String == "Java" ||
                 attribute($0, kAXDescriptionAttribute) as? String == "Java") })
        }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
    }

    func testChoicesReadCurrentDefinitionsRatherThanBundledCopy() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let selectedID = try XCTUnwrap(repository.loadSnapshot().slots.first { $0.topicID == "go" }).lessonID
        let lesson = try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first { $0.id == selectedID })
        lesson.title = "Corrected starter title"
        try context.save()
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let snapshot = try XCTUnwrap(store.state.snapshot)
        XCTAssertEqual(LearningView.choices(for: "go", in: snapshot).first?.title, "Corrected starter title")
    }

    func testEmptyStoreDoesNotPresentBundledOrPreviewContent() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let store = LearningCatalogStore(repository: SwiftDataCatalogRepository(container: container))
        try inspect(LearningView(store: store)) { _, elements in
            XCTAssertTrue(text(elements).contains("No learning topics are installed."))
            XCTAssertFalse(identifiers(elements).contains { $0.hasPrefix("learning-lesson-") })
        }
    }

    func testFailedReadNeverMasqueradesAsEmpty() throws {
        let repository = FailingCatalogReader()
        let store = LearningCatalogStore(repository: repository)
        try inspect(LearningView(store: store)) { _, elements in
            XCTAssertTrue(text(elements).contains("Error: Content could not be loaded."))
            XCTAssertFalse(text(elements).contains("No learning topics are installed."))
            XCTAssertFalse(identifiers(elements).contains { $0.hasPrefix("learning-lesson-") })
            let retry = try XCTUnwrap(elements.first {
                (attribute($0, kAXTitleAttribute) as? String) == "Retry learning choices" ||
                (attribute($0, kAXDescriptionAttribute) as? String) == "Retry learning choices"
            })
            repository.shouldFail = false
            XCTAssertEqual(AXUIElementPerformAction(retry, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(store.state, .empty(repository.empty))
            XCTAssertEqual(repository.reads, 2)
        }
    }

    func testPartialAndExhaustedTopicsShowExactCountsAndGenerateEntry() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let committed = SwiftDataCatalogRepository(container: container)
        _ = try committed.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let snapshot = try committed.loadSnapshot()
        let go = snapshot.slots.filter { $0.topicID == "go" }.sorted { $0.slotIndex < $1.slotIndex }
        let reader = FailingCatalogReader()
        reader.shouldFail = false
        reader.value = LearningCatalogSnapshot(topics: snapshot.topics, subtopics: snapshot.subtopics,
            concepts: snapshot.concepts, definitions: snapshot.definitions, progress: snapshot.progress,
            slots: Array(go.prefix(2)))
        let store = LearningCatalogStore(repository: reader)
        try inspect(LearningView(store: store)) { _, elements in
            XCTAssertTrue(text(elements).contains { $0.contains("2 available") })
            XCTAssertEqual(identifiers(elements).filter { $0.hasPrefix("learning-lesson-") }.count, 2)
            XCTAssertTrue(identifiers(elements).contains("learning-more-lessons"))
        }
        reader.value = LearningCatalogSnapshot(topics: snapshot.topics, subtopics: snapshot.subtopics,
            concepts: snapshot.concepts, definitions: snapshot.definitions, progress: snapshot.progress, slots: [])
        store.refresh()
        try inspect(LearningView(store: store)) { _, elements in
            XCTAssertTrue(text(elements).contains { $0.contains("0 available") })
            XCTAssertTrue(text(elements).contains { $0.contains("No choices available in Go.") })
            XCTAssertFalse(identifiers(elements).contains { $0.hasPrefix("learning-lesson-") })
            XCTAssertTrue(identifiers(elements).contains("learning-more-lessons"))
        }
    }

    // Historical hosted route fixture, compiled but not run by non-interactive validation. The shell,
    // not LearningView, must own the one full-height vertical scroll viewport.
    func testLearningRouteUsesShellScrollAtCompactAndWideWidths() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let dependencies = AppDependencies(container: container, catalogRepository: repository)
        let suite = "LearningRouteLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        navigation.select(.learning)

        func scrollViews(in view: NSView) -> [NSScrollView] {
            let nested = view.subviews.flatMap { scrollViews(in: $0) }
            return (view as? NSScrollView).map { [$0] + nested } ?? nested
        }
        func rect(of element: AXUIElement) throws -> CGRect {
            let position = try XCTUnwrap(attribute(element, kAXPositionAttribute)) as! AXValue
            let size = try XCTUnwrap(attribute(element, kAXSizeAttribute)) as! AXValue
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            XCTAssertTrue(AXValueGetValue(position, .cgPoint, &origin))
            XCTAssertTrue(AXValueGetValue(size, .cgSize, &dimensions))
            return CGRect(origin: origin, size: dimensions)
        }
        for width: CGFloat in [420, 620, 1000, 2000] {
            try inspect(AppShell(navigation: navigation, dependencies: dependencies),
                        width: width, scale: 1.3) { window, elements in
                let root = try XCTUnwrap(window.contentView)
                let scrolls = scrollViews(in: root)
                XCTAssertEqual(scrolls.count, 1, "Learning must use the shell's single vertical scroll view")
                let shellScroll = try XCTUnwrap(scrolls.first)
                let viewport = shellScroll.contentView
                let document = try XCTUnwrap(shellScroll.documentView)
                // Keep the real rendering when a geometry assertion fails; this
                // distinguishes a fixture/coordinate error from an actual reflow defect.
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let capture = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                            uniformTypeIdentifier: "public.png")
                capture.name = "learning-route-\(Int(width))x700-130pct"
                capture.lifetime = .keepAlways
                add(capture)
                print("A13 Learning geometry: content=\(root.bounds.size), pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), backingScale=\(window.backingScaleFactor)")
                XCTAssertGreaterThan(viewport.bounds.height, 350, "Catalog must not collapse into a tiny viewport")
                XCTAssertGreaterThan(document.frame.height, viewport.bounds.height,
                                     "Long choices must be scrollable in the shell")
                viewport.scroll(to: .zero)
                let start = viewport.bounds.origin.y
                viewport.scroll(to: NSPoint(x: 0, y: document.frame.height - viewport.bounds.height))
                shellScroll.reflectScrolledClipView(viewport)
                XCTAssertNotEqual(viewport.bounds.origin.y, start, "The full route must scroll")

                let topic = try XCTUnwrap(elements.first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-go"
                })
                let first = try XCTUnwrap(elements.first {
                    (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("learning-lesson-") == true
                })
                let topicFrame = try rect(of: topic)
                let lessonFrame = try rect(of: first)
                XCTAssertGreaterThanOrEqual(topicFrame.height, AppMetrics.preferredTarget)
                // Topics are a distinct row at every width; only list and preview
                // become adjacent when the available width and text scale permit it.
                XCTAssertGreaterThanOrEqual(lessonFrame.minY, topicFrame.maxY,
                                            "Choices must follow topics: lesson=\(lessonFrame), topic=\(topicFrame)")
            }
        }
    }

    // Historical hosted GUI assertions compile but are not validation gates.
    func testNarrowEnlargedTopicsAndOpenActionsRemainReachable() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let snapshot = try repository.loadSnapshot()
        let store = LearningCatalogStore(repository: repository)
        let suite = "LearningOpenLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        navigation.select(.learning)
        for width: CGFloat in [420, 620] {
            try inspect(LearningView(store: store, navigation: navigation), width: width, scale: 1.3) { window, elements in
                let topics = elements.filter {
                    (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("learning-topic-") == true
                }
                XCTAssertEqual(topics.count, 5)
                for topic in topics {
                    let position = try XCTUnwrap(attribute(topic, kAXPositionAttribute)) as! AXValue
                    let size = try XCTUnwrap(attribute(topic, kAXSizeAttribute)) as! AXValue
                    var origin = CGPoint.zero
                    var bounds = CGSize.zero
                    XCTAssertTrue(AXValueGetValue(position, .cgPoint, &origin))
                    XCTAssertTrue(AXValueGetValue(size, .cgSize, &bounds))
                    XCTAssertLessThanOrEqual(bounds.width, window.frame.width)
                    XCTAssertGreaterThanOrEqual(bounds.height, AppMetrics.preferredTarget)
                    XCTAssertEqual(AXUIElementPerformAction(topic, kAXPressAction as CFString), .success)
                }
                let updated = descendants(of: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
                XCTAssertFalse(identifiers(updated).contains { $0.hasPrefix("learning-answer-") })
                let java = try XCTUnwrap(liveElements(in: window).first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java"
                })
                window.makeKeyAndOrderFront(nil)
                XCTAssertEqual(AXUIElementSetAttributeValue(java, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                let focused = try XCTUnwrap(attribute(app, kAXFocusedUIElementAttribute))
                XCTAssertEqual(attribute(unsafeBitCast(focused, to: AXUIElement.self), kAXIdentifierAttribute) as? String,
                               "learning-topic-java")
                try pressSpace(in: window)
                try assertTopic("java", snapshot: snapshot, in: window)
                let go = try XCTUnwrap(liveElements(in: window).first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-go"
                })
                XCTAssertEqual(AXUIElementPerformAction(go, kAXPressAction as CFString), .success)
                try assertTopic("go", snapshot: snapshot, in: window)
                let current = try liveElements(in: window)
                let selectedGo = try XCTUnwrap(current.first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-go"
                })
                XCTAssertEqual(attribute(selectedGo, kAXValueAttribute) as? String, "Selected")
                XCTAssertEqual(AXUIElementSetAttributeValue(selectedGo, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
                XCTAssertEqual(attribute(selectedGo, kAXFocusedAttribute) as? Bool, true)
                let first = try XCTUnwrap(LearningView.choices(for: "go", in: snapshot).first)
                let row = try XCTUnwrap(current.first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-lesson-\(first.id)"
                })
                XCTAssertTrue(((attribute(row, kAXDescriptionAttribute) as? String ?? "") +
                               (attribute(row, kAXValueAttribute) as? String ?? "")).contains(first.title))
                let open = try XCTUnwrap(current.first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-open-\(first.id)"
                })
                let label = (attribute(open, kAXTitleAttribute) as? String ?? "") +
                    (attribute(open, kAXDescriptionAttribute) as? String ?? "")
                XCTAssertTrue(label.contains(first.title))
                XCTAssertFalse(text(current).joined(separator: " ").contains(first.referenceAnswer))
                XCTAssertFalse(identifiers(current).contains { $0.hasPrefix("learning-inspect-") })
            }
        }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
    }
}

@MainActor
private final class FailingCatalogReader: CatalogRepository {
    enum ReadError: Error { case injected }
    var shouldFail = true
    private(set) var reads = 0
    let empty = LearningCatalogSnapshot(topics: [], subtopics: [], concepts: [], definitions: [], progress: [], slots: [])
    var value: LearningCatalogSnapshot?
    func loadSnapshot() throws -> LearningCatalogSnapshot {
        reads += 1
        if shouldFail { throw ReadError.injected }
        return value ?? empty
    }
    func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot { throw ReadError.injected }
    func openLesson(lessonID: String, now: Date) throws -> LessonMutationResult { throw ReadError.injected }
    func loadLesson(lessonID: String) throws -> LessonDetailSnapshot { throw ReadError.injected }
    func loadHistory() throws -> [LessonHistorySnapshot] { throw ReadError.injected }
    func restoreDismissed(lessonID: String, now: Date) throws -> LessonMutationResult {
        throw ReadError.injected
    }
    func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult {
        throw ReadError.injected
    }
    func revealSolution(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
        throw ReadError.injected
    }
    func setSelfCheckAcknowledged(attemptID: UUID, expectedRevision: Int,
                                  acknowledged: Bool, now: Date) throws -> LessonMutationResult {
        throw ReadError.injected
    }
    func complete(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
        throw ReadError.injected
    }
    func dismiss(lessonID: String, expectedSlot: LessonSlotSnapshot, now: Date) throws -> LessonMutationResult {
        throw ReadError.injected
    }
    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult { .unchanged }
}
