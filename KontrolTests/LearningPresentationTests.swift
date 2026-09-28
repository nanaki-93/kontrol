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
        try check(window, descendants(of: try XCTUnwrap(learningWindow)))
    }

    private func text(_ elements: [AXUIElement]) -> [String] {
        elements.compactMap { attribute($0, kAXValueAttribute) as? String } +
            elements.compactMap { attribute($0, kAXDescriptionAttribute) as? String }
    }

    private func identifiers(_ elements: [AXUIElement]) -> [String] {
        elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
    }

    private func pressSpace(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        if !window.performKeyEquivalent(with: event) {
            if window.isKeyWindow { window.sendEvent(event) }
            else { window.firstResponder?.keyDown(with: event) }
        }
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
            let conceptNames = lesson.conceptIDs.compactMap { id in snapshot.concepts.first { $0.id == id }?.name }
            for field in [lesson.title, lesson.displayObjective, lesson.format.capitalized,
                          lesson.difficulty.capitalized, "\(lesson.estimatedMinutes) min"] + conceptNames {
                XCTAssertTrue(name.contains(field), "Missing \(field) from \(name)")
            }
        }
        // Native disclosure exposes all stored sections as text, without creating an attempt.
        XCTAssertEqual(ids.filter { $0.hasPrefix("learning-inspect-") },
                       go.map { "learning-inspect-\($0.id)" })
        let inspected = try XCTUnwrap(go.first)
        let disclosure = try XCTUnwrap(elements.first {
            attribute($0, kAXIdentifierAttribute) as? String == "learning-inspect-\(inspected.id)"
        })
        XCTAssertEqual(AXUIElementPerformAction(disclosure, kAXPressAction as CFString), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let expanded = descendants(of: try XCTUnwrap(learningWindow))
        let expandedText = text(expanded).joined(separator: "\n")
        for section in ["Read-only reference", "Explanation", "Worked example",
                        "Exercise prompt (for reading)", "Reference material · Example response",
                        "Reference material · Self-check criteria", inspected.explanation,
                        inspected.workedExample, inspected.exercise, inspected.referenceAnswer] + inspected.selfCheckCriteria {
            XCTAssertTrue(expandedText.contains(section), "Missing read-only section: \(section)")
        }
        XCTAssertFalse(identifiers(expanded).contains { $0.hasPrefix("learning-answer-") })
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        // Topic controls change this window's projection, not the shared assignments.
        let javaButton = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java" })
        XCTAssertEqual(AXUIElementPerformAction(javaButton, kAXPressAction as CFString), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let javaIDs = identifiers(descendants(of: try XCTUnwrap(learningWindow)))
        XCTAssertEqual(javaIDs.filter { $0.hasPrefix("learning-lesson-") },
                       LearningView.choices(for: "java", in: snapshot).map { "learning-lesson-\($0.id)" })
        XCTAssertEqual(javaIDs.filter { $0.hasPrefix("learning-inspect-") },
                       LearningView.choices(for: "java", in: snapshot).map { "learning-inspect-\($0.id)" })
        XCTAssertFalse(text(descendants(of: try XCTUnwrap(learningWindow))).contains(inspected.explanation),
                       "Changing topics closes the window-local inspection")
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

    func testPartialAndExhaustedTopicsShowExactCountsWithoutGenerate() throws {
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
            XCTAssertFalse(text(elements).contains { $0.contains("Generate") })
        }
        reader.value = LearningCatalogSnapshot(topics: snapshot.topics, subtopics: snapshot.subtopics,
            concepts: snapshot.concepts, definitions: snapshot.definitions, progress: snapshot.progress, slots: [])
        store.refresh()
        try inspect(LearningView(store: store)) { _, elements in
            XCTAssertTrue(text(elements).contains { $0.contains("0 available") })
            XCTAssertTrue(text(elements).contains { $0.contains("No choices available in Go.") })
            XCTAssertFalse(identifiers(elements).contains { $0.hasPrefix("learning-lesson-") })
            XCTAssertFalse(text(elements).contains { $0.contains("Generate") })
        }
    }

    // Hosted route check: F13 executes this with accessibility permission. The shell,
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
        for width: CGFloat in [420, 620, 1000] {
            try inspect(AppShell(navigation: navigation, dependencies: dependencies),
                        width: width, scale: 1.3) { window, elements in
                let root = try XCTUnwrap(window.contentView)
                let scrolls = scrollViews(in: root)
                XCTAssertEqual(scrolls.count, 1, "Learning must use the shell's single vertical scroll view")
                let shellScroll = try XCTUnwrap(scrolls.first)
                let viewport = shellScroll.contentView
                let document = try XCTUnwrap(shellScroll.documentView)
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
                if width < 720 {
                    XCTAssertLessThan(lessonFrame.minY, topicFrame.minY,
                                      "Compact choices must follow the topics vertically")
                } else {
                    XCTAssertGreaterThan(lessonFrame.minX, topicFrame.maxX,
                                         "Wide choices must sit beside the topic rail")
                }
            }
        }
    }

    // Hosted GUI assertions compile in F05; F13 runs them with accessibility permission.
    func testNarrowEnlargedTopicsAndDisclosureRemainReachable() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let snapshot = try repository.loadSnapshot()
        let store = LearningCatalogStore(repository: repository)
        for width: CGFloat in [420, 620] {
            try inspect(LearningView(store: store), width: width, scale: 1.3) { window, elements in
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
                let java = try XCTUnwrap(topics.first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java"
                })
                XCTAssertEqual(AXUIElementSetAttributeValue(java, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
                try pressSpace(in: window)
                XCTAssertEqual(attribute(java, kAXValueAttribute) as? String, "Selected")
                let go = try XCTUnwrap(topics.first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-go"
                })
                XCTAssertEqual(AXUIElementPerformAction(go, kAXPressAction as CFString), .success)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                let active = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
                let current = descendants(of: active)
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
                let disclosure = try XCTUnwrap(current.first {
                    attribute($0, kAXIdentifierAttribute) as? String == "learning-inspect-\(first.id)"
                })
                XCTAssertTrue((attribute(disclosure, kAXDescriptionAttribute) as? String ?? "").contains(first.title))
                XCTAssertEqual(AXUIElementSetAttributeValue(disclosure, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
                XCTAssertEqual(attribute(disclosure, kAXFocusedAttribute) as? Bool, true)
                try pressSpace(in: window)
                XCTAssertTrue(text(descendants(of: active)).joined(separator: " ").contains(first.referenceAnswer))
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
