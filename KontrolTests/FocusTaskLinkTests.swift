import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusTaskLinkTests: XCTestCase {
    private enum Injected: Error { case saveFailed }
    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    private let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    private func sessions(_ container: ModelContainer) throws -> [FocusSessionSnapshot] {
        // Inspect individual rows: the deletion must clear even legacy/corrupt stores
        // containing more than one active session, which fetchAll rejects.
        try ModelContext(container).fetch(FetchDescriptor<FocusSession>())
            .map(FocusSessionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func seed(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(try TaskItem(id: taskID, title: "Original task", createdAt: start))
        context.insert(try TaskItem(id: otherID, title: "Other task", createdAt: start))
        let plan = 1500
        let states: [(String, Double, Bool)] = [
            ("running", 12.5, false), ("paused", 20.25, false),
            ("paused", 30.75, true), ("completed", 1500, false),
            ("ended", 40.5, false)
        ]
        for (index, item) in states.enumerated() {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            let state = item.0
            let checkpoint = start.addingTimeInterval(60)
            context.insert(FocusSession(
                id: id, state: state, plannedSeconds: plan,
                accumulatedActiveSeconds: item.1,
                activeSegmentStartedAt: state == "running" ? checkpoint : nil,
                deadline: state == "running" ? checkpoint.addingTimeInterval(Double(plan) - item.1) : nil,
                pausedAt: state == "paused" ? checkpoint : nil,
                startedAt: start, endedAt: state == "completed" || state == "ended" ? checkpoint : nil,
                checkpointAt: checkpoint, recoveryRequired: item.2,
                linkedTaskID: taskID, linkedTitleSnapshot: "Original task"))
        }
        // Both a different task's link and a session with no link must survive.
        for (index, link) in [(6, otherID as UUID?), (7, nil)] {
            context.insert(FocusSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                state: "ended", plannedSeconds: plan, accumulatedActiveSeconds: 5,
                startedAt: start, endedAt: start.addingTimeInterval(60),
                checkpointAt: start.addingTimeInterval(60), linkedTaskID: link,
                linkedTitleSnapshot: "Unrelated title"))
        }
        try context.save()
    }

    private func assertOnlyLinksChanged(_ before: [FocusSessionSnapshot],
                                        _ after: [FocusSessionSnapshot]) {
        XCTAssertEqual(before.count, 7)
        XCTAssertEqual(after.count, before.count)
        for (old, new) in zip(before, after) {
            XCTAssertEqual(new.id, old.id)
            XCTAssertEqual(new.state, old.state)
            XCTAssertEqual(new.plannedSeconds, old.plannedSeconds)
            XCTAssertEqual(new.accumulatedActiveSeconds, old.accumulatedActiveSeconds)
            XCTAssertEqual(new.actualSeconds, old.actualSeconds)
            XCTAssertEqual(new.startedAt, old.startedAt)
            XCTAssertEqual(new.endedAt, old.endedAt)
            XCTAssertEqual(new.checkpointAt, old.checkpointAt)
            XCTAssertEqual(new.activeSegmentStartedAt, old.activeSegmentStartedAt)
            XCTAssertEqual(new.deadline, old.deadline)
            XCTAssertEqual(new.pausedAt, old.pausedAt)
            XCTAssertEqual(new.recoveryRequired, old.recoveryRequired)
            XCTAssertEqual(new.linkedTitleSnapshot, old.linkedTitleSnapshot)
            XCTAssertEqual(new.linkedLessonID, old.linkedLessonID)
            XCTAssertEqual(new.linkedTaskID, old.linkedTaskID == taskID ? nil : old.linkedTaskID)
        }
        XCTAssertEqual(before.filter { $0.linkedTaskID == taskID }.map(\.state),
                       [.running, .paused, .paused, .completed, .ended])
        XCTAssertEqual(after.filter { $0.linkedTaskID == taskID }.count, 0)
    }

    func testDeleteClearsEveryActiveRecoveryAndHistoricalLinkWithOneCommit() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        try seed(container)
        let before = try sessions(container)
        var saves = 0
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            saves += 1
            try context.save()
        })
        try repository.delete(id: taskID)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [otherID])
        assertOnlyLinksChanged(before, try sessions(container))
    }

    func testFailedSaveAndMissingTaskLeaveTaskAndAllLinksIntact() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        try seed(container)
        let before = try sessions(container)
        let missing = UUID()
        var saves = 0
        let failing = SwiftDataTaskRepository(container: container, save: { _ in
            saves += 1
            throw Injected.saveFailed
        })
        XCTAssertThrowsError(try failing.delete(id: missing)) {
            XCTAssertEqual($0 as? TaskRepositoryError, .notFound(missing))
        }
        XCTAssertEqual(saves, 0)
        XCTAssertThrowsError(try failing.delete(id: taskID)) {
            XCTAssertTrue($0 is Injected)
        }
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try failing.fetchAll().map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [taskID, otherID])
        XCTAssertEqual(try sessions(container), before)
        // A later unrelated commit cannot persist the discarded private edits.
        _ = try SwiftDataTaskRepository(container: container).setCompleted(id: otherID, completed: true)
        XCTAssertEqual(try sessions(container), before)
    }

    func testCheckpointFromPreDeletionSnapshotCannotRestoreLink() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let tasks = SwiftDataTaskRepository(container: container, makeID: { self.taskID })
        _ = try tasks.create(input: TaskInput(title: "Retained task title"))
        let focus = SwiftDataFocusRepository(container: container,
                                             makeID: { UUID(uuidString: "00000000-0000-0000-0000-000000000051")! })
        let old = try focus.create(input: FocusStartInput(
            plannedSeconds: 1500, startedAt: start, linkedTaskID: taskID))
        try tasks.delete(id: taskID)
        let calculation = try FocusTiming.checkpoint(old, at: start.addingTimeInterval(12),
                                                      monotonicDelta: 12)
        let saved = try focus.transition(id: old.id, command: calculation.transition)
        XCTAssertNil(saved.linkedTaskID)
        XCTAssertEqual(saved.linkedTitleSnapshot, "Retained task title")
        XCTAssertEqual(saved.accumulatedActiveSeconds, 12)
        XCTAssertEqual(try focus.fetchAll(), [saved])
    }
}
