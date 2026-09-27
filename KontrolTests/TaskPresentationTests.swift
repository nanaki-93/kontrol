import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

@MainActor
final class TaskPresentationTests: XCTestCase {
    private enum SaveError: Error { case injected }

    private final class FailingReadRepository: TaskRepository {
        let storage: SwiftDataTaskRepository
        init(storage: SwiftDataTaskRepository) { self.storage = storage }
        func fetchAll() throws -> [TaskItem] { throw SaveError.injected }
        func create(title: String, plannedFor: PlannedDay?) throws -> UUID {
            try storage.create(title: title, plannedFor: plannedFor)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func descendants(of element: AXUIElement) -> [AXUIElement] {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + descendants(of: $0) }
    }

    private func elements(in window: NSWindow, identifier: String) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let host = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == window.title }) else {
            return []
        }
        var roots = [host]
        if window.attachedSheet != nil {
            roots += attribute(host, "AXSheets") as? [AXUIElement] ?? []
            roots += windows.filter { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
        }
        return roots.flatMap { descendants(of: $0) }.filter {
            attribute($0, kAXIdentifierAttribute) as? String == identifier
        }
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    private func visibleText(in window: NSWindow) -> [String] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let host = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == window.title }) else {
            return []
        }
        return descendants(of: host).compactMap {
            (attribute($0, kAXValueAttribute) as? String) ?? (attribute($0, kAXDescriptionAttribute) as? String)
        }
    }

    private func inspectToday(_ repository: any TaskRepository, at instant: Date,
                              _ check: (NSWindow) throws -> Void) throws {
        let host = NSHostingView(rootView: TodayView(taskRepository: repository, now: { instant }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Today state inspection \(UUID().uuidString)"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle()
        try check(window)
    }

    func testTodayUsesRealDateSharedSectionsAndHonestEmptyStateWithoutWriting() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        try inspectToday(repository, at: instant) { window in
            let text = visibleText(in: window)
            XCTAssertTrue(text.contains("Today"))
            XCTAssertTrue(text.contains(instant.formatted(.dateTime.weekday(.wide).day().month(.wide))))
            XCTAssertTrue(text.contains("Next"))
            XCTAssertTrue(text.contains("No tasks planned or due today."))
            XCTAssertTrue(text.contains("Schedule"))
            XCTAssertTrue(text.contains("Scheduling isn't available yet."))
            XCTAssertFalse(text.contains("No blocks scheduled for today."))
            let add = try waitForElement("today-add-task", in: window)
            XCTAssertEqual(attribute(add, kAXRoleAttribute) as? String, kAXButtonRole)
            XCTAssertEqual(attribute(add, kAXDescriptionAttribute) as? String, "Add task")
            XCTAssertEqual(AXUIElementPerformAction(add, kAXPressAction as CFString), .success)
            _ = try waitForElement("quick-capture-title", in: window)
            XCTAssertTrue(try repository.fetchAll().isEmpty, "opening capture must not save a task")
        }
    }

    func testTodayShowsOnlyRealDueOrPlannedTasksAndNeverCallsFailureEmpty() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let repository = SwiftDataTaskRepository(container: container, now: { instant })
        let id = try repository.create(title: "Actual planned task", plannedFor: nil)
        try inspectToday(repository, at: instant) { window in
            XCTAssertEqual(elements(in: window, identifier: "task-row-\(id.uuidString)").count, 1)
            XCTAssertFalse(visibleText(in: window).contains("No tasks planned or due today."))
        }
        try inspectToday(FailingReadRepository(storage: repository), at: instant) { window in
            let text = visibleText(in: window)
            XCTAssertTrue(text.contains("Error: Content could not be loaded."))
            XCTAssertFalse(text.contains("No tasks planned or due today."))
            XCTAssertTrue(elements(in: window, identifier: "task-row-\(id.uuidString)").isEmpty)
            XCTAssertTrue(text.contains("Scheduling isn't available yet."))
        }
        XCTAssertEqual(try repository.fetchAll().map(\.id), [id], "rendering a failure must not change tasks")
    }

    private func waitForElement(_ identifier: String, in window: NSWindow) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if let found = elements(in: window, identifier: identifier).first { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return try XCTUnwrap(elements(in: window, identifier: identifier).first)
    }

    func testLocalDayDueBoundaryCompletionAndRepositoryOrder() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let next = try XCTUnwrap(calendar.dateInterval(of: .day, for: instant)?.end)
        let previous = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: instant))
        let today = PlannedDay.today(at: instant, calendar: calendar, timeZone: zone)
        let yesterday = PlannedDay.today(at: previous, calendar: calendar, timeZone: zone)
        let ids = (0..<6).map { _ in UUID() }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let tasks = try [
            TaskItem(id: ids[0], title: "planned", createdAt: instant, dueAt: next.addingTimeInterval(-1),
                     plannedDay: today.components, plannedTimeZoneID: today.timeZoneID),
            TaskItem(id: ids[1], title: "due", createdAt: instant, dueAt: next.addingTimeInterval(-1)),
            TaskItem(id: ids[2], title: "tomorrow", createdAt: instant, dueAt: next),
            TaskItem(id: ids[3], title: "yesterday", createdAt: instant, plannedDay: yesterday.components,
                     plannedTimeZoneID: yesterday.timeZoneID),
            TaskItem(id: ids[4], title: "completed", createdAt: instant, plannedDay: today.components,
                     plannedTimeZoneID: today.timeZoneID, completedAt: instant),
            TaskItem(id: ids[5], title: "unplanned", createdAt: instant)
        ]
        tasks.forEach(context.insert)
        try context.save()
        let ordered = try SwiftDataTaskRepository(container: container).fetchAll().map(TaskRow.init)
        XCTAssertEqual(ordered.map(\.id), ids.sorted { $0.uuidString < $1.uuidString })
        let visible = TaskRow.forToday(ordered, at: instant, calendar: calendar, timeZone: zone)
        XCTAssertEqual(Set(visible.map(\.id)), Set([ids[0], ids[1]]))
        XCTAssertEqual(visible.count, 2) // A planned and due task must not appear twice.
        XCTAssertEqual(Set(TaskRow.forToday(ordered, at: next, calendar: calendar, timeZone: zone).map(\.id)),
                       Set([ids[0], ids[1], ids[2]]))
        // Changing device zone must not reinterpret a saved planned date as a UTC midnight.
        XCTAssertEqual(TaskRow.forToday(ordered, at: instant, calendar: calendar,
                                        timeZone: TimeZone(secondsFromGMT: 0)!).map(\.id),
                       [ids[3]])
    }

    func testSaveFailureDoesNotPublishRowAndReopenedDiskStoreRendersCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskPresentation-\(UUID())")
        // SwiftData may retain SQLite descriptors after owners leave scope; keep
        // this UUID-isolated temporary store until the test host exits.
        let store = directory.appendingPathComponent("Tasks.store")
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let id = UUID()
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        do {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(store))
            let failed = SwiftDataTaskRepository(container: container, now: { instant }, makeID: { id },
                                                 timeZone: { zone }, save: { _ in throw SaveError.injected })
            let draft = QuickCaptureDraft(repository: failed)
            draft.title = "  One capture  "
            var dismissals = 0
            draft.add { dismissals += 1 }
            XCTAssertEqual(dismissals, 0)
            XCTAssertNotNil(draft.errorMessage)
            XCTAssertTrue(try failed.fetchAll().isEmpty)
            let successful = SwiftDataTaskRepository(container: container, now: { instant }, makeID: { id },
                                                     timeZone: { zone })
            let retry = QuickCaptureDraft(repository: successful)
            retry.title = draft.title
            retry.add { dismissals += 1 }
            XCTAssertEqual(dismissals, 1)
            XCTAssertEqual(try successful.fetchAll().map(\.id), [id])
        }
        // Release every owner before reopening, as in a new app process.
        try autoreleasepool {
            let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(store))
            let persisted = try SwiftDataTaskRepository(container: reopened).fetchAll().map(TaskRow.init)
            XCTAssertEqual(persisted.map(\.id), [id])
            XCTAssertEqual(persisted.map(\.title), ["One capture"])
            let today = TaskRow.forToday(persisted, at: instant, calendar: .current, timeZone: zone)
            XCTAssertEqual(today.map(\.id), [id])
        }
    }

    func testRenderedCaptureRefreshesTodayOnlyAfterSuccessfulSave() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let id = UUID()
        var fail = true
        let repository = SwiftDataTaskRepository(container: container, makeID: { id }, save: { context in
            if fail { throw SaveError.injected }
            try context.save()
        })
        let host = NSHostingView(rootView: TodayView(taskRepository: repository))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Today capture list inspection"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let rowID = "task-row-\(id.uuidString)"
        let addTask = try waitForElement("today-add-task", in: window)
        XCTAssertEqual(AXUIElementPerformAction(addTask, kAXPressAction as CFString), .success)
        let title = try waitForElement("quick-capture-title", in: window)
        XCTAssertEqual(AXUIElementSetAttributeValue(title, kAXValueAttribute as CFString,
                                                   "  New task  " as CFString), .success)
        settle()
        let add = try waitForElement("quick-capture-add", in: window)
        XCTAssertEqual(AXUIElementPerformAction(add, kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(elements(in: window, identifier: rowID).isEmpty)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        fail = false
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("quick-capture-add", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(elements(in: window, identifier: rowID).count, 1)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [id])
    }

    func testRenderedTodayAndTasksRefreshWhenNavigatingWithoutDuplicates() throws {
        let suite = "TaskPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let dependencies = AppDependencies(container: container, catalogRepository: SwiftDataCatalogRepository(container: container))
        let host = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: dependencies))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Task presentation inspection"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let id = UUID()
        let rowID = "task-row-\(id.uuidString)"
        XCTAssertTrue(elements(in: window, identifier: rowID).isEmpty)
        navigation.select(.tasks)
        settle()
        XCTAssertTrue(elements(in: window, identifier: rowID).isEmpty)
        _ = try SwiftDataTaskRepository(container: container, makeID: { id }).create(title: "Stored task")
        navigation.select(.today)
        settle()
        XCTAssertEqual(elements(in: window, identifier: rowID).count, 1)
        navigation.select(.tasks)
        settle()
        XCTAssertEqual(elements(in: window, identifier: rowID).count, 1)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [id])
    }
}
