import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusPresentationTests: XCTestCase {
    private func dependencies() throws -> AppDependencies {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        return AppDependencies(container: container,
                               catalogRepository: SwiftDataCatalogRepository(container: container))
    }

    // Configuration and application-hosted presentation coverage.
    func testConfigurationDefaultsPresetsAndInvalidCustom() throws {
        var draft = FocusReadyDraft()
        XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: true).plannedSeconds(), 1500)
        for (choice, expected) in [(FocusDuration.fifteen, 900), (.twentyFive, 1500), (.fifty, 3000), (.custom("7"), 420)] {
            draft.selectDuration(choice)
            XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: true).plannedSeconds(), expected)
        }
        for value in ["", "0", "-1", "1.5", "999999999999999999999999999999"] {
            draft.selectDuration(.custom(value))
            XCTAssertThrowsError(try draft.configuration(openTasks: [], tasksReadable: true))
        }
    }

    func testConfigurationRequiresExplicitChoiceAfterTaskDisappears() throws {
        let graph = try dependencies()
        let task = try graph.taskStore.create(input: TaskInput(title: "Open task"))
        var draft = FocusReadyDraft()
        draft.selectTask(task.id)
        XCTAssertEqual(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: true).linkedTaskID, task.id)
        XCTAssertThrowsError(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: false)) {
            XCTAssertEqual($0 as? FocusError, .unavailableTask)
        }
        try graph.taskStore.setCompleted(id: task.id, completed: true)
        XCTAssertThrowsError(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: true))
        XCTAssertEqual(draft.linkedTaskID, task.id)
        draft.selectTask(nil)
        XCTAssertNil(try draft.configuration(openTasks: graph.taskStore.snapshots, tasksReadable: true).linkedTaskID)
    }

    func testResetDraftWritesNothingAndSharedWindowsCannotCompete() throws {
        let graph = try dependencies()
        var first = FocusReadyDraft()
        first.selectDuration(.fifty)
        first = FocusReadyDraft() // Reset is local; no repository command.
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

    func testRecoveryCopyStaysFrozenAcrossReopenAndFailedEndRetry() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataFocusRepository(container: container, save: { context in
            if fail { throw FocusError.persistenceFailure }
            try context.save()
        })
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let original = try repository.create(input: FocusStartInput(plannedSeconds: 1500, startedAt: start))
        let clock = { start.addingTimeInterval(62.75) }
        let first = FocusService(repository: repository, wallClock: clock,
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
        first.loadIfNeeded()
        let pending = try XCTUnwrap(first.activeSession)
        XCTAssertEqual(pending.id, original.id)
        XCTAssertTrue(pending.recoveryRequired)
        let copy = FocusRecoveryPresentation(session: pending)
        XCTAssertEqual(copy.title, "Focus session")
        XCTAssertEqual(copy.recorded, "1 min 2 sec")
        XCTAssertEqual(copy.remaining, "23 min 58 sec")
        let reopened = FocusService(repository: repository, wallClock: { start.addingTimeInterval(300) },
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.activeSession, pending)
        XCTAssertEqual(FocusRecoveryPresentation(session: try XCTUnwrap(reopened.activeSession)).remaining, copy.remaining)
        fail = true
        XCTAssertThrowsError(try reopened.resolveRecovery(.end))
        XCTAssertEqual(reopened.activeSession, pending)
        XCTAssertEqual(reopened.mutationFailure?.action, .recover(.end))
        XCTAssertEqual(try repository.fetchAll(), [pending])
        fail = false
        try reopened.retryMutation()
        XCTAssertNil(reopened.activeSession)
        let terminal = try XCTUnwrap(reopened.snapshots.first)
        XCTAssertEqual(terminal.id, original.id)
        XCTAssertEqual(terminal.state, .ended)
        XCTAssertEqual(terminal.actualSeconds, pending.actualSeconds)
        XCTAssertEqual(try repository.fetchAll(), [terminal])
        XCTAssertThrowsError(try reopened.retryMutation())
        XCTAssertEqual(try repository.fetchAll().count, 1)
    }

    func testCompletionPendingIsNotHistoryUntilExplicitRetry() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataFocusRepository(container: container, save: { context in
            if fail { throw FocusError.persistenceFailure }
            try context.save()
        })
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let base = ContinuousClock().now
        var elapsed: Int64 = 0
        var tick: (() -> Void)?
        let service = FocusService(repository: repository,
            wallClock: { start.addingTimeInterval(Double(elapsed)) },
            monotonicClock: { base.advanced(by: .seconds(elapsed)) },
            scheduleTick: { callback in tick = callback; return {} },
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: FocusConfiguration(duration: .custom("1")))
        let saved = try XCTUnwrap(service.activeSession)
        fail = true
        elapsed = 90
        tick?()
        XCTAssertEqual(service.countdownSeconds, 0)
        XCTAssertEqual(service.completionPendingError, .persistenceFailure)
        XCTAssertEqual(service.activeSession, saved)
        XCTAssertEqual(service.history(.today).groups.flatMap(\.sessions).count, 0)
        XCTAssertEqual(try repository.fetchAll(), [saved])
        XCTAssertThrowsError(try service.start(configuration: FocusConfiguration())) {
            XCTAssertEqual($0 as? FocusServiceError, .completionPending)
        }
        XCTAssertThrowsError(try service.retryCompletion())
        XCTAssertEqual(service.activeSession, saved)
        fail = false
        try service.retryCompletion()
        XCTAssertNil(service.completionPendingError)
        XCTAssertNil(service.activeSession)
        XCTAssertEqual(service.snapshots.first?.state, .completed)
        XCTAssertEqual(service.snapshots.first?.id, saved.id)
        XCTAssertEqual(try repository.fetchAll(), service.snapshots)
        XCTAssertThrowsError(try service.retryCompletion())
    }

    func testHistoryPresentationUsesActualDurationOutcomesAndRetainedTitles() throws {
        let finish = Date(timeIntervalSinceReferenceDate: 10_000)
        let completed = try FocusSessionSnapshot(id: UUID(), state: .completed, plannedSeconds: 1500,
            accumulatedActiveSeconds: 1500, startedAt: finish.addingTimeInterval(-1500),
            endedAt: finish, checkpointAt: finish, linkedTitleSnapshot: "Retained task title")
        let ended = try FocusSessionSnapshot(id: UUID(), state: .ended, plannedSeconds: 1500,
            accumulatedActiveSeconds: 62.75, startedAt: finish.addingTimeInterval(-100),
            endedAt: finish, checkpointAt: finish)
        XCTAssertEqual(FocusHistoryPresentation.title(for: completed), "Retained task title")
        XCTAssertEqual(FocusHistoryPresentation.title(for: ended), "Focus session")
        XCTAssertEqual(FocusHistoryPresentation.detail(for: completed), "25 min 0 sec focused · Completed")
        XCTAssertEqual(FocusHistoryPresentation.detail(for: ended), "1 min 2 sec focused · Ended early")

        let result = FocusHistorySelection.select([ended, completed], filter: .recent,
            now: finish, calendar: .current, timeZone: .current)
        XCTAssertEqual(result.groups.flatMap(\.sessions).count, 2)
        XCTAssertFalse(FocusHistoryPresentation(result: result, readState: .loaded).isEmpty)
        let empty = FocusHistorySelection.select([], filter: .today,
            now: finish, calendar: .current, timeZone: .current)
        XCTAssertTrue(FocusHistoryPresentation(result: empty, readState: .loaded).isEmpty)
        let failed = FocusHistoryPresentation(result: result,
            readState: .failed(.persistenceFailure, hasStaleRows: true))
        XCTAssertTrue(failed.isUnreadable)
        XCTAssertTrue(failed.isStale)
        XCTAssertFalse(failed.isEmpty)
        let unavailable = FocusHistoryPresentation(result: empty,
            readState: .failed(.persistenceFailure, hasStaleRows: false))
        XCTAssertTrue(unavailable.isUnreadable)
        XCTAssertFalse(unavailable.isEmpty)
    }

    func testHistoryProjectionDoesNotChangeSharedActiveSession() throws {
        let graph = try dependencies()
        try graph.focusService.start(configuration: FocusConfiguration())
        let active = try XCTUnwrap(graph.focusService.activeSession)
        for filter in [FocusHistoryFilter.recent, .today, .thisWeek] {
            XCTAssertTrue(graph.focusService.history(filter).groups.isEmpty)
        }
        XCTAssertEqual(graph.focusService.activeSession, active)
        XCTAssertNotNil(graph.focusService.countdownSeconds)
        XCTAssertEqual(try SwiftDataFocusRepository(container: graph.container).fetchAll(), [active])
    }

    // Hosted presentation runs in the reserved GUI session.
    func testHostedHistoryAtBothReferenceSizes() throws {
        let graph = try dependencies()
        let host = NSHostingView(rootView: FocusHistoryView(service: graph.focusService,
                                                            filter: .constant(.recent)))
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 940)] {
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.size, size)
        }
    }

    func testHostedTwoWindowsFollowDefaultsPreserveOverridesAndResetAfterEnd() throws {
        // Own-process AX inspection/actions do not require cross-process TCC authorization.
        let graph = try dependencies()
        try saveDefault(37, graph: graph)
        let first = FocusPreferenceHost(graph: graph)
        let second = FocusPreferenceHost(graph: graph)
        defer { first.window.orderOut(nil); second.window.orderOut(nil) }
        try first.expect("focus-ready-countdown", contains: "37 minutes")
        try first.expect("focus-custom-minutes", contains: "37")
        try second.press(title: "25")
        try saveDefault(50, graph: graph)
        try first.expect("focus-ready-countdown", contains: "50 minutes")
        try second.expect("focus-ready-countdown", contains: "25 minutes")
        try second.press(identifier: "focus-cancel-configuration")
        try second.expect("focus-ready-countdown", contains: "50 minutes")
        try first.press(identifier: "focus-start")
        try first.expect("focus-timer-countdown", contains: "")
        let running = try XCTUnwrap(graph.focusService.activeSession)
        XCTAssertEqual(running.plannedSeconds, 3000)
        try saveDefault(15, graph: graph)
        XCTAssertEqual(graph.focusService.activeSession, running)
        try graph.focusService.pause()
        let paused = try XCTUnwrap(graph.focusService.activeSession)
        try saveDefault(37, graph: graph)
        XCTAssertEqual(graph.focusService.activeSession, paused)
        try graph.focusService.end()
        try first.expect("focus-ready-countdown", contains: "37 minutes")
        try second.expect("focus-ready-countdown", contains: "37 minutes")
        try first.expect("focus-custom-minutes", contains: "37")
        XCTAssertEqual(graph.focusService.snapshots.first?.plannedSeconds, 3000)
    }

    func testHostedFailedStartIsFrozenAndUnreadablePreferencesAreIdentified() throws {
        // The test fails if its real native controls cannot be inspected or operated.
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = true
        let repository = SwiftDataFocusRepository(container: container, save: { context in
            if fail { throw FocusError.persistenceFailure }
            try context.save()
        })
        let graph = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container), focusRepository: repository)
        try saveDefault(37, graph: graph)
        let first = FocusPreferenceHost(graph: graph)
        let second = FocusPreferenceHost(graph: graph)
        defer { first.window.orderOut(nil); second.window.orderOut(nil) }
        try first.press(identifier: "focus-start")
        try first.expect("focus-start-error", contains: "")
        try saveDefault(50, graph: graph)
        try first.expect("focus-ready-countdown", contains: "37 minutes")
        try second.expect("focus-ready-countdown", contains: "50 minutes")
        fail = false
        try first.press(identifier: "focus-start")
        try first.expect("focus-timer-countdown", contains: "")
        XCTAssertEqual(graph.focusService.activeSession?.plannedSeconds, 37 * 60)
        try graph.focusService.end()
        try first.expect("focus-ready-countdown", contains: "50 minutes")
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<AppPreferencesRecord>()).first)
        record.textSize = "unsupported"
        try context.save()
        graph.appPreferencesStore.retry()
        for host in [first, second] {
            try host.expect("focus-preferences-fallback", contains: "25-minute fallback")
            try host.expect("focus-ready-countdown", contains: "25 minutes")
        }
        record.textSize = "system"
        record.focusDefaultMinutes = 37
        try context.save()
        graph.appPreferencesStore.retry()
        for host in [first, second] {
            try host.expect("focus-ready-countdown", contains: "37 minutes")
            try host.expect("focus-custom-minutes", contains: "37")
            XCTAssertNil(host.element(identifier: "focus-preferences-fallback"))
        }
    }

    private func saveDefault(_ minutes: Int, graph: AppDependencies) throws {
        var input = AppPreferencesDraft()
        input.focusDefaultMinutes = String(minutes)
        try graph.appPreferencesStore.save(input, expectedRevision: graph.appPreferencesStore.committed?.revision)
    }

    func testHostedReadySurface() throws {
        let graph = try dependencies()
        let host = NSHostingView(rootView: FocusView(service: graph.focusService, taskStore: graph.taskStore,
                                                   learningStore: graph.learningCatalogStore,
                                                   preferencesStore: graph.appPreferencesStore))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.width, 1000)
    }

    func testHostedRecoveryAndCompletionPendingSurfaces() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataFocusRepository(container: container, save: { context in
            if fail { throw FocusError.persistenceFailure }
            try context.save()
        })
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let base = ContinuousClock().now
        var elapsed: Int64 = 10
        _ = try repository.create(input: FocusStartInput(plannedSeconds: 60, startedAt: start))
        let graph = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container),
            focusRepository: repository,
            focusWallClock: { start.addingTimeInterval(Double(elapsed)) },
            focusMonotonicClock: { base.advanced(by: .seconds(elapsed)) })
        let host = NSHostingView(rootView: FocusView(service: graph.focusService, taskStore: graph.taskStore,
                                                   learningStore: graph.learningCatalogStore,
                                                   preferencesStore: graph.appPreferencesStore))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(graph.focusService.activeSession?.recoveryRequired, true)
        try graph.focusService.resolveRecovery(.resume)
        elapsed = 80
        fail = true
        XCTAssertThrowsError(try graph.focusService.end())
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(graph.focusService.completionPendingError, .persistenceFailure)
        XCTAssertEqual(graph.focusService.countdownSeconds, 0)
    }

    func testHostedRunningAndPausedSurfaces() throws {
        let graph = try dependencies()
        try graph.focusService.start(configuration: FocusConfiguration())
        let host = NSHostingView(rootView: FocusView(service: graph.focusService, taskStore: graph.taskStore,
                                                   learningStore: graph.learningCatalogStore,
                                                   preferencesStore: graph.appPreferencesStore))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(graph.focusService.countdownSeconds)
        try graph.focusService.pause()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(graph.focusService.activeSession?.state, .paused)
    }
}

/// Inspect and operate real native controls, rather than asserting host dimensions alone.
@MainActor
private final class FocusPreferenceHost {
    let window: NSWindow
    private let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

    init(graph: AppDependencies) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 940),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Focus preferences \(UUID())"
        window.contentView = NSHostingView(rootView: ScrollView {
            FocusView(service: graph.focusService, taskStore: graph.taskStore,
                      learningStore: graph.learningCatalogStore, preferencesStore: graph.appPreferencesStore)
        })
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func descendants(_ element: AXUIElement) -> [AXUIElement] {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + descendants($0) }
    }

    private var elements: [AXUIElement] {
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let match = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == window.title })
        else { return [] }
        return descendants(match)
    }

    func element(identifier: String) -> AXUIElement? {
        elements.first { attribute($0, kAXIdentifierAttribute) as? String == identifier }
    }

    private func text(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .compactMap { attribute(element, $0) as? String }.joined(separator: " ")
    }

    private func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return predicate()
    }

    func expect(_ identifier: String, contains expected: String,
                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(wait {
            guard let element = element(identifier: identifier) else { return false }
            return expected.isEmpty || text(element).contains(expected)
        }, "Missing \(identifier) with \(expected); AX text: \(elements.map(text))", file: file, line: line)
    }

    func press(identifier: String? = nil, title: String? = nil,
               file: StaticString = #filePath, line: UInt = #line) throws {
        var button: AXUIElement?
        XCTAssertTrue(wait {
            button = elements.first {
                if let identifier { return attribute($0, kAXIdentifierAttribute) as? String == identifier }
                return attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                    (attribute($0, kAXTitleAttribute) as? String == title ||
                     attribute($0, kAXDescriptionAttribute) as? String == title)
            }
            return button != nil
        }, "Missing native button \(identifier ?? title ?? ""); AX text: \(elements.map(text))", file: file, line: line)
        let target = try XCTUnwrap(button, file: file, line: line)
        XCTAssertEqual(AXUIElementPerformAction(target, kAXPressAction as CFString), .success, file: file, line: line)
        // Callers poll the expected observable state after each native action.
    }
}
