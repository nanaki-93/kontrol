import AppKit
import SwiftUI
import XCTest
@testable import Kontrol

@MainActor
final class FocusPresentationTests: XCTestCase {
    private func dependencies() throws -> AppDependencies {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        return AppDependencies(container: container,
                               catalogRepository: SwiftDataCatalogRepository(container: container))
    }

    // Non-hosted configuration coverage; this suite is selected by individual method,
    // never as a whole until the reserved hosted GUI session.
    func testConfigurationDefaultsPresetsAndInvalidCustom() throws {
        var draft = FocusReadyDraft()
        XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: true).plannedSeconds(), 1500)
        for (choice, expected) in [(FocusDuration.fifteen, 900), (.twentyFive, 1500), (.fifty, 3000), (.custom("7"), 420)] {
            draft.duration = choice
            XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: true).plannedSeconds(), expected)
        }
        for value in ["", "0", "-1", "1.5", "999999999999999999999999999999"] {
            draft.duration = .custom(value)
            XCTAssertThrowsError(try draft.configuration(openTasks: [], tasksReadable: true))
        }
    }

    func testConfigurationRequiresExplicitChoiceAfterTaskDisappears() throws {
        let graph = try dependencies()
        let task = try graph.taskStore.create(input: TaskInput(title: "Open task"))
        var draft = FocusReadyDraft()
        draft.linkedTaskID = task.id
        XCTAssertEqual(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: true).linkedTaskID, task.id)
        XCTAssertThrowsError(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: false)) {
            XCTAssertEqual($0 as? FocusError, .unavailableTask)
        }
        try graph.taskStore.setCompleted(id: task.id, completed: true)
        XCTAssertThrowsError(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: true))
        XCTAssertEqual(draft.linkedTaskID, task.id)
        draft.linkedTaskID = nil
        XCTAssertNil(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: true).linkedTaskID)
    }

    func testCancelDraftWritesNothingAndSharedWindowsCannotCompete() throws {
        let graph = try dependencies()
        var first = FocusReadyDraft()
        first.duration = .fifty
        first = FocusReadyDraft() // Cancel/discard is local; no repository command.
        XCTAssertEqual(try first.configuration(openTasks: [], tasksReadable: true).plannedSeconds(), 1500)
        XCTAssertTrue(try SwiftDataFocusRepository(container: graph.container).fetchAll().isEmpty)
        let second = FocusReadyDraft()
        try graph.focusService.start(configuration: first.configuration(openTasks: [], tasksReadable: true))
        XCTAssertThrowsError(try graph.focusService.start(configuration: second.configuration(openTasks: [], tasksReadable: true))) {
            XCTAssertEqual($0 as? FocusError, .activeSessionConflict)
        }
        XCTAssertEqual(try SwiftDataFocusRepository(container: graph.container).fetchAll().count, 1)
    }

    func testTimerCopyUsesCommittedStateTitleAndFrozenPausedCountdown() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let running = try FocusSessionSnapshot(id: UUID(), state: .running, plannedSeconds: 1500,
            accumulatedActiveSeconds: 62.75, activeSegmentStartedAt: start.addingTimeInterval(63),
            deadline: start.addingTimeInterval(1500.25), startedAt: start,
            checkpointAt: start.addingTimeInterval(63), linkedTitleSnapshot: "Original task title")
        let runningCopy = FocusTimerPresentation(session: running, countdownSeconds: 1438)
        XCTAssertEqual(runningCopy.stateText, "Running")
        XCTAssertEqual(runningCopy.title, "Original task title")
        XCTAssertEqual(runningCopy.countdown, "23:58")
        XCTAssertEqual(runningCopy.actualDuration, "1 min 2 sec focused")

        let paused = try FocusSessionSnapshot(id: running.id, state: .paused, plannedSeconds: 1500,
            accumulatedActiveSeconds: 62.75, pausedAt: start.addingTimeInterval(63),
            startedAt: start, checkpointAt: start.addingTimeInterval(63))
        let pausedCopy = FocusTimerPresentation(session: paused, countdownSeconds: 1438)
        XCTAssertEqual(pausedCopy.stateText, "Paused")
        XCTAssertEqual(pausedCopy.countdown, "23:58")
        XCTAssertEqual(pausedCopy.title, "Focus session")
        XCTAssertEqual(pausedCopy.actualDuration, runningCopy.actualDuration)
    }

    func testCommittedPauseResumeEndAndTaskRemainsOpen() throws {
        let graph = try dependencies()
        let task = try graph.taskStore.create(input: TaskInput(title: "Keep open"))
        try graph.focusService.start(configuration: FocusConfiguration(linkedTaskID: task.id))
        let started = try XCTUnwrap(graph.focusService.activeSession)
        XCTAssertEqual(started.linkedTitleSnapshot, "Keep open")
        try graph.focusService.pause()
        let paused = try XCTUnwrap(graph.focusService.activeSession)
        XCTAssertEqual(paused.state, .paused)
        let frozen = graph.focusService.countdownSeconds
        XCTAssertEqual(frozen, Int(ceil(Double(paused.plannedSeconds) - paused.actualSeconds)))
        try graph.focusService.resume()
        XCTAssertEqual(graph.focusService.activeSession?.state, .running)
        try graph.focusService.end()
        XCTAssertNil(graph.focusService.activeSession)
        XCTAssertEqual(graph.focusService.history(.today).groups.flatMap(\.sessions).count, 1)
        XCTAssertEqual(graph.taskStore.snapshots.first(where: { $0.id == task.id })?.isCompleted, false)
    }

    func testNaturalCompletionDoesNotCompleteLinkedTask() throws {
        let graph = try dependencies()
        let task = try graph.taskStore.create(input: TaskInput(title: "Still open"))
        let repository = SwiftDataFocusRepository(container: graph.container)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let running = try repository.create(input: FocusStartInput(plannedSeconds: 60,
            startedAt: start, linkedTaskID: task.id))
        let change = try FocusTiming.checkpoint(running, at: start.addingTimeInterval(60), monotonicDelta: 60)
        let completed = try repository.transition(id: running.id, command: change.transition,
            effectiveEndedAt: change.snapshot.endedAt)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.linkedTitleSnapshot, "Still open")
        XCTAssertEqual(graph.taskStore.snapshots.first(where: { $0.id == task.id })?.isCompleted, false)
    }

    // Hosted presentation is compiled by build-for-testing, not executed in this step.
    func testHostedReadySurface() throws {
        let graph = try dependencies()
        let host = NSHostingView(rootView: FocusView(service: graph.focusService, taskStore: graph.taskStore))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.width, 1000)
    }

    func testHostedRunningAndPausedSurfaces() throws {
        let graph = try dependencies()
        try graph.focusService.start(configuration: FocusConfiguration())
        let host = NSHostingView(rootView: FocusView(service: graph.focusService, taskStore: graph.taskStore))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(graph.focusService.countdownSeconds)
        try graph.focusService.pause()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(graph.focusService.activeSession?.state, .paused)
    }
}
