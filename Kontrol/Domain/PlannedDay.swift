import Foundation

/// A selected calendar date, not a midnight instant. Keep the zone used to
/// choose the day so a later device-zone change cannot move that selection.
struct PlannedDay: Equatable {
    let components: KontrolSchemaV1.PlannedDayComponents
    let timeZoneID: String

    static func today(at instant: Date, calendar: Calendar = .current,
                      timeZone: TimeZone = .current) -> PlannedDay {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        return PlannedDay(
            components: .init(calendarIdentifier: String(describing: localCalendar.identifier),
                              year: localCalendar.component(.year, from: instant),
                              month: localCalendar.component(.month, from: instant),
                              day: localCalendar.component(.day, from: instant)),
            timeZoneID: timeZone.identifier)
    }
}
