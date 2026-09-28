import SwiftUI

/// The draft owns the instants. DatePicker bindings write only user-selected instants;
/// formatting and temporal updates never convert a local wall time back into storage.
struct ScheduleEditorView: View {
    @StateObject private var draft: ScheduleEditorDraft
    @ObservedObject var temporalStore: TaskStore
    let onCancel: () -> Void
    let onSaved: () -> Void
    let onDeleted: () -> Void
    let onMissingBlock: () -> Void
    @Environment(\.locale) private var locale
    @FocusState private var titleFocused: Bool

    init(draft: ScheduleEditorDraft, temporalStore: TaskStore,
         onCancel: @escaping () -> Void, onSaved: @escaping () -> Void,
         onDeleted: @escaping () -> Void, onMissingBlock: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: draft)
        self.temporalStore = temporalStore
        self.onCancel = onCancel
        self.onSaved = onSaved
        self.onDeleted = onDeleted
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

    static func overlapDurationLabel(_ duration: TimeInterval) -> String {
        guard duration >= 1, duration < Double(Int.max), duration.rounded(.down) == duration else {
            return "\(duration.formatted(.number.precision(.fractionLength(0...3)))) sec"
        }
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds) sec" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return ([hours > 0 ? "\(hours) hr" : nil, minutes > 0 ? "\(minutes) min" : nil,
                 remainder > 0 ? "\(remainder) sec" : nil].compactMap { $0 }).joined(separator: " ")
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
            if let review = draft.overlapReview {
                overlapDecision(review)
            } else {
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
            }
            if let deleteError = draft.deleteError {
                ErrorBanner(.saveFailed)
                    .accessibilityIdentifier("schedule-editor-delete-error")
                Text(deleteError == .notFound
                     ? "This block is no longer available. The list has been refreshed; close the editor."
                     : "The block and your edits are still here. Try deleting again or close the editor.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                if deleteError == .notFound {
                    ActionButton("Close editor", action: onMissingBlock)
                        .accessibilityIdentifier("schedule-editor-delete-close-missing")
                } else {
                    ActionButton("Try deleting again") { draft.requestDeletion() }
                        .accessibilityIdentifier("schedule-editor-delete-retry")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space3) { decisionActions }
                VStack(alignment: .leading, spacing: AppMetrics.space2) { decisionActions }
            }
        }
        .padding(AppMetrics.contentInset)
        .frame(minWidth: 380, idealWidth: 600, maxWidth: 600, minHeight: 480, idealHeight: 600)
        .background(AppColors.surface)
        .foregroundStyle(AppColors.textPrimary)
        .environment(\.calendar, pickerCalendar)
        .environment(\.timeZone, context.timeZone)
        .onAppear { titleFocused = true }
        .alert("Delete \"\(draft.deletionTitle ?? "block")\"?", isPresented: Binding(
            get: { draft.deletionRequested },
            // SwiftUI may set this false before running the destructive button action.
            // The explicit Cancel action disarms the request instead.
            set: { _ in }
        )) {
            Button("Cancel", role: .cancel) { draft.cancelDeletion() }
            Button("Delete block", role: .destructive) {
                draft.confirmDeletion(onSuccess: onDeleted)
            }
        } message: {
            Text("This removes only this block. This action cannot be undone.")
        }
    }

    @ViewBuilder private var decisionActions: some View {
        if draft.editingID != nil {
            ActionButton("Delete", variant: .destructive, isEnabled: draft.canRequestDeletion) {
                draft.requestDeletion()
            }
            .accessibilityLabel("Delete \(draft.deletionTitle ?? "block")")
            .accessibilityIdentifier("schedule-editor-delete")
        }
        ActionButton("Cancel") {
            if draft.cancel() { onCancel() }
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("schedule-editor-cancel")
        if draft.overlapReview != nil {
            ActionButton("Edit time") { draft.editTime() }
                .accessibilityIdentifier("schedule-editor-edit-time")
            ActionButton("Keep both", variant: .primary, isEnabled: draft.canKeepBoth) {
                draft.keepBoth { _ in onSaved() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("schedule-editor-keep-both")
        } else {
            ActionButton("Save", variant: .primary,
                         isEnabled: draft.canSubmit && draft.saveError != .notFound) {
                draft.submit { _ in onSaved() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("schedule-editor-submit")
        }
    }

    private func overlapDecision(_ review: ScheduleOverlapReview) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space3) {
            Text("Overlapping blocks")
                .appTypography(.dialog)
                .accessibilityAddTraits(.isHeader)
            Text("\(draft.title.trimmingCharacters(in: .whitespacesAndNewlines)) overlaps \(review.conflicts.count) block\(review.conflicts.count == 1 ? "" : "s"). Nothing has changed yet. Review each conflict before keeping both.")
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("schedule-editor-overlap")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppMetrics.space3) {
                    ForEach(review.conflicts, id: \.block.id) { conflict in
                        VStack(alignment: .leading, spacing: AppMetrics.space2) {
                            Text(conflict.block.title).appTypography(.body)
                            Text("\(endpoint(conflict.block.startAt)) – \(endpoint(conflict.block.endAt))")
                                .appTypography(.metadata)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Overlap: \(Self.overlapDurationLabel(conflict.duration))")
                                .appTypography(.metadata)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("schedule-conflict-\(conflict.block.id.uuidString)")
                        Divider()
                    }
                }
            }
            .accessibilityIdentifier("schedule-editor-conflicts")
            if draft.saveError != nil {
                ErrorBanner(.saveFailed)
                Text("Nothing was saved. Review the conflicts and try Keep both again, or edit the time.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .frame(maxHeight: 440, alignment: .topLeading)
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
