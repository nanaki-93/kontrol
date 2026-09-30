import Foundation

/// Synchronous, read-only mapping of supplied persisted rows. The caller owns the
/// fetch context and committed-read boundary; this mapper never fetches or saves.
/// Only detached values leave the main actor. Configuration is mapped separately.
@MainActor
enum DailyDataExportProjection {
    static func project(tasks: [TaskItem], blocks: [ScheduleBlock], sessions: [FocusSession],
                        into envelope: LocalDataExport) throws -> LocalDataExport {
        var value = envelope
        value.tasks = try tasks.map { row in
            // A missing half is corruption, not an unplanned legacy task.
            guard (row.plannedDay == nil) == (row.plannedTimeZoneID == nil) else {
                throw LocalDataExportError.invalidDate
            }
            let day = row.plannedDay.map { components in
                LocalDataExport.PlannedDay(calendarIdentifier: components.calendarIdentifier,
                    year: components.year, month: components.month, day: components.day,
                    timeZoneID: row.plannedTimeZoneID!)
            }
            return try .init(id: row.id, title: row.title, notes: row.notes,
                dueAt: row.dueAt.map { try ExportTimestamp($0) }, plannedDay: day,
                createdAt: ExportTimestamp(row.createdAt),
                completedAt: row.completedAt.map { try ExportTimestamp($0) })
        }
        value.blocks = try blocks.map { row in
            try .init(id: row.id, title: row.title, startAt: ExportTimestamp(row.startAt),
                endAt: ExportTimestamp(row.endAt), note: row.note, lessonID: row.lessonID,
                linkedTitleSnapshot: row.linkedTitleSnapshot)
        }
        value.sessions = try sessions.map { row in
            // Convert every date, including inactive fields, before checking state.
            let session = try LocalDataExport.Session(id: row.id, state: row.state,
                plannedSeconds: row.plannedSeconds,
                accumulatedActiveSeconds: row.accumulatedActiveSeconds,
                activeSegmentStartedAt: row.activeSegmentStartedAt.map { try ExportTimestamp($0) },
                deadline: row.deadline.map { try ExportTimestamp($0) },
                pausedAt: row.pausedAt.map { try ExportTimestamp($0) },
                startedAt: ExportTimestamp(row.startedAt),
                endedAt: row.endedAt.map { try ExportTimestamp($0) },
                checkpointAt: ExportTimestamp(row.checkpointAt), recoveryRequired: row.recoveryRequired,
                linkedTaskID: row.linkedTaskID, linkedLessonID: row.linkedLessonID,
                linkedTitleSnapshot: row.linkedTitleSnapshot)
            // Reuse the pure persisted-state validator, never the timer/repository
            // reconciliation path. Validate original precision, not rounded anchors.
            do { _ = try FocusSessionSnapshot(row) }
            catch { throw LocalDataExportError.invalidValue }
            return session
        }
        guard value.sessions.filter({ $0.state == "running" || $0.state == "paused" }).count <= 1 else {
            throw LocalDataExportError.invalidValue
        }
        // The shared contract validates identities, planned calendars, authored
        // titles, scalar links and block bounds (also at millisecond precision).
        try value.validate()
        return value.canonicalized()
    }
}
