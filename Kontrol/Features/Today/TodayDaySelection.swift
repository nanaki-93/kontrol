import Foundation

/// Window-local navigation state. A relative selection follows TaskStore's clock;
/// an explicit selection keeps civil components and the calendar in which they
/// were chosen, but is resolved in the store's *current* time zone on every read.
struct TodayDaySelection {
    private struct CivilDay {
        let era: Int?
        let year: Int
        let month: Int
        let day: Int
        let calendarIdentifier: Calendar.Identifier

        init(_ date: Date, calendar: Calendar) {
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
            era = parts.era
            year = parts.year!
            month = parts.month!
            day = parts.day!
            calendarIdentifier = calendar.identifier
        }
    }

    private enum Mode {
        case relativeToday
        case explicit(CivilDay)
    }

    private var mode: Mode = .relativeToday

    var followsToday: Bool {
        if case .relativeToday = mode { return true }
        return false
    }

    /// Use this date with TaskStore.select(.today, selectedDate:) and schedule
    /// day-interval selection. Noon avoids ambiguous/nonexistent local midnight;
    /// callers must never interpret it as a stored endpoint.
    func selectedDate(in context: TaskTemporalContext) -> Date? {
        switch mode {
        case .relativeToday:
            return context.now
        case .explicit(let day):
            let calendar = Self.calendar(day.calendarIdentifier, in: context)
            guard let date = calendar.date(from: DateComponents(era: day.era, year: day.year,
                                                                month: day.month, day: day.day,
                                                                hour: 12)) else {
                return nil
            }
            let actual = calendar.dateComponents([.era, .year, .month, .day], from: date)
            guard actual.era == day.era, actual.year == day.year, actual.month == day.month,
                  actual.day == day.day else { return nil }
            return date
        }
    }

    mutating func previous(in context: TaskTemporalContext) {
        move(by: -1, in: context)
    }

    mutating func next(in context: TaskTemporalContext) {
        move(by: 1, in: context)
    }

    mutating func returnToToday() {
        mode = .relativeToday
    }

    private mutating func move(by days: Int, in context: TaskTemporalContext) {
        let identifier: Calendar.Identifier
        switch mode {
        case .relativeToday: identifier = context.calendar.identifier
        case .explicit(let day): identifier = day.calendarIdentifier
        }
        let calendar = Self.calendar(identifier, in: context)
        guard let selected = selectedDate(in: context),
              let next = calendar.date(byAdding: .day, value: days, to: selected) else { return }
        mode = .explicit(CivilDay(next, calendar: calendar))
    }

    private static func calendar(_ identifier: Calendar.Identifier,
                                 in context: TaskTemporalContext) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = context.timeZone
        return calendar
    }
}
