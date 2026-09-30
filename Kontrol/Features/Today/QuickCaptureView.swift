import SwiftUI

/// Sheet-local state: no SwiftData context or draft record exists until Add succeeds.
@MainActor
final class QuickCaptureDraft: ObservableObject {
    @Published var title = "" {
        didSet { errorMessage = nil }
    }
    enum PlanChoice: Hashable { case today, date, unplanned }
    @Published var planChoice: PlanChoice = .today {
        didSet {
            // The first switch to an explicit date starts from the day of selection,
            // not the day the sheet happened to open.
            if planChoice == .date && selectedPlan == nil { plannedDate = clock() }
            errorMessage = nil
        }
    }
    @Published var plannedDate: Date {
        didSet {
            // DatePicker binds a Date, but a plan is a calendar day in the zone
            // where it was selected. Never reinterpret this instant on submission.
            selectedPlan = PlannedDay.today(at: plannedDate, calendar: calendar(), timeZone: timeZone())
            errorMessage = nil
        }
    }
    private(set) var selectedPlan: PlannedDay?
    @Published var hasDueDate = false { didSet { errorMessage = nil } }
    @Published var dueDate: Date { didSet { errorMessage = nil } }
    @Published private(set) var errorMessage: String?
    private let store: TaskStore
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private let timeZone: () -> TimeZone
    private var submitted = false
    private var submitting = false

    init(store: TaskStore, clock: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { .current },
         timeZone: @escaping () -> TimeZone = { .current }) {
        self.store = store
        self.clock = clock
        self.calendar = calendar
        self.timeZone = timeZone
        let initialDate = clock()
        plannedDate = initialDate
        dueDate = initialDate
    }

    /// Project the selected components into the current display zone so travel
    /// does not make the picker appear to select a different calendar day.
    var displayedPlannedDate: Date {
        guard let selectedPlan else { return plannedDate }
        var displayCalendar = calendar()
        displayCalendar.timeZone = timeZone()
        let day = selectedPlan.components
        return displayCalendar.date(from: DateComponents(year: day.year, month: day.month,
                                                         day: day.day, hour: 12)) ?? plannedDate
    }

    var canAdd: Bool {
        !submitted && !submitting && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func add(onSuccess: () -> Void) {
        guard canAdd else { return }
        submitting = true
        defer { submitting = false }
        let plan: PlannedDay?
        switch planChoice {
        case .today: plan = PlannedDay.today(at: clock(), calendar: calendar(), timeZone: timeZone())
        case .date: plan = selectedPlan
        case .unplanned: plan = nil
        }
        do {
            _ = try store.create(input: TaskInput(title: title, dueAt: hasDueDate ? dueDate : nil,
                                                   plannedFor: plan))
            submitted = true
            onSuccess()
        } catch {
            // Do not expose user text, store paths, or raw persistence errors.
            errorMessage = "Could not save the task. Your fields are still here; try again."
        }
    }
}

private struct CaptureContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct QuickCaptureView: View {
    @StateObject private var draft: QuickCaptureDraft
    // An initial estimate avoids opening a one-point sheet before the first measurement.
    @State private var fieldsHeight: CGFloat = 200
    let onCancel: () -> Void
    let onSaved: () -> Void
    @FocusState private var titleFocused: Bool

    init(store: TaskStore, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: QuickCaptureDraft(store: store))
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text("New task")
                .appTypography(.dialog)
                .accessibilityAddTraits(.isHeader)
            // Measure the fields at their natural height, but cap the scroll region so
            // the native sheet can always keep its actions outside the overflow area.
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.space4) {
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Title")
                        TextField("Title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                            .accessibilityIdentifier("quick-capture-title")
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        AppMenuPicker("Plan for", selection: $draft.planChoice, options: [
                            ("Today", .today), ("Choose date", .date), ("Unplanned", .unplanned)
                        ])
                        .accessibilityIdentifier("quick-capture-plan")
                        if draft.planChoice == .date {
                            DatePicker("Plan date", selection: Binding(
                                get: { draft.displayedPlannedDate },
                                set: { draft.plannedDate = $0 }), displayedComponents: .date)
                                .accessibilityIdentifier("quick-capture-plan-date")
                        }
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Toggle("Due", isOn: $draft.hasDueDate)
                            .accessibilityIdentifier("quick-capture-due")
                        if draft.hasDueDate {
                            DatePicker("Due date and time", selection: $draft.dueDate,
                                       displayedComponents: [.date, .hourAndMinute])
                                .accessibilityIdentifier("quick-capture-due-date")
                        }
                    }
                    if draft.errorMessage != nil {
                        ErrorBanner(.saveFailed)
                            .accessibilityIdentifier("quick-capture-error")
                        Text("Your fields are still here; try again.")
                            .appTypography(.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CaptureContentHeightKey.self,
                                               value: geometry.size.height)
                    }
                }
            }
            // Only the fields scroll; the header and native actions stay visible.
            .frame(height: min(fieldsHeight, 400))
            .onPreferenceChange(CaptureContentHeightKey.self) { measured in
                // SwiftUI may emit a transient zero when the native sheet first mounts.
                // Never collapse the only editable field out of the visible scroll area.
                if measured > 0, measured.isFinite { fieldsHeight = measured }
            }
            HStack(spacing: AppMetrics.space3) {
                ActionButton("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("quick-capture-cancel")
                ActionButton("Add", variant: .primary, isEnabled: draft.canAdd) {
                    draft.add(onSuccess: onSaved)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("quick-capture-add")
            }
        }
        .appTypography(.body)
        .padding(AppMetrics.contentInset)
        .frame(width: 520)
        .background(AppColors.surface)
        .foregroundStyle(AppColors.textPrimary)
        .onAppear { titleFocused = true }
    }
}
