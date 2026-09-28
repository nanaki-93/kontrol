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

    private func inspect<V: View>(_ view: V, check: ([AXUIElement], () -> [AXUIElement]) throws -> Void) throws {
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
        let root = try XCTUnwrap(target)
        try check(descendants(root), { self.descendants(root) })
    }

    func testShowAnotherCancelKeepsExactAssignmentAndPracticeResponse() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        graph.lessonDraftStore.observe(opened.detail)
        let snapshot = try repository.loadSnapshot()
        try inspect(LessonExperienceView(lessonID: id, store: store, drafts: graph.lessonDraftStore,
                                         navigation: NavigationStore())) { elements, currentElements in
            let dismiss = try XCTUnwrap(elements.first {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-dismiss"
            })
            XCTAssertEqual(AXUIElementPerformAction(dismiss, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let all = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
            let cancel = try XCTUnwrap(all.first { attribute($0, kAXTitleAttribute) as? String == "Keep lesson" })
            XCTAssertEqual(AXUIElementPerformAction(cancel, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(currentElements().contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-dismiss"
            })
            XCTAssertEqual(try repository.loadSnapshot(), snapshot)
            XCTAssertEqual(try repository.loadLesson(lessonID: id).progress?.status, .started)
            XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.id, opened.detail.attempt?.id)
        }
    }

    func testChoiceConfirmationDismissesOnlyCapturedLessonAndRestoresTopicFocus() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let snapshot = try XCTUnwrap(store.state.snapshot)
        let slot = try XCTUnwrap(snapshot.slots.first { $0.topicID == "go" })
        let navigation = NavigationStore()
        navigation.attachDrafts(graph.lessonDraftStore)
        try inspect(LearningView(store: store, navigation: navigation)) { elements, _ in
            let dismiss = try XCTUnwrap(elements.first {
                attribute($0, kAXIdentifierAttribute) as? String == "learning-dismiss-\(slot.lessonID)"
            })
            XCTAssertEqual(AXUIElementPerformAction(dismiss, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let all = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
            let confirm = try XCTUnwrap(all.first {
                attribute($0, kAXTitleAttribute) as? String == "Show another"
            })
            XCTAssertEqual(AXUIElementPerformAction(confirm, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            XCTAssertEqual(try repository.loadLesson(lessonID: slot.lessonID).progress?.status, .dismissed)
            XCTAssertNil(try repository.loadLesson(lessonID: slot.lessonID).progress?.completedAt)
            XCTAssertEqual(try repository.loadSnapshot().slots.filter { $0.key != slot.key },
                           snapshot.slots.filter { $0.key != slot.key })
            if let focused = attribute(app, kAXFocusedUIElementAttribute) {
                XCTAssertEqual(attribute(focused as! AXUIElement, kAXIdentifierAttribute) as? String,
                               "learning-topic-go")
            } else {
                XCTFail("Focus was not restored after confirmation")
            }
        }
    }

    func testExhaustedChoicesShowVacancyAndHonestGenerateNotice() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let initial = try repository.loadSnapshot()
        let topic = "go"
        let topicDefinitions = initial.definitions.filter { $0.topicID == topic }
        XCTAssertEqual(topicDefinitions.count, 8)
        // Consume real assignments, including the reserve lessons selected to refill
        // them. No slot rows are manually removed: the selector must run out of
        // eligible candidates and leave exactly two still-open lessons.
        for step in 0..<(topicDefinitions.count - 2) {
            let current = try repository.loadSnapshot()
            let slot = try XCTUnwrap(current.slots.filter { $0.topicID == topic }
                .max { $0.slotIndex < $1.slotIndex })
            _ = try repository.dismiss(lessonID: slot.lessonID, expectedSlot: slot,
                                       now: Date(timeIntervalSince1970: 2_000_000_000 + Double(step)))
        }
        let partial = try repository.loadSnapshot()
        let remaining = partial.slots.filter { $0.topicID == topic }
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.map(\.lessonID)).count, 2)
        XCTAssertEqual(try repository.loadHistory().filter { $0.topicID == topic }.count, 6)
        let graph = AppDependencies(container: container, catalogRepository: repository)
        graph.learningCatalogStore.loadIfNeeded()
        let navigation = NavigationStore()
        navigation.attachDrafts(graph.lessonDraftStore)
        try inspect(LearningView(store: graph.learningCatalogStore, navigation: navigation)) { elements, currentElements in
            let ids = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            XCTAssertTrue(ids.contains("learning-vacancy"))
            for slot in remaining {
                XCTAssertEqual(ids.filter { $0 == "learning-open-\(slot.lessonID)" }.count, 1)
            }
            let generate = try XCTUnwrap(elements.first {
                attribute($0, kAXIdentifierAttribute) as? String == "learning-generate-unavailable"
            })
            XCTAssertEqual(AXUIElementPerformAction(generate, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let all = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
            let labels = all.flatMap { element in
                [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                    .compactMap { attribute(element, $0) as? String }
            }
            XCTAssertTrue(labels.contains { $0.contains("Generation unavailable") })
            XCTAssertTrue(labels.contains { $0.contains("No additional eligible lessons are installed for this topic") })
            XCTAssertFalse(labels.contains { $0.contains("No more eligible lessons are installed") })
            XCTAssertTrue(labels.contains { $0 == "History" })
            XCTAssertTrue(labels.contains { $0 == "Another topic" })
            XCTAssertEqual(try repository.loadSnapshot(), partial)
            XCTAssertEqual(try repository.loadHistory().filter { $0.topicID == topic }.count, 6)
            XCTAssertEqual(currentElements().filter {
                (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("learning-open-") == true
            }.count, 2)
        }
        // The last two can also be dismissed without inventing replacement content.
        for (step, slot) in remaining.enumerated() {
            _ = try repository.dismiss(lessonID: slot.lessonID, expectedSlot: slot,
                                       now: Date(timeIntervalSince1970: 2_000_000_010 + Double(step)))
        }
        let empty = try repository.loadSnapshot()
        XCTAssertTrue(empty.slots.filter { $0.topicID == topic }.isEmpty)
        let emptyGraph = AppDependencies(container: container, catalogRepository: repository)
        emptyGraph.learningCatalogStore.loadIfNeeded()
        try inspect(LearningView(store: emptyGraph.learningCatalogStore)) { elements, _ in
            XCTAssertTrue(elements.contains { attribute($0, kAXIdentifierAttribute) as? String == "learning-vacancy" })
            let generate = try XCTUnwrap(elements.first {
                attribute($0, kAXIdentifierAttribute) as? String == "learning-generate-unavailable"
            })
            XCTAssertEqual(AXUIElementPerformAction(generate, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let all = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
            let messages = all.compactMap { attribute($0, kAXValueAttribute) as? String }
            XCTAssertTrue(messages.contains { $0.contains("No eligible lessons are installed for this topic") })
            XCTAssertFalse(messages.contains { $0.contains("No additional eligible lessons are installed") })
            XCTAssertEqual(try repository.loadSnapshot(), empty)
        }
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
                                             drafts: graph.lessonDraftStore, navigation: NavigationStore())) { elements, _ in
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

    func testRevealSelfCheckAndCompletionOnlyAppearAfterCommittedActions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        graph.lessonDraftStore.observe(opened.detail)
        let view = LessonExperienceView(lessonID: id, store: store,
                                        drafts: graph.lessonDraftStore, navigation: NavigationStore())
        try inspect(view) { elements, currentElements in
            let ids = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            XCTAssertTrue(ids.contains("lesson-show-solution"))
            XCTAssertFalse(ids.contains("lesson-reference-solution"))
            XCTAssertFalse(ids.contains("lesson-acknowledge"))
            XCTAssertFalse(ids.contains("lesson-complete"))
            let initialValues = elements.compactMap { attribute($0, kAXValueAttribute) as? String }.joined(separator: "\n")
            XCTAssertFalse(initialValues.contains("Self-check · authored criteria"))
            let reveal = try XCTUnwrap(elements.first { attribute($0, kAXIdentifierAttribute) as? String == "lesson-show-solution" })
            XCTAssertEqual(AXUIElementPerformAction(reveal, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertNotEqual(store.detailState, .current(opened.detail))
            let revealed = currentElements()
            let revealedIDs = revealed.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            XCTAssertTrue(revealedIDs.contains("lesson-reference-solution"))
            XCTAssertTrue(revealedIDs.contains("lesson-acknowledge"))
            let revealedValues = revealed.compactMap { attribute($0, kAXValueAttribute) as? String }.joined(separator: "\n")
            guard case .pinned(let definition) = opened.detail.content else {
                return XCTFail("Expected pinned studied content")
            }
            XCTAssertTrue(revealedValues.contains(definition.referenceAnswer))
            for criterion in definition.selfCheckCriteria { XCTAssertTrue(revealedValues.contains(criterion)) }
            let complete = try XCTUnwrap(revealed.first { attribute($0, kAXIdentifierAttribute) as? String == "lesson-complete" })
            XCTAssertEqual(attribute(complete, kAXEnabledAttribute) as? Bool, false)
            let back = try XCTUnwrap(revealed.first { attribute($0, kAXIdentifierAttribute) as? String == "lesson-back-to-exercise" })
            XCTAssertEqual(AXUIElementPerformAction(back, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let exerciseIDs = currentElements().compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            XCTAssertTrue(exerciseIDs.contains("lesson-response-\(id)"))
            XCTAssertFalse(exerciseIDs.contains("lesson-reference-solution"))
            let viewSolution = try XCTUnwrap(currentElements().first {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-show-solution"
            })
            XCTAssertEqual(AXUIElementPerformAction(viewSolution, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let acknowledge = try XCTUnwrap(currentElements().first {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-acknowledge"
            })
            XCTAssertEqual(AXUIElementPerformAction(acknowledge, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(currentElements().contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-acknowledged"
            })
            let ready = try XCTUnwrap(currentElements().first {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-complete"
            })
            XCTAssertEqual(attribute(ready, kAXEnabledAttribute) as? Bool, true)
            XCTAssertEqual(AXUIElementPerformAction(ready, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(currentElements().contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-completion-receipt"
            })
            XCTAssertFalse(currentElements().contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-complete"
            })
        }
    }

    func testFailedRevealKeepsExerciseAndDisplaysRetryableFailure() throws {
        enum Injected: Error { case save }
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        graph.lessonDraftStore.observe(opened.detail)
        fail = true
        try inspect(LessonExperienceView(lessonID: id, store: store,
                                         drafts: graph.lessonDraftStore, navigation: NavigationStore())) { elements, currentElements in
            let reveal = try XCTUnwrap(elements.first {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-show-solution"
            })
            XCTAssertEqual(AXUIElementPerformAction(reveal, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let ids = currentElements().compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            XCTAssertTrue(ids.contains("lesson-gate-error"))
            XCTAssertTrue(ids.contains("lesson-response-\(id)"))
            XCTAssertFalse(ids.contains("lesson-reference-solution"))
            XCTAssertFalse(ids.contains("lesson-complete"))
            XCTAssertNil(try repository.loadLesson(lessonID: id).attempt?.solutionRevealedAt)
        }
    }

    func testSolutionShowsSharedDraftSavingFailureAndRetryWithoutLeavingSolution() throws {
        enum Injected: Error { case save }
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load(from: Bundle.main))
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let store = graph.learningCatalogStore
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        let attemptID = try XCTUnwrap(opened.detail.attempt?.id)
        let drafts = graph.lessonDraftStore
        drafts.observe(opened.detail)
        try inspect(LessonExperienceView(lessonID: id, store: store, drafts: drafts,
                                         navigation: NavigationStore())) { elements, currentElements in
            let reveal = try XCTUnwrap(elements.first {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-show-solution"
            })
            XCTAssertEqual(AXUIElementPerformAction(reveal, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(currentElements().contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-reference-solution"
            })
            // A second window uses the same buffer while this one remains on the solution.
            drafts.edit("  shared 🧪\n", attemptID: attemptID)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(drafts.buffers[attemptID]?.status, .saving)
            let saving = currentElements()
            XCTAssertTrue(saving.contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-save-status" &&
                attribute($0, kAXValueAttribute) as? String == "Saving"
            })
            let pendingComplete = try XCTUnwrap(saving.first {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-complete"
            })
            XCTAssertEqual(attribute(pendingComplete, kAXEnabledAttribute) as? Bool, false)
            fail = true
            XCTAssertThrowsError(try drafts.flush(attemptID: attemptID))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let failed = currentElements()
            XCTAssertTrue(failed.contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-save-status" &&
                attribute($0, kAXValueAttribute) as? String == "Not saved — Retry"
            })
            XCTAssertTrue(failed.contains { attribute($0, kAXIdentifierAttribute) as? String == "lesson-reference-solution" })
            let complete = try XCTUnwrap(failed.first { attribute($0, kAXIdentifierAttribute) as? String == "lesson-complete" })
            XCTAssertEqual(attribute(complete, kAXEnabledAttribute) as? Bool, false)
            fail = false
            let retry = try XCTUnwrap(failed.first { attribute($0, kAXIdentifierAttribute) as? String == "lesson-retry-save" })
            XCTAssertEqual(AXUIElementPerformAction(retry, kAXPressAction as CFString), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(currentElements().contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lesson-save-status" &&
                attribute($0, kAXValueAttribute) as? String == "Saved"
            })
            XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "  shared 🧪\n")
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
                                         drafts: graph.lessonDraftStore, navigation: NavigationStore())) { elements, _ in
            let ids = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            let values = elements.compactMap { attribute($0, kAXValueAttribute) as? String }.joined(separator: "\n")
            XCTAssertTrue(values.contains("Studied content unavailable"))
            XCTAssertFalse(ids.contains("lesson-response-\(id)"))
            XCTAssertFalse(ids.contains("lesson-exercise"))
        }
    }
}
