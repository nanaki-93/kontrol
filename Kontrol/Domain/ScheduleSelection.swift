import Foundation

struct ScheduleConflict: Equatable {
    let block: ScheduleSnapshot
    let duration: TimeInterval
}

/// Pure interval operations over absolute instants. All intervals are half-open [start, end).
enum ScheduleSelection {
    static func select(_ blocks: [ScheduleSnapshot], selectedDate: Date,
                       calendar: Calendar, timeZone: TimeZone) -> [ScheduleSnapshot] {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        guard let day = localCalendar.dateInterval(of: .day, for: selectedDate) else { return [] }
        return orderedUnique(blocks.filter {
            intersectionDuration(startAt: $0.startAt, endAt: $0.endAt,
                                 withStartAt: day.start, endAt: day.end) != nil
        })
    }

    static func conflicts(for input: ScheduleInput, against blocks: [ScheduleSnapshot],
                          excluding editedID: UUID? = nil) -> [ScheduleConflict] {
        orderedUnique(blocks.filter { $0.id != editedID }).compactMap { block in
            guard let duration = intersectionDuration(startAt: input.startAt, endAt: input.endAt,
                                                      withStartAt: block.startAt,
                                                      endAt: block.endAt) else { return nil }
            return ScheduleConflict(block: block, duration: duration)
        }
    }

    /// Returns nil for disjoint, touching, or invalid intervals; duration is elapsed real time.
    static func intersectionDuration(startAt: Date, endAt: Date,
                                     withStartAt otherStart: Date,
                                     endAt otherEnd: Date) -> TimeInterval? {
        guard startAt.timeIntervalSinceReferenceDate.isFinite,
              endAt.timeIntervalSinceReferenceDate.isFinite,
              otherStart.timeIntervalSinceReferenceDate.isFinite,
              otherEnd.timeIntervalSinceReferenceDate.isFinite,
              startAt < endAt, otherStart < otherEnd,
              startAt < otherEnd, otherStart < endAt else { return nil }
        return min(endAt, otherEnd).timeIntervalSince(max(startAt, otherStart))
    }

    private static func orderedUnique(_ blocks: [ScheduleSnapshot]) -> [ScheduleSnapshot] {
        var seen = Set<UUID>()
        return blocks.sorted { lhs, rhs in
            if lhs.startAt != rhs.startAt { return lhs.startAt < rhs.startAt }
            if lhs.endAt != rhs.endAt { return lhs.endAt < rhs.endAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.filter { seen.insert($0.id).inserted }
    }
}
