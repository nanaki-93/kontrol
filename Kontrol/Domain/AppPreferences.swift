import Foundation

/// Stable payload codes, independent of UI labels and system accessibility inputs.
enum AppTextSize: String, CaseIterable, Sendable {
    case system, large
}

enum AppReduceMotion: String, CaseIterable, Sendable {
    case system, reduce
}

enum AppPreferencesError: Error, Equatable {
    case invalidFocusDuration(FocusError)
    case unsupportedPayloadVersion(Int)
    case unsupportedTextSize(String)
    case unsupportedReduceMotion(String)
    case invalidStoredData
    case duplicateRecords
    case staleRevision
    case persistenceFailure
}

/// Validated detached values. No model, editor, or active session is owned here.
struct AppPreferences: Equatable, Sendable {
    static let currentPayloadVersion = 1
    static let defaults = AppPreferences()

    let payloadVersion: Int
    let focusDefaultMinutes: Int
    let textSize: AppTextSize
    let reduceMotion: AppReduceMotion

    private init() {
        payloadVersion = Self.currentPayloadVersion
        focusDefaultMinutes = 25
        textSize = .system
        reduceMotion = .system
    }

    init(focusDefaultMinutes: Int, textSize: AppTextSize = .system,
         reduceMotion: AppReduceMotion = .system) throws {
        _ = try Self.focusSeconds(String(focusDefaultMinutes))
        payloadVersion = Self.currentPayloadVersion
        self.focusDefaultMinutes = focusDefaultMinutes
        self.textSize = textSize
        self.reduceMotion = reduceMotion
    }

    /// Storage boundaries must reject unfamiliar payloads, never coerce to defaults.
    init(payloadVersion: Int, focusDefaultMinutes: Int,
         textSizeCode: String, reduceMotionCode: String) throws {
        guard payloadVersion == Self.currentPayloadVersion else {
            throw AppPreferencesError.unsupportedPayloadVersion(payloadVersion)
        }
        guard let textSize = AppTextSize(rawValue: textSizeCode) else {
            throw AppPreferencesError.unsupportedTextSize(textSizeCode)
        }
        guard let reduceMotion = AppReduceMotion(rawValue: reduceMotionCode) else {
            throw AppPreferencesError.unsupportedReduceMotion(reduceMotionCode)
        }
        try self.init(focusDefaultMinutes: focusDefaultMinutes,
                      textSize: textSize, reduceMotion: reduceMotion)
    }

    /// Retain Focus's preset identity as well as its full custom-duration range.
    var focusDuration: FocusDuration {
        switch focusDefaultMinutes {
        case 15: return .fifteen
        case 25: return .twentyFive
        case 50: return .fifty
        default: return .custom(String(focusDefaultMinutes))
        }
    }

    fileprivate static func focusSeconds(_ text: String) throws -> Int {
        do {
            return try FocusDuration.custom(text).seconds()
        } catch let error as FocusError {
            throw AppPreferencesError.invalidFocusDuration(error)
        }
    }
}

/// A nil revision denotes absent storage, not a newly inserted default row.
struct AppPreferencesSnapshot: Equatable, Sendable {
    let preferences: AppPreferences
    let revision: UUID?

    static let defaults = AppPreferencesSnapshot(preferences: .defaults, revision: nil)
}

/// Unsaved input preserves the exact custom text, including invalid values.
/// Editor baseline revisions remain separate from the values being submitted.
struct AppPreferencesDraft: Equatable, Sendable {
    var focusDefaultMinutes: String
    var textSize: AppTextSize
    var reduceMotion: AppReduceMotion

    init(preferences: AppPreferences = .defaults) {
        focusDefaultMinutes = String(preferences.focusDefaultMinutes)
        textSize = preferences.textSize
        reduceMotion = preferences.reduceMotion
    }

    func validated() throws -> AppPreferences {
        let seconds = try AppPreferences.focusSeconds(focusDefaultMinutes)
        return try AppPreferences(focusDefaultMinutes: seconds / 60,
                                  textSize: textSize, reduceMotion: reduceMotion)
    }
}

@MainActor
protocol AppPreferencesRepository {
    func load() throws -> AppPreferencesSnapshot
    func save(_ draft: AppPreferencesDraft, expectedRevision: UUID?) throws -> AppPreferencesSnapshot
}
