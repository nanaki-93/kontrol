import SwiftUI

struct TodayView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var scheduleStore: ScheduleStore
    @State private var daySelection = TodayDaySelection()
    @State private var showingCapture = false
    @State private var presentation: EditorPresentation?
    @State private var editorOpenError = false
    @State private var actionError: TaskMutationError?
    @State private var lastEditorTriggerID: UUID?
    @FocusState private var addTaskFocused: Bool
    @FocusState private var editFocusedID: UUID?

    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let draft: TaskEditorDraft
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
            // The block editor is wired in Step 3.2. Do not offer a no-op save.
            ActionButton("Add block", symbol: "plus", isEnabled: false, action: {})
                .accessibilityIdentifier("today-add-block")
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
            if Self.showsEmptyBlocks(scheduleStore.readState, rows: blocks,
                                     hasSelectedDay: selectedDate != nil) {
                EmptyState("No blocks on this day.", guidance: "Use Add block to plan a time.")
            } else {
                ForEach(blocks) { block in
                    AppListRow(block.title, metadata: blockMetadata(block))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("schedule-row-\(block.id.uuidString)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
