import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusActivitySelectionTests: XCTestCase {
    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
    private let otherTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!

    private func snapshot(_ minutes: Int) throws -> AppPreferencesSnapshot {
        AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: minutes), revision: UUID())
    }

    func testTypeTransitionsNeverChooseAnInventoryItemAndOnlyKeepCompatibleLinks() throws {
        var draft = FocusReadyDraft()
        XCTAssertEqual(draft.activityType, .none)
        XCTAssertNil(draft.linkedTaskID)
        XCTAssertNil(draft.linkedLessonID)

        draft.selectActivityType(.task)
        XCTAssertEqual(draft.activityType, .task)
        XCTAssertNil(draft.linkedTaskID, "Type selection must not choose the first open task")
        draft.selectTask(taskID)
        XCTAssertEqual(draft.activityType, .task)
        draft.selectActivityType(.task)
        XCTAssertEqual(draft.linkedTaskID, taskID, "Same-type selection preserves the ID")
        draft.selectTask(otherTaskID)
        XCTAssertEqual(draft.linkedTaskID, otherTaskID, "Explicit selection uses the exact ID")
        draft.selectTask(nil)
        XCTAssertEqual(draft.activityType, .task, "The task picker retains its empty placeholder")
        XCTAssertNil(draft.linkedTaskID)
        draft.selectTask(taskID)

        draft.selectActivityType(.lesson)
        XCTAssertNil(draft.linkedTaskID)
        XCTAssertNil(draft.linkedLessonID, "Switching type must not select the first lesson")
        draft.selectLesson("lesson-exact")
        XCTAssertEqual(draft.activityType, .lesson)
        draft.selectActivityType(.lesson)
        XCTAssertEqual(draft.linkedLessonID, "lesson-exact")
        draft.selectLesson(nil)
        XCTAssertEqual(draft.activityType, .lesson)
        XCTAssertNil(draft.linkedLessonID)
        draft.selectLesson("lesson-exact")
        draft.selectActivityType(.task)
        XCTAssertNil(draft.linkedLessonID)
        XCTAssertNil(draft.linkedTaskID, "An old task is not restored across type switches")
        draft.selectLesson("lesson-direct")
        XCTAssertEqual(draft.activityType, .lesson)
        XCTAssertNil(draft.linkedTaskID)
        draft.selectTask(otherTaskID)
        XCTAssertEqual(draft.activityType, .task)
        XCTAssertNil(draft.linkedLessonID)
        draft.selectActivityType(.none)
        XCTAssertNil(draft.linkedTaskID)
        XCTAssertNil(draft.linkedLessonID)
        XCTAssertEqual(draft.activityType, .none)
        XCTAssertNil(try draft.configuration(openTasks: [], tasksReadable: false, lessons: nil).linkedTaskID)
        XCTAssertNil(try draft.configuration(openTasks: [], tasksReadable: false, lessons: nil).linkedLessonID)
    }

    func testStaleIDsAndUnreadableInventoriesRequireExplicitCorrection() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let task = try SwiftDataTaskRepository(container: container).create(input: TaskInput(title: "Open"))
        var draft = FocusReadyDraft()
        draft.selectTask(task.id)
        XCTAssertEqual(try draft.configuration(openTasks: [task], tasksReadable: true).linkedTaskID, task.id)
        for (tasks, readable) in [([], true), ([task], false)] {
            XCTAssertThrowsError(try draft.configuration(openTasks: tasks, tasksReadable: readable)) {
                XCTAssertEqual($0 as? FocusError, .unavailableTask)
            }
            XCTAssertEqual(draft.linkedTaskID, task.id)
            XCTAssertEqual(draft.activityType, .task)
        }
        draft.selectTask(nil)
        XCTAssertNil(try draft.configuration(openTasks: [], tasksReadable: false).linkedTaskID)

        let catalog = SwiftDataCatalogRepository(container: container)
        _ = try catalog.importIfNeeded(BundledCatalogLoader.load())
        let learning = LearningCatalogStore(repository: catalog)
        learning.loadIfNeeded()
        let options = try XCTUnwrap(FocusReadyDraft.lessons(from: learning.state))
        let lesson = try XCTUnwrap(options.first)
        draft.selectLesson(lesson.id)
        XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: false, lessons: options).linkedLessonID, lesson.id)
        for unavailable in [nil, [], options.filter { $0.id != lesson.id }] as [[LessonDefinitionSnapshot]?] {
            XCTAssertThrowsError(try draft.configuration(openTasks: [], tasksReadable: false, lessons: unavailable)) {
                XCTAssertEqual($0 as? FocusError, .unavailableLesson)
            }
            XCTAssertEqual(draft.linkedLessonID, lesson.id)
            XCTAssertEqual(draft.activityType, .lesson)
        }
        XCTAssertNil(FocusReadyDraft.lessons(from: .failed(stale: try XCTUnwrap(learning.state.snapshot))))
        draft.selectLesson(nil)
        XCTAssertNil(try draft.configuration(openTasks: [], tasksReadable: false, lessons: nil).linkedLessonID)
    }

    func testActivityChangesPreserveFollowingOverrideSubmittedAndResetPreferences() throws {
        var draft = FocusReadyDraft(preferences: try snapshot(37))
        draft.selectActivityType(.task)
        draft.followPreferences(try snapshot(50))
        XCTAssertEqual(draft.duration, .fifty)
        XCTAssertEqual(draft.durationSource, .followingDefault)
        draft.selectDuration(.custom("42"))
        draft.selectTask(taskID)
        draft.selectActivityType(.lesson)
        draft.followPreferences(try snapshot(15))
        XCTAssertEqual(draft.duration, .custom("42"))
        XCTAssertEqual(draft.durationSource, .userOverride)
        draft.selectLesson("retry-lesson")
        draft.markSubmitted()
        draft.selectActivityType(.lesson)
        draft.followPreferences(nil)
        XCTAssertEqual(draft.linkedLessonID, "retry-lesson")
        XCTAssertEqual(draft.duration, .custom("42"))
        XCTAssertEqual(draft.durationSource, .submitted)
        draft.selectLesson(nil)
        XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: false).plannedSeconds(), 42 * 60)
        draft = FocusReadyDraft(preferences: try snapshot(15))
        XCTAssertEqual(draft.activityType, .none)
        XCTAssertNil(draft.linkedLessonID)
        XCTAssertNil(draft.linkedTaskID)
        XCTAssertEqual(draft.duration, .fifteen)
        XCTAssertEqual(draft.durationSource, .followingDefault)
        draft = FocusReadyDraft(preferences: nil)
        XCTAssertEqual(draft.activityType, .none)
        XCTAssertNotNil(draft.fallbackMessage)
        draft.selectActivityType(.task)
        XCTAssertNotNil(draft.fallbackMessage)
        draft.followPreferences(try snapshot(50))
        XCTAssertEqual(draft.duration, .fifty)
        XCTAssertNil(draft.fallbackMessage)
    }

    func testReadyLinkSummaryFlagsUnavailableSelectionWithoutChoosingAnotherRecord() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let task = try SwiftDataTaskRepository(container: container).create(input: TaskInput(title: "Review work"))
        let catalog = SwiftDataCatalogRepository(container: container)
        _ = try catalog.importIfNeeded(BundledCatalogLoader.load())
        let learning = LearningCatalogStore(repository: catalog)
        learning.loadIfNeeded()
        let lesson = try XCTUnwrap(FocusReadyDraft.lessons(from: learning.state)?.first)
        let before = try catalog.loadSnapshot()
        var draft = FocusReadyDraft()
        func summary(_ tasks: [TaskSnapshot], _ readable: Bool,
                     _ lessons: [LessonDefinitionSnapshot]?) -> FocusReadyLinkPresentation {
            FocusReadyLinkPresentation(draft: draft, openTasks: tasks, tasksReadable: readable, lessons: lessons)
        }
        XCTAssertEqual(summary([], false, nil).summary, "No linked activity")
        draft.selectActivityType(.task)
        XCTAssertEqual(summary([task], true, nil).summary, "No linked activity")
        XCTAssertNil(try draft.configuration(openTasks: [], tasksReadable: false).linkedTaskID)
        draft.selectTask(task.id)
        XCTAssertEqual(summary([task], true, nil).summary, "Task: Review work")
        XCTAssertFalse(summary([task], true, nil).needsCorrection)
        XCTAssertTrue(summary([task], false, nil).needsCorrection)
        XCTAssertTrue(summary([], true, nil).summary.contains("Unavailable task"))
        XCTAssertThrowsError(try draft.configuration(openTasks: [], tasksReadable: true))
        draft.selectActivityType(.lesson)
        draft.selectLesson(lesson.id)
        XCTAssertEqual(summary([], false, [lesson]).summary, "Lesson: \(lesson.title)")
        XCTAssertTrue(summary([], false, nil).needsCorrection)
        XCTAssertThrowsError(try draft.configuration(openTasks: [], tasksReadable: false, lessons: nil))
        draft.selectLesson(nil)
        XCTAssertEqual(summary([], false, nil).summary, "No linked activity")
        draft.selectDuration(.custom("0"))
        XCTAssertFalse(summary([], false, nil).needsCorrection, "Duration correction belongs to the visible duration controls")
        XCTAssertThrowsError(try draft.configuration(openTasks: [], tasksReadable: false))
        draft = FocusReadyDraft(preferences: AppPreferencesSnapshot(
            preferences: try AppPreferences(focusDefaultMinutes: 50), revision: UUID()))
        XCTAssertEqual(draft.activityType, .none)
        XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: false).plannedSeconds(), 3000)
        XCTAssertEqual(try catalog.loadSnapshot(), before, "Reading the summary never writes Learning")
    }

    func testSelectingTypesAndLinksDoesNotWriteSessionsOrLearning() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = SwiftDataCatalogRepository(container: container)
        _ = try catalog.importIfNeeded(BundledCatalogLoader.load())
        let learning = LearningCatalogStore(repository: catalog)
        learning.loadIfNeeded()
        let before = try catalog.loadSnapshot()
        let lessonID = try XCTUnwrap(FocusReadyDraft.lessons(from: learning.state)?.first?.id)
        let focusRepository = SwiftDataFocusRepository(container: container)
        let focus = FocusService(repository: focusRepository, scheduleTick: { _ in {} },
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
        focus.loadIfNeeded()
        var draft = FocusReadyDraft()
        draft.selectActivityType(.task)
        draft.selectTask(taskID)
        draft.selectActivityType(.lesson)
        draft.selectLesson(lessonID)
        _ = try draft.configuration(openTasks: [], tasksReadable: false,
                                     lessons: try XCTUnwrap(FocusReadyDraft.lessons(from: learning.state)))
        draft.selectActivityType(.none)
        _ = try draft.configuration(openTasks: [], tasksReadable: false, lessons: nil)
        XCTAssertNil(focus.activeSession)
        XCTAssertTrue(try focusRepository.fetchAll().isEmpty)
        XCTAssertEqual(try catalog.loadSnapshot(), before)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
    }
}
