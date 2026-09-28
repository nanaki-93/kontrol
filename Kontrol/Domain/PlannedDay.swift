import Foundation

/// A selected calendar date, not a midnight instant. Keep the zone used to
/// choose the day so a later device-zone change cannot move that selection.
struct PlannedDay: Equatable {
    let components: KontrolSchemaV1.PlannedDayComponents
    let timeZoneID: String

    enum ValidationError: Error, Equatable {
        case invalidCalendarIdentifier
        case invalidTimeZoneID
        case invalidDate
    }

    /// Validate even values assembled via the ordinary memberwise initializer,
    /// before they reach a persistence mutation. Do not turn the selected day
    /// into a UTC midnight instant.
    func validated() throws -> PlannedDay {
        let supported: [Calendar.Identifier] = [
            .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
            .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
            .islamicCivil, .japanese, .persian, .republicOfChina,
            .islamicTabular, .islamicUmmAlQura
        ]
        guard let identifier = supported.first(where: {
            String(describing: $0) == components.calendarIdentifier
        }) else { throw ValidationError.invalidCalendarIdentifier }
        guard let zone = TimeZone(identifier: timeZoneID) else {
            throw ValidationError.invalidTimeZoneID
        }
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = zone
        guard components.year > 0, components.month > 0, components.day > 0 else {
            throw ValidationError.invalidDate
        }
        let requested = DateComponents(year: components.year, month: components.month,
                                       day: components.day)
        guard let date = calendar.date(from: requested) else { throw ValidationError.invalidDate }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == components.year, actual.month == components.month,
              actual.day == components.day else { throw ValidationError.invalidDate }
        return self
    }

    /// Both stored fields must be present together, or both absent.
    static func validated(components: KontrolSchemaV1.PlannedDayComponents?,
                          timeZoneID: String?) throws -> PlannedDay? {
        switch (components, timeZoneID) {
        case (nil, nil): return nil
        case let (components?, zone?):
            return try PlannedDay(components: components, timeZoneID: zone).validated()
        default: throw KontrolSchemaV1.TaskValidationError.incompletePlannedDay
        }
    }

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
