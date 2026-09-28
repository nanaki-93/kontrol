import SwiftUI

/// Presentation shared by Tasks and Today's Next section. Membership and ordering
/// come exclusively from TaskSelection, not from row display metadata.
struct TaskRows: View {
    let rows: [TaskSnapshot]
    let temporalContext: TaskTemporalContext

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                AppListRow(row.title, metadata: metadata(for: row),
                           status: row.isCompleted ? StatusPill("Completed", kind: .success) : nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task-row-\(row.id.uuidString)")
            }
        }
    }
}

/// Both routes observe the same app-owned snapshots. Filter changes never write records.
struct TasksView: View {
    @ObservedObject var store: TaskStore
    @State private var filter: TaskFilter = .today

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
            return ("Nothing planned or due today.", "Check Upcoming for other open tasks, or use Add task on Today.")
        case .upcoming:
            return ("No upcoming tasks.", "All other open tasks, including unscheduled tasks, appear here. Use Add task on Today to capture one.")
        case .completed:
            return ("No completed tasks yet.", "Completed tasks will appear here after you finish one.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Tasks")
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
                    TaskRows(rows: selected, temporalContext: store.temporalContext)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear { store.refresh() }
    }
}
