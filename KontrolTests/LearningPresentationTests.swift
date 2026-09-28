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

    private enum ReadError: Error { case injected }

    private func inspect(_ view: LearningView, width: CGFloat = 1000, scale: CGFloat = 1,
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
        // Window-server AX registration can lag layout when the full hosted suite runs.
        var learningWindow: AXUIElement?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            learningWindow = windows.first { attribute($0, kAXTitleAttribute) as? String == window.title }
        } while learningWindow == nil && Date() < deadline
        try check(window, descendants(of: try XCTUnwrap(learningWindow)))
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

    private func text(_ elements: [AXUIElement]) -> [String] {
        elements.compactMap { attribute($0, kAXValueAttribute) as? String } +
            elements.compactMap { attribute($0, kAXDescriptionAttribute) as? String }
    }

    func testSeededDefinitionsReadOfflineWithoutCreatingProgressOrActions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = try BundledCatalogLoader.load(from: Bundle.main)
        let repository = SwiftDataCatalogRepository(container: container)
        XCTAssertEqual(try repository.importIfNeeded(catalog), .imported)
        let summaries = try LearningTopicSummary.load(from: container)
        XCTAssertEqual(summaries.map(\.name), ["Go", "Java", "System Design", "Performance", "Security"])
        XCTAssertEqual(summaries.map(\.lessons.count), catalog.value.topics.map { topic in
            catalog.value.lessons.filter { $0.topicID == topic.id }.count
        })
        XCTAssertEqual(summaries.flatMap(\.lessons).count, catalog.value.lessons.count)
        XCTAssertEqual(Set(summaries.flatMap(\.lessons).map(\.title)), Set(catalog.value.lessons.map(\.title)))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)

        let suite = "LearningPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let dependencies = AppDependencies(container: container, catalogRepository: repository)
        XCTAssertEqual(AppShell.contentKind(for: .learning), .learning)
        let host = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: dependencies)
            .environment(\.appTextScaleOverride, CGFloat(1)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Learning starter inspection"
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        navigation.select(.learning)
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
        let identifiers = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
        let renderedTopics = identifiers.filter { $0.hasPrefix("learning-topic-") }
        XCTAssertEqual(renderedTopics, summaries.map { "learning-topic-\($0.id)" })
        for topic in summaries {
            XCTAssertTrue(identifiers.contains("learning-topic-\(topic.id)"), topic.name)
            for lesson in topic.lessons {
                XCTAssertTrue(identifiers.contains("learning-lesson-\(lesson.id)"), lesson.title)
            }
        }
        let labels = elements.compactMap { attribute($0, kAXValueAttribute) as? String } +
            elements.compactMap { attribute($0, kAXDescriptionAttribute) as? String }
        XCTAssertFalse(labels.contains { $0.contains("available offline") || $0.contains("4 available") ||
            $0.contains("Completed") || $0.contains("No starter") })
        for topic in summaries {
            let section = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-\(topic.id)" })
            XCTAssertTrue((attribute(section, kAXRoleAttribute) as? String == kAXHeadingRole) ||
                          (attribute(section, kAXRoleAttribute) as? String == kAXStaticTextRole))
            for lesson in topic.lessons {
                let row = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-lesson-\(lesson.id)" })
                let name = (attribute(row, kAXDescriptionAttribute) as? String ?? "") +
                    (attribute(row, kAXValueAttribute) as? String ?? "")
                XCTAssertTrue(name.contains(lesson.title), name)
                XCTAssertTrue(name.contains(lesson.format.capitalized), name)
                XCTAssertTrue(name.contains("\(lesson.estimatedMinutes) min"), name)
            }
        }
        XCTAssertEqual(elements.filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }.count,
                       AppDestination.allCases.count, "Learning must not offer nonfunctional lesson actions")
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
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }

    func testSummaryReadsCurrentImportedDefinitionsRatherThanBundledCopy() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let lesson = try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first { $0.topicID == "go" })
        let lessonID = lesson.id
        lesson.title = "Corrected starter title"
        try context.save()
        let summaries = try LearningTopicSummary.load(from: container)
        let go = try XCTUnwrap(summaries.first { $0.id == "go" })
        XCTAssertEqual(try XCTUnwrap(go.lessons.first { $0.id == lessonID }).title,
                       "Corrected starter title")
    }

    func testEmptyStoreDoesNotPresentBundledOrPreviewContent() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        XCTAssertTrue(try LearningTopicSummary.load(from: container).isEmpty)
        try inspect(LearningView(container: container)) { _, elements in
            let labels = text(elements)
            XCTAssertTrue(labels.contains("No starter topics are installed."))
            XCTAssertTrue(labels.contains("Starter content is not available yet."))
            XCTAssertFalse(labels.contains("Error: Content could not be loaded."))
            XCTAssertFalse(elements.contains { (attribute($0, kAXIdentifierAttribute) as? String ?? "").hasPrefix("learning-lesson-") })
            XCTAssertFalse(elements.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
        }
    }

    func testFailedReadNeverMasqueradesAsEmptyOrDisplaysDefinitions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        try inspect(LearningView(container: container, load: { _ in throw ReadError.injected })) { _, elements in
            let labels = text(elements)
            XCTAssertTrue(labels.contains("Error: Content could not be loaded."))
            XCTAssertTrue(labels.contains("Return to Learning to try again."))
            XCTAssertFalse(labels.contains("No starter topics are installed."))
            XCTAssertFalse(elements.contains { (attribute($0, kAXIdentifierAttribute) as? String ?? "").hasPrefix("learning-lesson-") })
            XCTAssertFalse(elements.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
        }
    }

    func testTopicWithNoLessonsUsesHonestGuidanceWithoutInventedRows() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let topic = LearningTopicSummary(id: "empty", name: "Empty topic", lessons: [])
        try inspect(LearningView(container: container, load: { _ in [topic] })) { _, elements in
            XCTAssertTrue(text(elements).contains("No starter lesson in this topic yet."))
            XCTAssertTrue(elements.contains { attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-empty" })
            XCTAssertFalse(elements.contains { (attribute($0, kAXIdentifierAttribute) as? String ?? "").hasPrefix("learning-lesson-") })
        }
    }

    func testLongLessonTitleAndMetadataWrapAtEnlargedTextWithoutLosingAccessibleContent() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let title = "Investigating cancellation propagation across nested requests and long-running background operations"
        let format = "extended guided discussion with detailed examples and follow-up questions"
        let lesson = LearningTopicSummary.StarterLesson(id: "long", title: title, format: format, estimatedMinutes: 125)
        let topic = LearningTopicSummary(id: "go", name: "Go", lessons: [lesson])
        var standardHeight: CGFloat = 0
        try inspect(LearningView(container: container, load: { _ in [topic] }), width: 360) { _, elements in
            let row = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-lesson-long" })
            standardHeight = try frame(row).height
        }
        try inspect(LearningView(container: container, load: { _ in [topic] }), width: 360, scale: 1.3) { _, elements in
            let row = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-lesson-long" })
            let bounds = try frame(row)
            XCTAssertGreaterThan(bounds.height, standardHeight)
            XCTAssertGreaterThan(bounds.height, AppMetrics.preferredTarget)
            XCTAssertLessThanOrEqual(bounds.width, 360 - 2 * AppMetrics.horizontalInset + 1)
            let name = (attribute(row, kAXDescriptionAttribute) as? String ?? "") +
                (attribute(row, kAXValueAttribute) as? String ?? "")
            XCTAssertTrue(name.contains(title), name)
            XCTAssertTrue(name.contains(format.capitalized), name)
            XCTAssertTrue(name.contains("125 min"), name)
            XCTAssertFalse(elements.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole })
        }
    }
}
