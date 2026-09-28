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

    // Hosted presentation is compiled by build-for-testing, not executed in this step.
    func testHostedReadySurface() throws {
        let graph = try dependencies()
        let host = NSHostingView(rootView: FocusView(service: graph.focusService, taskStore: graph.taskStore))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.width, 1000)
    }
}
