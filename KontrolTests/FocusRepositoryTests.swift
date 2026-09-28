import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusRepositoryTests: XCTestCase {
    private enum Injected: Error { case failed }
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    private func input(task: UUID? = nil, seconds: Int = 1500) -> FocusStartInput {
        FocusStartInput(plannedSeconds: seconds, startedAt: start, linkedTaskID: task)
    }

    private func rows(_ container: ModelContainer) throws -> [FocusSessionSnapshot] {
        try SwiftDataFocusRepository(container: container).fetchAll()
    }

    func testStartCommitsSnapshotWithoutPostSaveFetchAndRejectsRepeatedOrSecondWindowStart() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var reads = 0
        var ids = 0
        var saves = 0
        let writer = SwiftDataFocusRepository(container: container,
            makeID: { ids += 1; return self.first },
            fetchSessions: { context in
                reads += 1
                if reads > 1 { throw Injected.failed }
                return try context.fetch(FetchDescriptor<FocusSession>())
            }, save: { context in saves += 1; try context.save() })
        let saved = try writer.create(input: input())
        XCTAssertEqual(saved.id, first)
        XCTAssertEqual(saved.state, .running)
        XCTAssertEqual(saved.plannedSeconds, 1500)
        XCTAssertEqual(saved.accumulatedActiveSeconds, 0)
        XCTAssertEqual(saved.startedAt, start)
        XCTAssertEqual(saved.checkpointAt, start)
        XCTAssertEqual(saved.activeSegmentStartedAt, start)
        XCTAssertEqual(saved.deadline, start.addingTimeInterval(1500))
        XCTAssertNil(saved.linkedTaskID)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container), [saved])
        let otherWindow = SwiftDataFocusRepository(container: container, makeID: { self.second })
        XCTAssertThrowsError(try otherWindow.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(try rows(container), [saved])
        // A read error is not treated as an empty session set.
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
    }

    func testSelectedTaskIsResolvedInsideWriteContextAndNeverMutated() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        seed.insert(try TaskItem(id: taskID, title: "  Current title  ", createdAt: start))
        seed.insert(LessonProgress(lessonID: "lesson", status: .started, startedAt: start))
        try seed.save()
        // The selection was made before this rename; Start must use the current title.
        let editor = ModelContext(container)
        editor.autosaveEnabled = false
        let task = try XCTUnwrap(editor.fetch(FetchDescriptor<TaskItem>()).first)
        task.title = "Renamed task"
        try editor.save()
        var taskReads = 0
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first },
            fetchTasks: { context, id in
                taskReads += 1
                return try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
            })
        let saved = try writer.create(input: input(task: taskID))
        XCTAssertEqual(saved.linkedTaskID, taskID)
        XCTAssertEqual(saved.linkedTitleSnapshot, "Renamed task")
        XCTAssertEqual(taskReads, 1)
        XCTAssertEqual(try rows(container), [saved])
        let inspect = ModelContext(container)
        let persistedTask = try XCTUnwrap(inspect.fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(persistedTask.title, "Renamed task")
        XCTAssertNil(persistedTask.completedAt)
        let progress = try XCTUnwrap(inspect.fetch(FetchDescriptor<LessonProgress>()).first)
        XCTAssertEqual(progress.status, .started)
        XCTAssertEqual(progress.startedAt, start)
        XCTAssertNil(progress.completedAt)
    }

    func testUnavailableSelectedTaskIsDistinctAndNeverFallsBackToUnlinked() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = 0
        var saves = 0
        let writer = SwiftDataFocusRepository(container: container,
            makeID: { ids += 1; return self.first },
            save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try writer.create(input: input(task: taskID))) {
            XCTAssertEqual($0 as? FocusError, .unavailableTask)
        }
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        seed.insert(try TaskItem(id: taskID, title: "Finished", createdAt: start,
                                 completedAt: start.addingTimeInterval(10)))
        try seed.save()
        XCTAssertThrowsError(try writer.create(input: input(task: taskID))) {
            XCTAssertEqual($0 as? FocusError, .unavailableTask)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(try rows(container).isEmpty)
        let task = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(task.completedAt, start.addingTimeInterval(10))
        try SwiftDataTaskRepository(container: container).delete(id: taskID)
        XCTAssertThrowsError(try writer.create(input: input(task: taskID))) {
            XCTAssertEqual($0 as? FocusError, .unavailableTask)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(try rows(container).isEmpty)
    }

    func testInvalidInputAndFailedReadsNeverAllocateOrWrite() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var reads = 0
        var ids = 0
        var saves = 0
        let writer = SwiftDataFocusRepository(container: container,
            makeID: { ids += 1; return self.first },
            fetchSessions: { _ in reads += 1; throw Injected.failed },
            save: { _ in saves += 1; throw Injected.failed })
        for draft in [input(seconds: 0),
                      FocusStartInput(plannedSeconds: 10, startedAt: start,
                                      linkedTaskID: taskID, linkedLessonID: "lesson")] {
            XCTAssertThrowsError(try writer.create(input: draft))
        }
        XCTAssertEqual(reads, 0)
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertThrowsError(try writer.fetchAll()) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(try rows(container).isEmpty)
        let badTaskRead = SwiftDataFocusRepository(container: container, makeID: { self.first },
            fetchTasks: { _, _ in throw Injected.failed })
        XCTAssertThrowsError(try badTaskRead.create(input: input(task: taskID))) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
    }

    func testFailedSaveDiscardsPrivateInsertAndAllowsRetryWithoutChangingAnotherDraft() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let other = ModelContext(container)
        other.autosaveEnabled = false
        other.insert(try TaskItem(id: taskID, title: "Other owner's draft", createdAt: start))
        var saves = 0
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first },
            save: { _ in saves += 1; throw Injected.failed })
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(other.hasChanges)
        XCTAssertTrue(try rows(container).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count, 0)
        try other.save()
        let saved = try SwiftDataFocusRepository(container: container,
            makeID: { self.first }).create(input: input(task: taskID))
        XCTAssertEqual(saved.linkedTitleSnapshot, "Other owner's draft")
        XCTAssertEqual(try rows(container), [saved])
    }

    func testCorruptRowAndDuplicateIDCannotAuthorizeStart() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        seed.insert(FocusSession(id: first, state: "unknown", plannedSeconds: 1500,
                                 accumulatedActiveSeconds: 0, startedAt: start, checkpointAt: start))
        try seed.save()
        XCTAssertThrowsError(try SwiftDataFocusRepository(container: container,
            makeID: { self.second }).create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        let cleanup = ModelContext(container)
        cleanup.autosaveEnabled = false
        cleanup.delete(try XCTUnwrap(cleanup.fetch(FetchDescriptor<FocusSession>()).first))
        try cleanup.save()
        let terminal = ModelContext(container)
        terminal.autosaveEnabled = false
        terminal.insert(FocusSession(id: first, state: "ended", plannedSeconds: 1500,
                                     accumulatedActiveSeconds: 5, startedAt: start,
                                     endedAt: start.addingTimeInterval(5),
                                     checkpointAt: start.addingTimeInterval(5)))
        try terminal.save()
        XCTAssertThrowsError(try SwiftDataFocusRepository(container: container,
            makeID: { self.first }).create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(try rows(container).count, 1)
    }

    func testPausedAndMultipleActiveRecordsBlockStartWithoutChangingEitherRow() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        seed.insert(FocusSession(id: first, state: "paused", plannedSeconds: 1500,
                                 accumulatedActiveSeconds: 12.5,
                                 pausedAt: start.addingTimeInterval(13), startedAt: start,
                                 checkpointAt: start.addingTimeInterval(13),
                                 recoveryRequired: true))
        try seed.save()
        let original = try rows(container)
        var ids = 0
        let writer = SwiftDataFocusRepository(container: container,
            makeID: { ids += 1; return self.second })
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(try rows(container), original)
        let secondSeed = ModelContext(container)
        secondSeed.autosaveEnabled = false
        secondSeed.insert(FocusSession(id: second, state: "running", plannedSeconds: 1500,
                                       accumulatedActiveSeconds: 0, activeSegmentStartedAt: start,
                                       deadline: start.addingTimeInterval(1500), startedAt: start,
                                       checkpointAt: start))
        try secondSeed.save()
        let both = try rows(container)
        XCTAssertEqual(both.count, 2)
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(try rows(container), both)
    }

    func testStartSurvivesSeparateDiskOpenAndFailedStartDoesNotReachDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolFocusStart-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Kontrol.store")
        // SwiftData can retain SQLite descriptors after a container leaves scope.
        func open(_ check: (ModelContainer) throws -> Void) throws {
            try autoreleasepool {
                try check(ModelContainerFactory().makeContainer(mode: .persistent(url)))
            }
        }
        try open { container in
            let failing = SwiftDataFocusRepository(container: container,
                makeID: { self.first }, save: { _ in throw Injected.failed })
            XCTAssertThrowsError(try failing.create(input: input())) {
                XCTAssertEqual($0 as? FocusError, .persistenceFailure)
            }
            XCTAssertTrue(try rows(container).isEmpty)
        }
        try open { container in
            XCTAssertTrue(try rows(container).isEmpty)
            XCTAssertEqual(try SwiftDataFocusRepository(container: container,
                makeID: { self.first }).create(input: input()).id, first)
        }
        try open { container in
            XCTAssertEqual(try rows(container).map(\.id), [first])
            XCTAssertThrowsError(try SwiftDataFocusRepository(container: container,
                makeID: { self.second }).create(input: input())) {
                XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
            }
            XCTAssertEqual(try rows(container).map(\.id), [first])
        }
    }
}
