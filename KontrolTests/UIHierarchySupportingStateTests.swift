import SwiftData
import XCTest
@testable import Kontrol

@MainActor
private final class ProjectWorkPreferences: DestinationPreferences {
    var savedDestination: String?
}

private final class ProjectWorkInspector: ProjectInspecting {
    private(set) var calls = 0
    func inspect(selectedFolder: URL) async throws -> ProjectInspection {
        calls += 1
        throw ProjectInspectionFailure.inconsistentRead
    }
    func inspect(bookmarkData: Data) async throws -> ProjectInspection {
        calls += 1
        throw ProjectInspectionFailure.inconsistentRead
    }
    func makeBookmark(selectedFolder: URL) async throws -> Data {
        calls += 1
        throw ProjectInspectionFailure.inconsistentRead
    }
}

@MainActor
private final class ProjectWorkRepository: ProjectReferenceRepository {
    private(set) var calls = 0
    func fetchAll() throws -> [ProjectReferenceSnapshot] { calls += 1; return [] }
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot {
        calls += 1
        throw ProjectReferencePersistenceError.invalidReference
    }
    func remove(id: UUID, expectedRevision: UUID) throws { calls += 1 }
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot {
        calls += 1
        throw ProjectReferencePersistenceError.invalidReference
    }
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID,
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot {
        calls += 1
        throw ProjectReferencePersistenceError.invalidReference
    }
}

private final class ProjectWorkWriter: FeatureFileWriting {
    private(set) var calls = 0
    func complete(_ request: FeatureCompletionRequest) async throws -> FeatureMutationReceipt {
        calls += 1
        throw FeatureMutationFailure.writeFailed
    }
    func undo(_ request: FeatureUndoRequest) async throws -> FeatureMutationReceipt {
        calls += 1
        throw FeatureMutationFailure.writeFailed
    }
}

@MainActor
final class UIHierarchySupportingStateTests: XCTestCase {
    private enum Injected: Error { case save }

    func testCompactTaskMetadataKeepsCivilPlansDueInstantsAndProvenanceSeparate() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let savedZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-05T13:00:00Z"))
        let context = TaskTemporalContext(now: now, calendar: Calendar(identifier: .gregorian), timeZone: zone)
        func snapshot(_ n: Int, plan: KontrolSchemaV1.PlannedDayComponents? = nil,
                      due: Date? = nil, completed: Date? = nil) throws -> TaskSnapshot {
            TaskSnapshot(try TaskItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                                      title: "Row \(n)", createdAt: now, dueAt: due, plannedDay: plan,
                                      plannedTimeZoneID: plan == nil ? nil : savedZone.identifier,
                                      completedAt: completed))
        }
        let yesterday = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian", year: 2026, month: 6, day: 5)
        let past = try snapshot(1, plan: yesterday)
        let pastMetadata = TaskRowMetadata(past, in: context)
        XCTAssertEqual(pastMetadata.planPosition, .past)
        XCTAssertTrue(pastMetadata.isUnscheduled)
        XCTAssertTrue(pastMetadata.compact(in: context).contains("Planned (past) 2026-06-05 · Unscheduled"))
        XCTAssertFalse(pastMetadata.compact(in: context).contains(savedZone.identifier))
        XCTAssertEqual(pastMetadata.provenance, "Saved plan: gregorian calendar · \(savedZone.identifier)")

        // The device calendar differs from the saved calendar; today's Buddhist
        // civil day must not be mistaken for Gregorian 2026-06-05.
        let buddhistContext = TaskTemporalContext(now: now, calendar: Calendar(identifier: .buddhist), timeZone: zone)
        let today = try snapshot(2, plan: .init(calendarIdentifier: "gregorian", year: 2026, month: 6, day: 6))
        XCTAssertEqual(TaskRowMetadata(today, in: buddhistContext).planPosition, .today)
        XCTAssertEqual(TaskRowMetadata(today, in: buddhistContext).compact(in: buddhistContext), "Planned Today")
        let buddhistPlan = try snapshot(3, plan: .init(calendarIdentifier: "buddhist", year: 2569, month: 6, day: 6))
        XCTAssertEqual(TaskRowMetadata(buddhistPlan, in: context).planPosition, .today)
        let future = try snapshot(4, plan: .init(calendarIdentifier: "gregorian", year: 2026, month: 6, day: 7))
        XCTAssertEqual(TaskRowMetadata(future, in: context).planPosition, .future)
        XCTAssertFalse(TaskRowMetadata(future, in: context).isUnscheduled)

        let overdue = try snapshot(5, plan: yesterday, due: now.addingTimeInterval(-1))
        let dueMetadata = TaskRowMetadata(overdue, in: context)
        XCTAssertTrue(dueMetadata.isOverdue)
        XCTAssertFalse(dueMetadata.isUnscheduled)
        XCTAssertTrue(dueMetadata.compact(in: context).contains("Overdue · Due"))
        XCTAssertTrue(dueMetadata.compact(in: context).contains("Planned (past)"))
        let exact = TaskRowMetadata(try snapshot(6, due: now), in: context)
        XCTAssertFalse(exact.isOverdue)
        XCTAssertTrue(exact.compact(in: context).hasPrefix("Due "))
        XCTAssertNil(exact.plannedDay)
        let complete = TaskRowMetadata(try snapshot(7, plan: yesterday, due: now.addingTimeInterval(-1), completed: now), in: context)
        XCTAssertFalse(complete.isOverdue)
        XCTAssertFalse(complete.isUnscheduled)
        XCTAssertTrue(complete.compact(in: context).contains("Completed"))
        XCTAssertTrue(complete.compact(in: context).contains("Planned (past)"))
        XCTAssertTrue(complete.compact(in: context).contains("Due"))
        XCTAssertTrue(TaskSelection.select([past, overdue, today, future], filter: .upcoming,
                                            selectedDate: now, now: now, calendar: context.calendar,
                                            timeZone: zone).map(\.id).contains(past.id))
    }

    func testTaskDisclosureAndCapturedDeletionRemainReadOnlyUntilExplicitConfirmation() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var writes = 0
        let repository = SwiftDataTaskRepository(container: container, save: { context in
            writes += 1
            try context.save()
        })
        let store = TaskStore(repository: repository)
        let first = try store.create(input: TaskInput(title: "First", plannedFor: .today(at: .now)))
        let second = try store.create(input: TaskInput(title: "Second", plannedFor: .today(at: .now)))
        let baseline = writes
        var disclosures = TaskRowDisclosureState()
        disclosures.toggle(first.id)
        XCTAssertTrue(disclosures.contains(first.id))
        XCTAssertFalse(disclosures.contains(second.id))
        _ = TaskRowMetadata(first, in: store.temporalContext).compact(in: store.temporalContext)
        _ = store.select(.today)
        _ = store.select(.completed)
        disclosures.toggle(first.id)
        XCTAssertFalse(disclosures.contains(first.id))
        XCTAssertEqual(writes, baseline, "Disclosing and filtering must not persist tasks")

        let captured = TaskDeletionConfirmation(id: first.id, title: first.title)
        var pending: TaskDeletionConfirmation? = captured
        // Cancel clears the pending identity and cannot yield a deletion target.
        pending = nil
        XCTAssertNil(TaskDeletionConfirmation.confirmedID(captured: captured, pending: pending))
        XCTAssertEqual(writes, baseline)
        pending = captured
        XCTAssertNil(TaskDeletionConfirmation.confirmedID(captured: captured,
            pending: .init(id: second.id, title: second.title)))
        XCTAssertEqual(TaskDeletionConfirmation.confirmedID(captured: captured, pending: pending), first.id)
        _ = store.select(.upcoming) // Changed filter does not replace captured UUID.
        let target = try XCTUnwrap(TaskDeletionConfirmation.confirmedID(captured: captured, pending: pending))
        try store.delete(id: target)
        XCTAssertEqual(writes, baseline + 1)
        XCTAssertEqual(store.snapshots.map(\.id), [second.id])
        XCTAssertEqual(try repository.fetchAll().map(\.id), [second.id])
        // Today supplies no onDelete callback; shared rows accept nil and retain edit/completion.
        _ = TaskRows(rows: [second], temporalContext: store.temporalContext,
                     onEdit: { _ in }, onSetCompleted: { _, _ in })
        XCTAssertEqual(writes, baseline + 1)
    }

    func testTodayPracticeLabelsAndScheduleCueUseActualLocalToday() throws {
        XCTAssertEqual(TodayView.lessonOpenTitle(started: false), "Open")
        XCTAssertEqual(TodayView.lessonOpenTitle(started: true), "Resume")

        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T14:00:00Z"))
        let temporal = TaskTemporalContext(now: now, calendar: calendar, timeZone: zone)
        var day = TodayDaySelection()
        XCTAssertNil(TodayView.lessonScheduleCue(day: day, temporal: temporal))
        day.previous(in: temporal)
        let browsed = try XCTUnwrap(day.selectedDate(in: temporal))
        XCTAssertFalse(calendar.isDate(browsed, inSameDayAs: now))
        let cue = try XCTUnwrap(TodayView.lessonScheduleCue(day: day, temporal: temporal))
        XCTAssertEqual(cue, "Schedule… uses today, \(now.formatted(TodayView.localDateStyle(in: temporal))), not the selected day.")
        XCTAssertFalse(cue.contains(browsed.formatted(TodayView.localDateStyle(in: temporal))),
                       "Cue must not identify the browsed day as the scheduling day")
        day.returnToToday()
        XCTAssertNil(TodayView.lessonScheduleCue(day: day, temporal: temporal))
    }

    func testTodayProjectWorkUsesNavigationBarrierAndDoesNotInspectOrMutateProjects() throws {
        var failSave = false
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let catalog = SwiftDataCatalogRepository(container: container, beforeSave: {
            if failSave { throw Injected.save }
        })
        _ = try catalog.importIfNeeded(BundledCatalogLoader.load())
        let inspector = ProjectWorkInspector()
        let projects = ProjectWorkRepository()
        let writer = ProjectWorkWriter()
        let graph = AppDependencies(container: container, catalogRepository: catalog,
                                    projectInspector: inspector, projectRepository: projects,
                                    projectWriter: writer)
        graph.learningCatalogStore.loadIfNeeded()
        let lessonID = try XCTUnwrap(graph.learningCatalogStore.state.snapshot?.slots.first?.lessonID)
        let detail = try graph.learningCatalogStore.openLesson(lessonID: lessonID).detail
        let attemptID = try XCTUnwrap(detail.attempt?.id)
        // No debounce is run; all saves below are synchronous navigation barriers.
        let drafts = LessonDraftStore(learning: graph.learningCatalogStore, schedule: { _, _ in { } })
        drafts.observe(detail)
        let preferences = ProjectWorkPreferences()
        let navigation = NavigationStore(preferences: preferences)
        navigation.attachDrafts(drafts)
        _ = TodayView(store: graph.taskStore, scheduleStore: graph.scheduleStore,
                      learningStore: graph.learningCatalogStore, navigation: navigation)
        // The standalone Today initializer still needs neither navigation nor Learning.
        _ = TodayView(store: graph.taskStore, scheduleStore: graph.scheduleStore)

        TodayView.openProjectWork(navigation: navigation)
        XCTAssertEqual(navigation.selectedDestination, .projects)
        XCTAssertEqual(preferences.savedDestination, AppDestination.projects.rawValue)
        XCTAssertNil(navigation.pendingTransition)
        navigation.select(.today)
        XCTAssertEqual(navigation.selectedDestination, .today)
        drafts.edit("unsaved Project work 🧪", attemptID: attemptID)
        failSave = true
        TodayView.openProjectWork(navigation: navigation)
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(preferences.savedDestination, AppDestination.today.rawValue)
        XCTAssertEqual(navigation.pendingTransition, .destination(.projects))
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertEqual(drafts.buffers[attemptID]?.text, "unsaved Project work 🧪")
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        XCTAssertEqual(drafts.buffers[attemptID]?.status, .notSaved(.persistenceFailure))
        navigation.cancelTransition() // Stay here does not discard the failed draft.
        XCTAssertNil(navigation.pendingTransition)
        XCTAssertEqual(navigation.selectedDestination, .today)
        XCTAssertEqual(navigation.saveError, .persistenceFailure)
        XCTAssertTrue(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        TodayView.openProjectWork(navigation: navigation)
        XCTAssertEqual(navigation.pendingTransition, .destination(.projects))
        failSave = false
        navigation.retryTransition()
        XCTAssertNil(navigation.pendingTransition)
        XCTAssertNil(navigation.saveError)
        XCTAssertEqual(navigation.selectedDestination, .projects)
        XCTAssertEqual(preferences.savedDestination, AppDestination.projects.rawValue)
        XCTAssertEqual(drafts.buffers[attemptID]?.status, .saved)
        XCTAssertFalse(try XCTUnwrap(drafts.buffers[attemptID]).isDirty)
        XCTAssertEqual(try catalog.loadLesson(lessonID: lessonID).attempt?.answerDraft, "unsaved Project work 🧪")
        XCTAssertEqual(inspector.calls, 0)
        XCTAssertEqual(projects.calls, 0)
        XCTAssertEqual(writer.calls, 0)
        XCTAssertFalse(graph.projectStore.isLoaded)
        XCTAssertTrue(graph.projectStore.rows.isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ProjectReference>()).isEmpty)
    }
}
