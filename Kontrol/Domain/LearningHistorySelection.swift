import Foundation

// Civil dates, rather than stored timestamps: changing the viewing time zone
// reinterprets History instants, but does not change the chosen custom dates.
struct HistoryLocalDate: Equatable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar, timeZone: TimeZone) {
        var local = calendar
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    fileprivate func start(in calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: interval.start)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return interval.start
    }
}

enum LearningHistoryTopicFilter: Equatable {
    case all, topic(String), unknown
}

enum LearningHistoryStatusFilter: Equatable {
    case all, completed, dismissed
}

enum LearningHistoryDateFilter: Equatable {
    case allTime, today, lastSevenDays
    case custom(start: HistoryLocalDate, end: HistoryLocalDate)
}

struct LearningHistoryFilters: Equatable {
    var topic: LearningHistoryTopicFilter = .all
    var status: LearningHistoryStatusFilter = .all
    var date: LearningHistoryDateFilter = .allTime
}

enum LearningHistorySelectionError: Error, Equatable {
    case reversedCustomRange
    case invalidLocalDate
}

struct LearningHistoryDayGroup: Equatable {
    let day: DateInterval
    let label: String
    let rows: [LessonHistorySnapshot]
}

/// Pure read projection. All intervals are [start, end); no fixed 24-hour
/// arithmetic, stored-date edits, repository reads, or selection side effects.
enum LearningHistorySelection {
    static func select(_ rows: [LessonHistorySnapshot], filters: LearningHistoryFilters,
                       now: Date, calendar: Calendar, timeZone: TimeZone,
                       locale: Locale) -> Result<[LearningHistoryDayGroup], LearningHistorySelectionError> {
        var local = calendar
        local.timeZone = timeZone
        let today = local.dateInterval(of: .day, for: now)!
        let yesterday = local.date(byAdding: .day, value: -1, to: today.start)!
        let interval: DateInterval?
        switch filters.date {
        case .allTime:
            interval = nil
        case .today:
            interval = today
        case .lastSevenDays:
            let first = local.date(byAdding: .day, value: -6, to: today.start)!
            interval = DateInterval(start: first, end: today.end)
        case let .custom(start, end):
            guard let first = start.start(in: local), let last = end.start(in: local) else {
                return .failure(.invalidLocalDate)
            }
            guard first <= last else { return .failure(.reversedCustomRange) }
            guard let exclusiveEnd = local.date(byAdding: .day, value: 1, to: last) else {
                return .failure(.invalidLocalDate)
            }
            interval = DateInterval(start: first, end: exclusiveEnd)
        }

        let ordered = rows.filter { row in
            guard row.status == .completed || row.status == .dismissed else { return false }
            switch filters.topic {
            case .all: break
            case .topic(let id): guard row.topicID == id else { return false }
            case .unknown: guard row.topicID == nil || row.topicID == "" else { return false }
            }
            switch filters.status {
            case .all: break
            case .completed: guard row.status == .completed else { return false }
            case .dismissed: guard row.status == .dismissed else { return false }
            }
            return interval.map { $0.start <= row.date && row.date < $0.end } ?? true
        }.sorted { left, right in
            if left.date != right.date { return left.date > right.date }
            return left.lessonID < right.lessonID
        }

        let formatter = DateFormatter()
        formatter.calendar = local
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        let relative = RelativeDateTimeFormatter()
        relative.calendar = local
        relative.locale = locale
        relative.unitsStyle = .full
        relative.dateTimeStyle = .named

        var groups: [LearningHistoryDayGroup] = []
        for row in ordered {
            guard let day = local.dateInterval(of: .day, for: row.date) else { continue }
            let label: String
            if day.start == today.start || day.start == yesterday {
                label = relative.localizedString(from: DateComponents(day: day.start == today.start ? 0 : -1))
                    .capitalized(with: locale)
            } else {
                label = formatter.string(from: day.start)
            }
            if let last = groups.indices.last, groups[last].day.start == day.start {
                groups[last] = LearningHistoryDayGroup(day: day, label: label, rows: groups[last].rows + [row])
            } else {
                groups.append(LearningHistoryDayGroup(day: day, label: label, rows: [row]))
            }
        }
        return .success(groups)
    }
}
