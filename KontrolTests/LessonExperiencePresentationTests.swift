import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

/// Hosted assertions compile now; execution is reserved for the F13 GUI gate.
@MainActor
final class LessonExperiencePresentationTests: XCTestCase {
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }

    private func descendants(_ element: AXUIElement) -> [AXUIElement] {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + descendants($0) }
    }

    private func inspect(_ view: LessonExperienceView, check: ([AXUIElement]) throws -> Void) throws {
        let host = NSHostingView(rootView: ScrollView { view })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Practice inspection \(UUID())"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var target: AXUIElement?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            target = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
                attribute($0, kAXTitleAttribute) as? String == window.title
            }
        } while target == nil && Date() < deadline
        try check(descendants(try XCTUnwrap(target)))
    }

    func testFourFormatsShowStudiedSectionsAndLabeledResponseWithoutReferenceDisclosure() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let definitions = try XCTUnwrap(store.state.snapshot).definitions
        for format in ["learn", "code", "question", "design"] {
            let lesson = try XCTUnwrap(definitions.first { $0.format == format })
            let opened = try store.openLesson(lessonID: lesson.id)
            graph.lessonDraftStore.observe(opened.detail)
            try inspect(LessonExperienceView(lessonID: lesson.id, store: store,
                                             drafts: graph.lessonDraftStore, navigation: NavigationStore())) { elements in
                let ids = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
                let values = elements.compactMap { attribute($0, kAXValueAttribute) as? String }.joined(separator: "\n")
                for section in ["lesson-explanation", "lesson-worked-example", "lesson-exercise"] {
                    XCTAssertTrue(ids.contains(section), "Missing \(section) for \(format)")
                }
                XCTAssertTrue(ids.contains("lesson-response-\(lesson.id)"))
                XCTAssertTrue(ids.contains("lesson-save-status"))
                for content in [lesson.explanation, lesson.workedExample, lesson.exercise] {
                    XCTAssertTrue(values.contains(content), "Missing studied \(format) content")
                }
                XCTAssertFalse(values.contains(lesson.referenceAnswer))
            }
        }
    }

    func testMissingPinNeverPresentsCurrentCatalogOrEditableResponse() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<LessonAttempt>()).first { $0.id == attempt.id })
        row.pinnedContentData = nil
        try context.save()
        try inspect(LessonExperienceView(lessonID: id, store: store,
                                         drafts: graph.lessonDraftStore, navigation: NavigationStore())) { elements in
            let ids = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            let values = elements.compactMap { attribute($0, kAXValueAttribute) as? String }.joined(separator: "\n")
            XCTAssertTrue(values.contains("Studied content unavailable"))
            XCTAssertFalse(ids.contains("lesson-response-\(id)"))
            XCTAssertFalse(ids.contains("lesson-exercise"))
        }
    }
}
