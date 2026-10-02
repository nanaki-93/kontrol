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
        var failRead = true
        init(storage: SwiftDataTaskRepository) { self.storage = storage }
        func fetchAll() throws -> [TaskItem] {
            if failRead { throw SaveError.injected }
            return try storage.fetchAll()
        }
        func create(title: String, plannedFor: PlannedDay?) throws -> UUID {
            try storage.create(title: title, plannedFor: plannedFor)
        }
        func create(input: TaskInput) throws -> TaskSnapshot {
            try storage.create(input: input)
        }
        func update(id: UUID, input: TaskInput) throws -> TaskSnapshot {
            try storage.update(id: id, input: input)
        }
        func setCompleted(id: UUID, completed: Bool) throws -> TaskSnapshot {
            try storage.setCompleted(id: id, completed: completed)
        }
        func delete(id: UUID) throws { try storage.delete(id: id) }
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

    private func waitUntil(_ description: String, timeout: TimeInterval = 4,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private func key(_ code: UInt16, character: String, in window: NSWindow,
                     modifiers: NSEvent.ModifierFlags = []) {
        let receiver = window.attachedSheet ?? window
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: receiver.windowNumber, context: nil,
                                    characters: character, charactersIgnoringModifiers: character,
                                    isARepeat: false, keyCode: code)!
        if !receiver.performKeyEquivalent(with: event) {
            if receiver.isKeyWindow {
                receiver.sendEvent(event)
            } else {
                // Hosted XCTest windows cannot always activate as key windows;
                // deliver the keyboard event to their focused responder directly.
                receiver.firstResponder?.keyDown(with: event)
            }
        }
        settle()
    }

    private func focusedIdentifier() -> String? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        return attribute(unsafeBitCast(focused, to: AXUIElement.self), kAXIdentifierAttribute) as? String
    }

    private func assertTarget(_ identifier: String, in window: NSWindow,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let rect = try frame(waitForElement(identifier, in: window))
        XCTAssertGreaterThanOrEqual(rect.width, AppMetrics.minimumTarget, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.height, AppMetrics.minimumTarget, file: file, line: line)
        let containingWindow = window.attachedSheet ?? window
        let screen = try XCTUnwrap(containingWindow.screen, file: file, line: line)
        let native = containingWindow.frame
        let visibleAX = CGRect(x: native.minX, y: screen.frame.maxY - native.maxY,
                               width: native.width, height: native.height)
        XCTAssertTrue(visibleAX.insetBy(dx: -2, dy: -2).contains(rect),
                      "\(identifier) \(rect) outside window/sheet \(visibleAX)", file: file, line: line)
    }

    private func assertInSheet(_ identifier: String, in window: NSWindow,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let sheet = try XCTUnwrap(window.attachedSheet, file: file, line: line)
        let screen = try XCTUnwrap(sheet.screen, file: file, line: line)
        let native = sheet.frame
        let sheetAX = CGRect(x: native.minX, y: screen.frame.maxY - native.maxY,
                             width: native.width, height: native.height)
        let target = try frame(waitForElement(identifier, in: window))
        XCTAssertTrue(sheetAX.insetBy(dx: -2, dy: -2).contains(target),
                      "\(identifier) \(target) outside \(sheetAX)", file: file, line: line)
        try assertTarget(identifier, in: window, file: file, line: line)
    }

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

    private func frame(_ element: AXUIElement) throws -> CGRect {
        let position = try XCTUnwrap(attribute(element, kAXPositionAttribute))
        let size = try XCTUnwrap(attribute(element, kAXSizeAttribute))
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions))
        return CGRect(origin: origin, size: dimensions)
    }

    private func inspectTasks(_ repository: any TaskRepository, width: CGFloat = 1000,
                              scale: CGFloat = 1, _ check: (NSWindow) throws -> Void) throws {
        let host = NSHostingView(rootView: TasksView(store: TaskStore(repository: repository))
            .environment(\.appTextScaleOverride, scale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Tasks state inspection \(UUID().uuidString)"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle()
        try check(window)
    }

    private func todayView(_ store: TaskStore) -> TodayView {
        // Hosted fixtures use an isolated schedule store; production injects the app-owned one.
        let container = try! ModelContainerFactory().makeContainer(mode: .inMemory)
        return TodayView(store: store, scheduleStore: ScheduleStore(repository:
            SwiftDataScheduleRepository(container: container)))
    }

    private func inspectToday(_ repository: any TaskRepository, at instant: Date,
                              _ check: (NSWindow) throws -> Void) throws {
        let scheduleContainer = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let host = NSHostingView(rootView: TodayView(store: TaskStore(repository: repository,
            clock: { instant }), scheduleStore: ScheduleStore(repository:
                SwiftDataScheduleRepository(container: scheduleContainer))))
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
            XCTAssertTrue(text.contains(instant.formatted(.dateTime.weekday(.wide).day().month(.wide).year())))
            XCTAssertTrue(text.contains("Tasks"))
            XCTAssertTrue(text.contains("No tasks planned or due on this day."))
            XCTAssertTrue(text.contains("Schedule"))
            XCTAssertTrue(text.contains("No blocks on this day."))
            let add = try waitForElement("today-add-task", in: window)
            XCTAssertEqual(attribute(add, kAXRoleAttribute) as? String, kAXButtonRole)
            XCTAssertEqual(attribute(add, kAXDescriptionAttribute) as? String, "Add task")
            XCTAssertEqual(AXUIElementPerformAction(add, kAXPressAction as CFString), .success)
            _ = try waitForElement("quick-capture-title", in: window)
            XCTAssertTrue(try repository.fetchAll().isEmpty, "opening capture must not save a task")
        }
    }

    func testHostedTodayRecomputesRowsAndLocalDateAtMidnightAndAfterTravelWithoutSaving() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var saves = 0
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            saves += 1
            try context.save()
        })
        let center = NotificationCenter()
        var now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-01-01T12:00:00Z"))
        var zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let calendar = Calendar(identifier: .gregorian)
        var midnight: (() -> Void)?
        var boundaries: [Date] = []
        let store = TaskStore(repository: repository, notificationCenter: center,
                              clock: { now }, calendar: { calendar }, timeZone: { zone },
                              scheduleTimer: { boundary, fire in
            boundaries.append(boundary)
            midnight = fire
            return {}
        })
        let plan = PlannedDay.today(at: now, calendar: calendar, timeZone: zone)
        let planned = try store.create(input: TaskInput(title: "Planned for January 1", plannedFor: plan))
        let due = try store.create(input: TaskInput(title: "Due on January 2",
                                                     dueAt: try XCTUnwrap(ISO8601DateFormatter().date(
                                                        from: "2025-01-02T00:00:00Z"))))
        let initialSaves = saves
        func header(_ date: Date, in zone: TimeZone) -> String {
            var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
            style.calendar = calendar
            style.timeZone = zone
            return date.formatted(style)
        }
        let firstHeader = header(now, in: zone)
        let host = NSHostingView(rootView: todayView(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Temporal Today inspection \(UUID())"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle()
        let plannedRow = "task-row-\(planned.id.uuidString)"
        let dueRow = "task-row-\(due.id.uuidString)"
        // Window registration precedes SwiftUI's first committed layout. Wait for
        // the rendered row, not merely a fixed delay, before counting its peers.
        waitUntil("Initial planned row is rendered") {
            elements(in: window, identifier: plannedRow).count == 1
        }
        XCTAssertEqual(elements(in: window, identifier: plannedRow).count, 1)
        XCTAssertTrue(elements(in: window, identifier: dueRow).isEmpty)
        XCTAssertTrue(visibleText(in: window).contains(firstHeader))

        now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-01-02T00:00:00Z"))
        XCTAssertEqual(boundaries, [now])
        midnight?()
        settle()
        let nextHeader = header(now, in: zone)
        XCTAssertNotEqual(firstHeader, nextHeader)
        XCTAssertTrue(elements(in: window, identifier: plannedRow).isEmpty)
        XCTAssertEqual(elements(in: window, identifier: dueRow).count, 1)
        XCTAssertTrue(visibleText(in: window).contains(nextHeader))

        zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        settle()
        XCTAssertEqual(elements(in: window, identifier: plannedRow).count, 1)
        XCTAssertEqual(elements(in: window, identifier: dueRow).count, 1)
        XCTAssertEqual(header(now, in: zone), firstHeader)
        XCTAssertTrue(visibleText(in: window).contains(firstHeader))
        XCTAssertEqual(store.snapshots.first { $0.id == planned.id }?.plannedDay, plan.components)
        XCTAssertEqual(store.snapshots.first { $0.id == planned.id }?.plannedTimeZoneID, plan.timeZoneID)
        XCTAssertEqual(saves, initialSaves, "Temporal changes must not rewrite tasks")
        XCTAssertEqual(try repository.fetchAll().count, 2)
    }

    func testTodayShowsOnlyRealDueOrPlannedTasksAndNeverCallsFailureEmpty() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let repository = SwiftDataTaskRepository(container: container, now: { instant })
        let id = try repository.create(title: "Actual planned task", plannedFor: nil)
        try inspectToday(repository, at: instant) { window in
            XCTAssertEqual(elements(in: window, identifier: "task-row-\(id.uuidString)").count, 1)
            XCTAssertFalse(visibleText(in: window).contains("No tasks planned or due on this day."))
        }
        try inspectToday(FailingReadRepository(storage: repository), at: instant) { window in
            let text = visibleText(in: window)
            XCTAssertTrue(text.contains("Error: Content could not be loaded."))
            XCTAssertFalse(text.contains("No tasks planned or due on this day."))
            XCTAssertTrue(elements(in: window, identifier: "task-row-\(id.uuidString)").isEmpty)
            XCTAssertTrue(text.contains("No blocks on this day."))
        }
        XCTAssertEqual(try repository.fetchAll().map(\.id), [id], "rendering a failure must not change tasks")
    }

    private func waitForElement(_ identifier: String, in window: NSWindow) throws -> AXUIElement {
        // Edit/Delete live under the per-UUID disclosure. Expand only when an
        // interaction below explicitly asks for one of those controls.
        if (identifier.hasPrefix("task-edit-") || identifier.hasPrefix("task-delete-")),
           elements(in: window, identifier: identifier).isEmpty {
            let prefix = identifier.hasPrefix("task-edit-") ? "task-edit-" : "task-delete-"
            let id = String(identifier.dropFirst(prefix.count))
            let details = try waitForElement("task-details-\(id)", in: window)
            XCTAssertEqual(AXUIElementPerformAction(details, kAXPressAction as CFString), .success)
        }
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if let found = elements(in: window, identifier: identifier).first { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return try XCTUnwrap(elements(in: window, identifier: identifier).first,
                             "Missing AX control \(identifier) in \(window.title)")
    }

    /// Edit the native field editor rather than changing its AXValue (which can
    /// change without notifying SwiftUI's TextField binding). Validation and the
    /// committed snapshot are the oracles, not a fixed delay or the AX value.
    private func replaceEditorTitle(_ newTitle: String, in window: NSWindow,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let title = try waitForElement("task-editor-title", in: window)
        XCTAssertEqual(AXUIElementSetAttributeValue(title, kAXFocusedAttribute as CFString,
                                                    kCFBooleanTrue), .success, file: file, line: line)
        let sheet = try XCTUnwrap(window.attachedSheet, file: file, line: line)
        let editor = try XCTUnwrap(sheet.firstResponder as? NSTextView, file: file, line: line)
        XCTAssertTrue(editor.isFieldEditor, file: file, line: line)
        editor.insertText(" ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        waitUntil("Blank title must disable Save", file: file, line: line) {
            !elements(in: window, identifier: "task-editor-title-error").isEmpty &&
            elements(in: window, identifier: "task-editor-submit").first.flatMap {
                (attribute($0, kAXEnabledAttribute) as? NSNumber)?.boolValue
            } == false
        }
        editor.insertText(newTitle, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        waitUntil("Edited title must enable Save", file: file, line: line) {
            elements(in: window, identifier: "task-editor-submit").first.flatMap {
                (attribute($0, kAXEnabledAttribute) as? NSNumber)?.boolValue
            } == true && elements(in: window, identifier: "task-editor-title-error").isEmpty
        }
        XCTAssertEqual(attribute(try waitForElement("task-editor-title", in: window),
                                 kAXValueAttribute) as? String, newTitle, file: file, line: line)
    }

    func testRowActionsPublishAcrossBothRoutesAndReopenRestoresToday() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let now = Date()
        let repository = SwiftDataTaskRepository(container: container, now: { now })
        let store = TaskStore(repository: repository, clock: { now })
        let saved = try store.create(input: TaskInput(title: "Shared action", dueAt: now))
        let windows = (0..<2).map { index in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Row action \(index) \(UUID())"
            window.contentView = NSHostingView(rootView: index == 0 ?
                AnyView(todayView(store)) : AnyView(TasksView(store: store)))
            window.makeKeyAndOrderFront(nil)
            return window
        }
        defer { windows.forEach { $0.orderOut(nil) } }
        settle()
        let rowID = "task-row-\(saved.id.uuidString)"
        let completeID = "task-complete-\(saved.id.uuidString)"
        let reopenID = "task-reopen-\(saved.id.uuidString)"
        for window in windows {
            let row = try waitForElement(rowID, in: window)
            let complete = try waitForElement(completeID, in: window)
            XCTAssertTrue(elements(in: window, identifier: "task-edit-\(saved.id.uuidString)").isEmpty)
            XCTAssertTrue(elements(in: window, identifier: "task-delete-\(saved.id.uuidString)").isEmpty,
                          "Today has no Delete callback; Tasks must start collapsed")
            let edit = try waitForElement("task-edit-\(saved.id.uuidString)", in: window)
            XCTAssertEqual(attribute(complete, kAXRoleAttribute) as? String, kAXButtonRole)
            XCTAssertEqual(attribute(complete, kAXDescriptionAttribute) as? String, "Complete Shared action")
            XCTAssertEqual(attribute(edit, kAXRoleAttribute) as? String, kAXButtonRole)
            XCTAssertEqual(attribute(edit, kAXDescriptionAttribute) as? String, "Edit Shared action")
            let children = descendants(of: row)
            XCTAssertFalse(children.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole },
                           "row content must not swallow its sibling actions")
        }
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(completeID, in: windows[0]),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(elements(in: windows[0], identifier: rowID).isEmpty)
        XCTAssertTrue(elements(in: windows[1], identifier: rowID).isEmpty)
        XCTAssertNotNil(store.snapshots.first?.completedAt)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-filter-completed", in: windows[1]),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertEqual(elements(in: windows[1], identifier: rowID).count, 1)
        XCTAssertTrue(visibleText(in: windows[1]).contains(where: { $0.contains("Completed") && $0.contains("at") }))
        XCTAssertEqual(attribute(try waitForElement("tasks-filter-completed", in: windows[1]),
                                 kAXDescriptionAttribute) as? String, "Completed, 1 tasks")
        XCTAssertEqual(attribute(try waitForElement(reopenID, in: windows[1]),
                                 kAXDescriptionAttribute) as? String, "Reopen Shared action")
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(reopenID, in: windows[1]),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(elements(in: windows[1], identifier: rowID).isEmpty)
        XCTAssertEqual(elements(in: windows[0], identifier: rowID).count, 1)
        XCTAssertNil(store.snapshots.first?.completedAt)
        XCTAssertEqual(try repository.fetchAll().first?.completedAt, nil)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-edit-\(saved.id.uuidString)", in: windows[0]),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(attribute(try waitForElement("task-editor-title", in: windows[0]),
                                 kAXValueAttribute) as? String, "Shared action")
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-cancel", in: windows[0]),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertNil(windows[0].attachedSheet)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-edit-\(saved.id.uuidString)", in: windows[0]),
                                                 kAXPressAction as CFString), .success)
        try replaceEditorTitle("Edited from Today", in: windows[0])
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-submit", in: windows[0]),
                                                 kAXPressAction as CFString), .success)
        waitUntil("Today editor dismisses after committed edit") {
            windows[0].attachedSheet == nil && store.snapshots.first?.title == "Edited from Today"
        }
        XCTAssertEqual(store.snapshots.first?.id, saved.id)
        XCTAssertEqual(store.snapshots.first?.title, "Edited from Today")
        XCTAssertEqual(try repository.fetchAll().map(\.id), [saved.id])
    }

    func testFailedRowActionsKeepRowsAndShowSafeExplicitRetryGuidance() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            if fail { throw SaveError.injected }
            try context.save()
        })
        let store = TaskStore(repository: repository)
        let saved = try store.create(input: TaskInput(title: "Private task", plannedFor: .today(at: .now)))
        let windows = (0..<2).map { index in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Failed row action \(index) \(UUID())"
            window.contentView = NSHostingView(rootView: index == 0 ?
                AnyView(todayView(store)) : AnyView(TasksView(store: store)))
            window.makeKeyAndOrderFront(nil)
            return window
        }
        defer { windows.forEach { $0.orderOut(nil) } }
        settle()
        let complete = "task-complete-\(saved.id.uuidString)"
        fail = true
        for (index, window) in windows.enumerated() {
            XCTAssertEqual(AXUIElementPerformAction(try waitForElement(complete, in: window),
                                                     kAXPressAction as CFString), .success)
            settle()
            XCTAssertEqual(elements(in: window, identifier: "task-row-\(saved.id.uuidString)").count, 1)
            XCTAssertEqual(elements(in: window, identifier: index == 0 ? "today-action-error" : "tasks-action-error").count, 1)
            XCTAssertTrue(visibleText(in: window).contains(where: { $0.contains("Use the task action again to retry.") }))
            XCTAssertFalse(visibleText(in: window).contains(where: { $0.contains("injected") }))
        }
        XCTAssertNil(store.snapshots.first?.completedAt)
        XCTAssertNil(try repository.fetchAll().first?.completedAt)
        fail = false
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(complete, in: windows[0]),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(elements(in: windows[0], identifier: "today-action-error").isEmpty)
        XCTAssertNotNil(store.snapshots.first?.completedAt)
    }

    func testMissingRowActionOffersRefreshInsteadOfRetryingRemovedRowOnBothRoutes() throws {
        for isToday in [true, false] {
            let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
            let storage = SwiftDataTaskRepository(container: container)
            let repository = FailingReadRepository(storage: storage)
            repository.failRead = false
            let store = TaskStore(repository: repository)
            let saved = try store.create(input: TaskInput(title: "Removed elsewhere", dueAt: .now))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Missing row action \(UUID())"
            window.contentView = NSHostingView(rootView: isToday ?
                AnyView(todayView(store)) : AnyView(TasksView(store: store)))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            settle()
            let rowID = "task-row-\(saved.id.uuidString)"
            let completeID = "task-complete-\(saved.id.uuidString)"
            let prefix = isToday ? "today" : "tasks"
            _ = try waitForElement(completeID, in: window)
            try storage.delete(id: saved.id) // A different owner removed the displayed UUID.
            // On Today exercise a failed automatic refresh too: cached rows remain
            // stale, but the offered recovery must work once reads return.
            repository.failRead = isToday
            XCTAssertEqual(AXUIElementPerformAction(try waitForElement(completeID, in: window),
                                                     kAXPressAction as CFString), .success)
            waitUntil("Missing-task action publishes recovery controls") {
                store.mutationError == .notFound &&
                elements(in: window, identifier: "\(prefix)-action-refresh").count == 1
            }
            XCTAssertEqual(elements(in: window, identifier: "\(prefix)-action-error").count, 1)
            XCTAssertTrue(visibleText(in: window).contains(where: { $0.contains("This task is no longer available") }))
            XCTAssertFalse(visibleText(in: window).contains("Error: Changes could not be saved."))
            XCTAssertFalse(visibleText(in: window).contains(where: { $0.contains("Use the task action again") }))
            XCTAssertEqual(elements(in: window, identifier: rowID).count, isToday ? 1 : 0)
            if isToday {
                XCTAssertEqual(store.readState, .failed(hasStaleRows: true))
                repository.failRead = false
            }
            XCTAssertEqual(AXUIElementPerformAction(try waitForElement("\(prefix)-action-refresh", in: window),
                                                     kAXPressAction as CFString), .success)
            settle()
            XCTAssertEqual(store.readState, .loaded)
            XCTAssertTrue(elements(in: window, identifier: rowID).isEmpty)
            XCTAssertTrue(elements(in: window, identifier: "\(prefix)-action-error").isEmpty)
            XCTAssertTrue(try storage.fetchAll().isEmpty)
        }
    }

    private func alertNodes() -> [AXUIElement] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.flatMap { descendants(of: $0) }
    }

    private func alertButton(_ name: String) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if let button = alertNodes().first(where: {
                attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                attribute($0, kAXDescriptionAttribute) as? String == name
            }) { return button }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return try XCTUnwrap(alertNodes().first(where: {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
            attribute($0, kAXDescriptionAttribute) as? String == name
        }), "Missing \(name); visible buttons: \(alertNodes().filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }.compactMap { attribute($0, kAXDescriptionAttribute) as? String })")
    }

    private func pressAlert(_ name: String) throws {
        // Native alert AX buttons may invalidate while AXPress returns; assert
        // the resulting persisted state rather than the transient AX error code.
        _ = AXUIElementPerformAction(try alertButton(name), kAXPressAction as CFString)
        settle()
    }

    func testDeleteRequiresNamedConfirmationAndOnlyRemovesSelectedUUID() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var saves = 0
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            saves += 1
            try context.save()
        })
        let store = TaskStore(repository: repository)
        let first = try store.create(input: TaskInput(title: "Delete this", plannedFor: .today(at: .now)))
        let other = try store.create(input: TaskInput(title: "Keep this", plannedFor: .today(at: .now)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Delete confirmation \(UUID())"
        window.contentView = NSHostingView(rootView: TasksView(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        let deleteID = "task-delete-\(first.id.uuidString)"
        let otherID = "task-delete-\(other.id.uuidString)"
        let rowID = "task-row-\(first.id.uuidString)"
        let delete = try waitForElement(deleteID, in: window)
        XCTAssertEqual(attribute(delete, kAXRoleAttribute) as? String, kAXButtonRole)
        XCTAssertEqual(attribute(delete, kAXDescriptionAttribute) as? String, "Delete Delete this")
        XCTAssertFalse(descendants(of: try waitForElement(rowID, in: window)).contains {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
        })
        let before = saves
        XCTAssertEqual(AXUIElementPerformAction(delete, kAXPressAction as CFString), .success)
        _ = try alertButton("Delete task")
        XCTAssertTrue(alertNodes().contains { node in
            [kAXDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute].contains { key in
                (attribute(node, key) as? String)?.contains("Delete \"Delete this\"?") == true
            }
        }, "confirmation must name the selected task")
        XCTAssertEqual(saves, before, "opening confirmation must not write")
        try pressAlert("Cancel")
        XCTAssertEqual(focusedIdentifier(), "task-details-\(first.id.uuidString)")
        XCTAssertEqual(saves, before)
        XCTAssertEqual(Set(try repository.fetchAll().map(\.id)), Set([first.id, other.id]))
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(deleteID, in: window), kAXPressAction as CFString), .success)
        _ = try alertButton("Cancel")
        window.attachedSheet?.cancelOperation(nil) // Escape / native cancel path
        settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(saves, before)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(deleteID, in: window), kAXPressAction as CFString), .success)
        try pressAlert("Delete task")
        XCTAssertEqual(saves, before + 1)
        XCTAssertEqual(store.snapshots.map(\.id), [other.id])
        XCTAssertEqual(try repository.fetchAll().map(\.id), [other.id])
        XCTAssertTrue(elements(in: window, identifier: rowID).isEmpty)
        XCTAssertEqual(elements(in: window, identifier: otherID).count, 1)
        XCTAssertEqual(focusedIdentifier(), "task-details-\(other.id.uuidString)", "deleted control must hand focus to a surviving disclosure")
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(otherID, in: window), kAXPressAction as CFString), .success)
        _ = try alertButton("Cancel")
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel) // external alert closure is not confirmation
        }
        settle()
        XCTAssertEqual(saves, before + 1)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [other.id])
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(otherID, in: window), kAXPressAction as CFString), .success)
        try pressAlert("Cancel")
        XCTAssertEqual(try repository.fetchAll().map(\.id), [other.id])
    }

    func testFailedAndMissingDeleteNeverRetryOrDeleteAnotherTask() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        var deleteAttempts = 0
        let storage = SwiftDataTaskRepository(container: container, save: { context in
            if fail { throw SaveError.injected }
            try context.save()
        })
        let repository = FailingReadRepository(storage: storage)
        repository.failRead = false
        let store = TaskStore(repository: repository)
        let selected = try store.create(input: TaskInput(title: "Selected", plannedFor: .today(at: .now)))
        let other = try store.create(input: TaskInput(title: "Untouched", plannedFor: .today(at: .now)))
        // Count calls at the IO boundary, including unsuccessful attempts.
        let counting = CountingDeleteRepository(base: repository) { deleteAttempts += 1 }
        let shared = TaskStore(repository: counting)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Delete failure \(UUID())"
        window.contentView = NSHostingView(rootView: TasksView(store: shared))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        let deleteID = "task-delete-\(selected.id.uuidString)"
        fail = true
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(deleteID, in: window), kAXPressAction as CFString), .success)
        try pressAlert("Delete task")
        XCTAssertEqual(deleteAttempts, 1)
        XCTAssertEqual(shared.mutationError, .writeFailed)
        XCTAssertEqual(elements(in: window, identifier: "tasks-action-error").count, 1)
        XCTAssertEqual(elements(in: window, identifier: "task-row-\(selected.id.uuidString)").count, 1)
        XCTAssertEqual(Set(try storage.fetchAll().map(\.id)), Set([selected.id, other.id]))
        fail = false
        settle()
        XCTAssertEqual(deleteAttempts, 1, "no automatic retry after a failure")
        try storage.delete(id: selected.id) // external owner removed the pending UUID
        repository.failRead = true // failed refresh keeps stale rows visible
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement(deleteID, in: window), kAXPressAction as CFString), .success)
        try pressAlert("Delete task")
        XCTAssertEqual(deleteAttempts, 2)
        XCTAssertEqual(shared.mutationError, .notFound)
        XCTAssertEqual(shared.readState, .failed(hasStaleRows: true))
        XCTAssertEqual(elements(in: window, identifier: "tasks-action-error").count, 1)
        XCTAssertEqual(elements(in: window, identifier: "task-row-\(selected.id.uuidString)").count, 1)
        XCTAssertEqual(try storage.fetchAll().map(\.id), [other.id])
        repository.failRead = false
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-action-refresh", in: window), kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(elements(in: window, identifier: deleteID).isEmpty)
        XCTAssertEqual(elements(in: window, identifier: "task-row-\(other.id.uuidString)").count, 1)
        XCTAssertEqual(deleteAttempts, 2)
    }

    private final class CountingDeleteRepository: TaskRepository {
        let base: any TaskRepository
        let onDelete: () -> Void
        init(base: any TaskRepository, onDelete: @escaping () -> Void) {
            self.base = base
            self.onDelete = onDelete
        }
        func fetchAll() throws -> [TaskItem] { try base.fetchAll() }
        func create(title: String, plannedFor: PlannedDay?) throws -> UUID { try base.create(title: title, plannedFor: plannedFor) }
        func create(input: TaskInput) throws -> TaskSnapshot { try base.create(input: input) }
        func update(id: UUID, input: TaskInput) throws -> TaskSnapshot { try base.update(id: id, input: input) }
        func setCompleted(id: UUID, completed: Bool) throws -> TaskSnapshot { try base.setCompleted(id: id, completed: completed) }
        func delete(id: UUID) throws { onDelete(); try base.delete(id: id) }
    }

    func testTasksEmptyAndFailedReadRemainDistinctWithoutMutatingSavedRows() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        try inspectTasks(repository) { window in
            let text = visibleText(in: window)
            XCTAssertTrue(text.contains("Tasks"))
            XCTAssertTrue(text.contains("Nothing planned or due today."))
            XCTAssertTrue(text.contains("Check Upcoming for other open tasks, or use Add task."))
            XCTAssertFalse(text.contains("Error: Content could not be loaded."))
            XCTAssertFalse(text.contains("Saved task"))
            XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-filter-upcoming", in: window),
                                                     kAXPressAction as CFString), .success)
            settle()
            XCTAssertTrue(visibleText(in: window).contains("No upcoming tasks."))
            XCTAssertTrue(visibleText(in: window).contains(where: { $0.contains("including unscheduled tasks") }))
        }
        let id = try repository.create(title: "Saved task", plannedFor: nil)
        try inspectTasks(FailingReadRepository(storage: repository)) { window in
            let text = visibleText(in: window)
            XCTAssertTrue(text.contains("Error: Content could not be loaded."))
            XCTAssertFalse(text.contains("Nothing planned or due today."))
            XCTAssertFalse(text.contains("Saved task"))
            XCTAssertTrue(elements(in: window, identifier: "task-row-\(id.uuidString)").isEmpty)
        }
        XCTAssertEqual(try repository.fetchAll().map(\.id), [id], "failed rendering cannot change saved tasks")
    }

    func testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let store = TaskStore(repository: repository)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Editor lifecycle \(UUID())"
        window.contentView = NSHostingView(rootView: TasksView(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        let add = try waitForElement("tasks-add-task", in: window)
        XCTAssertEqual(AXUIElementPerformAction(add, kAXPressAction as CFString), .success)
        _ = try waitForElement("task-editor-title", in: window)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertNotNil(try? waitForElement("task-editor-notes", in: window))
        XCTAssertNotNil(try? waitForElement("task-editor-due", in: window))
        XCTAssertNotNil(try? waitForElement("task-editor-plan", in: window))
        XCTAssertFalse(elements(in: window, identifier: "task-editor-title-error").isEmpty)
        XCTAssertTrue(elements(in: window, identifier: "task-editor-due-date").isEmpty)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-cancel", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-add-task", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(AXUIElementSetAttributeValue(try waitForElement("task-editor-title", in: window),
                                                    kAXValueAttribute as CFString, "New task" as CFString), .success)
        XCTAssertEqual(AXUIElementSetAttributeValue(try waitForElement("task-editor-notes", in: window),
                                                    kAXValueAttribute as CFString, "First line\nSecond line" as CFString), .success)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-due", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-plan", in: window),
                                                 kAXPressAction as CFString), .success)
        _ = try waitForElement("task-editor-due-date", in: window)
        _ = try waitForElement("task-editor-plan-date", in: window)
        settle()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-submit", in: window),
                                                 kAXPressAction as CFString), .success)
        waitUntil("New task commits and editor closes") {
            store.snapshots.count == 1 && window.attachedSheet == nil
        }
        let saved = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(saved.title, "New task")
        XCTAssertEqual(saved.notes, "First line\nSecond line")
        XCTAssertNotNil(saved.dueAt)
        XCTAssertNotNil(saved.plannedDay)
        let edit = try waitForElement("task-edit-\(saved.id.uuidString)", in: window)
        XCTAssertEqual(AXUIElementPerformAction(edit, kAXPressAction as CFString), .success)
        XCTAssertEqual(attribute(try waitForElement("task-editor-title", in: window),
                                 kAXValueAttribute) as? String, "New task")
        XCTAssertEqual(AXUIElementSetAttributeValue(try waitForElement("task-editor-title", in: window),
                                                    kAXValueAttribute as CFString, "Discarded change" as CFString), .success)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-cancel", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(try repository.fetchAll().first?.title, "New task")
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-edit-\(saved.id.uuidString)", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(attribute(try waitForElement("task-editor-title", in: window),
                                 kAXValueAttribute) as? String, "New task")
        // AXValue can change before the SwiftUI draft does. Verify a draft-derived
        // validation state, not elapsed time or the native field's AXValue alone.
        try replaceEditorTitle("Renamed task", in: window)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-submit", in: window),
                                                 kAXPressAction as CFString), .success)
        waitUntil("Renamed task commits and editor closes") {
            window.attachedSheet == nil && store.snapshots.first?.title == "Renamed task"
        }
        XCTAssertEqual(store.snapshots.first?.id, saved.id)
        XCTAssertEqual(store.snapshots.first?.title, "Renamed task")
        XCTAssertEqual(try repository.fetchAll().map(\.id), [saved.id])
    }

    func testEditorLongNotesKeepActionsReachableAndClearsBothDates() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let store = TaskStore(repository: repository)
        let plan = PlannedDay.today(at: .now)
        let saved = try store.create(input: TaskInput(title: "With notes", notes: String(repeating: "Long note.\n", count: 150),
                                                      dueAt: .now, plannedFor: plan))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Long note editor \(UUID())"
        window.contentView = NSHostingView(rootView: TasksView(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-edit-\(saved.id.uuidString)", in: window),
                                                 kAXPressAction as CFString), .success)
        let action = try waitForElement("task-editor-submit", in: window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let bounds = sheet.frame
        let actionBounds = try frame(action)
        let screenTop = try XCTUnwrap(sheet.screen).frame.maxY
        XCTAssertGreaterThanOrEqual(actionBounds.minY, screenTop - bounds.maxY)
        XCTAssertLessThanOrEqual(actionBounds.maxY, screenTop - bounds.minY)
        XCTAssertNotNil(try? waitForElement("task-editor-notes", in: window))
        XCTAssertNotNil(try? waitForElement("task-editor-due-date", in: window))
        XCTAssertNotNil(try? waitForElement("task-editor-plan-date", in: window))
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-due", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-plan", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(elements(in: window, identifier: "task-editor-due-date").isEmpty)
        XCTAssertTrue(elements(in: window, identifier: "task-editor-plan-date").isEmpty)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-submit", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        let persisted = try XCTUnwrap(repository.fetchAll().first)
        XCTAssertEqual(persisted.id, saved.id)
        XCTAssertNil(persisted.dueAt)
        XCTAssertNil(persisted.plannedDay)
        XCTAssertNil(persisted.plannedTimeZoneID)
        XCTAssertEqual(persisted.notes, saved.notes)
    }

    func testEditorFailureAndMissingTaskKeepDraftAndOfferDistinctRecovery() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            if fail { throw SaveError.injected }
            try context.save()
        })
        let store = TaskStore(repository: repository)
        let saved = try store.create(input: TaskInput(title: "Original"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Editor failure \(UUID())"
        window.contentView = NSHostingView(rootView: TasksView(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-filter-upcoming", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-edit-\(saved.id.uuidString)", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(AXUIElementSetAttributeValue(try waitForElement("task-editor-title", in: window),
                                                    kAXValueAttribute as CFString, "Retained" as CFString), .success)
        fail = true
        settle()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-submit", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertNotNil(try? waitForElement("task-editor-error", in: window))
        XCTAssertEqual(attribute(try waitForElement("task-editor-title", in: window),
                                 kAXValueAttribute) as? String, "Retained")
        XCTAssertEqual(try repository.fetchAll().first?.title, "Original")
        fail = false
        try repository.delete(id: saved.id)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-submit", in: window),
                                                 kAXPressAction as CFString), .success)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertNotNil(try? waitForElement("task-editor-close-missing", in: window))
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-close-missing", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testTasksFiltersPartitionSavedRowsWithCountsMetadataAndNoWrites() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var saves = 0
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            saves += 1
            try context.save()
        })
        let plan = PlannedDay.today(at: now, calendar: .current, timeZone: zone)
        let today = try repository.create(input: TaskInput(title: "Today task", plannedFor: plan))
        let overdue = try repository.create(input: TaskInput(title: "Late task", dueAt: now.addingTimeInterval(-3600)))
        let undated = try repository.create(input: TaskInput(title: "Unscheduled task"))
        let past = try repository.create(input: TaskInput(title: "Past plan", plannedFor:
            PlannedDay.today(at: now.addingTimeInterval(-86400), calendar: .current, timeZone: zone)))
        let completed = try repository.create(input: TaskInput(title: "Finished task"))
        _ = try repository.setCompleted(id: completed.id, completed: true)
        let before = try repository.fetchAll().map(TaskSnapshot.init)
        let initialSaves = saves
        let store = TaskStore(repository: repository, clock: { now }, timeZone: { zone })
        let host = NSHostingView(rootView: TasksView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Filtered tasks inspection \(UUID())"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle()
        func present(_ ids: [UUID], absent: [UUID]) {
            for id in ids { XCTAssertEqual(elements(in: window, identifier: "task-row-\(id.uuidString)").count, 1) }
            for id in absent { XCTAssertTrue(elements(in: window, identifier: "task-row-\(id.uuidString)").isEmpty) }
        }
        func choose(_ name: String) throws {
            let button = try waitForElement("tasks-filter-\(name)", in: window)
            XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success)
            settle()
            XCTAssertEqual(attribute(try waitForElement("tasks-filter-\(name)", in: window),
                                     kAXValueAttribute) as? String, "Selected")
        }
        present([today.id, overdue.id], absent: [undated.id, past.id, completed.id])
        for (name, count) in [("today", 2), ("upcoming", 2), ("completed", 1)] {
            let button = try waitForElement("tasks-filter-\(name)", in: window)
            XCTAssertEqual(attribute(button, kAXDescriptionAttribute) as? String,
                           "\(name.capitalized), \(count) tasks")
        }
        XCTAssertTrue(visibleText(in: window).contains(where: { $0.contains("Overdue") }))
        try choose("upcoming")
        present([undated.id, past.id], absent: [today.id, overdue.id, completed.id])
        XCTAssertTrue(visibleText(in: window).contains(where: { $0.contains("Unscheduled") }))
        XCTAssertTrue(visibleText(in: window).contains(where: { $0.contains("Planned (past)") }))
        try choose("completed")
        present([completed.id], absent: [today.id, overdue.id, undated.id, past.id])
        XCTAssertTrue(visibleText(in: window).contains(where: { $0.contains("Completed") }))
        try choose("today")
        present([today.id, overdue.id], absent: [completed.id, undated.id, past.id])
        XCTAssertEqual(saves, initialSaves, "filtering is read-only")
        XCTAssertEqual(try repository.fetchAll().map(TaskSnapshot.init), before)
    }

    func testCrossCalendarPlanMetadataAgreesWithFiltersAndRetainsUnscheduledPastPlan() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var saves = 0
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            saves += 1
            try context.save()
        })
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let deviceZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let savedZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let todayPlan = PlannedDay.today(at: now, calendar: Calendar(identifier: .buddhist), timeZone: savedZone)
        let pastPlan = PlannedDay.today(at: now.addingTimeInterval(-86400),
                                        calendar: Calendar(identifier: .buddhist), timeZone: savedZone)
        let today = try repository.create(input: TaskInput(title: "Buddhist today", plannedFor: todayPlan))
        let past = try repository.create(input: TaskInput(title: "Buddhist past", plannedFor: pastPlan))
        let initialSaves = saves
        let store = TaskStore(repository: repository, clock: { now },
                              calendar: { Calendar(identifier: .gregorian) }, timeZone: { deviceZone })
        let host = NSHostingView(rootView: TasksView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Cross-calendar plan inspection \(UUID())"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle()
        func rowText(_ id: UUID) throws -> String {
            let row = try waitForElement("task-row-\(id.uuidString)", in: window)
            return (attribute(row, kAXDescriptionAttribute) as? String) ??
                   (attribute(row, kAXValueAttribute) as? String) ?? ""
        }
        XCTAssertTrue(try rowText(today.id).contains("Planned Today"))
        XCTAssertTrue(elements(in: window, identifier: "task-row-\(past.id.uuidString)").isEmpty)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-filter-upcoming", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        let metadata = try rowText(past.id)
        XCTAssertFalse(metadata.contains(savedZone.identifier), "Provenance is disclosed, not compact metadata")
        XCTAssertTrue(elements(in: window, identifier: "task-details-\(past.id.uuidString)").count == 1)
        XCTAssertTrue(metadata.contains("Planned (past)"), metadata)
        XCTAssertTrue(metadata.contains("Unscheduled"), metadata)
        XCTAssertTrue(elements(in: window, identifier: "task-row-\(today.id.uuidString)").isEmpty)
        XCTAssertEqual(saves, initialSaves, "filtering and metadata must not write plans")
        XCTAssertEqual(try repository.fetchAll().first { $0.id == past.id }?.plannedDay, pastPlan.components)
    }

    func testTasksTodayMatchesTodayNextAndEmptyFiltersGiveSpecificGuidance() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-05T12:00:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let repository = SwiftDataTaskRepository(container: container)
        let due = try repository.create(input: TaskInput(title: "Due today", dueAt: instant))
        let later = try repository.create(input: TaskInput(title: "Later", dueAt: instant.addingTimeInterval(86400)))
        let store = TaskStore(repository: repository, clock: { instant }, timeZone: { zone })
        let windows = [NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                styleMask: [.titled], backing: .buffered, defer: false),
                       NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                styleMask: [.titled], backing: .buffered, defer: false)]
        windows[0].title = "Today filter comparison \(UUID())"
        windows[1].title = "Tasks filter comparison \(UUID())"
        windows[0].contentView = NSHostingView(rootView: todayView(store))
        windows[1].contentView = NSHostingView(rootView: TasksView(store: store))
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        defer { windows.forEach { $0.orderOut(nil) } }
        settle()
        let dueRow = "task-row-\(due.id.uuidString)"
        let laterRow = "task-row-\(later.id.uuidString)"
        for window in windows {
            XCTAssertEqual(elements(in: window, identifier: dueRow).count, 1)
            XCTAssertTrue(elements(in: window, identifier: laterRow).isEmpty)
        }
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-filter-upcoming", in: windows[1]),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertEqual(elements(in: windows[1], identifier: laterRow).count, 1)
        XCTAssertTrue(elements(in: windows[1], identifier: dueRow).isEmpty)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-filter-completed", in: windows[1]),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertTrue(visibleText(in: windows[1]).contains("No completed tasks yet."))
        XCTAssertTrue(visibleText(in: windows[1]).contains("Completed tasks will appear here after you finish one."))
        XCTAssertEqual(try repository.fetchAll().count, 2)
    }

    func testTasksLongTitleWrapsAtEnlargedTextAndKeepsFullAccessibleName() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let title = "Investigate cancellation propagation through nested requests and document every edge case before the next review"
        let id = try repository.create(title: title, plannedFor: nil)
        var standardHeight: CGFloat = 0
        try inspectTasks(repository, width: 360) { window in
            let row = try XCTUnwrap(elements(in: window, identifier: "task-row-\(id.uuidString)").first)
            standardHeight = try frame(row).height
        }
        try inspectTasks(repository, width: 360, scale: 1.3) { window in
            let row = try XCTUnwrap(elements(in: window, identifier: "task-row-\(id.uuidString)").first)
            let bounds = try frame(row)
            XCTAssertGreaterThan(bounds.height, standardHeight, "text scaling grows the wrapped row")
            XCTAssertGreaterThan(bounds.height, AppMetrics.preferredTarget, "long title uses multiple lines")
            XCTAssertLessThanOrEqual(bounds.width, 360 - 2 * AppMetrics.horizontalInset + 1)
            XCTAssertTrue((attribute(row, kAXDescriptionAttribute) as? String ?? "").contains(title) ||
                          (attribute(row, kAXValueAttribute) as? String ?? "").contains(title))
        }
        XCTAssertEqual(try repository.fetchAll().map(\.id), [id])
    }

    func testTaskControlsAndEditorAtBothSizesAndTextScales() throws {
        for (width, height) in [(1000.0, 700.0), (1440.0, 940.0)] {
            for scale in [1.0, 1.3] {
                    let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                    let repository = SwiftDataTaskRepository(container: container)
                    let store = TaskStore(repository: repository)
                    let saved = try store.create(input: TaskInput(title: "Keyboard target", plannedFor: .today(at: .now)))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.title = "Task layout \(UUID())"
                    window.contentView = NSHostingView(rootView: TasksView(store: store)
                        .environment(\.appTextScaleOverride, scale))
                    window.makeKeyAndOrderFront(nil)
                    defer { window.orderOut(nil) }
                    settle()
                    let rowID = "task-row-\(saved.id.uuidString)"
                    let actions = ["task-complete-", "task-details-", "task-edit-", "task-delete-"].map { $0 + saved.id.uuidString }
                    let row = try waitForElement(rowID, in: window)
                    XCTAssertFalse(descendants(of: row).contains {
                        attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                    })
                    for id in actions {
                        let action = try waitForElement(id, in: window)
                        XCTAssertEqual(attribute(action, kAXRoleAttribute) as? String, kAXButtonRole)
                        XCTAssertTrue((attribute(action, kAXDescriptionAttribute) as? String ?? "").contains(saved.title))
                        try assertTarget(id, in: window)
                    }
                    for name in ["today", "upcoming", "completed"] {
                        try assertTarget("tasks-filter-\(name)", in: window)
                        XCTAssertEqual(attribute(try waitForElement("tasks-filter-\(name)", in: window),
                                                 kAXValueAttribute) as? String,
                                       name == "today" ? "Selected" : "Not selected")
                    }
                    try assertTarget("tasks-add-task", in: window)
                    // AppKit's Tab traversal works even when XCTest cannot make
                    // its hosted window key for synthetic NSEvent delivery.
                    XCTAssertEqual(AXUIElementSetAttributeValue(try waitForElement(actions[2], in: window),
                                                                kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
                    window.selectNextKeyView(nil)
                    XCTAssertEqual(focusedIdentifier(), actions[3], "Delete follows Edit in keyboard focus order")
                    XCTAssertEqual(AXUIElementPerformAction(try waitForElement(actions[2], in: window),
                                                             kAXPressAction as CFString), .success)
                    _ = try waitForElement("task-editor-title", in: window)
                    XCTAssertEqual(focusedIdentifier(), "task-editor-title")
                    for id in ["task-editor-cancel", "task-editor-submit"] {
                        try assertInSheet(id, in: window)
                    }
                    XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-cancel", in: window),
                                                             kAXPressAction as CFString), .success)
                    settle()
                    XCTAssertNil(window.attachedSheet)
                    XCTAssertEqual(focusedIdentifier(), "task-details-\(saved.id.uuidString)")
                    XCTAssertEqual(try repository.fetchAll().map(\.id), [saved.id])
            }
        }
    }

    func testTodayRowControlsAtBothSizesAndTextScales() throws {
        for (width, height) in [(1000.0, 700.0), (1440.0, 940.0)] {
            for scale in [1.0, 1.3] {
                let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
                let repository = SwiftDataTaskRepository(container: container)
                let store = TaskStore(repository: repository)
                let task = try store.create(input: TaskInput(title: "Today keyboard target", plannedFor: .today(at: .now)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Today layout \(UUID())"
                window.contentView = NSHostingView(rootView: todayView(store)
                    .environment(\.appTextScaleOverride, scale))
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil) }
                settle()
                let row = try waitForElement("task-row-\(task.id.uuidString)", in: window)
                XCTAssertFalse(descendants(of: row).contains {
                    attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                })
                for (id, label) in [("task-complete-\(task.id.uuidString)", "Complete"),
                                    ("task-edit-\(task.id.uuidString)", "Edit")] {
                    let button = try waitForElement(id, in: window)
                    XCTAssertEqual(attribute(button, kAXDescriptionAttribute) as? String,
                                   "\(label) \(task.title)")
                    try assertTarget(id, in: window)
                }
                try assertTarget("today-add-task", in: window)
                XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-edit-\(task.id.uuidString)", in: window),
                                                         kAXPressAction as CFString), .success)
                _ = try waitForElement("task-editor-title", in: window)
                XCTAssertEqual(focusedIdentifier(), "task-editor-title")
                try assertInSheet("task-editor-cancel", in: window)
                try assertInSheet("task-editor-submit", in: window)
                XCTAssertEqual(AXUIElementPerformAction(try waitForElement("task-editor-cancel", in: window),
                                                         kAXPressAction as CFString), .success)
                settle()
                XCTAssertEqual(focusedIdentifier(), "task-details-\(task.id.uuidString)")
                XCTAssertEqual(try repository.fetchAll().map(\.id), [task.id])
            }
        }
    }

    func testKeyboardShortcutsCancelAndSubmitEditorWithoutPointer() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let store = TaskStore(repository: repository)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Keyboard editor \(UUID())"
        window.contentView = NSHostingView(rootView: TasksView(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-add-task", in: window),
                                                 kAXPressAction as CFString), .success)
        _ = try waitForElement("task-editor-title", in: window)
        XCTAssertEqual(focusedIdentifier(), "task-editor-title")
        key(53, character: "\u{1b}", in: window) // Escape
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(focusedIdentifier(), "tasks-add-task")
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("tasks-add-task", in: window),
                                                 kAXPressAction as CFString), .success)
        let title = try waitForElement("task-editor-title", in: window)
        XCTAssertEqual(AXUIElementSetAttributeValue(title, kAXValueAttribute as CFString,
                                                    "Keyboard save" as CFString), .success)
        settle()
        key(36, character: "\r", in: window) // Return / default action
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(try repository.fetchAll().map(\.title), ["Keyboard save"])
        XCTAssertEqual(store.snapshots.count, 1)
    }

    func testNativeDeleteAlertKeyboardNavigationAndConfirmation() throws {
        // A native alert only receives synthetic keyboard events in an active GUI
        // session. Never claim AXPress is keyboard confirmation in a headless run.
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let store = TaskStore(repository: repository)
        let saved = try store.create(input: TaskInput(title: "Keyboard deletion", plannedFor: .today(at: .now)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Keyboard confirmation \(UUID())"
        window.contentView = NSHostingView(rootView: TasksView(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        try XCTSkipIf(!NSApp.isActive || !window.isKeyWindow,
                      "Native alert keyboard confirmation requires an active GUI session and key window")
        let deleteID = "task-delete-\(saved.id.uuidString)"
        // Seed focus without activating the control; Tab and Space do the work.
        XCTAssertEqual(AXUIElementSetAttributeValue(try waitForElement("task-edit-\(saved.id.uuidString)", in: window),
                                                    kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        key(48, character: "\t", in: window)
        XCTAssertEqual(focusedIdentifier(), deleteID)
        key(49, character: " ", in: window)
        _ = try alertButton("Delete task")
        _ = try XCTUnwrap(window.attachedSheet)
        func deleteHasKeyboardFocus() -> Bool {
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            guard let value = attribute(app, kAXFocusedUIElementAttribute) else { return false }
            let focused = unsafeBitCast(value, to: AXUIElement.self)
            return attribute(focused, kAXRoleAttribute) as? String == kAXButtonRole &&
                attribute(focused, kAXDescriptionAttribute) as? String == "Delete task"
        }
        for _ in 0..<8 where !deleteHasKeyboardFocus() {
            key(48, character: "\t", in: window)
        }
        XCTAssertTrue(deleteHasKeyboardFocus(), "Tab must focus the destructive alert button")
        key(49, character: " ", in: window)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        waitUntil("Focus returns to Add task after keyboard deletion") {
            focusedIdentifier() == "tasks-add-task"
        }
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
        let ordered = try SwiftDataTaskRepository(container: container).fetchAll().map(TaskSnapshot.init)
        XCTAssertEqual(ordered.map(\.id), ids.sorted { $0.uuidString < $1.uuidString })
        let visible = TaskSelection.select(ordered, filter: .today, selectedDate: instant, now: instant, calendar: calendar, timeZone: zone)
        XCTAssertEqual(Set(visible.map(\.id)), Set([ids[0], ids[1]]))
        XCTAssertEqual(visible.count, 2) // A planned and due task must not appear twice.
        XCTAssertEqual(Set(TaskSelection.select(ordered, filter: .today, selectedDate: next, now: next, calendar: calendar, timeZone: zone).map(\.id)),
                       Set([ids[0], ids[1], ids[2]]))
        // Changing device zone must not reinterpret a saved planned date as a UTC midnight.
        XCTAssertEqual(TaskSelection.select(ordered, filter: .today, selectedDate: instant, now: instant,
                             calendar: calendar, timeZone: TimeZone(secondsFromGMT: 0)!).map(\.id),
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
            let draft = QuickCaptureDraft(store: TaskStore(repository: failed), clock: { instant },
                                          timeZone: { zone })
            draft.title = "  One capture  "
            var dismissals = 0
            draft.add { dismissals += 1 }
            XCTAssertEqual(dismissals, 0)
            XCTAssertNotNil(draft.errorMessage)
            XCTAssertTrue(try failed.fetchAll().isEmpty)
            let successful = SwiftDataTaskRepository(container: container, now: { instant }, makeID: { id },
                                                     timeZone: { zone })
            let retry = QuickCaptureDraft(store: TaskStore(repository: successful), clock: { instant },
                                          timeZone: { zone })
            retry.title = draft.title
            retry.add { dismissals += 1 }
            XCTAssertEqual(dismissals, 1)
            XCTAssertEqual(try successful.fetchAll().map(\.id), [id])
        }
        // Release every owner before reopening, as in a new app process.
        try autoreleasepool {
            let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(store))
            let persisted = try SwiftDataTaskRepository(container: reopened).fetchAll().map(TaskSnapshot.init)
            XCTAssertEqual(persisted.map(\.id), [id])
            XCTAssertEqual(persisted.map(\.title), ["One capture"])
            let today = TaskSelection.select(persisted, filter: .today, selectedDate: instant,
                                             now: instant, calendar: .current, timeZone: zone)
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
        let host = NSHostingView(rootView: todayView(TaskStore(repository: repository)))
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

    func testQuickCapturePublishesAcrossTodayAndTasksWithoutPostSaveRead() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let storage = SwiftDataTaskRepository(container: container)
        let repository = FailingReadRepository(storage: storage)
        repository.failRead = false
        let store = TaskStore(repository: repository)
        let today = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                             styleMask: [.titled], backing: .buffered, defer: false)
        today.title = "Capture shared Today \(UUID())"
        today.contentView = NSHostingView(rootView: todayView(store))
        today.makeKeyAndOrderFront(nil)
        let tasks = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                             styleMask: [.titled], backing: .buffered, defer: false)
        tasks.title = "Capture shared Tasks \(UUID())"
        tasks.contentView = NSHostingView(rootView: TasksView(store: store))
        tasks.makeKeyAndOrderFront(nil)
        defer { today.orderOut(nil); tasks.orderOut(nil) }
        settle()
        repository.failRead = true // A post-commit read would fail; creation still succeeds.
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("today-add-task", in: today),
                                                 kAXPressAction as CFString), .success)
        XCTAssertEqual(AXUIElementSetAttributeValue(try waitForElement("quick-capture-title", in: today),
                                                    kAXValueAttribute as CFString,
                                                    "Shared capture" as CFString), .success)
        settle()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("quick-capture-add", in: today),
                                                 kAXPressAction as CFString), .success)
        settle()
        let saved = try XCTUnwrap(store.snapshots.first)
        let row = "task-row-\(saved.id.uuidString)"
        XCTAssertNil(today.attachedSheet)
        XCTAssertEqual(store.readState, .loaded)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(elements(in: today, identifier: row).count, 1)
        XCTAssertEqual(elements(in: tasks, identifier: row).count, 1)
        XCTAssertEqual(try storage.fetchAll().map(\.id), [saved.id])
    }

    func testSharedCommittedSnapshotAppearsInTwoWindowsWithoutNavigation() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataTaskRepository(container: container)
        let dependencies = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container), taskRepository: repository)
        let suite = "SharedTasks.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let todayNavigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let tasksNavigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        tasksNavigation.select(.tasks)
        let windows = [todayNavigation, tasksNavigation].enumerated().map { index, navigation in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Shared task window \(index) \(UUID())"
            window.contentView = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: dependencies))
            window.makeKeyAndOrderFront(nil)
            return window
        }
        defer { windows.forEach { $0.orderOut(nil) } }
        settle()
        let planned = PlannedDay.today(at: .now, calendar: .current, timeZone: .current)
        let committed = try dependencies.taskStore.create(input: TaskInput(title: "Shared task", plannedFor: planned))
        let rowID = "task-row-\(committed.id.uuidString)"
        settle()
        for window in windows {
            XCTAssertEqual(elements(in: window, identifier: rowID).count, 1)
        }
        XCTAssertEqual(dependencies.taskStore.snapshots.map(\.id), [committed.id])
        XCTAssertEqual(try repository.fetchAll().map(\.id), [committed.id])
    }

    func testStaleReadErrorIsVisibleOnBothRoutesAndRetryRecovers() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let storage = SwiftDataTaskRepository(container: container)
        let id = try storage.create(title: "Cached task")
        let repository = FailingReadRepository(storage: storage)
        repository.failRead = false
        let dependencies = AppDependencies(container: container,
            catalogRepository: SwiftDataCatalogRepository(container: container), taskRepository: repository)
        let suite = "StaleTasks.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NavigationStore(preferences: UserDefaultsDestinationPreferences(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Stale shared task inspection"
        window.contentView = NSHostingView(rootView: AppShell(navigation: navigation, dependencies: dependencies))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        XCTAssertEqual(dependencies.taskStore.readState, .loaded)
        repository.failRead = true
        navigation.select(.tasks)
        settle()
        for route in [AppDestination.tasks, .today] {
            navigation.select(route)
            settle()
            let text = visibleText(in: window)
            XCTAssertTrue(text.contains("Error: Content could not be loaded."))
            XCTAssertTrue(text.contains("Could not refresh tasks. Showing previously loaded tasks. Retry to update."))
            XCTAssertFalse(text.contains("Nothing planned or due today."))
            XCTAssertFalse(text.contains("No tasks planned or due on this day."))
            XCTAssertEqual(elements(in: window, identifier: "task-row-\(id.uuidString)").count, 1)
        }
        repository.failRead = false
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let host = try XCTUnwrap((attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
            attribute($0, kAXTitleAttribute) as? String == window.title
        })
        let retry = try XCTUnwrap(descendants(of: host).first {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
            attribute($0, kAXDescriptionAttribute) as? String == "Retry"
        })
        XCTAssertEqual(AXUIElementPerformAction(retry, kAXPressAction as CFString), .success)
        settle()
        XCTAssertEqual(dependencies.taskStore.readState, .loaded)
        XCTAssertFalse(visibleText(in: window).contains("Error: Content could not be loaded."))
        XCTAssertEqual(try storage.fetchAll().map(\.id), [id])
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
