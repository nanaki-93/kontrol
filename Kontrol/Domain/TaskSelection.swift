import Foundation

enum TaskFilter {
    case today, upcoming, completed
}

/// Pure selection over immutable persisted values. Plans are calendar dates, not instants:
/// compare their components in the selected zone, without moving the stored plan's zone.
enum TaskSelection {
    static func select(_ tasks: [TaskSnapshot], filter: TaskFilter,
                       selectedDate: Date, now: Date, calendar: Calendar,
                       timeZone: TimeZone) -> [TaskSnapshot] {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let nextDay = localCalendar.dateInterval(of: .day, for: selectedDate)?.end

        switch filter {
        case .today, .upcoming:
            return tasks.filter { task in
                guard !task.isCompleted else { return false }
                let plannedToday = isPlanned(task, for: selectedDate,
                                             calendar: localCalendar)
                let dueBySelectedDay = nextDay.map { boundary in
                    task.dueAt.map { $0 < boundary } ?? false
                } ?? false
                let isToday = plannedToday || dueBySelectedDay
                return filter == .today ? isToday : !isToday
            }.sorted { lhs, rhs in
                let lhsOverdue = lhs.dueAt.map { $0 < now } ?? false
                let rhsOverdue = rhs.dueAt.map { $0 < now } ?? false
                if lhsOverdue != rhsOverdue { return lhsOverdue }
                if lhs.dueAt != rhs.dueAt {
                    if let lhsDue = lhs.dueAt, let rhsDue = rhs.dueAt {
                        return lhsDue < rhsDue
                    }
                    return lhs.dueAt != nil // Undated tasks last.
                }
                return createdBefore(lhs, rhs)
            }
        case .completed:
            return tasks.filter(\.isCompleted).sorted { lhs, rhs in
                if lhs.completedAt != rhs.completedAt {
                    return lhs.completedAt! > rhs.completedAt!
                }
                return createdBefore(lhs, rhs)
            }
        }
    }

    private static func createdBefore(_ lhs: TaskSnapshot, _ rhs: TaskSnapshot) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func isPlanned(_ task: TaskSnapshot, for date: Date,
                                  calendar: Calendar) -> Bool {
        guard let plan = task.plannedDay, task.plannedTimeZoneID != nil else { return false }
        // A persisted plan may have been chosen under a different calendar from the
        // current system calendar. Read the selected local date in the plan's calendar;
        // never interpret the stored components as midnight in either time zone.
        let identifiers: [Calendar.Identifier] = [
            .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
            .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
            .islamicCivil, .japanese, .persian, .republicOfChina,
            .islamicTabular, .islamicUmmAlQura
        ]
        guard let identifier = identifiers.first(where: {
            String(describing: $0) == plan.calendarIdentifier
        }) else { return false }
        var planCalendar = Calendar(identifier: identifier)
        planCalendar.timeZone = calendar.timeZone
        let selected = planCalendar.dateComponents([.year, .month, .day], from: date)
        return selected.year == plan.year && selected.month == plan.month && selected.day == plan.day
    }
}
