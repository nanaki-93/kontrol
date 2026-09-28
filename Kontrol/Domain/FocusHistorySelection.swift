import Foundation

enum FocusHistoryFilter {
    case recent, today, thisWeek
}

/// A civil-day group identified by its calendar interval, not by a fixed number of seconds.
struct FocusHistoryGroup {
    let day: DateInterval
    let sessions: [FocusSessionSnapshot]
}

struct FocusHistoryResult {
    let groups: [FocusHistoryGroup]
    let todaySeconds: Double

    /// Truncate only after adding the real (possibly fractional) durations.
    var todayWholeMinutes: Int { Int(min(todaySeconds / 60, Double(Int.max).nextDown)) }
}

enum FocusHistorySelection {
    /// Calendar intervals are half-open: a finish at the next midnight/week start
    /// belongs only to the new interval, never to both adjacent intervals.
    private static func includes(_ date: Date, in interval: DateInterval?) -> Bool {
        guard let interval else { return false }
        return interval.start <= date && date < interval.end
    }

    static func select(_ rows: [FocusSessionSnapshot], filter: FocusHistoryFilter,
                       now: Date, calendar: Calendar, timeZone: TimeZone) -> FocusHistoryResult {
        var local = calendar
        local.timeZone = timeZone
        let today = local.dateInterval(of: .day, for: now)
        let week = local.dateInterval(of: .weekOfYear, for: now)
        let finished = rows.filter { ($0.state == .completed || $0.state == .ended) && $0.endedAt != nil }
        let total = finished.reduce(0.0) { sum, row in
            sum + (includes(row.endedAt!, in: today) ? row.actualSeconds : 0)
        }
        let ordered = finished.filter { row in
            switch filter {
            case .recent: return true
            case .today: return includes(row.endedAt!, in: today)
            case .thisWeek: return includes(row.endedAt!, in: week)
            }
        }.sorted { lhs, rhs in
            if lhs.endedAt != rhs.endedAt { return lhs.endedAt! > rhs.endedAt! }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var groups: [FocusHistoryGroup] = []
        for row in ordered {
            guard let day = local.dateInterval(of: .day, for: row.endedAt!) else { continue }
            if let last = groups.indices.last, groups[last].day == day {
                groups[last] = FocusHistoryGroup(day: day, sessions: groups[last].sessions + [row])
            } else {
                groups.append(FocusHistoryGroup(day: day, sessions: [row]))
            }
        }
        return FocusHistoryResult(groups: groups, todaySeconds: total)
    }
}
