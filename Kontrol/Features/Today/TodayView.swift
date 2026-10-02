import SwiftUI

struct TodayView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var scheduleStore: ScheduleStore
    var learningStore: LearningCatalogStore? = nil
    var navigation: NavigationStore? = nil
    @State private var daySelection = TodayDaySelection()
    @State private var showingCapture = false
    @State private var presentation: EditorPresentation?
    @State private var blockPresentation: BlockPresentation?
    @State private var lastBlockTriggerID: UUID?
    @State private var linkedLessonError: (blockID: UUID, title: String, reason: LessonExperienceError)?
    @FocusState private var addBlockFocused: Bool
    @FocusState private var editBlockFocusedID: UUID?
    @State private var editorOpenError = false
    @State private var actionError: TaskMutationError?
    @State private var lastEditorTriggerID: UUID?
    @FocusState private var addTaskFocused: Bool
    @FocusState private var editFocusedID: UUID?

    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let draft: TaskEditorDraft
    }

    private struct BlockPresentation: Identifiable {
        let id = UUID()
        let draft: ScheduleEditorDraft
    }

    /// Only the navigation owner may cross into Projects. Its existing draft-save
    /// barrier decides when to publish the destination; Today never inspects a folder.
    static func openProjectWork(navigation: NavigationStore) {
        navigation.select(.projects)
    }

    /// Recheck the displayed assignment against the latest committed projection.
    /// Flush before opening so a failed save creates neither an attempt nor a route.
    static func startNow(_ suggestion: TodayLessonSelection.Suggestion,
                         learning: LearningCatalogStore, navigation: NavigationStore) throws {
        guard let current = TodayLessonSelection.suggestions(from: learning.state),
              current.contains(suggestion) else { throw LessonExperienceError.staleSlot }
        guard navigation.flushForLifecycle() else {
            throw navigation.saveError ?? LessonExperienceError.persistenceFailure
        }
        let receipt = try learning.openLesson(lessonID: suggestion.id)
        guard receipt.detail.id == suggestion.id else { throw LessonExperienceError.invalidStoredData }
        navigation.enterLesson(id: suggestion.id)
    }

    /// Suggestion identity is checked at the tap, not when the row was rendered.
    /// The temporal clock supplies the real local day; browsing a different day
    /// must not change the lesson's proposed block date.
    static func addToTodayDraft(_ suggestion: TodayLessonSelection.Suggestion,
                                learning: LearningCatalogStore, temporal: TaskTemporalContext,
                                schedule: ScheduleStore) throws -> ScheduleEditorDraft {
        guard let current = TodayLessonSelection.suggestions(from: learning.state),
              current.contains(suggestion) else { throw LessonExperienceError.staleSlot }
        var calendar = temporal.calendar
        calendar.timeZone = temporal.timeZone
        return ScheduleEditorDraft(creatingOn: temporal.now, calendar: calendar,
                                   in: schedule, lesson: suggestion)
    }

    /// The block retains its own identity and title even when choices rotate or the
    /// definition disappears. Reading the exact ID is required before any mutation;
    /// the navigation barrier runs before opening an active lesson.
    static func openLinkedBlock(_ block: ScheduleSnapshot,
                                learning: LearningCatalogStore, navigation: NavigationStore) throws {
        guard let id = block.lessonID, !id.isEmpty else { throw LessonExperienceError.lessonNotFound }
        guard navigation.flushForLifecycle() else {
            throw navigation.saveError ?? LessonExperienceError.persistenceFailure
        }
        let detail = try learning.loadLinkedBlockDetail(lessonID: id)
        guard detail.id == id else { throw LessonExperienceError.invalidStoredData }
        switch detail.progress?.status ?? .available {
        case .completed, .dismissed:
            // Never resume terminal work. The pinned/archived content is read-only.
            guard detail.content != .unavailable else { throw LessonExperienceError.contentUnavailable }
        case .available, .started:
            switch detail.content {
            case .current, .pinned: break
            case .legacyCompleted, .unavailable: throw LessonExperienceError.contentUnavailable
            }
            let receipt = try learning.openLesson(lessonID: id)
            guard receipt.detail.id == id else { throw LessonExperienceError.invalidStoredData }
        }
        navigation.enterLesson(id: id)
    }

    private func editBlock(_ block: ScheduleSnapshot) {
        lastBlockTriggerID = block.id
        blockPresentation = BlockPresentation(draft: ScheduleEditorDraft(editing: block, in: scheduleStore))
    }

    private func addBlock() {
        guard let selectedDate else { return }
        lastBlockTriggerID = nil
        var calendar = store.temporalContext.calendar
        calendar.timeZone = store.temporalContext.timeZone
        blockPresentation = BlockPresentation(draft: ScheduleEditorDraft(
            creatingOn: selectedDate, calendar: calendar, in: scheduleStore))
    }

    private func edit(_ row: TaskSnapshot) {
        do {
            presentation = EditorPresentation(draft: try TaskEditorDraft(editing: row, in: store))
            editorOpenError = false
        } catch {
            editorOpenError = true
            store.refresh()
        }
    }

    private func setCompleted(_ row: TaskSnapshot, completed: Bool) {
        do {
            try store.setCompleted(id: row.id, completed: completed)
            actionError = nil
        } catch {
            actionError = store.mutationError ?? .writeFailed
        }
    }

    /// Both sections use the same window-local civil day and the same temporal snapshot.
    /// A failed schedule read remains a failure even when cached rows still intersect the day.
    static func selectedRows(day: TodayDaySelection, tasks: TaskStore,
                             blocks: ScheduleStore) -> (tasks: [TaskSnapshot], blocks: [ScheduleSnapshot])? {
        let context = tasks.temporalContext
        guard let date = day.selectedDate(in: context) else { return nil }
        return (tasks.select(.today, selectedDate: date),
                ScheduleSelection.select(blocks.snapshots, selectedDate: date,
                                         calendar: context.calendar, timeZone: context.timeZone))
    }

    static func showsEmptyBlocks(_ state: ScheduleReadState, rows: [ScheduleSnapshot],
                                 hasSelectedDay: Bool) -> Bool {
        state == .loaded && hasSelectedDay && rows.isEmpty
    }

    private var localDateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
        style.calendar = store.temporalContext.calendar
        style.timeZone = store.temporalContext.timeZone
        return style
    }

    private var blockDateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.calendar = store.temporalContext.calendar
        style.timeZone = store.temporalContext.timeZone
        return style
    }

    private var selectedDate: Date? { daySelection.selectedDate(in: store.temporalContext) }

    /// Compare against the shared complete snapshot, not just rows starting on this day.
    static func overlaps(for block: ScheduleSnapshot, in blocks: [ScheduleSnapshot]) -> [ScheduleConflict] {
        ScheduleSelection.conflicts(for: ScheduleInput(title: block.title, startAt: block.startAt,
                                                       endAt: block.endAt, note: block.note),
                                    against: blocks, excluding: block.id)
    }

    private func blockMetadata(_ block: ScheduleSnapshot) -> String {
        let duration = Int(block.endAt.timeIntervalSince(block.startAt) / 60)
        let elapsed: String
        if duration == 0 {
            elapsed = "\(Int(block.endAt.timeIntervalSince(block.startAt))) sec"
        } else if duration >= 60 {
            elapsed = "\(duration / 60) hr \(duration % 60) min"
        } else {
            elapsed = "\(duration) min"
        }
        return "\(block.startAt.formatted(blockDateStyle)) – \(block.endAt.formatted(blockDateStyle)) · \(elapsed)"
    }

    var body: some View {
        let rows = Self.selectedRows(day: daySelection, tasks: store, blocks: scheduleStore)
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Today", metadata: selectedDate?.formatted(localDateStyle) ?? "Date unavailable")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space2) { dayActions; addActions }
                VStack(alignment: .leading, spacing: AppMetrics.space2) { dayActions; addActions }
            }
            if let learningStore, let navigation {
                TodayLessonSection(learningStore: learningStore, navigation: navigation,
                                   temporalStore: store, scheduleStore: scheduleStore,
                                   onAddToToday: { draft in
                    lastBlockTriggerID = nil
                    blockPresentation = BlockPresentation(draft: draft)
                })
            }
            if let navigation {
                VStack(alignment: .leading, spacing: AppMetrics.space2) {
                    SectionHeader("Project work")
                    Text("Continue in your project workspace.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                    ActionButton("Next features", symbol: "arrow.right", variant: .primary) {
                        Self.openProjectWork(navigation: navigation)
                    }
                    .accessibilityLabel("Open Project work in Projects")
                    .accessibilityIdentifier("today-project-work")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppMetrics.space8) {
                    scheduleSection(rows?.blocks ?? []).frame(minWidth: 280, maxWidth: .infinity)
                    taskSection(rows?.tasks ?? []).frame(minWidth: 280, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: AppMetrics.space6) {
                    scheduleSection(rows?.blocks ?? [])
                    taskSection(rows?.tasks ?? [])
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear {
            store.refresh()
            scheduleStore.refresh()
            learningStore?.loadIfNeeded()
        }
        .sheet(item: $blockPresentation, onDismiss: {
            if let id = lastBlockTriggerID,
               let blocks = Self.selectedRows(day: daySelection, tasks: store, blocks: scheduleStore)?.blocks,
               blocks.contains(where: { $0.id == id }) {
                editBlockFocusedID = id
            } else {
                addBlockFocused = true
            }
            lastBlockTriggerID = nil
        }) { item in
            ScheduleEditorView(draft: item.draft, temporalStore: store, onCancel: {
                blockPresentation = nil
            }, onSaved: {
                blockPresentation = nil
            }, onDeleted: {
                blockPresentation = nil
            }, onMissingBlock: {
                item.draft.cancel()
                blockPresentation = nil
            })
        }
        .sheet(isPresented: $showingCapture, onDismiss: {
            // Wait for the native sheet to finish closing before returning keyboard focus.
            addTaskFocused = true
        }) {
            QuickCaptureView(store: store, onCancel: {
                showingCapture = false
            }, onSaved: {
                showingCapture = false
            })
        }
        .sheet(item: $presentation, onDismiss: {
            if let id = lastEditorTriggerID,
               let date = selectedDate,
               store.select(.today, selectedDate: date).contains(where: { $0.id == id }) {
                editFocusedID = id
            } else {
                addTaskFocused = true
            }
            lastEditorTriggerID = nil
        }) { item in
            TaskEditorView(draft: item.draft, onCancel: {
                presentation = nil
            }, onSaved: {
                presentation = nil
            }, onMissingTask: {
                presentation = nil
            })
        }
    }

    private var dayActions: some View {
        HStack(spacing: AppMetrics.space2) {
            ActionButton("Previous day") { daySelection.previous(in: store.temporalContext) }
                .accessibilityIdentifier("today-previous-day")
            ActionButton("Next day") { daySelection.next(in: store.temporalContext) }
                .accessibilityIdentifier("today-next-day")
            if !daySelection.followsToday {
                ActionButton("Today") { daySelection.returnToToday() }
                    .accessibilityIdentifier("today-return-to-today")
            }
        }
    }

    private var addActions: some View {
        HStack(spacing: AppMetrics.space2) {
            ActionButton("Add task", symbol: "plus", variant: .primary) {
                // Quick capture always defaults to relative Today, not the browsed day.
                showingCapture = true
            }
            .accessibilityIdentifier("today-add-task")
            .focused($addTaskFocused)
            ActionButton("Add block", symbol: "plus", isEnabled: selectedDate != nil, action: addBlock)
                .accessibilityIdentifier("today-add-block")
                .focused($addBlockFocused)
        }
    }

    private func taskSection(_ tasks: [TaskSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            SectionHeader("Tasks")
            if editorOpenError {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: {
                    editorOpenError = false
                    store.retryRead()
                })
                Text("Could not open this task. Refresh the list and try again.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if let actionError {
                switch actionError {
                case .writeFailed:
                    ErrorBanner(.saveFailed)
                        .accessibilityIdentifier("today-action-error")
                    Text("\(actionError.message) Use the task action again to retry.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                case .notFound:
                    Text("This task is no longer available. Refresh the list or choose another task.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.error)
                        .accessibilityIdentifier("today-action-error")
                    ActionButton("Refresh tasks") {
                        store.retryRead()
                        self.actionError = nil
                    }
                    .accessibilityIdentifier("today-action-refresh")
                }
            }
            if let message = store.readState.message {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: store.retryRead)
                Text(message)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if store.readState == .loaded && selectedDate != nil && tasks.isEmpty {
                EmptyState("No tasks planned or due on this day.", guidance: "Use Add task to capture one.")
            } else if !tasks.isEmpty {
                TaskRows(rows: tasks, temporalContext: store.temporalContext, onEdit: { row in
                    lastEditorTriggerID = row.id
                    edit(row)
                }, onSetCompleted: setCompleted, editFocus: $editFocusedID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scheduleSection(_ blocks: [ScheduleSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            SectionHeader("Schedule")
            if let message = scheduleStore.readState.message {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: scheduleStore.retryRead)
                    .accessibilityIdentifier("today-schedule-error")
                Text(message)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if let error = linkedLessonError, blocks.contains(where: { $0.id == error.blockID }) {
                let unavailable = error.reason == .lessonNotFound || error.reason == .contentUnavailable ||
                    error.reason == .invalidStoredData
                Text("Could not open \(error.title). " + (unavailable
                     ? "Lesson content is unavailable; the block is unchanged. You can still edit this block or open another lesson."
                     : "Your block and location are unchanged. Retry Open lesson after resolving the read or save error."))
                    .appTypography(.body)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("schedule-lesson-error-\(error.blockID.uuidString)")
                if let learningStore, case .failed(let id, _) = learningStore.detailState,
                   blocks.contains(where: { $0.id == error.blockID && $0.lessonID == id }) {
                    ActionButton("Retry lesson read") {
                        _ = try? learningStore.retryDetail(lessonID: id)
                    }
                    .accessibilityIdentifier("schedule-lesson-retry-\(error.blockID.uuidString)")
                }
            }
            if Self.showsEmptyBlocks(scheduleStore.readState, rows: blocks,
                                     hasSelectedDay: selectedDate != nil) {
                EmptyState("No blocks on this day.", guidance: "Use Add block to plan a time.")
            } else {
                ForEach(blocks) { block in
                    let conflicts = Self.overlaps(for: block, in: scheduleStore.snapshots)
                    HStack(spacing: AppMetrics.space3) {
                        VStack(alignment: .leading, spacing: AppMetrics.space2) {
                            AppListRow(block.title, metadata: blockMetadata(block))
                            if block.lessonID != nil {
                                Text("Linked lesson · \(block.linkedTitleSnapshot ?? "Title unavailable")")
                                    .appTypography(.metadata)
                                    .foregroundStyle(AppColors.textSecondary)
                                    .accessibilityIdentifier("schedule-lesson-title-\(block.id.uuidString)")
                            }
                            if !conflicts.isEmpty {
                                Label("Overlaps \(conflicts.count) block\(conflicts.count == 1 ? "" : "s")",
                                      systemImage: "exclamationmark.triangle")
                                    .appTypography(.metadata)
                                    .foregroundStyle(AppColors.error)
                                    .accessibilityIdentifier("schedule-overlap-\(block.id.uuidString)")
                            }
                        }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("schedule-row-\(block.id.uuidString)")
                        if block.lessonID != nil, let learningStore, let navigation {
                            ActionButton("Open lesson") {
                                do {
                                    try Self.openLinkedBlock(block, learning: learningStore, navigation: navigation)
                                    linkedLessonError = nil
                                } catch {
                                    linkedLessonError = (block.id, block.linkedTitleSnapshot ?? block.title,
                                                         (error as? LessonExperienceError) ?? .persistenceFailure)
                                }
                            }
                            .accessibilityLabel("Open linked lesson: \(block.linkedTitleSnapshot ?? block.title)")
                            .accessibilityIdentifier("schedule-open-lesson-\(block.id.uuidString)")
                        }
                        ActionButton("Edit") { editBlock(block) }
                            .accessibilityLabel("Edit \(block.title)")
                            .accessibilityIdentifier("schedule-edit-\(block.id.uuidString)")
                            .focused($editBlockFocusedID, equals: block.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Only the shell's Today view observes the shared Learning publication. Standalone
/// task/schedule previews can continue to render without a second catalog owner.
private struct TodayLessonSection: View {
    @ObservedObject var learningStore: LearningCatalogStore
    let navigation: NavigationStore
    @ObservedObject var temporalStore: TaskStore
    @ObservedObject var scheduleStore: ScheduleStore
    let onAddToToday: (ScheduleEditorDraft) -> Void
    @State private var lessonError: LessonExperienceError?
    @State private var scheduleError: LessonExperienceError?

    private var canStart: Bool {
        guard learningStore.state.isAuthoritative else { return false }
        if case .failed = learningStore.detailState { return false }
        if case .failed = learningStore.historyState { return false }
        return true // A failed write may be retried; only failed reads block entry.
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            SectionHeader("Learning", metadata: "Suggestions for any day")
            if lessonError != nil {
                ErrorBanner(.saveFailed)
                Text("Could not start the lesson. Your work and location are retained. Retry Start now after resolving the error.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if scheduleError != nil {
                ErrorBanner(.readFailed)
                Text("Could not prepare this lesson block. Refresh learning choices and try Add to Today again.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if case .failed = learningStore.state {
                ErrorBanner(.readFailed, recoveryTitle: "Retry learning choices", recovery: learningStore.retry)
                Text("Learning suggestions are unavailable until the catalog read succeeds.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if case .failed(let id, _) = learningStore.detailState {
                ErrorBanner(.readFailed, recoveryTitle: "Retry lesson read") {
                    _ = try? learningStore.retryDetail(lessonID: id)
                }
            }
            if case .failed = learningStore.historyState {
                ErrorBanner(.readFailed, recoveryTitle: "Retry History read") {
                    _ = try? learningStore.retryHistory()
                }
            }
            if let suggestions = TodayLessonSelection.suggestions(from: learningStore.state) {
                if suggestions.isEmpty {
                    EmptyState("No lessons to suggest right now.", guidance: "Browse Learning or History for more.")
                }
                ForEach(suggestions) { suggestion in
                    HStack(spacing: AppMetrics.space4) {
                        AppListRow(suggestion.lesson.title,
                                   metadata: "\(suggestion.started ? "Started" : "Available") · \(suggestion.lesson.estimatedMinutes) min · \(suggestion.lesson.format.capitalized)")
                        Spacer(minLength: 0)
                        ActionButton("Start now", isEnabled: canStart) {
                            do {
                                try TodayView.startNow(suggestion, learning: learningStore, navigation: navigation)
                                lessonError = nil
                            } catch {
                                lessonError = (error as? LessonExperienceError) ?? .persistenceFailure
                            }
                        }
                        .accessibilityLabel("Start now: \(suggestion.lesson.title)")
                        .accessibilityIdentifier("today-start-\(suggestion.id)")
                        ActionButton("Add to Today", isEnabled: learningStore.state.isAuthoritative) {
                            do {
                                let draft = try TodayView.addToTodayDraft(
                                    suggestion, learning: learningStore,
                                    temporal: temporalStore.temporalContext, schedule: scheduleStore)
                                scheduleError = nil
                                onAddToToday(draft)
                            } catch {
                                scheduleError = (error as? LessonExperienceError) ?? .persistenceFailure
                            }
                        }
                        .accessibilityLabel("Add to Today: \(suggestion.lesson.title)")
                        .accessibilityIdentifier("today-add-lesson-\(suggestion.id)")
                    }
                }
            } else if case .notLoaded = learningStore.state {
                LoadingState("Loading learning suggestions")
            } else if case .loading = learningStore.state {
                LoadingState("Loading learning suggestions")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
