import Foundation

/// Errors are classifications only: never attach personal answer text or a pin payload.
enum LessonExperienceError: Error, Equatable {
    case lessonNotFound
    case attemptNotFound
    case invalidTransition
    case staleRevision
    case staleSlot
    case completionRequirementsMissing
    case contentUnavailable
    case invalidStoredData
    case persistenceFailure
}

/// Version belongs to the envelope, independently of the author's contentVersion.
/// A pin is the entire definition, not a reference to a replaceable catalog row.
struct PinnedLessonContent: Codable, Equatable {
    static let currentVersion = 1
    let envelopeVersion: Int
    let definition: LessonDefinitionSnapshot

    init(definition: LessonDefinitionSnapshot) {
        envelopeVersion = Self.currentVersion
        self.definition = definition
    }

    func encoded() throws -> Data {
        try Self.validate(definition)
        guard envelopeVersion == Self.currentVersion else { throw LessonExperienceError.invalidStoredData }
        return try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?, lessonID: String, contentVersion: Int) throws -> Self {
        guard let data, !data.isEmpty else { throw LessonExperienceError.contentUnavailable }
        // Reject unknown fields as well as missing/wrongly typed fields: a future
        // envelope must not be silently interpreted as the current definition.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["envelopeVersion", "definition"]),
              let rawDefinition = object["definition"] as? [String: Any],
              Set(rawDefinition.keys) == Set([
                "id", "objectiveKey", "objective", "title", "topicID", "subtopicID",
                "conceptIDs", "difficulty", "format", "estimatedMinutes",
                "prerequisiteConceptIDs", "explanation", "workedExample", "exercise",
                "referenceAnswer", "selfCheckCriteria", "contentVersion",
                "normalizedContentHash", "source", "provenance"
              ]),
              let pin = try? JSONDecoder().decode(Self.self, from: data),
              pin.envelopeVersion == currentVersion,
              pin.definition.id == lessonID,
              pin.definition.contentVersion == contentVersion else {
            throw LessonExperienceError.invalidStoredData
        }
        try validate(pin.definition)
        return pin
    }

    private static func validate(_ definition: LessonDefinitionSnapshot) throws {
        guard !definition.id.isEmpty, definition.contentVersion > 0,
              !definition.topicID.isEmpty, !definition.subtopicID.isEmpty,
              !definition.normalizedContentHash.isEmpty,
              ["learn", "code", "question", "design"].contains(definition.format) else {
            throw LessonExperienceError.invalidStoredData
        }
    }

    // The released completed-snapshot Codable fields/order are not extended by V5.
    var completedSnapshot: KontrolSchemaV1.LessonContentSnapshot {
        .init(title: definition.title, objectiveKey: definition.objectiveKey,
              conceptIDs: definition.conceptIDs, difficulty: definition.difficulty,
              format: definition.format, explanation: definition.explanation,
              workedExample: definition.workedExample, exercise: definition.exercise,
              referenceAnswer: definition.referenceAnswer,
              selfCheckCriteria: definition.selfCheckCriteria)
    }
}

/// Only committed attempt/progress values should be passed in. Callers persist the
/// resulting value in their private context before publishing a receipt.
enum LessonExperience {
    static func studiedContent(_ attempt: LessonAttemptSnapshot) throws -> LessonStudiedContent {
        // Prefer the full studied definition for newly completed attempts. A
        // present but corrupt pin must fail rather than fall back to reduced data.
        // An empty pin records an upgrade that could not recover the studied
        // version. Nil still allows a legacy draft to match the installed version.
        if let data = attempt.pinnedContentData, data.isEmpty { return .unavailable }
        if let data = attempt.pinnedContentData {
            return .pinned(try PinnedLessonContent.decode(data, lessonID: attempt.lessonID,
                                                          contentVersion: attempt.contentVersion).definition)
        }
        if attempt.completedAt != nil, let legacy = attempt.completedContentSnapshot {
            return .legacyCompleted(legacy)
        }
        return .unavailable
    }

    static func edit(_ attempt: LessonAttemptSnapshot, status: LessonProgressStatus,
                     expectedRevision: Int, answer: String) throws -> LessonAttemptSnapshot {
        try checkActive(attempt, status: status, expectedRevision: expectedRevision)
        guard answer != attempt.answerDraft else { return attempt }
        return try copy(attempt, answer: answer, clearAcknowledgement: true)
    }

    static func reveal(_ attempt: LessonAttemptSnapshot, status: LessonProgressStatus,
                       expectedRevision: Int, now: Date) throws -> LessonAttemptSnapshot {
        try checkActiveStateAndPin(attempt, status: status)
        guard attempt.solutionRevealedAt == nil else { return attempt }
        try checkRevision(attempt, expectedRevision: expectedRevision)
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw LessonExperienceError.invalidTransition }
        return try copy(attempt, revealedAt: now)
    }

    static func acknowledge(_ attempt: LessonAttemptSnapshot, status: LessonProgressStatus,
                            expectedRevision: Int, acknowledged: Bool,
                            now: Date) throws -> LessonAttemptSnapshot {
        try checkActiveStateAndPin(attempt, status: status)
        guard attempt.solutionRevealedAt != nil else { throw LessonExperienceError.invalidTransition }
        if acknowledged == (attempt.selfCheckAcknowledgedAt != nil) { return attempt }
        try checkRevision(attempt, expectedRevision: expectedRevision)
        if acknowledged && !now.timeIntervalSinceReferenceDate.isFinite {
            throw LessonExperienceError.invalidTransition
        }
        return try copy(attempt, acknowledgedAt: acknowledged ? now : nil,
                        clearAcknowledgement: !acknowledged)
    }

    static func complete(_ attempt: LessonAttemptSnapshot, progress: LessonProgressSnapshot,
                         expectedRevision: Int, now: Date) throws -> LessonAttemptSnapshot {
        guard progress.lessonID == attempt.lessonID else { throw LessonExperienceError.invalidStoredData }
        // Repeated completion is idempotent even when the caller holds an old revision.
        if progress.status == .completed, attempt.completedAt != nil,
           attempt.completedContentSnapshot != nil {
            if attempt.pinnedContentData != nil { _ = try studiedContent(attempt) }
            return attempt
        }
        try checkActive(attempt, status: progress.status, expectedRevision: expectedRevision)
        guard progress.startedAt != nil, attempt.solutionRevealedAt != nil,
              attempt.selfCheckAcknowledgedAt != nil else {
            throw LessonExperienceError.completionRequirementsMissing
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw LessonExperienceError.invalidTransition }
        let pin = try PinnedLessonContent.decode(attempt.pinnedContentData,
                                                 lessonID: attempt.lessonID,
                                                 contentVersion: attempt.contentVersion)
        return try copy(attempt, completedAt: now, completedContent: pin.completedSnapshot)
    }

    private static func checkActive(_ attempt: LessonAttemptSnapshot, status: LessonProgressStatus,
                                    expectedRevision: Int) throws {
        try checkActiveStateAndPin(attempt, status: status)
        try checkRevision(attempt, expectedRevision: expectedRevision)
    }

    private static func checkActiveStateAndPin(_ attempt: LessonAttemptSnapshot,
                                               status: LessonProgressStatus) throws {
        guard status == .started, attempt.completedAt == nil else {
            throw LessonExperienceError.invalidTransition
        }
        guard attempt.revision >= 0 else { throw LessonExperienceError.invalidStoredData }
        _ = try PinnedLessonContent.decode(attempt.pinnedContentData,
                                           lessonID: attempt.lessonID,
                                           contentVersion: attempt.contentVersion)
    }

    private static func checkRevision(_ attempt: LessonAttemptSnapshot,
                                      expectedRevision: Int) throws {
        guard expectedRevision == attempt.revision else { throw LessonExperienceError.staleRevision }
    }

    // Explicit overrides avoid accidentally changing an immutable snapshot on a no-op.
    private static func copy(_ value: LessonAttemptSnapshot, answer: String? = nil,
                             revealedAt: Date? = nil, acknowledgedAt: Date? = nil,
                             clearAcknowledgement: Bool = false, completedAt: Date? = nil,
                             completedContent: KontrolSchemaV1.LessonContentSnapshot? = nil) throws -> LessonAttemptSnapshot {
        guard value.revision < Int.max else { throw LessonExperienceError.invalidStoredData }
        return LessonAttemptSnapshot(id: value.id, lessonID: value.lessonID,
                                     contentVersion: value.contentVersion,
                                     answerDraft: answer ?? value.answerDraft,
                                     solutionRevealedAt: revealedAt ?? value.solutionRevealedAt,
                                     selfCheckAcknowledgedAt: clearAcknowledgement ? nil : (acknowledgedAt ?? value.selfCheckAcknowledgedAt),
                                     completedAt: completedAt ?? value.completedAt,
                                     completedContentSnapshot: completedContent ?? value.completedContentSnapshot,
                                     pinnedContentData: value.pinnedContentData,
                                     revision: value.revision + 1)
    }
}
