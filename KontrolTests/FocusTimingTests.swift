import Foundation
import XCTest
@testable import Kontrol

final class FocusTimingTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func row(state: FocusSessionState = .running, planned: Int = 1500,
                     accrued: Double = 0, anchor: Date? = nil, deadline: Date? = nil,
                     paused: Date? = nil, ended: Date? = nil, checkpoint: Date? = nil,
                     recovery: Bool = false, task: UUID? = nil,
                     lesson: String? = nil, title: String? = nil) throws -> FocusSessionSnapshot {
        try FocusSessionSnapshot(id: UUID(), state: state, plannedSeconds: planned,
                                 accumulatedActiveSeconds: accrued,
                                 activeSegmentStartedAt: anchor ?? (state == .running ? start : nil),
                                 deadline: deadline ?? (state == .running ?
                                     start.addingTimeInterval(Double(planned) - accrued) : nil),
                                 pausedAt: paused, startedAt: start, endedAt: ended,
                                 checkpointAt: checkpoint ?? start, recoveryRequired: recovery,
                                 linkedTaskID: task, linkedLessonID: lesson,
                                 linkedTitleSnapshot: title)
    }

    private func invalid(_ operation: () throws -> Any, _ expected: FocusError,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? FocusError, expected, file: file, line: line)
        }
    }

    func testDefaultPresetsAndCustomParsingArePure() throws {
        XCTAssertEqual(FocusConfiguration().duration, .twentyFive)
        XCTAssertNil(FocusConfiguration().linkedTaskID)
        XCTAssertEqual(try FocusConfiguration().plannedSeconds(), 1500)
        XCTAssertEqual(try FocusDuration.fifteen.seconds(), 900)
        XCTAssertEqual(try FocusDuration.twentyFive.seconds(), 1500)
        XCTAssertEqual(try FocusDuration.fifty.seconds(), 3000)
        XCTAssertEqual(try FocusDuration.custom(" \n 17 \t").seconds(), 1020)
        let selected = UUID()
        let config = FocusConfiguration(duration: .custom("3"), linkedTaskID: selected)
        XCTAssertEqual(try config.plannedSeconds(), 180)
        XCTAssertEqual(config.linkedTaskID, selected)
        XCTAssertEqual(try FocusDuration.custom(String(Int.max / 60)).seconds(),
                       (Int.max / 60) * 60)
    }

    func testLargestAcceptedCustomDurationHasAValidRunningDeadline() throws {
        let minutes = Int.max / 60
        let seconds = try FocusDuration.custom(String(minutes)).seconds()
        XCTAssertEqual(seconds, minutes * 60)
        XCTAssertEqual(try FocusStartInput(plannedSeconds: seconds, startedAt: start)
            .validated().plannedSeconds, seconds)

        // Date cannot represent every second at this magnitude. Construct the
        // deadline as the timing contract specifies and retain accrued fractions.
        let accrued = 12.375
        let expected = start.addingTimeInterval(Double(seconds) - accrued)
        let snapshot = try row(planned: seconds, accrued: accrued, deadline: expected)
        XCTAssertEqual(snapshot.deadline, expected)
        XCTAssertEqual(snapshot.actualSeconds, accrued)
        XCTAssertGreaterThan(try FocusTiming.sample(snapshot, monotonicDelta: 0).countdownSeconds, 0)
        invalid({ try row(planned: seconds, accrued: accrued,
                          deadline: expected.addingTimeInterval(4_096)) }, .invalidStoredData)
    }

    func testInvalidCustomValuesCannotBecomeDurationsOrSessions() {
        for text in ["", " \t\n", "0", "000", "-1", "+5", "1.5", "1e2",
                     "NaN", "Infinity", "１２", "1 0", "2\n3"] {
            invalid({ try FocusDuration.custom(text).seconds() }, .invalidCustomMinutes)
        }
        for text in [String(Int.max / 60 + 1), String(repeating: "9", count: 100)] {
            invalid({ try FocusDuration.custom(text).seconds() }, .durationOverflow)
        }
        // Configuration is a value, not a persisted `ready` record.
        XCTAssertNil(FocusSessionState(rawValue: "ready"))
    }

    func testStartInputValidatesLinkAndTimeWithoutMakingOrResolvingATask() throws {
        let task = UUID()
        let valid = FocusStartInput(plannedSeconds: 900, startedAt: start, linkedTaskID: task)
        XCTAssertEqual(try valid.validated(), valid)
        XCTAssertEqual(try FocusStartInput(plannedSeconds: 60, startedAt: start,
                                           linkedLessonID: "lesson").validated().linkedLessonID,
                       "lesson")
        invalid({ try FocusStartInput(plannedSeconds: 0, startedAt: start).validated() },
                .invalidDuration)
        invalid({ try FocusStartInput(plannedSeconds: -1, startedAt: start).validated() },
                .invalidDuration)
        invalid({ try FocusStartInput(plannedSeconds: 60,
                                     startedAt: Date(timeIntervalSinceReferenceDate: .nan)).validated() },
                .invalidStartTime)
        invalid({ try FocusStartInput(plannedSeconds: 60,
                                     startedAt: Date(timeIntervalSinceReferenceDate: .infinity)).validated() },
                .invalidStartTime)
        invalid({ try FocusStartInput(plannedSeconds: 60, startedAt: start,
                                     linkedTaskID: task, linkedLessonID: "lesson").validated() },
                .invalidLinks)
        invalid({ try FocusStartInput(plannedSeconds: 60, startedAt: start,
                                     linkedLessonID: "  ").validated() }, .invalidLinks)
    }

    func testSnapshotsCopyModelAndRetainFractionalSeconds() throws {
        let task = UUID()
        let model = FocusSession(id: UUID(), state: "paused", plannedSeconds: 1500,
                                 accumulatedActiveSeconds: 12.375, pausedAt: start.addingTimeInterval(13),
                                 startedAt: start, checkpointAt: start.addingTimeInterval(13),
                                 recoveryRequired: true, linkedTaskID: task,
                                 linkedTitleSnapshot: "Retained title")
        let snapshot = try FocusSessionSnapshot(model)
        model.accumulatedActiveSeconds = 90
        model.linkedTaskID = nil
        XCTAssertEqual(snapshot.actualSeconds, 12.375)
        XCTAssertEqual(snapshot.linkedTaskID, task)
        XCTAssertEqual(snapshot.linkedTitleSnapshot, "Retained title")
        XCTAssertTrue(snapshot.recoveryRequired)
        XCTAssertEqual(snapshot.id, model.id)
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.plannedSeconds, 1500)
        XCTAssertNil(snapshot.activeSegmentStartedAt)
        XCTAssertNil(snapshot.deadline)
        XCTAssertEqual(snapshot.pausedAt, start.addingTimeInterval(13))
        XCTAssertEqual(snapshot.startedAt, start)
        XCTAssertNil(snapshot.endedAt)
        XCTAssertEqual(snapshot.checkpointAt, start.addingTimeInterval(13))
        XCTAssertNil(snapshot.linkedLessonID)
        // Deleted task references may be nil while the captured title survives.
        let historical = try row(state: .ended, accrued: 12.375,
                                 ended: start.addingTimeInterval(13),
                                 checkpoint: start.addingTimeInterval(13), title: "Retained title")
        XCTAssertNil(historical.linkedTaskID)
        XCTAssertEqual(historical.actualSeconds, 12.375)
    }

    func testStructuralStateAndStoredValueRejection() throws {
        _ = try row()
        _ = try row(state: .paused, accrued: 10.25, paused: start.addingTimeInterval(11),
                    checkpoint: start.addingTimeInterval(11), recovery: true)
        _ = try row(state: .completed, accrued: 1500, ended: start.addingTimeInterval(1500),
                    checkpoint: start.addingTimeInterval(1500))
        _ = try row(state: .ended, accrued: 0, ended: start)
        invalid({ try row(planned: 0) }, .invalidStoredData)
        for amount in [Double.nan, .infinity, -.infinity, -0.1, 1500.1] {
            invalid({ try row(accrued: amount) }, .invalidStoredData)
        }
        invalid({ try row(accrued: 1500) }, .invalidStoredData)
        invalid({ try row(deadline: start.addingTimeInterval(12)) }, .invalidStoredData)
        invalid({ try row(anchor: start.addingTimeInterval(1)) }, .invalidStoredData)
        invalid({ try row(paused: start) }, .invalidStoredData)
        invalid({ try row(recovery: true) }, .invalidStoredData)
        invalid({ try row(checkpoint: start.addingTimeInterval(-1)) }, .invalidStoredData)
        invalid({ try row(state: .paused) }, .invalidStoredData)
        invalid({ try row(state: .paused, paused: start, ended: start) }, .invalidStoredData)
        invalid({ try row(state: .ended, accrued: 1500, ended: start) }, .invalidStoredData)
        invalid({ try row(state: .completed, accrued: 1499, ended: start) }, .invalidStoredData)
        invalid({ try row(state: .ended, ended: start.addingTimeInterval(-1)) }, .invalidStoredData)
        invalid({ try row(state: .ended, ended: start, recovery: true) }, .invalidStoredData)
        invalid({ try row(task: UUID(), lesson: "also") }, .invalidStoredData)
        invalid({ try row(lesson: " ") }, .invalidStoredData)
        invalid({ try row(title: "\n") }, .invalidStoredData)
        invalid({ try FocusSessionSnapshot(id: UUID(), state: .running, plannedSeconds: 60,
                                           accumulatedActiveSeconds: 0, startedAt: start,
                                           checkpointAt: start) }, .invalidStoredData)
        invalid({ try FocusSessionSnapshot(id: UUID(), state: .running, plannedSeconds: 60,
                                           accumulatedActiveSeconds: 0,
                                           activeSegmentStartedAt: start,
                                           deadline: Date(timeIntervalSinceReferenceDate: .nan),
                                           startedAt: start, checkpointAt: start) },
                .invalidStoredData)
        invalid({ try FocusSessionSnapshot(id: UUID(), state: .ended, plannedSeconds: 60,
                                           accumulatedActiveSeconds: 0, startedAt: start,
                                           endedAt: start.addingTimeInterval(2),
                                           checkpointAt: start) }, .invalidStoredData)
        let unknown = FocusSession(id: UUID(), state: "ready", plannedSeconds: 60,
                                   accumulatedActiveSeconds: 0, startedAt: start,
                                   checkpointAt: start)
        invalid({ try FocusSessionSnapshot(unknown) }, .invalidStoredData)
        unknown.state = "other"
        invalid({ try FocusSessionSnapshot(unknown) }, .invalidStoredData)
        unknown.state = "ended"
        unknown.endedAt = Date(timeIntervalSinceReferenceDate: .nan)
        invalid({ try FocusSessionSnapshot(unknown) }, .invalidStoredData)
    }

    func testTransitionSamplesRejectInvalidDurationsAndNonfiniteValues() throws {
        let valid = FocusTransitionPayload(expectedCheckpointAt: start, sampledAt: start,
                                           accumulatedActiveSeconds: 0.125)
        XCTAssertEqual(try valid.validated(plannedSeconds: 60), valid)
        invalid({ try valid.validated(plannedSeconds: 0) }, .invalidTransition)
        for amount in [Double.nan, .infinity, -.infinity, -1, 60.1] {
            invalid({ try FocusTransitionPayload(expectedCheckpointAt: start, sampledAt: start,
                                                  accumulatedActiveSeconds: amount)
                .validated(plannedSeconds: 60) }, .invalidTransition)
        }
        invalid({ try FocusTransitionPayload(expectedCheckpointAt: start,
                                              sampledAt: Date(timeIntervalSinceReferenceDate: .nan),
                                              accumulatedActiveSeconds: 0)
            .validated(plannedSeconds: 60) }, .invalidTransition)
        invalid({ try FocusTransitionPayload(
            expectedCheckpointAt: Date(timeIntervalSinceReferenceDate: .infinity),
            sampledAt: start, accumulatedActiveSeconds: 0)
            .validated(plannedSeconds: 60) }, .invalidTransition)
    }

    func testPauseFiveMinutesAndRepeatedSegmentsDoNotDoubleCount() throws {
        let original = try row(planned: 60, task: UUID(), title: "Retained")
        let first = try FocusTiming.pause(original, at: start.addingTimeInterval(10),
                                          monotonicDelta: 10.375)
        XCTAssertEqual(first.snapshot.actualSeconds, 10.375)
        XCTAssertNil(first.snapshot.deadline)
        XCTAssertNil(first.snapshot.activeSegmentStartedAt)
        XCTAssertEqual(first.snapshot.linkedTaskID, original.linkedTaskID)
        guard case .pause(let pausePayload) = first.transition else { return XCTFail("Expected pause") }
        XCTAssertEqual(pausePayload.expectedCheckpointAt, start)
        let resumed = try FocusTiming.resume(first.snapshot, at: start.addingTimeInterval(310))
        XCTAssertEqual(resumed.snapshot.actualSeconds, 10.375)
        XCTAssertEqual(resumed.snapshot.deadline, start.addingTimeInterval(359.625))
        let checkpoint = try FocusTiming.checkpoint(resumed.snapshot,
            at: start.addingTimeInterval(320), monotonicDelta: 9.125)
        XCTAssertEqual(checkpoint.snapshot.actualSeconds, 19.5)
        XCTAssertEqual(checkpoint.snapshot.activeSegmentStartedAt, start.addingTimeInterval(320))
        XCTAssertEqual(checkpoint.snapshot.deadline, start.addingTimeInterval(360.5))
        guard case .checkpoint(let payload) = checkpoint.transition else {
            return XCTFail("Expected checkpoint")
        }
        XCTAssertEqual(payload.expectedCheckpointAt, start.addingTimeInterval(310))
        XCTAssertEqual(payload.accumulatedActiveSeconds, 19.5)
        let second = try FocusTiming.pause(checkpoint.snapshot,
            at: start.addingTimeInterval(322), monotonicDelta: 1.25)
        XCTAssertEqual(second.snapshot.actualSeconds, 20.75)
        XCTAssertEqual(second.snapshot.id, original.id)
        XCTAssertEqual(second.snapshot.linkedTitleSnapshot, "Retained")
        let again = try FocusTiming.resume(second.snapshot, at: start.addingTimeInterval(622))
        let ended = try FocusTiming.end(again.snapshot, at: start.addingTimeInterval(624),
                                        monotonicDelta: 1.5)
        XCTAssertEqual(ended.snapshot.state, .ended)
        XCTAssertEqual(ended.snapshot.actualSeconds, 22.25)
        XCTAssertEqual(ended.snapshot.endedAt, start.addingTimeInterval(624))
        XCTAssertNil(ended.snapshot.activeSegmentStartedAt)
    }

    func testCountdownCapsAfterSleepAndCompletionWinsOverPauseAndEnd() throws {
        let original = try row(planned: 15, accrued: 3.25,
                               deadline: start.addingTimeInterval(11.75))
        let before = try FocusTiming.sample(original, monotonicDelta: 0.125)
        XCTAssertEqual(before.elapsedSeconds, 3.375)
        XCTAssertEqual(before.remainingSeconds, 11.625)
        XCTAssertEqual(before.countdownSeconds, 12)
        let wall = start.addingTimeInterval(10_000)
        let capped = try FocusTiming.sample(original, monotonicDelta: 100)
        XCTAssertEqual(capped.elapsedSeconds, 15)
        XCTAssertEqual(capped.remainingSeconds, 0)
        XCTAssertEqual(capped.countdownSeconds, 0)
        let paused = try FocusTiming.pause(original, at: wall, monotonicDelta: 100)
        let ended = try FocusTiming.end(original, at: wall, monotonicDelta: 100)
        let complete = try FocusTiming.complete(original, at: wall, monotonicDelta: 100)
        for result in [paused, ended, complete] {
            XCTAssertEqual(result.snapshot.state, .completed)
            XCTAssertEqual(result.snapshot.actualSeconds, 15)
            XCTAssertEqual(result.snapshot.endedAt, wall.addingTimeInterval(-88.25))
            XCTAssertEqual(result.snapshot.checkpointAt, wall)
            guard case .complete = result.transition else { return XCTFail("Expected completion") }
        }
        let atDeadline = try FocusTiming.checkpoint(original, at: start.addingTimeInterval(12),
                                                     monotonicDelta: 11.75)
        XCTAssertEqual(atDeadline.snapshot.endedAt, start.addingTimeInterval(12))
        invalid({ try FocusTiming.complete(original, at: start, monotonicDelta: 1) },
                .invalidTransition)
    }

    func testWallClockJumpsCannotAlterMonotonicDurationAndRebaseAnchors() throws {
        let original = try row(planned: 60)
        let forward = try FocusTiming.checkpoint(original, at: start.addingTimeInterval(3_600),
                                                 monotonicDelta: 2.5)
        XCTAssertEqual(forward.snapshot.actualSeconds, 2.5)
        XCTAssertEqual(forward.snapshot.deadline, start.addingTimeInterval(3_657.5))
        let backward = try FocusTiming.checkpoint(forward.snapshot, at: start.addingTimeInterval(-500),
                                                  monotonicDelta: 4.25)
        XCTAssertEqual(backward.snapshot.actualSeconds, 6.75)
        XCTAssertEqual(backward.snapshot.activeSegmentStartedAt, start.addingTimeInterval(3_600))
        XCTAssertEqual(backward.snapshot.deadline, start.addingTimeInterval(3_653.25))
        let early = try FocusTiming.end(backward.snapshot, at: start.addingTimeInterval(-500),
                                        monotonicDelta: 1.125)
        XCTAssertEqual(early.snapshot.actualSeconds, 7.875)
        XCTAssertEqual(early.snapshot.endedAt, start)
        XCTAssertEqual(early.snapshot.checkpointAt, start.addingTimeInterval(3_600))
        // A backwards wall timestamp must not invalidate a valid completed row.
        let finished = try FocusTiming.complete(backward.snapshot,
            at: start.addingTimeInterval(-500), monotonicDelta: 10_000)
        XCTAssertEqual(finished.snapshot.endedAt, start)
        XCTAssertEqual(finished.snapshot.actualSeconds, 60)
    }

    func testTimingRejectsInvalidSamplesAndStates() throws {
        let running = try row()
        let maximum = try row(planned: Int.max,
                              deadline: start.addingTimeInterval(Double(Int.max)))
        XCTAssertEqual(try FocusTiming.sample(maximum, monotonicDelta: 0).countdownSeconds,
                       Int.max)
        for delta in [Double.nan, .infinity, -.infinity, -0.1] {
            invalid({ try FocusTiming.sample(running, monotonicDelta: delta) }, .invalidTransition)
        }
        let badWall = Date(timeIntervalSinceReferenceDate: .nan)
        invalid({ try FocusTiming.checkpoint(running, at: badWall, monotonicDelta: 1) },
                .invalidTransition)
        invalid({ try FocusTiming.pause(running, at: badWall, monotonicDelta: 1) },
                .invalidTransition)
        let paused = try row(state: .paused, accrued: 2, paused: start, recovery: true)
        invalid({ try FocusTiming.resume(paused, at: start) }, .invalidTransition)
        invalid({ try FocusTiming.sample(paused, monotonicDelta: 5) }, .invalidTransition)
    }
}
