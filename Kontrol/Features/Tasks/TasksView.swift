import SwiftUI

/// Presentation shared by Tasks and Today's Next section. Membership and ordering
/// come exclusively from TaskSelection, not from row display metadata.
struct TaskRows: View {
    let rows: [TaskSnapshot]
    let temporalContext: TaskTemporalContext
    var onEdit: ((TaskSnapshot) -> Void)? = nil
    var onSetCompleted: ((TaskSnapshot, Bool) -> Void)? = nil
    var onDelete: ((TaskSnapshot) -> Void)? = nil
    var editFocus: FocusState<UUID?>.Binding? = nil

    private var dateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        style.calendar = temporalContext.calendar
        style.timeZone = temporalContext.timeZone
        return style
    }

    private var timeStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.calendar = temporalContext.calendar
        style.timeZone = temporalContext.timeZone
        return style
    }

    private func metadata(for task: TaskSnapshot) -> String {
        var parts: [String] = []
        var pastPlan = false
        if let completed = task.completedAt {
            parts.append("Completed \(completed.formatted(dateStyle)) at \(completed.formatted(timeStyle))")
        }
        if let due = task.dueAt {
            let prefix = task.completedAt == nil && due < temporalContext.now ? "Overdue · Due" : "Due"
            parts.append("\(prefix) \(due.formatted(dateStyle)) at \(due.formatted(timeStyle))")
        }
        if let plan = task.plannedDay {
            let components = plan
            // Compare the selected local date in the saved plan's calendar, just as
            // TaskSelection does. The saved zone describes where the plan was chosen;
            // it is not a midnight instant or the zone for today's selection.
            let identifiers: [Calendar.Identifier] = [
                .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
                .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
                .islamicCivil, .japanese, .persian, .republicOfChina,
                .islamicTabular, .islamicUmmAlQura
            ]
            let selectedDay: DateComponents? = identifiers.first {
                String(describing: $0) == components.calendarIdentifier
            }.map { identifier in
                var calendar = Calendar(identifier: identifier)
                calendar.timeZone = temporalContext.timeZone
                return calendar.dateComponents([.year, .month, .day], from: temporalContext.now)
            }
            let planned = [components.year, components.month, components.day]
            let current = selectedDay.map { [$0.year ?? 0, $0.month ?? 0, $0.day ?? 0] }
            pastPlan = current.map { planned.lexicographicallyPrecedes($0) } ?? false
            let label: String
            if current == planned {
                label = "Today"
            } else {
                label = "\(pastPlan ? "(past)" : "for") \(components.year)-\(String(format: "%02d", components.month))-\(String(format: "%02d", components.day))"
            }
            parts.append("Planned \(label) (\(plan.calendarIdentifier), \(task.plannedTimeZoneID ?? "unknown zone"))")
        }
        if task.completedAt == nil && task.dueAt == nil && (task.plannedDay == nil || pastPlan) {
            parts.append("Unscheduled")
        }
        return parts.joined(separator: " · ")
    }

    private func editButton(for row: TaskSnapshot, action: @escaping (TaskSnapshot) -> Void) -> some View {
        ActionButton("Edit", action: { action(row) })
            .accessibilityLabel("Edit \(row.title)")
            .accessibilityIdentifier("task-edit-\(row.id.uuidString)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .center, spacing: AppMetrics.space3) {
                    AppListRow(row.title, metadata: metadata(for: row),
                               status: row.isCompleted ? StatusPill("Completed", kind: .success) : nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("task-row-\(row.id.uuidString)")
                    // The read-only row and its controls are independent AX children.
                    // Never combine an ancestor containing buttons into one element.
                    VStack(spacing: AppMetrics.space2) {
                        if let onSetCompleted {
                            ActionButton(row.isCompleted ? "Reopen" : "Complete") {
                                onSetCompleted(row, !row.isCompleted)
                            }
                            .accessibilityLabel("\(row.isCompleted ? "Reopen" : "Complete") \(row.title)")
                            .accessibilityIdentifier("task-\(row.isCompleted ? "reopen" : "complete")-\(row.id.uuidString)")
                        }
                        if let onEdit {
                            if let editFocus {
                                editButton(for: row, action: onEdit)
                                    .focused(editFocus, equals: row.id)
                            } else {
                                editButton(for: row, action: onEdit)
                            }
                        }
                        if let onDelete {
                            ActionButton("Delete", action: { onDelete(row) })
                                .accessibilityLabel("Delete \(row.title)")
                                .accessibilityIdentifier("task-delete-\(row.id.uuidString)")
                        }
                    }
                }
            }
        }
    }
}

/// Both routes observe the same app-owned snapshots. Filter changes never write records.
struct TasksView: View {
    @ObservedObject var store: TaskStore
    @State private var filter: TaskFilter = .today
    @State private var presentation: EditorPresentation?
    @State private var editorOpenError = false
    @State private var actionError: TaskMutationError?
    @State private var lastEditorTriggerID: UUID?
    @State private var pendingDeletion: PendingDeletion?
    @State private var isDeletePresented = false
    @FocusState private var addFocused: Bool
    @FocusState private var editFocusedID: UUID?

    /// Own the draft at the moment of opening, not during a subsequent body redraw.
    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let draft: TaskEditorDraft
    }

    /// A frozen identity/copy of the displayed name, independent of filter changes
    /// and subsequent store refreshes. Never look up a different visible row to delete.
    private struct PendingDeletion {
        let id: UUID
        let title: String
    }

    private func confirmDelete(_ selection: PendingDeletion) {
        pendingDeletion = nil
        do {
            try store.delete(id: selection.id)
            actionError = nil
        } catch {
            actionError = store.mutationError ?? .writeFailed
        }
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

    private func title(_ filter: TaskFilter) -> String {
        switch filter {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .completed: "Completed"
        }
    }

    private var emptyGuidance: (String, String) {
        switch filter {
        case .today:
            return ("Nothing planned or due today.", "Check Upcoming for other open tasks, or use Add task.")
        case .upcoming:
            return ("No upcoming tasks.", "All other open tasks, including unscheduled tasks, appear here. Use Add task to capture one.")
        case .completed:
            return ("No completed tasks yet.", "Completed tasks will appear here after you finish one.")
        }
    }

    var body: some View {
        let selectedDeletion = pendingDeletion
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Tasks") {
                ActionButton("Add task", symbol: "plus", variant: .primary) {
                    presentation = EditorPresentation(draft: TaskEditorDraft(creatingIn: store))
                    editorOpenError = false
                }
                .accessibilityIdentifier("tasks-add-task")
                .focused($addFocused)
            }
            HStack(spacing: AppMetrics.space2) {
                ForEach([TaskFilter.today, .upcoming, .completed], id: \.self) { option in
                    let label = title(option)
                    ActionButton("\(label) (\(store.select(option).count))", variant: filter == option ? .primary : .secondary) {
                        filter = option
                    }
                    .accessibilityIdentifier("tasks-filter-\(label.lowercased())")
                    .accessibilityLabel("\(label), \(store.select(option).count) tasks")
                    .accessibilityValue(filter == option ? "Selected" : "Not selected")
                }
            }
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
                        .accessibilityIdentifier("tasks-action-error")
                    Text("\(actionError.message) Use the task action again to retry.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                case .notFound:
                    Text("This task is no longer available. Refresh the list or choose another task.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.error)
                        .accessibilityIdentifier("tasks-action-error")
                    ActionButton("Refresh tasks") {
                        store.retryRead()
                        self.actionError = nil
                    }
                    .accessibilityIdentifier("tasks-action-refresh")
                }
            }
            if let message = store.readState.message {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: store.retryRead)
                Text(message)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            SectionHeader(title(filter), metadata: "\(store.select(filter).count) tasks")
            let selected = store.select(filter)
            if store.readState == .loaded && selected.isEmpty {
                EmptyState(emptyGuidance.0, guidance: emptyGuidance.1)
            } else if !selected.isEmpty {
                ScrollView {
                    TaskRows(rows: selected, temporalContext: store.temporalContext, onEdit: { row in
                        lastEditorTriggerID = row.id
                        edit(row)
                    }, onSetCompleted: setCompleted, onDelete: { row in
                        pendingDeletion = PendingDeletion(id: row.id, title: row.title)
                        isDeletePresented = true
                    }, editFocus: $editFocusedID)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear { store.refresh() }
        .confirmationAffordance(isPresented: $isDeletePresented,
                               title: "Delete \"\(pendingDeletion?.title ?? "task")\"?",
                               message: "This task will be permanently deleted.",
                               confirmTitle: "Delete task", cancelTitle: "Cancel", isDestructive: true,
                               onConfirm: {
            // The alert is modal; its only destructive path is this explicit action.
            // A dismissed or superseded selection must never target another row.
            if let selectedDeletion { confirmDelete(selectedDeletion) }
        })
        .onChange(of: isDeletePresented) { _, presented in
            if !presented { pendingDeletion = nil }
        }
        .sheet(item: $presentation, onDismiss: {
            if let id = lastEditorTriggerID, store.select(filter).contains(where: { $0.id == id }) {
                editFocusedID = id
            } else {
                addFocused = true
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
}
