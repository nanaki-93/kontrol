import Foundation

/// Stable storage codes. Ready is configuration only; it must never become a stored row.
enum FocusSessionState: String, Equatable {
    case running, paused, completed, ended

    var isActive: Bool { self == .running || self == .paused }
}

enum FocusError: Error, Equatable {
    case invalidDuration
    case invalidCustomMinutes
    case durationOverflow
    case invalidStartTime
    case invalidLinks
    case invalidStoredData
    case missingSession
    case unavailableTask
    case unavailableLesson
    case invalidTransition
    case staleBaseline
    case activeSessionConflict
    case persistenceFailure
}

/// Duration configuration is ephemeral until Start. Parsing never creates a session.
enum FocusDuration: Equatable {
    case fifteen, twentyFive, fifty
    case custom(String)

    static let `default`: FocusDuration = .twentyFive

    func seconds() throws -> Int {
        switch self {
        case .fifteen: return 15 * 60
        case .twentyFive: return 25 * 60
        case .fifty: return 50 * 60
        case .custom(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Decimal ASCII digits only: no signs, decimals, exponents or locale-dependent
            // numeric coercion. Reject oversized decimal input without trapping.
            guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw FocusError.invalidCustomMinutes
            }
            guard let minutes = Int(trimmed) else { throw FocusError.durationOverflow }
            guard minutes > 0 else { throw FocusError.invalidCustomMinutes }
            let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
            guard !overflow else { throw FocusError.durationOverflow }
            return seconds
        }
    }
}

struct FocusConfiguration: Equatable {
    let duration: FocusDuration
    let linkedTaskID: UUID?
    let linkedLessonID: String?

    init(duration: FocusDuration = .default, linkedTaskID: UUID? = nil,
         linkedLessonID: String? = nil) {
        self.duration = duration
        self.linkedTaskID = linkedTaskID
        self.linkedLessonID = linkedLessonID
    }

    func plannedSeconds() throws -> Int {
        guard linkedTaskID == nil || linkedLessonID == nil,
              linkedLessonID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
        else { throw FocusError.invalidLinks }
        return try duration.seconds()
    }
}

/// Unsaved input; the repository resolves a selected link and captures its title at Start.
struct FocusStartInput: Equatable {
    let plannedSeconds: Int
    let startedAt: Date
    let linkedTaskID: UUID?
    let linkedLessonID: String?

    init(plannedSeconds: Int, startedAt: Date, linkedTaskID: UUID? = nil,
         linkedLessonID: String? = nil) {
        self.plannedSeconds = plannedSeconds
        self.startedAt = startedAt
        self.linkedTaskID = linkedTaskID
        self.linkedLessonID = linkedLessonID
    }

    func validated() throws -> FocusStartInput {
        guard plannedSeconds > 0 else { throw FocusError.invalidDuration }
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FocusError.invalidStartTime
        }
        guard linkedTaskID == nil || linkedLessonID == nil,
              linkedLessonID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
        else { throw FocusError.invalidLinks }
        return self
    }
}

enum FocusRecoveryChoice: Equatable {
    case resume, end
}

/// A sampled transition carries its expected durable baseline and absolute accrued value.
/// Later timing calculations supply the anchors; the repository checks the baseline against
/// the latest row before writing. No transition payload owns a persistent model.
struct FocusTransitionPayload: Equatable {
    let expectedCheckpointAt: Date
    let sampledAt: Date
    let accumulatedActiveSeconds: Double
    // Only checkpoints carry this separately from the ordered stale-write watermark.
    // A wall-clock rollback can put the real segment anchor before startedAt.
    let wallAnchorAt: Date?

    init(expectedCheckpointAt: Date, sampledAt: Date, accumulatedActiveSeconds: Double,
         wallAnchorAt: Date? = nil) {
        self.expectedCheckpointAt = expectedCheckpointAt
        self.sampledAt = sampledAt
        self.accumulatedActiveSeconds = accumulatedActiveSeconds
        self.wallAnchorAt = wallAnchorAt
    }

    func validated(plannedSeconds: Int) throws -> FocusTransitionPayload {
        guard plannedSeconds > 0,
              expectedCheckpointAt.timeIntervalSinceReferenceDate.isFinite,
              sampledAt.timeIntervalSinceReferenceDate.isFinite,
              wallAnchorAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 <= sampledAt }) ?? true,
              accumulatedActiveSeconds.isFinite,
              accumulatedActiveSeconds >= 0,
              accumulatedActiveSeconds <= Double(plannedSeconds) else {
            throw FocusError.invalidTransition
        }
        return self
    }
}

enum FocusTransition: Equatable {
    case pause(FocusTransitionPayload)
    case resume(FocusTransitionPayload)
    case checkpoint(FocusTransitionPayload)
    case end(FocusTransitionPayload)
    case complete(FocusTransitionPayload)
    case reconcile(FocusTransitionPayload)
    case recover(FocusRecoveryChoice, FocusTransitionPayload)
}

/// Immutable copy of a stored row. Validate before publishing or calculating time.
struct FocusSessionSnapshot: Equatable, Identifiable {
    let id: UUID
    let state: FocusSessionState
    let plannedSeconds: Int
    let accumulatedActiveSeconds: Double
    let activeSegmentStartedAt: Date?
    let deadline: Date?
    let pausedAt: Date?
    let startedAt: Date
    let endedAt: Date?
    let checkpointAt: Date
    let recoveryRequired: Bool
    let linkedTaskID: UUID?
    let linkedLessonID: String?
    let linkedTitleSnapshot: String?

    var actualSeconds: Double { accumulatedActiveSeconds }

    init(id: UUID, state: FocusSessionState, plannedSeconds: Int,
         accumulatedActiveSeconds: Double, activeSegmentStartedAt: Date? = nil,
         deadline: Date? = nil, pausedAt: Date? = nil, startedAt: Date,
         endedAt: Date? = nil, checkpointAt: Date, recoveryRequired: Bool = false,
         linkedTaskID: UUID? = nil, linkedLessonID: String? = nil,
         linkedTitleSnapshot: String? = nil) throws {
        guard plannedSeconds > 0, accumulatedActiveSeconds.isFinite,
              accumulatedActiveSeconds >= 0,
              accumulatedActiveSeconds <= Double(plannedSeconds),
              [startedAt, checkpointAt].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              [activeSegmentStartedAt, deadline, pausedAt, endedAt].allSatisfy({
                  $0.map { $0.timeIntervalSinceReferenceDate.isFinite } ?? true
              }),
              checkpointAt >= startedAt,
              linkedTaskID == nil || linkedLessonID == nil,
              linkedLessonID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
              linkedTitleSnapshot.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
        else { throw FocusError.invalidStoredData }

        switch state {
        case .running:
            guard let anchor = activeSegmentStartedAt, let deadline,
                  checkpointAt >= anchor,
                  deadline > anchor, pausedAt == nil, endedAt == nil,
                  !recoveryRequired, accumulatedActiveSeconds < Double(plannedSeconds),
                  // Compare Dates in the same representation used to write the deadline.
                  // Subtracting a small anchor from a huge Date first can round away
                  // seconds even when the stored deadline is exactly the computed one.
                  abs(deadline.timeIntervalSinceReferenceDate -
                      anchor.addingTimeInterval(Double(plannedSeconds) - accumulatedActiveSeconds)
                          .timeIntervalSinceReferenceDate) < 0.001
            else { throw FocusError.invalidStoredData }
        case .paused:
            guard activeSegmentStartedAt == nil, deadline == nil, endedAt == nil,
                  let pausedAt, pausedAt >= startedAt, checkpointAt >= pausedAt,
                  accumulatedActiveSeconds < Double(plannedSeconds)
            else { throw FocusError.invalidStoredData }
        case .completed, .ended:
            guard activeSegmentStartedAt == nil, deadline == nil, pausedAt == nil,
                  let endedAt, endedAt >= startedAt, checkpointAt >= endedAt,
                  !recoveryRequired,
                  state == .completed ? accumulatedActiveSeconds == Double(plannedSeconds) :
                      accumulatedActiveSeconds < Double(plannedSeconds)
            else { throw FocusError.invalidStoredData }
        }
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

    init(_ model: FocusSession) throws {
        guard let state = FocusSessionState(rawValue: model.state) else {
            throw FocusError.invalidStoredData
        }
        try self.init(id: model.id, state: state, plannedSeconds: model.plannedSeconds,
                      accumulatedActiveSeconds: model.accumulatedActiveSeconds,
                      activeSegmentStartedAt: model.activeSegmentStartedAt,
                      deadline: model.deadline, pausedAt: model.pausedAt,
                      startedAt: model.startedAt, endedAt: model.endedAt,
                      checkpointAt: model.checkpointAt, recoveryRequired: model.recoveryRequired,
                      linkedTaskID: model.linkedTaskID, linkedLessonID: model.linkedLessonID,
                      linkedTitleSnapshot: model.linkedTitleSnapshot)
    }
}
