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

    func testSeededDefinitionsReadOfflineWithoutCreatingProgressOrActions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = try BundledCatalogLoader.load(from: Bundle.main)
        let repository = SwiftDataCatalogRepository(container: container)
        XCTAssertEqual(try repository.importIfNeeded(catalog), .imported)
        let summaries = try LearningTopicSummary.load(from: container)
        XCTAssertEqual(summaries.map(\.name), ["Go", "Java", "System Design", "Performance", "Security"])
        XCTAssertEqual(summaries.map(\.lessons.count), [1, 1, 1, 1, 1])
        XCTAssertEqual(Set(summaries.flatMap(\.lessons).map(\.title)), Set(catalog.value.lessons.map(\.title)))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)

        let suite = "LearningPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let dependencies = AppDependencies(container: container, catalogRepository: repository)
        XCTAssertEqual(AppShell.contentKind(for: .learning), .learning)
        let host = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: dependencies))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Learning starter inspection"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        navigation.select(.learning)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let learningWindow = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
        let elements = descendants(of: learningWindow)
        let identifiers = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
        for topic in summaries {
            XCTAssertTrue(identifiers.contains("learning-topic-\(topic.id)"), topic.name)
            for lesson in topic.lessons {
                XCTAssertTrue(identifiers.contains("learning-lesson-\(lesson.id)"), lesson.title)
            }
        }
        let labels = elements.compactMap { attribute($0, kAXValueAttribute) as? String } +
            elements.compactMap { attribute($0, kAXDescriptionAttribute) as? String }
        XCTAssertTrue(labels.contains { $0.contains("available offline") })
        XCTAssertFalse(labels.contains { $0.contains("4 available") || $0.contains("Completed") })
        XCTAssertEqual(elements.filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }.count,
                       AppDestination.allCases.count, "Learning must not offer nonfunctional lesson actions")
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
        lesson.title = "Corrected starter title"
        try context.save()
        XCTAssertEqual(try LearningTopicSummary.load(from: container).first?.lessons.first?.title,
                       "Corrected starter title")
    }

    func testEmptyStoreDoesNotPresentBundledOrPreviewContent() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        XCTAssertTrue(try LearningTopicSummary.load(from: container).isEmpty)
    }
}
