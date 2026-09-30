import Foundation
import XCTest
@testable import Kontrol

/// Domain contract coverage; persistence coverage is added with the repository.
final class AppPreferencesRepositoryTests: XCTestCase {
    private func invalid(_ operation: () throws -> Any, _ expected: AppPreferencesError,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? AppPreferencesError, expected, file: file, line: line)
        }
    }

    func testDefaultsAreValidatedAndHaveNoStoredRevision() throws {
        let defaults = AppPreferences.defaults
        XCTAssertEqual(defaults.payloadVersion, 1)
        XCTAssertEqual(AppPreferences.currentPayloadVersion, 1)
        XCTAssertEqual(defaults.focusDefaultMinutes, 25)
        XCTAssertEqual(defaults.textSize, .system)
        XCTAssertEqual(defaults.reduceMotion, .system)
        XCTAssertEqual(defaults.focusDuration, .default)
        XCTAssertEqual(try defaults.focusDuration.seconds(), 1500)
        XCTAssertEqual(try AppPreferencesDraft().validated(), defaults)
        XCTAssertEqual(AppPreferencesSnapshot.defaults.preferences, defaults)
        XCTAssertNil(AppPreferencesSnapshot.defaults.revision)
    }

    func testPresetsRetainFocusIdentityAndCustomMinutesAreSupported() throws {
        for (minutes, duration) in [(15, FocusDuration.fifteen), (25, .twentyFive), (50, .fifty)] {
            let preferences = try AppPreferences(focusDefaultMinutes: minutes)
            XCTAssertEqual(preferences.focusDuration, duration)
            XCTAssertEqual(try preferences.focusDuration.seconds(), minutes * 60)
            XCTAssertEqual(try AppPreferencesDraft(preferences: preferences).validated(), preferences)
        }
        for minutes in [1, 17, 51, 1440, Int.max / 60] {
            let preferences = try AppPreferences(focusDefaultMinutes: minutes,
                                                 textSize: .large, reduceMotion: .reduce)
            XCTAssertEqual(preferences.focusDuration, .custom(String(minutes)))
            XCTAssertEqual(try preferences.focusDuration.seconds(), minutes * 60)
            XCTAssertEqual(try AppPreferencesDraft(preferences: preferences).validated(), preferences)
        }
    }

    func testCustomTextUsesExistingFocusWhitespaceAndLeadingZeroRules() throws {
        var draft = AppPreferencesDraft()
        for text in ["17", "0017", " \n 17 \t"] {
            draft.focusDefaultMinutes = text
            XCTAssertEqual(try draft.validated().focusDefaultMinutes, 17)
            XCTAssertEqual(draft.focusDefaultMinutes, text)
        }
    }

    func testInvalidCustomInputIsRejectedWithoutChangingDraft() {
        var draft = AppPreferencesDraft()
        for text in ["", " \t\n", "0", "000", "-1", "+5", "1.5", "1e2", "1E2",
                     "NaN", "Infinity", "１２", "١٢", "1 0", "2\n3", "0x10", "1_000"] {
            draft.focusDefaultMinutes = text
            invalid({ try draft.validated() }, .invalidFocusDuration(.invalidCustomMinutes))
            XCTAssertEqual(draft.focusDefaultMinutes, text)
        }
    }

    func testOverflowUsesCheckedFocusMultiplicationWithNoSmallerLimit() throws {
        var draft = AppPreferencesDraft()
        draft.focusDefaultMinutes = String(Int.max / 60)
        XCTAssertEqual(try draft.validated().focusDefaultMinutes, Int.max / 60)
        for text in [String(Int.max / 60 + 1), String(Int.max), String(repeating: "9", count: 100)] {
            draft.focusDefaultMinutes = text
            invalid({ try draft.validated() }, .invalidFocusDuration(.durationOverflow))
            XCTAssertEqual(draft.focusDefaultMinutes, text)
        }
        invalid({ try AppPreferences(focusDefaultMinutes: Int.max / 60 + 1) },
                .invalidFocusDuration(.durationOverflow))
        invalid({ try AppPreferences(focusDefaultMinutes: Int.max) },
                .invalidFocusDuration(.durationOverflow))
    }

    func testTypedAndStoredMinutesMustAlsoBeValidated() {
        for minutes in [0, -1, Int.min] {
            invalid({ try AppPreferences(focusDefaultMinutes: minutes) },
                    .invalidFocusDuration(.invalidCustomMinutes))
            invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: minutes,
                                          textSizeCode: "system", reduceMotionCode: "system") },
                    .invalidFocusDuration(.invalidCustomMinutes))
        }
        invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: Int.max,
                                      textSizeCode: "system", reduceMotionCode: "system") },
                .invalidFocusDuration(.durationOverflow))
    }

    func testUnsupportedPayloadVersionsAreNotCoerced() {
        for version in [Int.min, -1, 0, 2, Int.max] {
            invalid({ try AppPreferences(payloadVersion: version, focusDefaultMinutes: 25,
                                          textSizeCode: "system", reduceMotionCode: "system") },
                    .unsupportedPayloadVersion(version))
        }
    }

    func testOnlyExactSupportedEnumCodesAreAccepted() throws {
        XCTAssertEqual(AppTextSize.allCases.map(\.rawValue), ["system", "large"])
        XCTAssertEqual(AppReduceMotion.allCases.map(\.rawValue), ["system", "reduce"])
        for textSize in AppTextSize.allCases {
            for reduceMotion in AppReduceMotion.allCases {
                let preferences = try AppPreferences(payloadVersion: 1, focusDefaultMinutes: 17,
                    textSizeCode: textSize.rawValue, reduceMotionCode: reduceMotion.rawValue)
                XCTAssertEqual(preferences.textSize, textSize)
                XCTAssertEqual(preferences.reduceMotion, reduceMotion)
                XCTAssertEqual(preferences.payloadVersion, 1)
            }
        }
        for code in ["", "System", " system", "large ", "small", "reduce"] {
            invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: 25,
                                          textSizeCode: code, reduceMotionCode: "system") },
                    .unsupportedTextSize(code))
        }
        for code in ["", "System", "system ", " reduce", "off", "large"] {
            invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: 25,
                                          textSizeCode: "system", reduceMotionCode: code) },
                    .unsupportedReduceMotion(code))
        }
    }

    func testDraftAndSnapshotAreIndependentDetachedValues() throws {
        let revision = UUID()
        let preferences = try AppPreferences(focusDefaultMinutes: 50, textSize: .large,
                                             reduceMotion: .reduce)
        let snapshot = AppPreferencesSnapshot(preferences: preferences, revision: revision)
        let original = AppPreferencesDraft(preferences: snapshot.preferences)
        var edited = original
        edited.focusDefaultMinutes = "7"
        edited.textSize = .system
        edited.reduceMotion = .system
        XCTAssertEqual(snapshot.preferences, preferences)
        XCTAssertEqual(snapshot.revision, revision)
        XCTAssertEqual(original.focusDefaultMinutes, "50")
        XCTAssertEqual(original.textSize, .large)
        XCTAssertEqual(original.reduceMotion, .reduce)
        XCTAssertEqual(try edited.validated(), try AppPreferences(focusDefaultMinutes: 7))
    }
}
