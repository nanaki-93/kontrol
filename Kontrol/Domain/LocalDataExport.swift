import Foundation

/// Finite categories only; never attach authored content, identities, or paths.
enum LocalDataExportError: Error, Equatable {
    case unsupportedVersion
    case invalidDate
    case invalidValue
    case duplicateIdentity
    case identityMismatch
}

/// A canonical UTC instant. Quantization happens once, at capture, not on decode.
struct ExportTimestamp: Codable, Sendable, Equatable, Comparable {
    let value: String

    init(_ date: Date) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else {
            throw LocalDataExportError.invalidDate
        }
        let rounded = Date(timeIntervalSince1970: (seconds * 1_000).rounded() / 1_000)
        try self.init(value: Self.formatter().string(from: rounded))
    }

    init(value: String) throws {
        let formatter = Self.formatter()
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#,
                          options: .regularExpression) != nil,
              !value.hasPrefix("0000"), let date = formatter.date(from: value),
              date.timeIntervalSince1970.isFinite, formatter.string(from: date) == value else {
            throw LocalDataExportError.invalidDate
        }
        self.value = value
    }

    var date: Date { Self.formatter().date(from: value)! }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    init(from decoder: Decoder) throws {
        try self.init(value: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        // Foundation otherwise switches to Julian dates before October 1582.
        formatter.gregorianStartDate = Date(timeIntervalSince1970: -62_135_596_800)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.isLenient = false
        return formatter
    }
}

/// Synthesized Codable must emit null, not omit an unavailable field. The key
/// remains required on decode. This wrapper holds only a detached value.
@propertyWrapper
struct ExportNull<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var wrappedValue: Value?
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

/// Version-1 field allowlist. No SwiftData models, payload blobs, services, or drafts.
struct LocalDataExport: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var schemaVersion: Int = Self.currentVersion
    var exportedAt: ExportTimestamp
    var appVersion: String
    var tasks: [Task] = []
    var blocks: [Block] = []
    var learning: Learning = .init()
    var sessions: [Session] = []
    var feedPreferences: FeedPreferences = .init(selectedTopicIDs: [], feeds: [])
    var generalPreferences: GeneralPreferences = .defaults

    struct PlannedDay: Codable, Sendable, Equatable {
        var calendarIdentifier: String
        var year: Int
        var month: Int
        var day: Int
        var timeZoneID: String
    }

    struct Task: Codable, Sendable, Equatable {
        var id: UUID
        var title: String
        @ExportNull var notes: String?
        @ExportNull var dueAt: ExportTimestamp?
        @ExportNull var plannedDay: PlannedDay?
        var createdAt: ExportTimestamp
        @ExportNull var completedAt: ExportTimestamp?
    }

    struct Block: Codable, Sendable, Equatable {
        var id: UUID
        var title: String
        var startAt: ExportTimestamp
        var endAt: ExportTimestamp
        @ExportNull var note: String?
        @ExportNull var lessonID: String?
        @ExportNull var linkedTitleSnapshot: String?
    }

    struct Session: Codable, Sendable, Equatable {
        var id: UUID
        var state: String
        var plannedSeconds: Int
        var accumulatedActiveSeconds: Double
        @ExportNull var activeSegmentStartedAt: ExportTimestamp?
        @ExportNull var deadline: ExportTimestamp?
        @ExportNull var pausedAt: ExportTimestamp?
        var startedAt: ExportTimestamp
        @ExportNull var endedAt: ExportTimestamp?
        var checkpointAt: ExportTimestamp
        var recoveryRequired: Bool
        @ExportNull var linkedTaskID: UUID?
        @ExportNull var linkedLessonID: String?
        @ExportNull var linkedTitleSnapshot: String?
    }

    struct FeedPreferences: Codable, Sendable, Equatable {
        var selectedTopicIDs: [String]
        var feeds: [Feed]
    }

    struct Feed: Codable, Sendable, Equatable {
        var id: UUID
        var name: String
        var endpoint: String
        var topicIDs: [String]
        var isEnabled: Bool
    }

    struct GeneralPreferences: Codable, Sendable, Equatable {
        var schemaVersion: Int = 1
        var focusDefaultMinutes: Int
        var textSize: String
        var reduceMotion: String
        var ai: AI
        static let defaults = Self(focusDefaultMinutes: 25, textSize: "system", reduceMotion: "system",
                                   ai: .init(enabled: false, providerID: "openai", modelID: nil))
    }

    struct AI: Codable, Sendable, Equatable {
        var enabled: Bool
        var providerID: String
        @ExportNull var modelID: String?
    }

    struct Learning: Codable, Sendable, Equatable {
        var topics: [Topic] = []
        var subtopics: [Subtopic] = []
        var concepts: [Concept] = []
        var definitions: [Definition] = []
        var progress: [Progress] = []
        var attempts: [Attempt] = []
        var slots: [Slot] = []
        var terminalRecords: [TerminalRecord] = []
        var catalogMembership: [CatalogMembership] = []
    }

    struct Topic: Codable, Sendable, Equatable {
        var id: String
        var name: String
    }

    struct Subtopic: Codable, Sendable, Equatable {
        var id: String
        var topicID: String
        var name: String
    }

    struct Concept: Codable, Sendable, Equatable {
        var id: String
        var subtopicID: String
        var name: String
        var prerequisiteConceptIDs: [String]
    }

    struct Definition: Codable, Sendable, Equatable {
        var id: String
        var objectiveKey: String
        var objective: String // Empty on some retained legacy definitions; never invented.
        var title: String
        var topicID: String
        var subtopicID: String
        var conceptIDs: [String]
        var difficulty: String
        var format: String
        var estimatedMinutes: Int
        var prerequisiteConceptIDs: [String]
        var explanation: String
        var workedExample: String
        var exercise: String
        var referenceAnswer: String
        var selfCheckCriteria: [String]
        var contentVersion: Int
        var normalizedContentHash: String
        var source: String
        @ExportNull var provenance: Provenance?
    }

    /// Explicitly approved attribution/generation metadata, never raw stored JSON.
    struct Provenance: Codable, Sendable, Equatable {
        var schemaVersion: Int = 1
        @ExportNull var attribution: String?
        @ExportNull var generation: Generation?
    }

    struct Generation: Codable, Sendable, Equatable {
        var provider: String
        var requestedModel: String
        @ExportNull var returnedModel: String?
        var generatedAt: ExportTimestamp
        var operationID: UUID
        var requestSchemaVersion: Int
        var objectiveRegistryVersion: Int
    }

    struct Progress: Codable, Sendable, Equatable {
        var lessonID: String
        var status: String
        @ExportNull var firstShownAt: ExportTimestamp?
        @ExportNull var startedAt: ExportTimestamp?
        @ExportNull var completedAt: ExportTimestamp?
        @ExportNull var dismissedAt: ExportTimestamp?
        @ExportNull var lastOpenedAt: ExportTimestamp?
    }

    struct Attempt: Codable, Sendable, Equatable {
        var id: UUID
        var lessonID: String
        var contentVersion: Int
        var answerDraft: String // Persisted saved answer only, not the unsaved editor.
        var revision: Int
        @ExportNull var solutionRevealedAt: ExportTimestamp?
        @ExportNull var selfCheckAcknowledgedAt: ExportTimestamp?
        @ExportNull var completedAt: ExportTimestamp?
        @ExportNull var pinnedContent: Pin?
        @ExportNull var completedContentSnapshot: CompletedContent?
    }

    struct Pin: Codable, Sendable, Equatable {
        var envelopeVersion: Int = 1
        var definition: Definition
    }

    /// The released partial completed snapshot has no identity or invented metadata.
    struct CompletedContent: Codable, Sendable, Equatable {
        var title: String
        var objectiveKey: String
        var conceptIDs: [String]
        var difficulty: String
        var format: String
        var explanation: String
        var workedExample: String
        var exercise: String
        var referenceAnswer: String
        var selfCheckCriteria: [String]
    }

    struct Slot: Codable, Sendable, Equatable {
        var key: String
        var topicID: String
        var slotIndex: Int
        var lessonID: String
        var assignedAt: ExportTimestamp
    }

    struct TerminalRecord: Codable, Sendable, Equatable {
        var schemaVersion: Int = 1
        var lessonID: String
        var provenance: String
        @ExportNull var title: String?
        @ExportNull var topicID: String?
        @ExportNull var subtopicID: String?
        @ExportNull var contentVersion: Int?
        @ExportNull var objectiveKey: String?
        @ExportNull var conceptIDs: [String]?
        @ExportNull var normalizedContentHash: String?
        @ExportNull var format: String?
        @ExportNull var dismissalTimeDefinition: Definition?
    }

    struct CatalogMembership: Codable, Sendable, Equatable {
        var schemaVersion: Int = 1
        var catalogID: String
        var catalogVersion: Int
        var topicIDs: [String]
        var subtopicIDs: [String]
        var conceptIDs: [String]
        var seededLessonIDs: [String]
    }

    /// Entry points used by preparation; plain Codable also validates the envelope.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, appVersion, tasks, blocks, learning, sessions
        case feedPreferences, generalPreferences
    }

    init(exportedAt: ExportTimestamp, appVersion: String) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentVersion else { throw LocalDataExportError.unsupportedVersion }
        exportedAt = try container.decode(ExportTimestamp.self, forKey: .exportedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        tasks = try container.decode([Task].self, forKey: .tasks)
        blocks = try container.decode([Block].self, forKey: .blocks)
        learning = try container.decode(Learning.self, forKey: .learning)
        sessions = try container.decode([Session].self, forKey: .sessions)
        feedPreferences = try container.decode(FeedPreferences.self, forKey: .feedPreferences)
        generalPreferences = try container.decode(GeneralPreferences.self, forKey: .generalPreferences)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        let value = canonicalized()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.schemaVersion, forKey: .schemaVersion)
        try container.encode(value.exportedAt, forKey: .exportedAt)
        try container.encode(value.appVersion, forKey: .appVersion)
        try container.encode(value.tasks, forKey: .tasks)
        try container.encode(value.blocks, forKey: .blocks)
        try container.encode(value.learning, forKey: .learning)
        try container.encode(value.sessions, forKey: .sessions)
        try container.encode(value.feedPreferences, forKey: .feedPreferences)
        try container.encode(value.generalPreferences, forKey: .generalPreferences)
    }

    func validate() throws {
        try version(schemaVersion)
        try require(!appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try unique(tasks.map { $0.id.uuidString })
        try unique(blocks.map { $0.id.uuidString })
        try unique(sessions.map { $0.id.uuidString })
        for task in tasks {
            try nonblank(task.title)
            if let day = task.plannedDay { try day.validate() }
        }
        for block in blocks {
            try nonblank(block.title)
            try require(block.startAt < block.endAt)
            try optionalIdentity(block.lessonID)
        }
        for session in sessions {
            try require(["running", "paused", "completed", "ended"].contains(session.state))
            try require(session.plannedSeconds > 0 && session.accumulatedActiveSeconds.isFinite &&
                        session.accumulatedActiveSeconds >= 0)
            try require(session.linkedTaskID == nil || session.linkedLessonID == nil)
            try optionalIdentity(session.linkedLessonID)
        }
        try version(generalPreferences.schemaVersion)
        _ = try AppPreferences(payloadVersion: generalPreferences.schemaVersion,
                               focusDefaultMinutes: generalPreferences.focusDefaultMinutes,
                               textSizeCode: generalPreferences.textSize,
                               reduceMotionCode: generalPreferences.reduceMotion)
        try identity(generalPreferences.ai.providerID)
        if let model = generalPreferences.ai.modelID { try nonblank(model) }
        try identities(feedPreferences.selectedTopicIDs)
        try unique(feedPreferences.feeds.map { $0.id.uuidString })
        for feed in feedPreferences.feeds {
            try nonblank(feed.name)
            try nonblank(feed.endpoint)
            try identities(feed.topicIDs)
        }
        try unique(learning.topics.map(\.id))
        try unique(learning.subtopics.map(\.id))
        try unique(learning.concepts.map(\.id))
        try unique(learning.definitions.map(\.id))
        try unique(learning.progress.map(\.lessonID))
        try unique(learning.attempts.map { $0.id.uuidString })
        try unique(learning.slots.map(\.key))
        try unique(learning.slots.map(\.lessonID))
        try unique(learning.terminalRecords.map(\.lessonID))
        try unique(learning.catalogMembership.map(\.catalogID))
        for topic in learning.topics { try nonblank(topic.name) }
        for subtopic in learning.subtopics { try identity(subtopic.topicID); try nonblank(subtopic.name) }
        for concept in learning.concepts {
            try identity(concept.subtopicID); try nonblank(concept.name)
            try identities(concept.prerequisiteConceptIDs)
        }
        for definition in learning.definitions { try definition.validate() }
        for progress in learning.progress {
            try require(["available", "started", "completed", "dismissed"].contains(progress.status))
        }
        for attempt in learning.attempts {
            try identity(attempt.lessonID)
            try require(attempt.contentVersion > 0 && attempt.revision >= 0)
            if let pin = attempt.pinnedContent {
                try version(pin.envelopeVersion)
                try pin.definition.validate()
                guard pin.definition.id == attempt.lessonID,
                      pin.definition.contentVersion == attempt.contentVersion else {
                    throw LocalDataExportError.identityMismatch
                }
            }
            if let content = attempt.completedContentSnapshot { try content.validate() }
        }
        for slot in learning.slots {
            try identity(slot.topicID)
            try require(slot.slotIndex >= 0)
            guard slot.key == "\(slot.topicID.utf8.count):\(slot.topicID):\(slot.slotIndex)" else {
                throw LocalDataExportError.identityMismatch
            }
        }
        for record in learning.terminalRecords { try record.validate() }
        for membership in learning.catalogMembership {
            try version(membership.schemaVersion)
            try require(membership.catalogVersion > 0)
            try identities(membership.topicIDs); try identities(membership.subtopicIDs)
            try identities(membership.conceptIDs); try identities(membership.seededLessonIDs)
        }
    }

    /// Only sets/identity collections are sorted. Teaching sections and self-checks
    /// are sequences and are deliberately never sorted or normalized.
    func canonicalized() -> Self {
        var value = self
        value.tasks.sort { $0.id.uuidString < $1.id.uuidString }
        value.blocks.sort { $0.id.uuidString < $1.id.uuidString }
        value.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        value.feedPreferences.selectedTopicIDs.sort()
        value.feedPreferences.feeds = value.feedPreferences.feeds.map { feed in
            var feed = feed; feed.topicIDs.sort(); return feed
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        value.learning.topics.sort { $0.id < $1.id }
        value.learning.subtopics.sort { $0.id < $1.id }
        value.learning.concepts = value.learning.concepts.map { concept in
            var concept = concept; concept.prerequisiteConceptIDs.sort(); return concept
        }.sorted { $0.id < $1.id }
        value.learning.definitions = value.learning.definitions.map { $0.canonicalized() }.sorted { $0.id < $1.id }
        value.learning.progress.sort { $0.lessonID < $1.lessonID }
        value.learning.attempts = value.learning.attempts.map { attempt in
            var attempt = attempt
            if var pin = attempt.pinnedContent { pin.definition = pin.definition.canonicalized(); attempt.pinnedContent = pin }
            if var content = attempt.completedContentSnapshot { content.conceptIDs.sort(); attempt.completedContentSnapshot = content }
            return attempt
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        value.learning.slots.sort { $0.key < $1.key }
        value.learning.terminalRecords = value.learning.terminalRecords.map { record in
            var record = record
            record.conceptIDs = record.conceptIDs?.sorted()
            record.dismissalTimeDefinition = record.dismissalTimeDefinition?.canonicalized()
            return record
        }.sorted { $0.lessonID < $1.lessonID }
        value.learning.catalogMembership = value.learning.catalogMembership.map { membership in
            var membership = membership
            membership.topicIDs.sort(); membership.subtopicIDs.sort(); membership.conceptIDs.sort()
            membership.seededLessonIDs.sort(); return membership
        }.sorted { $0.catalogID < $1.catalogID }
        return value
    }
}

private func require(_ condition: Bool) throws {
    guard condition else { throw LocalDataExportError.invalidValue }
}
private func version(_ value: Int) throws {
    guard value == 1 else { throw LocalDataExportError.unsupportedVersion }
}
private func nonblank(_ value: String) throws {
    try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}
private func identity(_ value: String) throws {
    try nonblank(value)
    try require(value == value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping)
}
private func optionalIdentity(_ value: String?) throws { if let value { try identity(value) } }
private func unique(_ values: [String]) throws {
    try values.forEach(identity)
    guard Set(values).count == values.count else { throw LocalDataExportError.duplicateIdentity }
}
private func identities(_ values: [String]) throws { try unique(values) }
private func hash(_ value: String) throws {
    try require(value.hasPrefix("sha256:") && value.utf8.count == 71 &&
                value.utf8.dropFirst(7).allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
}
private func contentCodes(difficulty: String, format: String) throws {
    try require(["basic", "intermediate", "advanced"].contains(difficulty))
    try require(["learn", "code", "question", "design"].contains(format))
}

private extension LocalDataExport.PlannedDay {
    func validate() throws {
        let calendars: [Calendar.Identifier] = [.gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
            .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic, .islamicCivil, .japanese, .persian,
            .republicOfChina, .islamicTabular, .islamicUmmAlQura]
        guard let identifier = calendars.first(where: { String(describing: $0) == calendarIdentifier }),
              let zone = TimeZone(identifier: timeZoneID), year > 0, month > 0, day > 0 else {
            throw LocalDataExportError.invalidDate
        }
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { throw LocalDataExportError.invalidDate }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { throw LocalDataExportError.invalidDate }
    }
}

private extension LocalDataExport.Definition {
    func validate() throws {
        try identity(id); try identity(topicID); try identity(subtopicID)
        try nonblank(objectiveKey); try nonblank(title)
        try identities(conceptIDs); try require(!conceptIDs.isEmpty)
        try identities(prerequisiteConceptIDs)
        try contentCodes(difficulty: difficulty, format: format)
        try require(estimatedMinutes > 0 && contentVersion > 0)
        try hash(normalizedContentHash)
        try require(["seed", "generated"].contains(source))
        try [explanation, workedExample, exercise, referenceAnswer].forEach(nonblank)
        try require(!selfCheckCriteria.isEmpty); try selfCheckCriteria.forEach(nonblank)
        if let provenance {
            try version(provenance.schemaVersion)
            if let attribution = provenance.attribution { try nonblank(attribution) }
            if let generation = provenance.generation {
                try identity(generation.provider); try nonblank(generation.requestedModel)
                if let returned = generation.returnedModel { try nonblank(returned) }
                try version(generation.requestSchemaVersion)
                try require(generation.objectiveRegistryVersion > 0)
                try require(source == "generated")
            }
        }
    }
    func canonicalized() -> Self {
        var value = self
        value.conceptIDs.sort(); value.prerequisiteConceptIDs.sort()
        return value
    }
}

private extension LocalDataExport.CompletedContent {
    func validate() throws {
        try nonblank(title); try nonblank(objectiveKey); try identities(conceptIDs)
        try contentCodes(difficulty: difficulty, format: format)
        try [explanation, workedExample, exercise, referenceAnswer].forEach(nonblank)
        try require(!selfCheckCriteria.isEmpty); try selfCheckCriteria.forEach(nonblank)
    }
}

private extension LocalDataExport.TerminalRecord {
    func validate() throws {
        try version(schemaVersion)
        let legacy = ["legacyCompletedPartial", "legacyRecoveredReference"].contains(provenance)
        try require(legacy || ["studiedPin", "dismissalPin", "dismissalReference"].contains(provenance))
        try optionalIdentity(topicID); try optionalIdentity(subtopicID)
        if let contentVersion { try require(contentVersion > 0) }
        if let objectiveKey { try nonblank(objectiveKey) }
        if let conceptIDs { try identities(conceptIDs); try require(!conceptIDs.isEmpty) }
        if let normalizedContentHash { try hash(normalizedContentHash) }
        if let format { try require(["learn", "code", "question", "design"].contains(format)) }
        if !legacy {
            try require(title != nil && topicID != nil && subtopicID != nil && contentVersion != nil &&
                        objectiveKey != nil && conceptIDs != nil && normalizedContentHash != nil && format != nil)
        }
        if let definition = dismissalTimeDefinition {
            try require(["dismissalReference", "legacyRecoveredReference"].contains(provenance))
            try definition.validate()
            guard definition.id == lessonID,
                  contentVersion.map({ $0 == definition.contentVersion }) ?? true,
                  topicID.map({ $0 == definition.topicID }) ?? true,
                  subtopicID.map({ $0 == definition.subtopicID }) ?? true,
                  objectiveKey.map({ $0 == definition.objectiveKey }) ?? true,
                  normalizedContentHash.map({ $0 == definition.normalizedContentHash }) ?? true,
                  format.map({ $0 == definition.format }) ?? true,
                  conceptIDs.map({ Set($0) == Set(definition.conceptIDs) }) ?? true else {
                throw LocalDataExportError.identityMismatch
            }
        }
    }
}
