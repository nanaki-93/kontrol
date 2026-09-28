import Foundation
import SwiftData

// Retain the released V1/V2 model types and their persisted identities.
enum KontrolSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        KontrolSchemaV2.models + [FocusSession.self]
    }

    @Model
    final class FocusSession {
        @Attribute(.unique) var id: UUID
        // Stable storage codes; domain validation of states and transitions is separate.
        var state: String
        var plannedSeconds: Int
        var accumulatedActiveSeconds: Double
        var activeSegmentStartedAt: Date?
        var deadline: Date?
        var pausedAt: Date?
        var startedAt: Date
        var endedAt: Date?
        var checkpointAt: Date
        var recoveryRequired: Bool
        // Scalar links intentionally have no cascading relationship to tasks or lessons.
        var linkedTaskID: UUID?
        var linkedLessonID: String?
        var linkedTitleSnapshot: String?

        init(id: UUID, state: String, plannedSeconds: Int,
             accumulatedActiveSeconds: Double, activeSegmentStartedAt: Date? = nil,
             deadline: Date? = nil, pausedAt: Date? = nil, startedAt: Date,
             endedAt: Date? = nil, checkpointAt: Date, recoveryRequired: Bool = false,
             linkedTaskID: UUID? = nil, linkedLessonID: String? = nil,
             linkedTitleSnapshot: String? = nil) {
            self.id = id
            self.state = state
            self.plannedSeconds = plannedSeconds
            self.accumulatedActiveSeconds = accumulatedActiveSeconds
            self.activeSegmentStartedAt = activeSegmentStartedAt
            self.deadline = deadline
            self.pausedAt = pausedAt
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.checkpointAt = checkpointAt
            self.recoveryRequired = recoveryRequired
            self.linkedTaskID = linkedTaskID
            self.linkedLessonID = linkedLessonID
            self.linkedTitleSnapshot = linkedTitleSnapshot
        }
    }
}

typealias FocusSession = KontrolSchemaV3.FocusSession
