import Combine
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusPreferencesTests: XCTestCase {
    private func snapshot(_ minutes: Int) throws -> AppPreferencesSnapshot {
        AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: minutes), revision: UUID())
    }

    private func save(_ minutes: Int, to store: AppPreferencesStore) throws {
        var input = AppPreferencesDraft()
        input.focusDefaultMinutes = String(minutes)
        try store.save(input, expectedRevision: store.committed?.revision)
    }

    func testNewDraftUsesValidatedPresetAndCustomPreferences() throws {
        for (minutes, duration) in [(15, FocusDuration.fifteen), (25, .twentyFive),
                                    (50, .fifty), (37, .custom("37"))] {
            let draft = FocusReadyDraft(preferences: try snapshot(minutes))
            XCTAssertEqual(draft.duration, duration)
            XCTAssertEqual(draft.durationSource, .followingDefault)
            XCTAssertNil(draft.fallbackMessage)
            XCTAssertEqual(try draft.configuration(openTasks: [], tasksReadable: true).plannedSeconds(), minutes * 60)
        }
    }

    func testTwoWindowDraftsFollowOnlyDurableReceiptsAndKeepExplicitInput() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataAppPreferencesRepository(container: container, beforeSave: {
            if fail { throw AppPreferencesError.persistenceFailure }
        })
        let store = AppPreferencesStore(repository: repository)
        var first = FocusReadyDraft(preferences: store.editableSnapshot)
        var second = first
        second.selectDuration(.custom(" 007 "))
        let taskID = UUID()
        first.selectTask(taskID)
        let observation = store.$committed.sink { receipt in
            first.followPreferences(receipt)
            second.followPreferences(receipt)
        }
        defer { observation.cancel() }
        try save(50, to: store)
        XCTAssertEqual(first.duration, .fifty)
        XCTAssertEqual(first.linkedTaskID, taskID)
        XCTAssertEqual(second.duration, .custom(" 007 "))
        XCTAssertEqual(second.durationSource, .userOverride)
        fail = true
        XCTAssertThrowsError(try save(15, to: store))
        XCTAssertEqual(first.duration, .fifty)
        XCTAssertEqual(second.duration, .custom(" 007 "))
        XCTAssertEqual(try repository.load(), store.committed)
        second = FocusReadyDraft(preferences: store.editableSnapshot)
        XCTAssertEqual(second.duration, .fifty)
        XCTAssertNil(second.linkedTaskID)
    }

    func testEvenChoosingCurrentDefaultIsAnExplicitOverride() throws {
        var draft = FocusReadyDraft()
        draft.selectDuration(.twentyFive)
        draft.followPreferences(try snapshot(50))
        XCTAssertEqual(draft.duration, .twentyFive)
        draft.selectDuration(.custom("invalid"))
        draft.followPreferences(try snapshot(15))
        XCTAssertEqual(draft.duration, .custom("invalid"))
        XCTAssertThrowsError(try draft.configuration(openTasks: [], tasksReadable: true))
    }

    func testFailedReadUsesHonestFallbackRatherThanRetainedCommittedValue() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataAppPreferencesRepository(container: container)
        let store = AppPreferencesStore(repository: repository)
        try save(50, to: store)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<AppPreferencesRecord>()).first)
        record.textSize = "unsupported"
        try context.save()
        store.retry()
        XCTAssertEqual(store.committed?.preferences.focusDefaultMinutes, 50)
        XCTAssertNil(store.editableSnapshot)
        var draft = FocusReadyDraft(preferences: store.editableSnapshot)
        XCTAssertEqual(draft.duration, .twentyFive)
        XCTAssertNotNil(draft.fallbackMessage)
        record.textSize = "system"
        try context.save()
        store.retry()
        draft.followPreferences(store.editableSnapshot)
        XCTAssertEqual(draft.duration, .fifty)
        XCTAssertNil(draft.fallbackMessage)
        draft.followPreferences(nil)
        draft.markSubmitted()
        draft.followPreferences(store.editableSnapshot)
        XCTAssertEqual(draft.duration, .twentyFive)
        XCTAssertNotNil(draft.fallbackMessage, "A submitted fallback remains identified until reset or explicit edit")
        draft.selectDuration(.fifteen)
        XCTAssertNil(draft.fallbackMessage)
    }

    func testFailedStartFreezesDefaultDurationAndTaskForRetry() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = true
        let repository = SwiftDataFocusRepository(container: container, save: { context in
            if fail { throw FocusError.persistenceFailure }
            try context.save()
        })
        let service = FocusService(repository: repository, scheduleTick: { _ in {} },
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        let task = try SwiftDataTaskRepository(container: container).create(input: TaskInput(title: "Keep link"))
        var draft = FocusReadyDraft(preferences: try snapshot(37))
        draft.selectTask(task.id)
        let submitted = try draft.configuration(openTasks: [task], tasksReadable: true)
        draft.markSubmitted()
        XCTAssertThrowsError(try service.start(configuration: submitted))
        draft.followPreferences(try snapshot(50))
        XCTAssertEqual(draft.durationSource, .submitted)
        XCTAssertEqual(try draft.configuration(openTasks: [task], tasksReadable: true), submitted)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        fail = false
        try service.start(configuration: draft.configuration(openTasks: [task], tasksReadable: true))
        XCTAssertEqual(service.activeSession?.plannedSeconds, 37 * 60)
        XCTAssertEqual(service.activeSession?.linkedTaskID, task.id)
        try service.end()
        draft = FocusReadyDraft(preferences: try snapshot(50))
        XCTAssertEqual(draft.duration, .fifty)
        XCTAssertNil(draft.linkedTaskID)
    }

    func testPreferencesRetainFullRangeAndStartTimeValidationRemainsAuthoritative() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let minutes = Int.max / 60
        var draft = FocusReadyDraft(preferences: try snapshot(minutes))
        let input = try draft.configuration(openTasks: [], tasksReadable: true)
        XCTAssertEqual(try input.plannedSeconds(), minutes * 60)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let service = FocusService(repository: SwiftDataFocusRepository(container: container),
            wallClock: { now }, scheduleTick: { _ in {} },
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
        service.loadIfNeeded()
        try service.start(configuration: input)
        XCTAssertEqual(service.activeSession?.plannedSeconds, minutes * 60)
        try service.end()
        let before = try service.repository.fetchAll()
        now = Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)
        draft.markSubmitted()
        XCTAssertThrowsError(try service.start(configuration: input)) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        draft.followPreferences(.defaults)
        XCTAssertEqual(draft.duration, input.duration)
        XCTAssertEqual(try service.repository.fetchAll(), before)
    }

    func testPreferenceCommitsDoNotChangeAnyPersistedSessionStateOrTiming() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for (state, actual, recovery) in [("running", 12.0, false), ("paused", 20.0, false),
                                        ("paused", 30.0, true), ("completed", 1500.0, false),
                                        ("ended", 40.0, false)] {
            let checkpoint = start.addingTimeInterval(60)
            context.insert(FocusSession(id: UUID(), state: state, plannedSeconds: 1500,
                accumulatedActiveSeconds: actual,
                activeSegmentStartedAt: state == "running" ? checkpoint : nil,
                deadline: state == "running" ? checkpoint.addingTimeInterval(1500 - actual) : nil,
                pausedAt: state == "paused" ? checkpoint : nil, startedAt: start,
                endedAt: ["completed", "ended"].contains(state) ? checkpoint : nil,
                checkpointAt: checkpoint, recoveryRequired: recovery,
                linkedTaskID: UUID(), linkedTitleSnapshot: "Original title"))
        }
        try context.save()
        func rows() throws -> [FocusSessionSnapshot] {
            try ModelContext(container).fetch(FetchDescriptor<FocusSession>())
                .map(FocusSessionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        }
        let before = try rows()
        let store = AppPreferencesStore(repository: SwiftDataAppPreferencesRepository(container: container))
        for minutes in [50, 37, 15] {
            try save(minutes, to: store)
            XCTAssertEqual(try rows(), before)
        }
    }
}
