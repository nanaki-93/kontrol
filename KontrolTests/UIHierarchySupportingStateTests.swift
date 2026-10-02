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

    func testNewsDiagnosticDisclosureAndFiltersOnlyProjectCachedData() {
        let failedID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let articleID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        func feed(_ id: UUID, name: String, topic: String, error: NewsErrorCode?) -> FeedSourceSnapshot {
            FeedSourceSnapshot(id: id, name: name, url: URL(string: "https://feeds.example/rss")!,
                topicIDs: [topic], isEnabled: true, configurationRevision: id,
                etag: nil, lastModified: nil, lastAttemptAt: date, lastSuccessAt: nil,
                lastError: error, retryNotBefore: nil)
        }
        let source = NewsArticleSource(feedID: failedID, feedName: "Failed feed", topicIDs: ["go"], guid: nil)
        let article = ArticleMetadata(id: articleID, url: URL(string: "https://example.com/story")!,
            canonicalURL: "https://example.com/story", title: "Retained headline",
            publishedAt: date, firstFetchedAt: date, summary: "Saved summary", sources: [source])
        let snapshot = NewsSnapshot(topics: [NewsTopic(id: "go", name: "Go"),
                                             NewsTopic(id: "empty", name: "Empty"),
                                             NewsTopic(id: "swift", name: "Swift")],
            feeds: [feed(failedID, name: "Failed feed", topic: "go", error: .timeout),
                    feed(otherID, name: "Unselected feed", topic: "swift", error: .offline)],
            articleStates: [NewsSelection.State(article: article, aliases: [:])],
            preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: ["go", "empty"],
                                         revision: UUID(), lastRefreshAt: date))
        let before = snapshot
        let closed = NewsView.browse(in: snapshot, filter: nil, diagnosticsExpanded: false)
        let open = NewsView.browse(in: snapshot, filter: nil, diagnosticsExpanded: true)
        XCTAssertEqual(closed.sections, open.sections)
        XCTAssertEqual(open.sections.flatMap(\.articles).map(\.article.id), [articleID])
        XCTAssertTrue(closed.diagnostics.isEmpty)
        XCTAssertEqual(open.diagnostics.map(\.id), [failedID])
        XCTAssertTrue(open.diagnostics[0].text.contains("Failed feed: A feed timed out."))
        XCTAssertTrue(open.diagnostics[0].text.contains("Saved headlines remain available."))
        let filtered = NewsView.browse(in: snapshot, filter: "swift", diagnosticsExpanded: true)
        XCTAssertEqual(filtered.sections, open.sections, "Unselected filter falls back to All")
        XCTAssertEqual(filtered.diagnostics, open.diagnostics)
        let empty = NewsView.browse(in: snapshot, filter: "empty", diagnosticsExpanded: true)
        XCTAssertTrue(empty.sections.isEmpty)
        XCTAssertEqual(empty.diagnostics, open.diagnostics)
        XCTAssertEqual(NewsView.contentState(snapshot: snapshot, isLoading: false,
                                              localFailure: nil, filter: "empty"), .filteredEmpty)
        XCTAssertEqual(NewsView.contentState(snapshot: snapshot, isLoading: false,
                                              localFailure: .read, filter: nil), .readFailure)
        XCTAssertEqual(NewsView.browse(in: snapshot, filter: nil, diagnosticsExpanded: false).sections,
                       open.sections, "Retained headlines remain projected during a local read failure")
        XCTAssertEqual(snapshot, before, "Disclosure and filtering cannot change subscriptions or cached content")
    }

    func testNewsRefreshSummaryExplainsStoreAdmissionAndServerBlockedSubsets() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = now.addingTimeInterval(120)
        func feed(_ n: Int, selected: Bool = true, enabled: Bool = true,
                  retry: Date? = nil) -> FeedSourceSnapshot {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
            return FeedSourceSnapshot(id: id, name: "Feed \(n)", url: URL(string: "https://example.com/feed")!,
                topicIDs: [selected ? "go" : "other"], isEnabled: enabled, configurationRevision: id,
                etag: nil, lastModified: nil, lastAttemptAt: nil, lastSuccessAt: nil,
                lastError: retry == nil ? nil : .rateLimited, retryNotBefore: retry)
        }
        func snapshot(_ feeds: [FeedSourceSnapshot], topics: Set<String> = ["go"]) -> NewsSnapshot {
            NewsSnapshot(topics: [NewsTopic(id: "go", name: "Go")], feeds: feeds, articleStates: [],
                preferences: NewsPreferences(catalogVersion: 1, selectedTopicIDs: topics,
                                             revision: UUID(), lastRefreshAt: nil))
        }
        func summary(_ value: NewsSnapshot?, loading: Bool = false, failure: NewsLocalFailure? = nil,
                     refreshing: Bool = false, allowed: Bool = false, at date: Date? = nil)
            -> NewsView.RefreshDisplaySummary {
            NewsView.refreshDisplaySummary(snapshot: value, isLoading: loading, localFailure: failure,
                isRefreshing: refreshing, canRetry: allowed, at: date ?? now)
        }
        XCTAssertTrue(try XCTUnwrap(summary(nil, loading: true).disabledReason).contains("loading"))
        XCTAssertTrue(try XCTUnwrap(summary(nil, failure: .read).disabledReason).contains("could not be read"))
        XCTAssertTrue(try XCTUnwrap(summary(nil).disabledReason).contains("until local News is loaded"))
        let ready = snapshot([feed(1)])
        XCTAssertTrue(try XCTUnwrap(summary(ready, refreshing: true).disabledReason).contains("in progress"))
        XCTAssertTrue(try XCTUnwrap(summary(ready, failure: .read).disabledReason).contains("could not be read"),
                      "Retained cache after failed read is not refreshable")
        XCTAssertTrue(try XCTUnwrap(summary(snapshot([feed(1)], topics: [])).disabledReason).contains("select topics"))
        XCTAssertTrue(try XCTUnwrap(summary(snapshot([feed(1, selected: false), feed(2, enabled: false)])).disabledReason).contains("enable a feed"))
        XCTAssertNil(summary(ready, allowed: true).disabledReason)
        let subset = snapshot([feed(1, retry: deadline), feed(2), feed(3, selected: false, retry: deadline)])
        let partial = summary(subset, allowed: true)
        XCTAssertNil(partial.disabledReason, "Only the store's admission decision enables the button")
        XCTAssertTrue(try XCTUnwrap(partial.deadlineNote).contains("Other selected feeds are not server-blocked"))
        XCTAssertFalse(try XCTUnwrap(partial.deadlineNote).contains("Selected feeds have server retry deadlines"))
        let all = snapshot([feed(1, retry: deadline), feed(2, retry: deadline.addingTimeInterval(60))])
        let blocked = summary(all)
        XCTAssertTrue(try XCTUnwrap(blocked.disabledReason).contains("server retry deadlines"))
        XCTAssertTrue(try XCTUnwrap(blocked.deadlineNote).contains("Next retry after \(deadline.formatted(date: .abbreviated, time: .shortened))"))
        XCTAssertTrue(try XCTUnwrap(blocked.deadlineNote).contains("others may be later"))
        XCTAssertNil(summary(all, allowed: true, at: deadline).disabledReason)
        XCTAssertTrue(try XCTUnwrap(summary(all, allowed: true, at: deadline).deadlineNote)
            .contains("Other selected feeds are not server-blocked"), "Expired deadlines do not block admission")
        XCTAssertNil(summary(all, allowed: true, at: deadline.addingTimeInterval(60)).deadlineNote)
        XCTAssertEqual(subset.feeds[0].retryNotBefore, deadline, "Projection cannot alter server policy")
    }

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
