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
        // Topic controls change this window's projection, not the shared assignments.
        let javaButton = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "learning-topic-java" })
        XCTAssertEqual(AXUIElementPerformAction(javaButton, kAXPressAction as CFString), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let javaIDs = identifiers(descendants(of: try XCTUnwrap(learningWindow)))
        XCTAssertEqual(javaIDs.filter { $0.hasPrefix("learning-lesson-") },
                       LearningView.choices(for: "java", in: snapshot).map { "learning-lesson-\($0.id)" })
        XCTAssertEqual(elements.filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }.count,
                       AppDestination.allCases.count + topics.count, "Only navigation and topic selection are actionable")
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
        }
    }
}

@MainActor
private final class FailingCatalogReader: CatalogRepository {
    enum ReadError: Error { case injected }
    func loadSnapshot() throws -> LearningCatalogSnapshot { throw ReadError.injected }
    func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot { throw ReadError.injected }
    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult { .unchanged }
}
