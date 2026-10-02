import SwiftUI

/// Pure, read-only projection. A plan is a civil date in its saved calendar;
/// its saved zone is provenance, not a midnight instant in the current zone.
struct TaskRowMetadata {
    enum PlanPosition: Equatable { case today, past, future }
    let dueAt: Date?
    let isOverdue: Bool
    let completedAt: Date?
    let plannedDay: KontrolSchemaV1.PlannedDayComponents?
    let planPosition: PlanPosition?
    let isUnscheduled: Bool
    let provenance: String?

    init(_ task: TaskSnapshot, in context: TaskTemporalContext) {
        dueAt = task.dueAt
        isOverdue = task.completedAt == nil && (task.dueAt.map { $0 < context.now } ?? false)
        completedAt = task.completedAt
        plannedDay = task.plannedDay
        if let plan = task.plannedDay {
            let identifiers: [Calendar.Identifier] = [
                .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
                .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
                .islamicCivil, .japanese, .persian, .republicOfChina,
                .islamicTabular, .islamicUmmAlQura
            ]
            let current = identifiers.first { String(describing: $0) == plan.calendarIdentifier }.map { id -> [Int] in
                var calendar = Calendar(identifier: id)
                calendar.timeZone = context.timeZone
                let date = calendar.dateComponents([.year, .month, .day], from: context.now)
                return [date.year ?? 0, date.month ?? 0, date.day ?? 0]
            }
            let chosen = [plan.year, plan.month, plan.day]
            if let current {
                planPosition = chosen == current ? .today : (chosen.lexicographicallyPrecedes(current) ? .past : .future)
            } else {
                planPosition = nil
            }
            provenance = "Saved plan: \(plan.calendarIdentifier) calendar · \(task.plannedTimeZoneID ?? "unknown zone")"
        } else {
            planPosition = nil
            provenance = nil
        }
        isUnscheduled = task.completedAt == nil && task.dueAt == nil &&
            (task.plannedDay == nil || planPosition == .past)
    }

    func compact(in context: TaskTemporalContext) -> String {
        var dateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        dateStyle.calendar = context.calendar
        dateStyle.timeZone = context.timeZone
        var timeStyle = Date.FormatStyle.dateTime.hour().minute()
        timeStyle.calendar = context.calendar
        timeStyle.timeZone = context.timeZone
        var parts: [String] = []
        if let completedAt {
            parts.append("Completed \(completedAt.formatted(dateStyle)) at \(completedAt.formatted(timeStyle))")
        }
        if let dueAt {
            parts.append("\(isOverdue ? "Overdue · Due" : "Due") \(dueAt.formatted(dateStyle)) at \(dueAt.formatted(timeStyle))")
        }
        if let plannedDay {
            let day = "\(plannedDay.year)-\(String(format: "%02d", plannedDay.month))-\(String(format: "%02d", plannedDay.day))"
            switch planPosition {
            case .today: parts.append("Planned Today")
            case .past: parts.append("Planned (past) \(day)")
            case .future: parts.append("Planned for \(day)")
            case nil: parts.append("Planned \(day)")
            }
        }
        if isUnscheduled { parts.append("Unscheduled") }
        return parts.joined(separator: " · ")
    }
}

/// The modal captures an immutable UUID; filter changes cannot retarget it.
struct TaskDeletionConfirmation: Equatable {
    let id: UUID
    let title: String

    static func confirmedID(captured: Self?, pending: Self?) -> UUID? {
        guard let captured, captured == pending else { return nil }
        return captured.id
    }
}

/// Pure local disclosure state, keyed by persisted identity. Toggling never calls a store.
struct TaskRowDisclosureState {
    private(set) var expandedIDs: Set<UUID> = []

    func contains(_ id: UUID) -> Bool { expandedIDs.contains(id) }
    mutating func toggle(_ id: UUID) {
        if !expandedIDs.insert(id).inserted { expandedIDs.remove(id) }
    }
}

/// Presentation shared by Tasks and Today's Tasks section. Membership and ordering
/// come exclusively from TaskSelection, not from row display metadata.
struct TaskRows: View {
    @State private var disclosures = TaskRowDisclosureState()
    let rows: [TaskSnapshot]
    let temporalContext: TaskTemporalContext
    var onEdit: ((TaskSnapshot) -> Void)? = nil
    var onSetCompleted: ((TaskSnapshot, Bool) -> Void)? = nil
    var onDelete: ((TaskSnapshot) -> Void)? = nil
    var editFocus: FocusState<UUID?>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                let projection = TaskRowMetadata(row, in: temporalContext)
                TaskCompactRow(row: row, metadata: projection.compact(in: temporalContext),
                               provenance: projection.provenance,
                               onEdit: onEdit, onSetCompleted: onSetCompleted, onDelete: onDelete,
                               disclosureFocus: editFocus,
                               isExpanded: disclosures.contains(row.id),
                               toggle: { disclosures.toggle(row.id) })
            }
        }
    }
}

/// Stable ForEach identity also owns each row's independent disclosure state.
private struct TaskCompactRow: View {
    let row: TaskSnapshot
    let metadata: String
    let provenance: String?
    let onEdit: ((TaskSnapshot) -> Void)?
    let onSetCompleted: ((TaskSnapshot, Bool) -> Void)?
    let onDelete: ((TaskSnapshot) -> Void)?
    let disclosureFocus: FocusState<UUID?>.Binding?
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            HStack(alignment: .center, spacing: AppMetrics.space3) {
                AppListRow(row.title, metadata: metadata,
                           status: row.isCompleted ? StatusPill("Completed", kind: .success) : nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task-row-\(row.id.uuidString)")
                // The read-only row and its controls remain independent AX children.
                if let onSetCompleted {
                    ActionButton(row.isCompleted ? "Reopen" : "Complete") {
                        onSetCompleted(row, !row.isCompleted)
                    }
                    .accessibilityLabel("\(row.isCompleted ? "Reopen" : "Complete") \(row.title)")
                    .accessibilityIdentifier("task-\(row.isCompleted ? "reopen" : "complete")-\(row.id.uuidString)")
                }
            }
            if onEdit != nil || onDelete != nil || provenance != nil {
                let disclosure = ActionButton("Details & actions", symbol: isExpanded ? "chevron.down" : "chevron.right") {
                    toggle() // Only local view state; never reads or writes a store.
                }
                .accessibilityLabel("Details & actions for \(row.title)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("task-details-\(row.id.uuidString)")
                if let disclosureFocus {
                    disclosure.focused(disclosureFocus, equals: row.id)
                } else {
                    disclosure
                }
                if isExpanded {
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        if let provenance {
                            Text(provenance)
                                .appTypography(.metadata)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        HStack(spacing: AppMetrics.space2) {
                            if let onEdit {
                                ActionButton("Edit") { onEdit(row) }
                                    .accessibilityLabel("Edit \(row.title)")
                                    .accessibilityIdentifier("task-edit-\(row.id.uuidString)")
                            }
                            if let onDelete {
                                ActionButton("Delete") { onDelete(row) }
                                    .accessibilityLabel("Delete \(row.title)")
                                    .accessibilityIdentifier("task-delete-\(row.id.uuidString)")
                            }
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
    @State private var pendingDeletion: TaskDeletionConfirmation?
    @State private var isDeletePresented = false
    @FocusState private var addFocused: Bool
    @FocusState private var editFocusedID: UUID?
    @State private var lastDeletionTriggerID: UUID?

    /// Own the draft at the moment of opening, not during a subsequent body redraw.
    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let draft: TaskEditorDraft
    }

    private func confirmDelete(_ selection: TaskDeletionConfirmation) {
        guard let id = TaskDeletionConfirmation.confirmedID(captured: selection, pending: pendingDeletion) else { return }
        pendingDeletion = nil
        do {
            try store.delete(id: id)
            actionError = nil
        } catch {
            actionError = store.mutationError ?? .writeFailed
        }
        // The deleted control cannot receive focus. Return to a surviving action,
        // or Add task when the filter is empty. Wait until the native alert closes.
        restoreDeletionFocus(preferred: selection.id)
    }

    private func restoreDeletionFocus(preferred id: UUID) {
        DispatchQueue.main.async {
            let visible = store.select(filter)
            if visible.contains(where: { $0.id == id }) {
                editFocusedID = id
            } else if let survivor = visible.first {
                editFocusedID = survivor.id
            } else {
                addFocused = true
            }
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
                        pendingDeletion = TaskDeletionConfirmation(id: row.id, title: row.title)
                        lastDeletionTriggerID = row.id
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
            if !presented {
                pendingDeletion = nil
                if let id = lastDeletionTriggerID { restoreDeletionFocus(preferred: id) }
                lastDeletionTriggerID = nil
            }
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
