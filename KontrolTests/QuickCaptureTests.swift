import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

@MainActor
final class QuickCaptureTests: XCTestCase {
    private enum SaveFailure: Error { case injected }

    private final class RecordingRepository: TaskRepository {
        var calls: [(String, PlannedDay?)] = []
        var fail = false
        let container: ModelContainer
        let storage: SwiftDataTaskRepository

        init() throws {
            container = try ModelContainerFactory().makeContainer(mode: .inMemory)
            storage = SwiftDataTaskRepository(container: container)
        }

        func create(title: String, plannedFor: PlannedDay?) throws -> UUID {
            calls.append((title, plannedFor))
            if fail { throw SaveFailure.injected }
            return try storage.create(title: title, plannedFor: plannedFor)
        }

        func fetchAll() throws -> [TaskItem] { try storage.fetchAll() }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private func descendants(of element: AXUIElement) -> [AXUIElement] {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { [$0] + descendants(of: $0) }
    }

    // AX publishes a newly hosted SwiftUI window (and its native sheet) asynchronously.
    // First identify our own window by title; never treat another test/app window as the host.
    private func element(_ identifier: String, in window: NSWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let host = windows.first(where: {
            attribute($0, kAXTitleAttribute) as? String == window.title
        }) else { return nil }
        var roots = [host]
        if window.attachedSheet != nil {
            roots += attribute(host, "AXSheets") as? [AXUIElement] ?? []
            // Some macOS versions expose the sheet as a separate AX window.
            roots += windows.filter { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
        }
        return roots.flatMap { descendants(of: $0) }.first {
            attribute($0, kAXIdentifierAttribute) as? String == identifier
        }
    }

    private func waitForElement(_ identifier: String, in window: NSWindow,
                                file: StaticString = #filePath, line: UInt = #line) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if let found = element(identifier, in: window) { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return try XCTUnwrap(element(identifier, in: window),
                             "Accessibility control \(identifier) missing from hosted window \(window.title)",
                             file: file, line: line)
    }

    func testBlankDraftNeverSaves() throws {
        let repository = try RecordingRepository()
        let draft = QuickCaptureDraft(repository: repository)
        var dismissed = false
        draft.title = "  \n  "
        XCTAssertFalse(draft.canAdd)
        draft.add { dismissed = true }
        XCTAssertFalse(dismissed)
        XCTAssertTrue(repository.calls.isEmpty)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testFailureKeepsEditableTitleAndSheetUntilSingleSuccessfulRetry() throws {
        let repository = try RecordingRepository()
        repository.fail = true
        let draft = QuickCaptureDraft(repository: repository)
        draft.title = "  Keep my draft  "
        var dismissals = 0
        draft.add { dismissals += 1 }
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(draft.title, "  Keep my draft  ")
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertEqual(repository.calls.count, 1)
        XCTAssertNil(repository.calls.first?.1) // Current local day, not a due timestamp.
        XCTAssertTrue(try repository.fetchAll().isEmpty)

        draft.title = "  Edited after error  "
        XCTAssertNil(draft.errorMessage)
        repository.fail = false
        draft.add { dismissals += 1 }
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(repository.calls.count, 2)
        let saved = try XCTUnwrap(repository.fetchAll().first)
        XCTAssertEqual(try repository.fetchAll().count, 1)
        XCTAssertEqual(saved.title, "Edited after error")
        XCTAssertNotNil(saved.plannedDay)
        XCTAssertEqual(saved.plannedTimeZoneID, TimeZone.current.identifier)
        XCTAssertNil(saved.dueAt)
    }

    func testRenderedSaveFailureRetainsSheetAndEditableTextUntilRetry() throws {
        let repository = try RecordingRepository()
        repository.fail = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Capture retry test"
        let host = NSHostingView(rootView: TodayView(taskRepository: repository))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("today-add-task", in: window),
                                                 kAXPressAction as CFString), .success)
        let title = try waitForElement("quick-capture-title", in: window)
        XCTAssertEqual(AXUIElementSetAttributeValue(title, kAXValueAttribute as CFString,
                                                   "  Retry me  " as CFString), .success)
        settle()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("quick-capture-add", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertEqual(repository.calls.count, 1)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertNotNil(window.attachedSheet)
        _ = try waitForElement("quick-capture-error", in: window)
        XCTAssertEqual(attribute(try waitForElement("quick-capture-title", in: window), kAXValueAttribute) as? String,
                       "  Retry me  ")
        repository.fail = false
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("quick-capture-add", in: window),
                                                 kAXPressAction as CFString), .success)
        settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(repository.calls.count, 2)
        XCTAssertEqual(try repository.fetchAll().map(\.title), ["Retry me"])
    }

    func testTodayOpensNativeSheetWithReachableControlsAndCancelWithoutInsert() throws {
        let repository = try RecordingRepository()
        let host = NSHostingView(rootView: TodayView(taskRepository: repository))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Quick capture test"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        // See AppShellTests: closing a hosted window crashes the XCTest autorelease checker.
        defer { window.orderOut(nil) }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(AXUIElementPerformAction(try waitForElement("today-add-task", in: window),
                                                 kAXPressAction as CFString), .success)
        let title = try waitForElement("quick-capture-title", in: window)
        let cancel = try waitForElement("quick-capture-cancel", in: window)
        let add = try waitForElement("quick-capture-add", in: window)
        XCTAssertEqual(attribute(title, kAXRoleAttribute) as? String, kAXTextFieldRole)
        XCTAssertEqual(attribute(cancel, kAXRoleAttribute) as? String, kAXButtonRole)
        XCTAssertEqual(attribute(add, kAXRoleAttribute) as? String, kAXButtonRole)
        XCTAssertEqual((attribute(add, kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
        XCTAssertEqual(attribute(try waitForElement("quick-capture-plan", in: window), kAXValueAttribute) as? String,
                       "Plan for Today")
        XCTAssertEqual(attribute(try waitForElement("quick-capture-due", in: window), kAXValueAttribute) as? String,
                       "Due None")
        XCTAssertEqual(AXUIElementSetAttributeValue(title, kAXValueAttribute as CFString,
                                                   "  \n  " as CFString), .success)
        settle()
        XCTAssertEqual((attribute(add, kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
        XCTAssertTrue(repository.calls.isEmpty)
        // The native sheet initially focuses the editable title. Both actions are
        // real accessible buttons (Add becomes enabled once the title is nonblank).
        XCTAssertNotNil(window.attachedSheet)
        let focused = try XCTUnwrap(attribute(app, kAXFocusedUIElementAttribute))
        XCTAssertEqual(attribute(unsafeBitCast(focused, to: AXUIElement.self), kAXIdentifierAttribute) as? String,
                       "quick-capture-title")
        XCTAssertEqual(AXUIElementSetAttributeValue(title, kAXValueAttribute as CFString,
                                                   "Discard me" as CFString), .success)
        settle()
        XCTAssertEqual((attribute(add, kAXEnabledAttribute) as? NSNumber)?.boolValue, true)
        XCTAssertEqual(AXUIElementPerformAction(cancel, kAXPressAction as CFString), .success)
        settle()
        XCTAssertNil(element("quick-capture-title", in: window))
        XCTAssertTrue(repository.calls.isEmpty)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }
}
