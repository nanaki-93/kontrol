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
        let both = try ModelContext(container).fetch(FetchDescriptor<FocusSession>())
            .map(FocusSessionSnapshot.init)
        XCTAssertEqual(both.count, 2)
        XCTAssertThrowsError(try writer.fetchAll()) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FocusSession>())
            .map(FocusSessionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString },
            both.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private func payload(_ baseline: FocusSessionSnapshot, seconds: Double,
                         offset: TimeInterval) -> FocusTransitionPayload {
        FocusTransitionPayload(expectedCheckpointAt: baseline.checkpointAt,
                               sampledAt: start.addingTimeInterval(offset),
                               accumulatedActiveSeconds: seconds)
    }

    func testCheckpointPauseResumeEndAndRepeatedTerminalCommands() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let running = try writer.create(input: input())
        let checkpoint = try writer.transition(id: first, command: .checkpoint(
            payload(running, seconds: 12.5, offset: 13)))
        XCTAssertEqual(checkpoint.state, .running)
        XCTAssertEqual(checkpoint.activeSegmentStartedAt, start.addingTimeInterval(13))
        XCTAssertEqual(checkpoint.deadline, start.addingTimeInterval(1500.5))
        XCTAssertEqual(checkpoint.accumulatedActiveSeconds, 12.5)
        XCTAssertEqual(try rows(container), [checkpoint])
        let paused = try writer.transition(id: first, command: .pause(
            payload(checkpoint, seconds: 25.25, offset: 26)))
        XCTAssertNil(paused.deadline)
        XCTAssertNil(paused.activeSegmentStartedAt)
        XCTAssertEqual(paused.pausedAt, start.addingTimeInterval(26))
        let resumed = try writer.transition(id: first, command: .resume(
            payload(paused, seconds: 25.25, offset: 326)))
        XCTAssertNil(resumed.pausedAt)
        XCTAssertEqual(resumed.deadline, start.addingTimeInterval(1800.75))
        let ended = try writer.transition(id: first, command: .end(
            payload(resumed, seconds: 30.75, offset: 332)))
        XCTAssertEqual(ended.state, .ended)
        XCTAssertEqual(ended.endedAt, start.addingTimeInterval(332))
        XCTAssertNil(ended.activeSegmentStartedAt)
        XCTAssertNil(ended.pausedAt)
        XCTAssertEqual(try rows(container), [ended])
        var saves = 0
        let duplicate = SwiftDataFocusRepository(container: container,
            save: { context in saves += 1; try context.save() })
        XCTAssertEqual(try duplicate.transition(id: first, command: .end(
            payload(running, seconds: 1, offset: 1))), ended)
        XCTAssertEqual(try duplicate.transition(id: first, command: .complete(
            payload(running, seconds: 1500, offset: 1500))), ended)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try rows(container), [ended])
    }

    func testCompletionUsesEffectiveFinishAndIsIdempotent() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let running = try writer.create(input: input(seconds: 20))
        let finished = try writer.transition(id: first, command: .complete(
            payload(running, seconds: 20, offset: 200)),
            effectiveEndedAt: start.addingTimeInterval(20))
        XCTAssertEqual(finished.endedAt, start.addingTimeInterval(20))
        XCTAssertEqual(finished.checkpointAt, start.addingTimeInterval(200))
        XCTAssertEqual(finished.actualSeconds, 20)
        XCTAssertEqual(try writer.transition(id: first, command: .complete(
            payload(running, seconds: 20, offset: 201))), finished)
        XCTAssertEqual(try rows(container), [finished])
    }

    func testStaleAndInvalidTransitionsNeverSaveOrModifyLatestRow() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let running = try writer.create(input: input())
        let newer = try writer.transition(id: first, command: .checkpoint(
            payload(running, seconds: 4.5, offset: 5)))
        var saves = 0
        let guarded = SwiftDataFocusRepository(container: container,
            save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try guarded.transition(id: first, command: .checkpoint(
            payload(running, seconds: 8, offset: 9)))) {
            XCTAssertEqual($0 as? FocusError, .staleBaseline)
        }
        let invalid: [FocusTransition] = [
            .resume(payload(newer, seconds: 4.5, offset: 6)),
            .pause(payload(newer, seconds: 1500, offset: 1500)),
            .end(payload(newer, seconds: 3, offset: 6)),
            .complete(payload(newer, seconds: 4.5, offset: 6)),
            .complete(payload(newer, seconds: 1500, offset: 1500)),
            .checkpoint(payload(newer, seconds: 4, offset: 5)),
            .checkpoint(payload(newer, seconds: 9, offset: 4)),
            .reconcile(payload(newer, seconds: 9, offset: 9))
        ]
        for command in invalid {
            XCTAssertThrowsError(try guarded.transition(id: first, command: command)) {
                XCTAssertEqual($0 as? FocusError, .invalidTransition)
            }
        }
        XCTAssertThrowsError(try guarded.transition(id: second, command: .pause(
            payload(newer, seconds: 5, offset: 6)))) {
            XCTAssertEqual($0 as? FocusError, .missingSession)
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try rows(container), [newer])
    }

    func testRollbackPauseResumeRejectsOldRunningCheckpointAndAcceptsFreshOne() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let initial = try writer.create(input: input())
        let running = try writer.transition(id: first, command: .checkpoint(
            payload(initial, seconds: 5, offset: 10)))
        let oldCallback = FocusTransition.checkpoint(
            payload(running, seconds: 30, offset: 40))
        // The wall clock has fallen behind the checkpoint; pure timing clamps it.
        let rollback = start.addingTimeInterval(2)
        let pause = try FocusTiming.pause(running, at: rollback, monotonicDelta: 1)
        let paused = try writer.transition(id: first, command: pause.transition)
        XCTAssertEqual(paused.actualSeconds, 6)
        XCTAssertGreaterThan(paused.checkpointAt, running.checkpointAt)
        XCTAssertEqual(paused.pausedAt, paused.checkpointAt)
        let resume = try FocusTiming.resume(paused, at: rollback)
        let resumed = try writer.transition(id: first, command: resume.transition)
        XCTAssertEqual(resumed.actualSeconds, 6)
        XCTAssertGreaterThan(resumed.checkpointAt, paused.checkpointAt)
        XCTAssertEqual(resumed.activeSegmentStartedAt, resumed.checkpointAt)
        XCTAssertEqual(resumed.deadline,
                       resumed.checkpointAt.addingTimeInterval(1500 - 6))
        var saves = 0
        let guarded = SwiftDataFocusRepository(container: container,
            save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try guarded.transition(id: first, command: oldCallback)) {
            XCTAssertEqual($0 as? FocusError, .staleBaseline)
        }
        let fresh = try FocusTiming.checkpoint(resumed, at: rollback, monotonicDelta: 2)
        let checkpoint = try guarded.transition(id: first, command: fresh.transition)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(checkpoint.actualSeconds, 8)
        XCTAssertGreaterThan(checkpoint.checkpointAt, resumed.checkpointAt)
        XCTAssertEqual(checkpoint.activeSegmentStartedAt, rollback)
        XCTAssertEqual(checkpoint.deadline,
                       rollback.addingTimeInterval(1500 - 8))
        XCTAssertThrowsError(try guarded.transition(id: first, command: fresh.transition)) {
            XCTAssertEqual($0 as? FocusError, .staleBaseline)
        }
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container), [checkpoint])
    }

    func testRollbackWatermarkSurvivesDiskReopenAndFailedSaveDoesNotAdvanceIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolFocusRollback-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Kontrol.store")
        var oldRunning: FocusSessionSnapshot!
        var committed: FocusSessionSnapshot!
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
            oldRunning = try writer.create(input: input())
            let pause = try FocusTiming.pause(oldRunning, at: start.addingTimeInterval(-60),
                                              monotonicDelta: 0)
            let failing = SwiftDataFocusRepository(container: container,
                save: { _ in throw Injected.failed })
            XCTAssertThrowsError(try failing.transition(id: first, command: pause.transition)) {
                XCTAssertEqual($0 as? FocusError, .persistenceFailure)
            }
            XCTAssertEqual(try writer.fetchAll(), [oldRunning])
            let paused = try writer.transition(id: first, command: pause.transition)
            let resume = try FocusTiming.resume(paused, at: start.addingTimeInterval(-60))
            committed = try writer.transition(id: first, command: resume.transition)
            XCTAssertGreaterThan(committed.checkpointAt, paused.checkpointAt)
        }
        try autoreleasepool {
            let writer = SwiftDataFocusRepository(container:
                try ModelContainerFactory().makeContainer(mode: .persistent(url)))
            XCTAssertEqual(try writer.fetchAll(), [committed])
            XCTAssertThrowsError(try writer.transition(id: first, command: .checkpoint(
                payload(oldRunning, seconds: 2, offset: 3)))) {
                XCTAssertEqual($0 as? FocusError, .staleBaseline)
            }
            let fresh = try FocusTiming.checkpoint(committed, at: start.addingTimeInterval(-60),
                                                   monotonicDelta: 2)
            let updated = try writer.transition(id: first, command: fresh.transition)
            XCTAssertEqual(updated.actualSeconds, 2)
            XCTAssertGreaterThan(updated.checkpointAt, committed.checkpointAt)
            XCTAssertEqual(updated.activeSegmentStartedAt, start.addingTimeInterval(-60))
            XCTAssertEqual(updated.deadline, start.addingTimeInterval(1500 - 62))
        }
        let reopened = SwiftDataFocusRepository(container:
            try ModelContainerFactory().makeContainer(mode: .persistent(url)))
        let durable = try XCTUnwrap(reopened.fetchAll().first)
        XCTAssertEqual(durable.activeSegmentStartedAt, start.addingTimeInterval(-60))
        XCTAssertEqual(durable.deadline, start.addingTimeInterval(1500 - 62))
    }

    func testFailedWritesLeaveStoredAnchorsUntouchedAndRetryOnce() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        var current = try writer.create(input: input())
        let transitions: [(FocusSessionSnapshot) -> FocusTransition] = [
            { .checkpoint(self.payload($0, seconds: 10, offset: 11)) },
            { .pause(self.payload($0, seconds: 20, offset: 21)) },
            { .resume(self.payload($0, seconds: 20, offset: 22)) },
            { .end(self.payload($0, seconds: 23, offset: 25)) }
        ]
        for transition in transitions {
            let command = transition(current)
            let failing = SwiftDataFocusRepository(container: container,
                save: { _ in throw Injected.failed })
            XCTAssertThrowsError(try failing.transition(id: first, command: command)) {
                XCTAssertEqual($0 as? FocusError, .persistenceFailure)
            }
            XCTAssertEqual(try rows(container), [current])
            current = try writer.transition(id: first, command: command)
            XCTAssertEqual(try rows(container), [current])
        }
        let other = try SwiftDataFocusRepository(container: container,
            makeID: { self.second }).create(input: input(seconds: 20))
        // Terminal history must not interfere with a fresh completion failure.
        let failing = SwiftDataFocusRepository(container: container,
            save: { _ in throw Injected.failed })
        let completion = FocusTransition.complete(payload(other, seconds: 20, offset: 40))
        XCTAssertThrowsError(try failing.transition(id: other.id, command: completion,
                                                    effectiveEndedAt: start.addingTimeInterval(20))) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertEqual(try rows(container).first(where: { $0.id == other.id }), other)
        let finished = try SwiftDataFocusRepository(container: container).transition(
            id: other.id, command: completion, effectiveEndedAt: start.addingTimeInterval(20))
        XCTAssertEqual(finished.endedAt, start.addingTimeInterval(20))
    }

    func testPauseCanEndWithoutAccruingPausedTime() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let running = try writer.create(input: input())
        let paused = try writer.transition(id: first, command: .pause(
            payload(running, seconds: 6.125, offset: 7)))
        XCTAssertThrowsError(try writer.transition(id: first, command: .end(
            payload(paused, seconds: 7, offset: 307)))) {
            XCTAssertEqual($0 as? FocusError, .invalidTransition)
        }
        let ended = try writer.transition(id: first, command: .end(
            payload(paused, seconds: 6.125, offset: 307)))
        XCTAssertEqual(ended.actualSeconds, 6.125)
        XCTAssertEqual(ended.endedAt, start.addingTimeInterval(307))
        XCTAssertEqual(try rows(container), [ended])
    }

    func testCommittedTransitionsSurviveDistinctDiskOpens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolFocusTransitions-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Kontrol.store")
        func open(_ check: (ModelContainer) throws -> Void) throws {
            try autoreleasepool {
                try check(ModelContainerFactory().makeContainer(mode: .persistent(url)))
            }
        }
        try open { container in
            let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
            let started = try writer.create(input: input(seconds: 30))
            let paused = try writer.transition(id: first, command: .pause(
                payload(started, seconds: 7.25, offset: 8)))
            XCTAssertEqual(paused.state, .paused)
        }
        try open { container in
            let writer = SwiftDataFocusRepository(container: container)
            let paused = try XCTUnwrap(writer.fetchAll().first)
            XCTAssertEqual(paused.actualSeconds, 7.25)
            let running = try writer.transition(id: first, command: .resume(
                payload(paused, seconds: 7.25, offset: 308)))
            XCTAssertEqual(running.deadline, start.addingTimeInterval(330.75))
            let ended = try writer.transition(id: first, command: .end(
                payload(running, seconds: 11.75, offset: 313)))
            XCTAssertEqual(ended.state, .ended)
        }
        try open { container in
            let ended = try XCTUnwrap(rows(container).first)
            XCTAssertEqual(ended.actualSeconds, 11.75)
            XCTAssertEqual(ended.endedAt, start.addingTimeInterval(313))
            XCTAssertEqual(try SwiftDataFocusRepository(container: container).transition(
                id: first, command: .end(payload(ended, seconds: 12, offset: 314))), ended)
        }
    }

    func testEachCommandAndNaturalCompletionSurviveIndependentDiskOpens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolFocusEndToEnd-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Kontrol.store")
        func open(makeID: @escaping () -> UUID = UUID.init,
                  _ check: (SwiftDataFocusRepository) throws -> Void) throws {
            try autoreleasepool {
                try check(SwiftDataFocusRepository(container:
                    ModelContainerFactory().makeContainer(mode: .persistent(url)), makeID: makeID))
            }
        }
        try open(makeID: { self.first }) { writer in
            XCTAssertEqual(try writer.create(input: input(seconds: 30)).id, first)
        }
        try open { writer in
            let started = try XCTUnwrap(writer.fetchAll().first)
            let paused = try writer.transition(id: first, command: FocusTiming.pause(started,
                at: start.addingTimeInterval(7.25), monotonicDelta: 7.25).transition)
            XCTAssertEqual(paused.actualSeconds, 7.25)
        }
        try open { writer in
            let paused = try XCTUnwrap(writer.fetchAll().first)
            let resumed = try writer.transition(id: first, command: FocusTiming.resume(paused,
                at: start.addingTimeInterval(307.25)).transition)
            XCTAssertEqual(resumed.actualSeconds, 7.25) // 300 seconds paused, zero accrued
        }
        try open { writer in
            let resumed = try XCTUnwrap(writer.fetchAll().first)
            let ended = try writer.transition(id: first, command: FocusTiming.end(resumed,
                at: start.addingTimeInterval(311.75), monotonicDelta: 4.5).transition)
            XCTAssertEqual(ended.state, .ended)
            XCTAssertEqual(ended.actualSeconds, 11.75)
        }
        try open(makeID: { self.second }) { writer in
            let ended = try XCTUnwrap(writer.fetchAll().first)
            XCTAssertEqual(ended.endedAt, start.addingTimeInterval(311.75))
            XCTAssertEqual(ended.actualSeconds, 11.75)
            XCTAssertEqual(try writer.create(input: FocusStartInput(plannedSeconds: 30,
                startedAt: start.addingTimeInterval(400))).id, second)
        }
        try open { writer in
            let running = try XCTUnwrap(writer.fetchAll().first { $0.id == second })
            let completion = try FocusTiming.complete(running,
                at: start.addingTimeInterval(440), monotonicDelta: 40)
            let finished = try writer.transition(id: second, command: completion.transition,
                                                 effectiveEndedAt: completion.snapshot.endedAt)
            XCTAssertEqual(finished.state, .completed)
            XCTAssertEqual(finished.actualSeconds, 30)
            XCTAssertEqual(finished.endedAt, start.addingTimeInterval(430))
        }
        try open { writer in
            let history = try writer.fetchAll()
            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(history.first { $0.id == first }?.actualSeconds, 11.75)
            XCTAssertEqual(history.first { $0.id == second }?.endedAt, start.addingTimeInterval(430))
            XCTAssertTrue(history.allSatisfy { !$0.state.isActive })
        }
    }

    func testRelaunchAfterRapidCheckpointUsesSavedWallAnchorNotLogicalWatermark() throws {
        for (relaunch, expectedState, expectedElapsed) in [
            (10.0, FocusSessionState.paused, 14.0),
            (40.0, FocusSessionState.completed, 30.0)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "KontrolFocusCheckpointRelaunch-\(UUID().uuidString)", isDirectory: true)
            let url = directory.appendingPathComponent("Kontrol.store")
            try autoreleasepool {
                let writer = SwiftDataFocusRepository(container:
                    try ModelContainerFactory().makeContainer(mode: .persistent(url)),
                    makeID: { self.first })
                let started = try writer.create(input: input(seconds: 30))
                // A first checkpoint sampled at exactly the previous watermark
                // advances it by 1 ms while retaining the true wall anchor.
                let checkpoint = try FocusTiming.checkpoint(started, at: start, monotonicDelta: 4)
                let saved = try writer.transition(id: first, command: checkpoint.transition)
                XCTAssertEqual(saved.activeSegmentStartedAt, start)
                XCTAssertGreaterThan(saved.checkpointAt, start)
                XCTAssertEqual(saved.actualSeconds, 4)
            }
            try autoreleasepool {
                let writer = SwiftDataFocusRepository(container:
                    try ModelContainerFactory().makeContainer(mode: .persistent(url)))
                let saved = try XCTUnwrap(writer.fetchAll().first)
                guard case .changed(let calculation) = try FocusTiming.reconcileOnRelaunch(
                    saved, at: start.addingTimeInterval(relaunch)) else {
                    return XCTFail("expected one durable reconciliation")
                }
                let result = try writer.transition(id: first, command: calculation.transition)
                XCTAssertEqual(result.state, expectedState)
                XCTAssertEqual(result.actualSeconds, expectedElapsed)
                XCTAssertEqual(result.recoveryRequired, expectedState == .paused)
                if expectedState == .completed {
                    XCTAssertEqual(result.endedAt, start.addingTimeInterval(26))
                }
            }
            try autoreleasepool {
                let writer = SwiftDataFocusRepository(container:
                    try ModelContainerFactory().makeContainer(mode: .persistent(url)))
                let durable = try XCTUnwrap(writer.fetchAll().first)
                XCTAssertEqual(durable.state, expectedState)
                XCTAssertEqual(durable.actualSeconds, expectedElapsed)
                XCTAssertEqual(try FocusTiming.reconcileOnRelaunch(durable,
                    at: start.addingTimeInterval(100)), .unchanged(durable))
            }
        }
    }

    func testRollbackImmediatelyAfterRapidCheckpointReconcilesOnceAcrossDiskOpens() throws {
        for offset in [-0.5, 0, 0.0005] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "KontrolFocusRapidRollback-\(UUID().uuidString)", isDirectory: true)
            let url = directory.appendingPathComponent("Kontrol.store")
            var saved: FocusSessionSnapshot!
            try autoreleasepool {
                let writer = SwiftDataFocusRepository(container:
                    try ModelContainerFactory().makeContainer(mode: .persistent(url)),
                    makeID: { self.first })
                let started = try writer.create(input: input(seconds: 30))
                saved = try writer.transition(id: first, command: FocusTiming.checkpoint(
                    started, at: start, monotonicDelta: 4).transition)
                XCTAssertEqual(saved.actualSeconds, 4)
                XCTAssertEqual(saved.activeSegmentStartedAt, start)
                XCTAssertGreaterThan(saved.checkpointAt, start)
            }
            let wall = start.addingTimeInterval(offset)
            var pending: FocusSessionSnapshot!
            try autoreleasepool {
                let writer = SwiftDataFocusRepository(container:
                    try ModelContainerFactory().makeContainer(mode: .persistent(url)))
                XCTAssertEqual(try writer.fetchAll(), [saved])
                guard case .changed(let change) = try FocusTiming.reconcileOnRelaunch(saved,
                    at: wall), case .reconcile(let payload) = change.transition else {
                    return XCTFail("expected pending recovery")
                }
                XCTAssertEqual(payload.sampledAt, wall) // not the later checkpoint watermark
                XCTAssertEqual(payload.expectedCheckpointAt, saved.checkpointAt)
                XCTAssertEqual(payload.accumulatedActiveSeconds, 4)
                pending = try writer.transition(id: first, command: change.transition)
                XCTAssertEqual(pending.state, .paused)
                XCTAssertTrue(pending.recoveryRequired)
                XCTAssertEqual(pending.actualSeconds, 4)
                XCTAssertGreaterThan(pending.checkpointAt, saved.checkpointAt)
                XCTAssertEqual(try writer.transition(id: first, command: change.transition), pending)
            }
            try autoreleasepool {
                let writer = SwiftDataFocusRepository(container:
                    try ModelContainerFactory().makeContainer(mode: .persistent(url)))
                XCTAssertEqual(try writer.fetchAll(), [pending])
                XCTAssertEqual(try FocusTiming.reconcileOnRelaunch(pending,
                    at: start.addingTimeInterval(100)), .unchanged(pending))
                XCTAssertThrowsError(try writer.create(input: input())) {
                    XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
                }
            }
        }
    }

    func testTimingWriteMergesClearedLinkInsteadOfResurrectingStaleMetadata() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = ModelContext(container)
        seed.insert(try TaskItem(id: taskID, title: "Retained title", createdAt: start))
        try seed.save()
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let old = try writer.create(input: input(task: taskID))
        let unlink = ModelContext(container)
        unlink.autosaveEnabled = false
        let stored = try XCTUnwrap(unlink.fetch(FetchDescriptor<FocusSession>()).first)
        stored.linkedTaskID = nil
        try unlink.save()
        let updated = try writer.transition(id: first, command: .checkpoint(
            payload(old, seconds: 10, offset: 11)))
        XCTAssertNil(updated.linkedTaskID)
        XCTAssertEqual(updated.linkedTitleSnapshot, "Retained title")
        XCTAssertNil(try rows(container).first?.linkedTaskID)
    }

    func testRelaunchReconciliationIsDurableOnceAndRecoveryResumeKeepsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolFocusRecovery-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Kontrol.store")
        var original: FocusSessionSnapshot!
        var reconciliation: FocusTransition!
        var pending: FocusSessionSnapshot!
        var resumed: FocusSessionSnapshot!
        try autoreleasepool {
            let writer = SwiftDataFocusRepository(container:
                try ModelContainerFactory().makeContainer(mode: .persistent(url)),
                makeID: { self.first })
            original = try writer.create(input: input(seconds: 30))
            let change = try FocusTiming.reconcileOnRelaunch(original,
                at: start.addingTimeInterval(7.25))
            guard case .changed(let calculation) = change else { return XCTFail("expected change") }
            reconciliation = calculation.transition
            let failing = SwiftDataFocusRepository(container:
                try ModelContainerFactory().makeContainer(mode: .persistent(url)),
                save: { _ in throw Injected.failed })
            XCTAssertThrowsError(try failing.transition(id: first, command: calculation.transition)) {
                XCTAssertEqual($0 as? FocusError, .persistenceFailure)
            }
            XCTAssertEqual(try writer.fetchAll(), [original])
            XCTAssertThrowsError(try writer.create(input: input())) {
                XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
            }
            pending = try writer.transition(id: first, command: calculation.transition)
            XCTAssertEqual(pending.id, first)
            XCTAssertEqual(pending.state, .paused)
            XCTAssertTrue(pending.recoveryRequired)
            XCTAssertEqual(pending.actualSeconds, 7.25)
            XCTAssertNil(pending.deadline)
            XCTAssertEqual(try writer.transition(id: first, command: calculation.transition), pending)
        }
        try autoreleasepool {
            let writer = SwiftDataFocusRepository(container:
                try ModelContainerFactory().makeContainer(mode: .persistent(url)))
            XCTAssertEqual(try writer.fetchAll(), [pending])
            XCTAssertEqual(try FocusTiming.reconcileOnRelaunch(pending,
                at: start.addingTimeInterval(600)), .unchanged(pending))
            let decision = FocusTransition.recover(.resume,
                payload(pending, seconds: 7.25, offset: 600))
            var saves = 0
            let failing = SwiftDataFocusRepository(container:
                try ModelContainerFactory().makeContainer(mode: .persistent(url)),
                save: { _ in saves += 1; throw Injected.failed })
            XCTAssertThrowsError(try failing.transition(id: first, command: decision)) {
                XCTAssertEqual($0 as? FocusError, .persistenceFailure)
            }
            XCTAssertEqual(saves, 1)
            XCTAssertEqual(try writer.fetchAll(), [pending])
            resumed = try writer.transition(id: first, command: decision)
            XCTAssertEqual(resumed.id, first)
            XCTAssertEqual(resumed.state, .running)
            XCTAssertFalse(resumed.recoveryRequired)
            XCTAssertEqual(resumed.actualSeconds, 7.25)
            XCTAssertEqual(resumed.deadline, resumed.activeSegmentStartedAt?.addingTimeInterval(22.75))
            XCTAssertEqual(try failing.transition(id: first, command: decision), resumed)
            XCTAssertEqual(saves, 1)
            XCTAssertThrowsError(try writer.transition(id: first, command: .recover(.end,
                payload(pending, seconds: 7.25, offset: 601)))) {
                XCTAssertEqual($0 as? FocusError, .staleBaseline)
            }
            XCTAssertThrowsError(try writer.transition(id: first, command: reconciliation)) {
                XCTAssertEqual($0 as? FocusError, .staleBaseline)
            }
        }
        try autoreleasepool {
            let writer = SwiftDataFocusRepository(container:
                try ModelContainerFactory().makeContainer(mode: .persistent(url)))
            XCTAssertEqual(try writer.fetchAll(), [resumed])
        }
    }

    func testRecoveryEndAndDeadlineCompletionAreOneTimeAndKeepEffectiveFinish() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let running = try writer.create(input: input(seconds: 30))
        guard case .changed(let calculation) = try FocusTiming.reconcileOnRelaunch(
            running, at: start.addingTimeInterval(4.5)) else { return XCTFail("expected change") }
        let pending = try writer.transition(id: first, command: calculation.transition)
        let end = FocusTransition.recover(.end, payload(pending, seconds: 4.5, offset: 300))
        let ended = try writer.transition(id: first, command: end)
        XCTAssertEqual(ended.id, first)
        XCTAssertEqual(ended.state, .ended)
        XCTAssertEqual(ended.actualSeconds, 4.5)
        XCTAssertEqual(ended.endedAt, start.addingTimeInterval(300))
        XCTAssertFalse(ended.recoveryRequired)
        var saves = 0
        let guarded = SwiftDataFocusRepository(container: container,
            save: { _ in saves += 1; throw Injected.failed })
        XCTAssertEqual(try guarded.transition(id: first, command: end), ended)
        XCTAssertEqual(saves, 0)
        let next = SwiftDataFocusRepository(container: container, makeID: { self.second })
        let other = try next.create(input: input(seconds: 30))
        guard case .changed(let deadline) = try FocusTiming.reconcileOnRelaunch(
            other, at: start.addingTimeInterval(800)) else { return XCTFail("expected finish") }
        let failingCompletion = SwiftDataFocusRepository(container: container,
            save: { _ in throw Injected.failed })
        XCTAssertThrowsError(try failingCompletion.transition(id: second,
            command: deadline.transition)) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertEqual(try rows(container).first { $0.id == second }, other)
        XCTAssertThrowsError(try next.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        let finished = try next.transition(id: second, command: deadline.transition)
        XCTAssertEqual(finished.id, second)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.actualSeconds, 30)
        XCTAssertEqual(finished.endedAt, start.addingTimeInterval(30))
        XCTAssertEqual(try guarded.transition(id: second, command: deadline.transition), finished)
        XCTAssertEqual(saves, 0)
    }

    func testInvalidRecoveryPayloadAndCorruptRowsRejectWithoutMutation() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let running = try writer.create(input: input(seconds: 30))
        var saves = 0
        let guarded = SwiftDataFocusRepository(container: container,
            save: { _ in saves += 1; throw Injected.failed })
        for command in [
            FocusTransition.reconcile(payload(running, seconds: 30, offset: 1)),
            .reconcile(payload(running, seconds: 5, offset: 4)),
            .recover(.resume, payload(running, seconds: 0, offset: 1))
        ] {
            XCTAssertThrowsError(try guarded.transition(id: first, command: command)) {
                XCTAssertEqual($0 as? FocusError, .invalidTransition)
            }
        }
        XCTAssertThrowsError(try guarded.transition(id: second, command: .reconcile(
            payload(running, seconds: 0, offset: 1)))) {
            XCTAssertEqual($0 as? FocusError, .missingSession)
        }
        guard case .changed(let calculation) = try FocusTiming.reconcileOnRelaunch(
            running, at: start.addingTimeInterval(5)) else { return XCTFail("expected change") }
        let pending = try writer.transition(id: first, command: calculation.transition)
        XCTAssertThrowsError(try guarded.transition(id: first, command: .recover(.end,
            payload(running, seconds: 0, offset: 6)))) {
            XCTAssertEqual($0 as? FocusError, .staleBaseline)
        }
        XCTAssertThrowsError(try guarded.transition(id: first, command: .resume(
            payload(pending, seconds: 5, offset: 6)))) {
            XCTAssertEqual($0 as? FocusError, .invalidTransition)
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try writer.fetchAll(), [pending])
        let corrupt = ModelContext(container)
        corrupt.autosaveEnabled = false
        corrupt.insert(FocusSession(id: second, state: "unknown", plannedSeconds: 30,
            accumulatedActiveSeconds: 0, startedAt: start, checkpointAt: start))
        try corrupt.save()
        XCTAssertThrowsError(try writer.fetchAll()) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        XCTAssertThrowsError(try guarded.transition(id: first, command: .recover(.end,
            payload(pending, seconds: 5, offset: 6)))) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        XCTAssertEqual(saves, 0)
    }

    func testMultipleActiveRecordsBlockReconciliationAndDecisionsWithoutAutomaticWrites() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        seed.insert(FocusSession(id: first, state: "running", plannedSeconds: 30,
            accumulatedActiveSeconds: 0, activeSegmentStartedAt: start,
            deadline: start.addingTimeInterval(30), startedAt: start, checkpointAt: start))
        seed.insert(FocusSession(id: second, state: "paused", plannedSeconds: 30,
            accumulatedActiveSeconds: 2, pausedAt: start.addingTimeInterval(2),
            startedAt: start, checkpointAt: start.addingTimeInterval(2), recoveryRequired: true))
        try seed.save()
        let before = try seed.fetch(FetchDescriptor<FocusSession>())
            .map(FocusSessionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        var saves = 0
        let writer = SwiftDataFocusRepository(container: container,
            save: { _ in saves += 1; throw Injected.failed })
        for (id, command) in [
            (first, FocusTransition.reconcile(payload(before[0], seconds: 30, offset: 500))),
            (second, .recover(.end, payload(before[1], seconds: 2, offset: 500)))
        ] {
            XCTAssertThrowsError(try writer.transition(id: id, command: command)) {
                XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
            }
        }
        XCTAssertThrowsError(try writer.fetchAll()) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FocusSession>())
            .map(FocusSessionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, before)
    }

    func testBackwardAndInconsistentWallRecoveryFreezesTrustedTime() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.first })
        let original = try writer.create(input: input(seconds: 30))
        let running = try writer.transition(id: first, command: .checkpoint(
            payload(original, seconds: 3.5, offset: 4)))
        guard case .changed(let calculation) = try FocusTiming.reconcileOnRelaunch(
            running, at: start.addingTimeInterval(-10)) else { return XCTFail("expected recovery") }
        let pending = try writer.transition(id: first, command: calculation.transition)
        XCTAssertEqual(pending.id, first)
        XCTAssertEqual(pending.actualSeconds, 3.5)
        XCTAssertEqual(pending.state, .paused)
        XCTAssertTrue(pending.recoveryRequired)
        XCTAssertEqual(try writer.transition(id: first, command: calculation.transition), pending)

        // A structurally valid row may have a checkpoint later than its segment
        // anchor (an interrupted or inconsistent wall timestamp). Do not turn a
        // passed deadline into a completed row in this case.
        let other = ModelContext(container)
        other.autosaveEnabled = false
        other.insert(FocusSession(id: second, state: "running", plannedSeconds: 30,
            accumulatedActiveSeconds: 3.5, activeSegmentStartedAt: start.addingTimeInterval(4),
            deadline: start.addingTimeInterval(30.5), startedAt: start,
            checkpointAt: start.addingTimeInterval(5)))
        // Resolve the first active row before installing a second one.
        let ended = try writer.transition(id: first, command: .recover(.end,
            payload(pending, seconds: 3.5, offset: 6)))
        XCTAssertEqual(ended.state, .ended)
        try other.save()
        let inconsistent = try XCTUnwrap(writer.fetchAll().first { $0.id == second })
        guard case .changed(let cautious) = try FocusTiming.reconcileOnRelaunch(
            inconsistent, at: start.addingTimeInterval(100)) else { return XCTFail("expected recovery") }
        let recovered = try writer.transition(id: second, command: cautious.transition)
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertTrue(recovered.recoveryRequired)
        XCTAssertEqual(recovered.actualSeconds, 3.5)
        XCTAssertNil(recovered.endedAt)
    }

    func testInvalidStoredTerminalAndNonfiniteTimeBlockStartAndRecovery() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        seed.insert(FocusSession(id: first, state: "running", plannedSeconds: 30,
            accumulatedActiveSeconds: 0, activeSegmentStartedAt: start,
            deadline: start.addingTimeInterval(30), startedAt: start, checkpointAt: start))
        seed.insert(FocusSession(id: second, state: "completed", plannedSeconds: 30,
            accumulatedActiveSeconds: .nan, startedAt: start,
            endedAt: start.addingTimeInterval(20), checkpointAt: start.addingTimeInterval(20)))
        try seed.save()
        let writer = SwiftDataFocusRepository(container: container)
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        XCTAssertThrowsError(try writer.fetchAll()) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        XCTAssertThrowsError(try writer.transition(id: first, command: .reconcile(
            FocusTransitionPayload(expectedCheckpointAt: start,
                sampledAt: start.addingTimeInterval(40), accumulatedActiveSeconds: 30)))) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FocusSession>()).count, 2)
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
