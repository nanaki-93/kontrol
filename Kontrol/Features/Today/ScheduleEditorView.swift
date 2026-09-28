import SwiftUI

/// The draft owns the instants. DatePicker bindings write only user-selected instants;
/// formatting and temporal updates never convert a local wall time back into storage.
struct ScheduleEditorView: View {
    @StateObject private var draft: ScheduleEditorDraft
    @ObservedObject var temporalStore: TaskStore
    let onCancel: () -> Void
    let onSaved: () -> Void
    let onMissingBlock: () -> Void
    @Environment(\.locale) private var locale
    @FocusState private var titleFocused: Bool

    init(draft: ScheduleEditorDraft, temporalStore: TaskStore,
         onCancel: @escaping () -> Void, onSaved: @escaping () -> Void,
         onMissingBlock: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: draft)
        self.temporalStore = temporalStore
        self.onCancel = onCancel
        self.onSaved = onSaved
        self.onMissingBlock = onMissingBlock
    }

    /// The offset disambiguates both occurrences of a repeated fall-back hour.
    /// The full date also exposes overnight/multi-day ranges and picker normalization.
    static func endpointLabel(_ date: Date, calendar: Calendar, timeZone: TimeZone,
                              locale: Locale) -> String {
        let formatter = DateFormatter()
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        formatter.calendar = localCalendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let seconds = timeZone.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+",
                            minutes / 60, minutes % 60)
        return "\(formatter.string(from: date)) · \(timeZone.abbreviation(for: date) ?? timeZone.identifier) (\(offset))"
    }

    private func endpoint(_ date: Date) -> String {
        let context = temporalStore.temporalContext
        return Self.endpointLabel(date, calendar: context.calendar,
                                  timeZone: context.timeZone, locale: locale)
    }

    var body: some View {
        let context = temporalStore.temporalContext
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text(draft.editingID == nil ? "New block" : "Edit block")
                .appTypography(.dialog)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.space4) {
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Title")
                        TextField("Title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                            .accessibilityIdentifier("schedule-editor-title")
                        if draft.invalidFields.contains(.title) {
                            Text("Enter a title.")
                                .foregroundStyle(AppColors.error)
                                .accessibilityIdentifier("schedule-editor-title-error")
                        }
                    }
                    endpointField("Start date and time", selection: $draft.startAt,
                                  invalid: draft.invalidFields.contains(.start),
                                  guidance: "Choose a valid start date and time.", id: "start")
                    endpointField("End date and time", selection: $draft.endAt,
                                  invalid: draft.invalidFields.contains(.end),
                                  guidance: "End must be after Start.", id: "end")
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Note (optional)")
                        TextEditor(text: $draft.note)
                            .frame(minHeight: 90)
                            .accessibilityLabel("Note (optional)")
                            .accessibilityIdentifier("schedule-editor-note")
                    }
                    if draft.overlapReview != nil {
                        Text("This time overlaps another block. Adjust the times to save without an overlap.")
                            .appTypography(.metadata)
                            .foregroundStyle(AppColors.error)
                            .accessibilityIdentifier("schedule-editor-overlap")
                    }
                    if let error = draft.saveError {
                        ErrorBanner(.saveFailed)
                            .accessibilityIdentifier("schedule-editor-error")
                        Text(error == .notFound
                             ? "This block is no longer available. Close the editor to see the refreshed list."
                             : "Your fields are still here; try saving again.")
                            .appTypography(.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                        if error == .notFound {
                            ActionButton("Close editor", action: onMissingBlock)
                                .accessibilityIdentifier("schedule-editor-close-missing")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appTypography(.body)
            }
            .frame(maxHeight: 440)
            HStack(spacing: AppMetrics.space3) {
                ActionButton("Cancel") {
                    draft.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("schedule-editor-cancel")
                ActionButton("Save", variant: .primary,
                             isEnabled: draft.canSubmit && draft.saveError != .notFound) {
                    draft.submit { _ in onSaved() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("schedule-editor-submit")
            }
        }
        .padding(AppMetrics.contentInset)
        .frame(minWidth: 380, idealWidth: 600, maxWidth: 600, minHeight: 480, idealHeight: 600)
        .background(AppColors.surface)
        .foregroundStyle(AppColors.textPrimary)
        .environment(\.calendar, pickerCalendar)
        .environment(\.timeZone, context.timeZone)
        .onAppear { titleFocused = true }
    }

    private var pickerCalendar: Calendar {
        var calendar = temporalStore.temporalContext.calendar
        calendar.timeZone = temporalStore.temporalContext.timeZone
        return calendar
    }

    private func endpointField(_ label: String, selection: Binding<Date>, invalid: Bool,
                               guidance: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            DatePicker(label, selection: selection, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier("schedule-editor-\(id)")
            // This reflects the picker's actual Date, not an uncommitted typed wall time.
            Text(endpoint(selection.wrappedValue))
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("schedule-editor-\(id)-local")
            if invalid {
                Text(guidance)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.error)
                    .accessibilityIdentifier("schedule-editor-\(id)-error")
            }
        }
    }
}
