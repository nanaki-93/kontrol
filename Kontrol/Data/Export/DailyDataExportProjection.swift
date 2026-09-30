import Foundation

/// Synchronous, read-only mapping of supplied persisted rows. The caller owns the
/// fetch context and committed-read boundary; this mapper never fetches or saves.
/// Only detached values leave the main actor. No feature owner is initialized.
@MainActor
enum DailyDataExportProjection {
    /// The caller supplies the detached bundled catalog; reading its resource is
    /// independent of News initialization. Persisted rows always take precedence.
    static func project(general: [AppPreferencesRecord], ai: [AISettingsRecord],
                        newsPreferences: [NewsPreferencesRecord], feeds: [NewsFeedRecord],
                        catalog: DefaultFeedCatalog, into envelope: LocalDataExport) throws -> LocalDataExport {
        guard general.count <= 1, ai.count <= 1, newsPreferences.count <= 1,
              Set(feeds.map(\.id)).count == feeds.count else {
            throw LocalDataExportError.duplicateIdentity
        }
        guard general.allSatisfy({ $0.key == AppPreferencesRecord.singletonKey }),
              ai.allSatisfy({ $0.key == "ai.settings" }),
              newsPreferences.allSatisfy({ $0.key == "news.preferences" }) else {
            throw LocalDataExportError.invalidValue
        }
        var preferences = AppPreferences.defaults
        if let row = general.first {
            do {
                preferences = try AppPreferences(payloadVersion: row.payloadVersion,
                    focusDefaultMinutes: row.focusDefaultMinutes, textSizeCode: row.textSize,
                    reduceMotionCode: row.reduceMotion)
            } catch AppPreferencesError.unsupportedPayloadVersion {
                throw LocalDataExportError.unsupportedVersion
            } catch { throw LocalDataExportError.invalidValue }
        }
        var aiSettings = AISettingsSnapshot.disabled
        if let row = ai.first {
            guard row.payloadVersion == 1 else { throw LocalDataExportError.unsupportedVersion }
            aiSettings = AISettingsSnapshot(enabled: row.enabled, providerID: row.providerID,
                modelID: row.modelID, credentialReference: row.credentialReference, revision: row.revision)
            // Pure configuration validation, including the opaque reference's UUID
            // shape. No credential lookup occurs; the reference never leaves here.
            do { try aiSettings.validate() }
            catch { throw LocalDataExportError.invalidValue }
        }
        try validateCatalog(catalog)
        let known = Set(catalog.topics.map(\.id))
        var feedPreferences: LocalDataExport.FeedPreferences
        if let row = newsPreferences.first {
            guard row.catalogVersion > 0, feeds.count <= 32 else {
                throw LocalDataExportError.invalidValue
            }
            let selected = try topics(row.selectedTopicIDsPayload)
            guard Set(selected).isSubset(of: known) else { throw LocalDataExportError.invalidValue }
            var endpoints = Set<String>()
            let projected = try feeds.map { feed -> LocalDataExport.Feed in
                let mappings = try topics(feed.topicIDsPayload)
                guard !feed.name.isEmpty, feed.name.utf8.count <= 256,
                      feed.name == feed.name.trimmingCharacters(in: .whitespacesAndNewlines),
                      !mappings.isEmpty, Set(mappings).isSubset(of: known),
                      let endpoint = try? NewsURLPolicy.normalizedFeedURL(feed.endpoint) else {
                    throw LocalDataExportError.invalidValue
                }
                guard endpoints.insert(endpoint).inserted else { throw LocalDataExportError.duplicateIdentity }
                // Validate endpoint identity without rewriting the configured text.
                // Transport timestamps, validators, headers and errors are not read.
                return .init(id: feed.id, name: feed.name, endpoint: feed.endpoint,
                    topicIDs: mappings, isEnabled: feed.isEnabled)
            }
            feedPreferences = .init(selectedTopicIDs: selected, feeds: projected)
        } else {
            guard feeds.isEmpty else { throw LocalDataExportError.invalidValue }
            feedPreferences = .init(selectedTopicIDs: catalog.initialSelectedTopicIDs.sorted(),
                feeds: catalog.feeds.map {
                    .init(id: $0.id, name: $0.name, endpoint: $0.url.absoluteString,
                        topicIDs: $0.topicIDs.sorted(), isEnabled: true)
                })
        }
        var value = envelope
        value.generalPreferences = .init(schemaVersion: preferences.payloadVersion,
            focusDefaultMinutes: preferences.focusDefaultMinutes, textSize: preferences.textSize.rawValue,
            reduceMotion: preferences.reduceMotion.rawValue,
            ai: .init(enabled: aiSettings.enabled, providerID: aiSettings.providerID, modelID: aiSettings.modelID))
        value.feedPreferences = feedPreferences
        try value.validate()
        return value.canonicalized()
    }

    private static func topics(_ payload: Data) throws -> [String] {
        do { return try NewsRecordPayload.topics(payload) }
        catch NewsRecordPayload.Error.unsupportedVersion { throw LocalDataExportError.unsupportedVersion }
        catch { throw LocalDataExportError.invalidValue }
    }

    private static func validateCatalog(_ catalog: DefaultFeedCatalog) throws {
        let ids = Set(catalog.topics.map(\.id))
        guard catalog.version > 0, !ids.isEmpty, ids.count == catalog.topics.count, ids.count <= 32,
              catalog.topics.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              catalog.initialSelectedTopicIDs.isSubset(of: ids), catalog.feeds.count <= 32,
              Set(catalog.feeds.map(\.id)).count == catalog.feeds.count,
              Set(catalog.feeds.compactMap { try? NewsURLPolicy.normalizedFeedURL($0.url.absoluteString) })
                .count == catalog.feeds.count,
              catalog.feeds.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256 &&
                  !$0.topicIDs.isEmpty && $0.topicIDs.isSubset(of: ids) }) else {
            throw LocalDataExportError.invalidValue
        }
    }

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
