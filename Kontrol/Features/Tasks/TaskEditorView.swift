import SwiftUI

/// A native, sheet-local editor. The header and actions never scroll with long notes.
struct TaskEditorView: View {
    @StateObject private var draft: TaskEditorDraft
    @State private var dueDate: Date
    @State private var planDate: Date
    let onCancel: () -> Void
    let onSaved: () -> Void
    let onMissingTask: () -> Void
    @FocusState private var titleFocused: Bool

    init(draft: TaskEditorDraft, onCancel: @escaping () -> Void,
         onSaved: @escaping () -> Void, onMissingTask: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: draft)
        _dueDate = State(initialValue: draft.dueAt ?? .now)
        _planDate = State(initialValue: Self.displayDate(for: draft.plannedFor) ?? .now)
        self.onCancel = onCancel
        self.onSaved = onSaved
        self.onMissingTask = onMissingTask
    }

    private static func displayDate(for plan: PlannedDay?) -> Date? {
        guard let plan else { return nil }
        // Keep the stored calendar components intact when opening an editor after travel.
        let identifiers: [Calendar.Identifier] = [
            .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
            .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
            .islamicCivil, .japanese, .persian, .republicOfChina,
            .islamicTabular, .islamicUmmAlQura
        ]
        guard let identifier = identifiers.first(where: { String(describing: $0) == plan.components.calendarIdentifier }) else {
            return nil
        }
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = .current
        let day = plan.components
        return calendar.date(from: DateComponents(year: day.year, month: day.month,
                                                   day: day.day, hour: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text(draft.editingID == nil ? "New task" : "Edit task")
                .appTypography(.dialog)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.space4) {
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Title")
                        TextField("Title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                            .accessibilityIdentifier("task-editor-title")
                        if draft.invalidFields.contains(.title) {
                            Text("Enter a title.")
                                .foregroundStyle(AppColors.error)
                                .accessibilityIdentifier("task-editor-title-error")
                        }
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Toggle("Due", isOn: Binding(
                            get: { draft.dueAt != nil },
                            set: { draft.dueAt = $0 ? dueDate : nil }))
                            .accessibilityIdentifier("task-editor-due")
                        if draft.dueAt != nil {
                            DatePicker("Due date and time", selection: Binding(
                                get: { draft.dueAt ?? dueDate },
                                set: { dueDate = $0; draft.dueAt = $0 }),
                                displayedComponents: [.date, .hourAndMinute])
                                .accessibilityIdentifier("task-editor-due-date")
                        }
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Toggle("Plan for", isOn: Binding(
                            get: { draft.plannedFor != nil },
                            set: { enabled in
                                if enabled {
                                    planDate = .now
                                    draft.selectPlannedDate(planDate, calendar: .current, timeZone: .current)
                                } else {
                                    draft.plannedFor = nil
                                }
                            }))
                            .accessibilityIdentifier("task-editor-plan")
                        if draft.plannedFor != nil {
                            DatePicker("Plan date", selection: Binding(
                                get: { Self.displayDate(for: draft.plannedFor) ?? planDate },
                                set: {
                                    planDate = $0
                                    draft.selectPlannedDate($0, calendar: .current, timeZone: .current)
                                }), displayedComponents: .date)
                                .accessibilityIdentifier("task-editor-plan-date")
                        }
                        if draft.invalidFields.contains(.plan) {
                            Text("Choose a valid plan date.")
                                .foregroundStyle(AppColors.error)
                                .accessibilityIdentifier("task-editor-plan-error")
                        }
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Notes")
                        TextEditor(text: $draft.notes)
                            .frame(minHeight: 110)
                            .accessibilityLabel("Notes")
                            .accessibilityIdentifier("task-editor-notes")
                    }
                    if let error = draft.saveError {
                        ErrorBanner(.saveFailed)
                            .accessibilityIdentifier("task-editor-error")
                        Text(error == .notFound
                             ? "This task is no longer available. Close the editor to see the refreshed list."
                             : "Your fields are still here; try saving again.")
                            .appTypography(.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                        if error == .notFound {
                            ActionButton("Close editor", action: onMissingTask)
                                .accessibilityIdentifier("task-editor-close-missing")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appTypography(.body)
            }
            .frame(maxHeight: 400)
            HStack(spacing: AppMetrics.space3) {
                ActionButton("Cancel", action: {
                    draft.cancel()
                    onCancel()
                })
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("task-editor-cancel")
                ActionButton(draft.editingID == nil ? "Add" : "Save", variant: .primary,
                             isEnabled: draft.canSubmit && draft.saveError != .notFound) {
                    draft.submit { _ in onSaved() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("task-editor-submit")
            }
        }
        .padding(AppMetrics.contentInset)
        .frame(width: 600, height: 560)
        .background(AppColors.surface)
        .foregroundStyle(AppColors.textPrimary)
        .onAppear { titleFocused = true }
    }
}
