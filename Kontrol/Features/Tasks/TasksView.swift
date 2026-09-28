import SwiftUI

/// A value snapshot keeps the read-only UI independent of a repository context.
struct TaskRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let plannedDay: KontrolSchemaV1.PlannedDayComponents?
    let dueAt: Date?
    let completedAt: Date?

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        plannedDay = task.plannedDay
        dueAt = task.dueAt
        completedAt = task.completedAt
    }

    init(_ task: TaskSnapshot) {
        id = task.id
        title = task.title
        plannedDay = task.plannedDay
        dueAt = task.dueAt
        completedAt = task.completedAt
    }

    static func forToday(_ rows: [TaskRow], at date: Date, calendar: Calendar,
                         timeZone: TimeZone) -> [TaskRow] {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let today = PlannedDay.today(at: date, calendar: localCalendar, timeZone: timeZone).components
        let tomorrow = localCalendar.dateInterval(of: .day, for: date)?.end
        return rows.filter { row in
            guard row.completedAt == nil else { return false }
            // The saved plan is a calendar date, not a midnight UTC instant.
            return row.plannedDay == today || (row.dueAt.map { due in
                tomorrow.map { due < $0 } ?? false
            } ?? false)
        }
    }
}

struct TaskRows: View {
    let rows: [TaskRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                AppListRow(row.title, status: row.completedAt == nil ? nil : StatusPill("Completed", kind: .success))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task-row-\(row.id.uuidString)")
            }
        }
    }
}

/// Both routes observe the same app-owned snapshots. Mutations arrive without navigation.
struct TasksView: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Tasks")
            if let message = store.readState.message {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: store.retryRead)
                Text(message)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if store.readState == .loaded && store.snapshots.isEmpty {
                EmptyState("No tasks captured yet.", guidance: "Use Add task on Today to capture one.")
            } else if !store.snapshots.isEmpty {
                TaskRows(rows: store.snapshots.map(TaskRow.init))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear { store.refresh() }
    }
}
