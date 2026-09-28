import Foundation

/// A pure calculation. `monotonicDelta` is the continuous-clock time since the
/// current in-process anchor (not a timer callback count or a wall-clock delta).
/// The caller replaces that anchor only after committing a checkpoint/transition.
struct FocusTimingSample: Equatable {
    let elapsedSeconds: Double
    let remainingSeconds: Double

    var countdownSeconds: Int {
        // Clamp before converting: even a very large valid plan fits in Int.
        remainingSeconds >= Double(Int.max) ? Int.max : Int(ceil(remainingSeconds))
    }

    var isComplete: Bool { remainingSeconds == 0 }
}

struct FocusTimingChange: Equatable {
    let transition: FocusTransition
    let snapshot: FocusSessionSnapshot
}

enum FocusTiming {
    static func sample(_ session: FocusSessionSnapshot,
                       monotonicDelta: TimeInterval) throws -> FocusTimingSample {
        guard session.state == .running, !session.recoveryRequired,
              monotonicDelta.isFinite, monotonicDelta >= 0 else {
            throw FocusError.invalidTransition
        }
        let plan = Double(session.plannedSeconds)
        // Subtract first to avoid overflowing when a valid but huge delta is added.
        let remaining = max(0, plan - session.accumulatedActiveSeconds)
        let consumed = min(monotonicDelta, remaining)
        let elapsed = min(plan, session.accumulatedActiveSeconds + consumed)
        return FocusTimingSample(elapsedSeconds: elapsed,
                                 remainingSeconds: max(0, plan - elapsed))
    }

    static func pause(_ session: FocusSessionSnapshot, at wall: Date,
                      monotonicDelta: TimeInterval) throws -> FocusTimingChange {
        let measured = try sample(session, monotonicDelta: monotonicDelta)
        if measured.isComplete {
            return try finish(session, at: wall, monotonicDelta: monotonicDelta,
                              measured: measured, completed: true)
        }
        let stamp = try durableStamp(session, wall)
        let payload = payloadFor(session, at: stamp, elapsed: measured.elapsedSeconds)
        return FocusTimingChange(transition: .pause(payload),
            snapshot: try copy(session, state: .paused, elapsed: measured.elapsedSeconds,
                               pausedAt: stamp, checkpointAt: stamp))
    }

    static func end(_ session: FocusSessionSnapshot, at wall: Date,
                    monotonicDelta: TimeInterval) throws -> FocusTimingChange {
        let measured = try sample(session, monotonicDelta: monotonicDelta)
        return try finish(session, at: wall, monotonicDelta: monotonicDelta,
                          measured: measured, completed: measured.isComplete)
    }

    static func complete(_ session: FocusSessionSnapshot, at wall: Date,
                         monotonicDelta: TimeInterval) throws -> FocusTimingChange {
        let measured = try sample(session, monotonicDelta: monotonicDelta)
        guard measured.isComplete else { throw FocusError.invalidTransition }
        return try finish(session, at: wall, monotonicDelta: monotonicDelta,
                          measured: measured, completed: true)
    }

    static func checkpoint(_ session: FocusSessionSnapshot, at wall: Date,
                           monotonicDelta: TimeInterval) throws -> FocusTimingChange {
        let measured = try sample(session, monotonicDelta: monotonicDelta)
        if measured.isComplete {
            return try finish(session, at: wall, monotonicDelta: monotonicDelta,
                              measured: measured, completed: true)
        }
        let stamp = try durableStamp(session, wall)
        let remaining = measured.remainingSeconds
        let payload = payloadFor(session, at: stamp, elapsed: measured.elapsedSeconds)
        return FocusTimingChange(transition: .checkpoint(payload),
            snapshot: try copy(session, state: .running, elapsed: measured.elapsedSeconds,
                               anchor: stamp, deadline: stamp.addingTimeInterval(remaining),
                               checkpointAt: stamp))
    }

    static func resume(_ session: FocusSessionSnapshot, at wall: Date) throws -> FocusTimingChange {
        guard session.state == .paused, !session.recoveryRequired else {
            throw FocusError.invalidTransition
        }
        let stamp = try durableStamp(session, wall)
        let payload = payloadFor(session, at: stamp, elapsed: session.accumulatedActiveSeconds)
        return FocusTimingChange(transition: .resume(payload),
            snapshot: try copy(session, state: .running,
                               elapsed: session.accumulatedActiveSeconds, anchor: stamp,
                               deadline: stamp.addingTimeInterval(
                                   Double(session.plannedSeconds) - session.accumulatedActiveSeconds),
                               checkpointAt: stamp))
    }

    private static func finish(_ session: FocusSessionSnapshot, at wall: Date,
                               monotonicDelta: TimeInterval, measured: FocusTimingSample,
                               completed: Bool) throws -> FocusTimingChange {
        let stamp = try durableStamp(session, wall)
        // A delayed wake/callback must not put the finish at the wake time. Wall time
        // is used only to date the event; it never determines accrued duration.
        let overshoot = completed ? max(0, monotonicDelta -
            (Double(session.plannedSeconds) - session.accumulatedActiveSeconds)) : 0
        let effective = max(session.startedAt, wall.addingTimeInterval(-overshoot))
        let checkpoint = max(stamp, effective)
        let elapsed = completed ? Double(session.plannedSeconds) : measured.elapsedSeconds
        let payload = payloadFor(session, at: checkpoint, elapsed: elapsed)
        return FocusTimingChange(transition: completed ? .complete(payload) : .end(payload),
            snapshot: try copy(session, state: completed ? .completed : .ended,
                               elapsed: elapsed, endedAt: effective, checkpointAt: checkpoint))
    }

    private static func durableStamp(_ session: FocusSessionSnapshot, _ wall: Date) throws -> Date {
        guard wall.timeIntervalSinceReferenceDate.isFinite else { throw FocusError.invalidTransition }
        // Preserve ordered durable timestamps if the system wall clock moves backward.
        return max(session.checkpointAt, session.startedAt, wall)
    }

    private static func payloadFor(_ session: FocusSessionSnapshot, at stamp: Date,
                                   elapsed: Double) -> FocusTransitionPayload {
        FocusTransitionPayload(expectedCheckpointAt: session.checkpointAt, sampledAt: stamp,
                               accumulatedActiveSeconds: elapsed)
    }

    private static func copy(_ session: FocusSessionSnapshot, state: FocusSessionState,
                             elapsed: Double, anchor: Date? = nil, deadline: Date? = nil,
                             pausedAt: Date? = nil, endedAt: Date? = nil,
                             checkpointAt: Date) throws -> FocusSessionSnapshot {
        try FocusSessionSnapshot(id: session.id, state: state,
                                 plannedSeconds: session.plannedSeconds,
                                 accumulatedActiveSeconds: elapsed,
                                 activeSegmentStartedAt: anchor, deadline: deadline,
                                 pausedAt: pausedAt, startedAt: session.startedAt,
                                 endedAt: endedAt, checkpointAt: checkpointAt,
                                 linkedTaskID: session.linkedTaskID,
                                 linkedLessonID: session.linkedLessonID,
                                 linkedTitleSnapshot: session.linkedTitleSnapshot)
    }
}
