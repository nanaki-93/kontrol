import Foundation
import SwiftData

@MainActor
protocol CatalogRepository {
    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult
    func loadSnapshot() throws -> LearningCatalogSnapshot
    func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot
    func openLesson(lessonID: String, now: Date) throws -> LessonMutationResult
    func loadLesson(lessonID: String) throws -> LessonDetailSnapshot
    func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult
}

enum CatalogImportResult: Equatable {
    case imported
    case unchanged
}

enum CatalogImportError: Error, Equatable {
    case downgrade(installed: Int, requested: Int)
    case lowerContentVersion
    case unchangedContentVersionConflict
    case objectiveIdentityConflict
    case generatedIDCollision
}

// Each import owns a fresh context. In particular, neither a failed save nor a
// pre-save error can roll back unsaved work in a view's main context.
@MainActor
final class SwiftDataCatalogRepository: CatalogRepository {
    private let container: ModelContainer
    private let beforeSave: () throws -> Void
    private let save: (ModelContext) throws -> Void

    // Hooks are scoped to the operation's commit boundary, not the shared container.
    // A throwing save hook must fail *instead of* saving, never after a commit.
    init(container: ModelContainer,
         beforeSave: @escaping () throws -> Void = {},
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.beforeSave = beforeSave
        self.save = save
    }

    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let value = catalog.value
        let states = try context.fetch(FetchDescriptor<CatalogImportState>())
        let state = states.first { $0.catalogID == value.catalogID }
        if let installed = state?.lastImportedVersion {
            if value.version < installed {
                throw CatalogImportError.downgrade(installed: installed, requested: value.version)
            }
            if value.version == installed {
                // An installed release can still need initial slots (e.g. a V3
                // migration) or replacement after personal progress changes.
                try reconcile(in: context, now: Date())
                return .unchanged
            }
        }

        // Load all definition identities before changing anything. The input has
        // already passed whole-catalog validation; absence in a later version is
        // not a deletion instruction.
        let topics = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Topic>()).map { ($0.id, $0) })
        let subtopics = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Subtopic>()).map { ($0.id, $0) })
        let concepts = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Concept>()).map { ($0.id, $0) })
        let lessons = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<LessonDefinition>()).map { ($0.id, $0) })

        // Preflight the entire upgrade before touching even a topic name. A failed
        // compatibility check must not leave partial changes in this context.
        for item in value.lessons {
            guard let existing = lessons[item.id] else { continue }
            if existing.source == "generated" && item.source == "seed" {
                throw CatalogImportError.generatedIDCollision
            }
            if existing.objectiveKey != item.objectiveKey {
                throw CatalogImportError.objectiveIdentityConflict
            }
            if item.contentVersion < existing.contentVersion {
                throw CatalogImportError.lowerContentVersion
            }
            if item.contentVersion == existing.contentVersion && !Self.matches(existing, item) {
                throw CatalogImportError.unchangedContentVersionConflict
            }
        }

        // Capture the installed version before any definition is overwritten. A
        // migrated V4 draft has no pin; a newer catalog is never evidence of
        // what its author saw. Nil remains the explicit unavailable state for
        // missing/mismatched content (the answer and version stay untouched).
        for attempt in try context.fetch(FetchDescriptor<LessonAttempt>())
            where attempt.completedAt == nil && attempt.pinnedContentData == nil {
            guard let installed = lessons[attempt.lessonID],
                  installed.contentVersion == attempt.contentVersion else { continue }
            attempt.pinnedContentData = try PinnedLessonContent(
                definition: Self.definitionSnapshot(installed)).encoded()
        }

        for item in value.topics {
            if let existing = topics[item.id] {
                existing.name = item.name
            } else {
                context.insert(Topic(id: item.id, name: item.name))
            }
        }
        for item in value.subtopics {
            if let existing = subtopics[item.id] {
                existing.topicID = item.topicID
                existing.name = item.name
            } else {
                context.insert(Subtopic(id: item.id, topicID: item.topicID, name: item.name))
            }
        }
        for item in value.concepts {
            if let existing = concepts[item.id] {
                existing.subtopicID = item.subtopicID
                existing.name = item.name
                existing.prerequisiteConceptIDs = item.prerequisiteConceptIDs
            } else {
                context.insert(Concept(id: item.id, subtopicID: item.subtopicID,
                                       name: item.name, prerequisiteConceptIDs: item.prerequisiteConceptIDs))
            }
        }
        for item in value.lessons {
            let definition: LessonDefinition
            if let existing = lessons[item.id] {
                definition = existing
            } else {
                definition = LessonDefinition(
                    id: item.id, objectiveKey: item.objectiveKey, title: item.title,
                    topicID: item.topicID, subtopicID: item.subtopicID,
                    conceptIDs: item.conceptIDs, difficulty: item.difficulty,
                    format: item.format, estimatedMinutes: item.estimatedMinutes,
                    prerequisiteConceptIDs: item.prerequisiteConceptIDs,
                    explanation: item.explanation, workedExample: item.workedExample,
                    exercise: item.exercise, referenceAnswer: item.referenceAnswer,
                    selfCheckCriteria: item.selfCheckCriteria, contentVersion: item.contentVersion,
                    normalizedContentHash: item.normalizedContentHash, source: item.source,
                    provenance: item.provenance, objective: item.objective)
                context.insert(definition)
            }
            definition.objectiveKey = item.objectiveKey
            definition.objective = item.objective
            definition.title = item.title
            definition.topicID = item.topicID
            definition.subtopicID = item.subtopicID
            definition.conceptIDs = item.conceptIDs
            definition.difficulty = item.difficulty
            definition.format = item.format
            definition.estimatedMinutes = item.estimatedMinutes
            definition.prerequisiteConceptIDs = item.prerequisiteConceptIDs
            definition.explanation = item.explanation
            definition.workedExample = item.workedExample
            definition.exercise = item.exercise
            definition.referenceAnswer = item.referenceAnswer
            definition.selfCheckCriteria = item.selfCheckCriteria
            definition.contentVersion = item.contentVersion
            definition.normalizedContentHash = item.normalizedContentHash
            definition.source = item.source
            definition.provenance = item.provenance
        }
        if let state {
            state.lastImportedVersion = value.version
        } else {
            context.insert(CatalogImportState(catalogID: value.catalogID,
                                              lastImportedVersion: value.version))
        }
        // Re-fetch within this private write context, including newly inserted
        // definitions. One commit owns the definitions, slots, and version marker.
        try reconcile(in: context, now: Date(), commit: false)
        try beforeSave()
        try save(context)
        return .imported
    }

    func loadSnapshot() throws -> LearningCatalogSnapshot {
        let context = ModelContext(container)
        return try snapshot(in: context)
    }

    func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try reconcile(in: context, now: now)
        // Return committed values, never projections of an uncommitted context.
        return try loadSnapshot()
    }

    // These synchronous main-actor operations each use their own non-autosaving
    // context. Reentrant consumers observe only the committed previous operation.
    func loadLesson(lessonID: String) throws -> LessonDetailSnapshot {
        try detail(lessonID: lessonID, in: ModelContext(container))
    }

    func openLesson(lessonID: String, now: Date) throws -> LessonMutationResult {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw LessonExperienceError.invalidTransition
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let definitions = try context.fetch(FetchDescriptor<LessonDefinition>()).filter { $0.id == lessonID }
        let progressRows = try context.fetch(FetchDescriptor<LessonProgress>()).filter { $0.lessonID == lessonID }
        let attempts = try context.fetch(FetchDescriptor<LessonAttempt>()).filter { $0.lessonID == lessonID }
        guard definitions.count <= 1, progressRows.count <= 1 else {
            throw LessonExperienceError.invalidStoredData
        }
        let progress = progressRows.first
        let unfinished = attempts.filter { $0.completedAt == nil }
        let completed = attempts.filter { $0.completedAt != nil }
        guard unfinished.count <= 1, completed.count <= 1 else {
            throw LessonExperienceError.invalidStoredData
        }
        let status = progress.map { LessonProgressStatus(rawValue: $0.status.rawValue) }
        if progress != nil && status == nil { throw LessonExperienceError.invalidStoredData }
        // A terminal row never implicitly starts work. It can be inspected even
        // when the current definition has been removed or superseded.
        if status == .completed || status == .dismissed {
            let detail = try self.detail(lessonID: lessonID, in: context)
            return try result(.unchanged, detail: detail, in: context)
        }
        let progressStatus = status ?? .available
        guard completed.isEmpty, progressStatus == .started || unfinished.isEmpty else {
            throw LessonExperienceError.invalidStoredData
        }
        var recoveredPin = false
        if let attempt = unfinished.first {
            if attempt.pinnedContentData == nil {
                // Same-version imports do not enter the upgrade backfill path.
                // Recover a migrated V4 draft only from the matching installed
                // definition, in this same transaction as the resumed progress.
                guard let definition = definitions.first,
                      definition.contentVersion == attempt.contentVersion else {
                    throw LessonExperienceError.contentUnavailable
                }
                attempt.pinnedContentData = try PinnedLessonContent(
                    definition: Self.definitionSnapshot(definition)).encoded()
                recoveredPin = true
            }
            _ = try PinnedLessonContent.decode(attempt.pinnedContentData,
                lessonID: lessonID, contentVersion: attempt.contentVersion)
        } else if definitions.first == nil {
            throw LessonExperienceError.contentUnavailable
        }
        let record: LessonProgress
        if let progress {
            record = progress
        } else {
            record = LessonProgress(lessonID: lessonID)
            context.insert(record)
        }
        let createdAttempt = unfinished.isEmpty
        if createdAttempt {
            let definition = try PinnedLessonContent(definition: Self.definitionSnapshot(definitions[0])).encoded()
            context.insert(LessonAttempt(id: UUID(), lessonID: lessonID,
                contentVersion: definitions[0].contentVersion, pinnedContentData: definition))
        }
        let changed = createdAttempt || recoveredPin || record.status != .started || record.startedAt == nil ||
            record.firstShownAt == nil || record.lastOpenedAt == nil || record.lastOpenedAt! < now
        if changed {
            record.status = .started
            if record.startedAt == nil { record.startedAt = now }
            if record.firstShownAt == nil { record.firstShownAt = now }
            // Do not move the clock backwards when a delayed caller opens a lesson.
            if record.lastOpenedAt == nil || record.lastOpenedAt! < now { record.lastOpenedAt = now }
        }
        let detail = try self.detail(lessonID: lessonID, in: context)
        let receipt = try result(changed ? .changed : .unchanged, detail: detail, in: context)
        if !changed { return receipt }
        try beforeSave()
        try save(context)
        return receipt
    }

    func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let matches = try context.fetch(FetchDescriptor<LessonAttempt>()).filter { $0.id == attemptID }
        guard matches.count <= 1 else { throw LessonExperienceError.invalidStoredData }
        guard let row = matches.first else { throw LessonExperienceError.attemptNotFound }
        // Detail checks the unique progress/attempt pairing and decodes the studied
        // pin. Never choose an arbitrary unfinished row if storage is contradictory.
        let current = try detail(lessonID: row.lessonID, in: context)
        guard let attempt = current.attempt, attempt.id == attemptID,
              let progress = current.progress else { throw LessonExperienceError.invalidStoredData }
        let edited = try LessonExperience.edit(attempt, status: progress.status,
                                               expectedRevision: expectedRevision, answer: answer)
        if edited == attempt { return try result(.unchanged, detail: current, in: context) }
        row.answerDraft = edited.answerDraft
        row.selfCheckAcknowledgedAt = edited.selfCheckAcknowledgedAt
        row.revision = edited.revision
        // Project the complete receipt in the write context before the commit;
        // a failed save cannot publish speculative text or a bumped revision.
        let updated = try detail(lessonID: row.lessonID, in: context)
        let receipt = try result(.changed, detail: updated, in: context)
        try beforeSave()
        try save(context)
        return receipt
    }

    private func result(_ outcome: LessonMutationOutcome, detail: LessonDetailSnapshot,
                        in context: ModelContext) throws -> LessonMutationResult {
        let catalog = try snapshot(in: context)
        // History is projected from the same write context, never a fallible
        // post-commit read. A future History command can reuse this projection.
        var history: [LessonHistorySnapshot] = []
        for progress in catalog.progress where progress.status == .completed || progress.status == .dismissed {
            let item = try self.detail(lessonID: progress.lessonID, in: context)
            let timestamp: Date? = progress.status == .completed ? progress.completedAt : progress.dismissedAt
            guard let date = timestamp else { throw LessonExperienceError.invalidStoredData }
            history.append(LessonHistorySnapshot(lessonID: progress.lessonID, status: progress.status,
                                                 date: date, content: item.content, attempt: item.attempt))
        }
        history.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.lessonID < rhs.lessonID }
            return lhs.date > rhs.date
        }
        return LessonMutationResult(outcome: outcome, catalog: catalog, detail: detail,
                                    history: history, replacedSlot: nil)
    }

    private func detail(lessonID: String, in context: ModelContext) throws -> LessonDetailSnapshot {
        let definitions = try context.fetch(FetchDescriptor<LessonDefinition>()).filter { $0.id == lessonID }
        let progressRows = try context.fetch(FetchDescriptor<LessonProgress>()).filter { $0.lessonID == lessonID }
        let attempts = try context.fetch(FetchDescriptor<LessonAttempt>()).filter { $0.lessonID == lessonID }
        guard definitions.count <= 1, progressRows.count <= 1,
              attempts.filter({ $0.completedAt == nil }).count <= 1,
              attempts.filter({ $0.completedAt != nil }).count <= 1 else {
            throw LessonExperienceError.invalidStoredData
        }
        let row = progressRows.first
        guard let status = row.map({ LessonProgressStatus(rawValue: $0.status.rawValue) }) ?? .available else {
            throw LessonExperienceError.invalidStoredData
        }
        let completed = attempts.filter { $0.completedAt != nil }
        let unfinished = attempts.filter { $0.completedAt == nil }
        let selected: LessonAttempt?
        switch status {
        case .completed:
            guard completed.count == 1, unfinished.isEmpty,
                  row?.completedAt != nil else { throw LessonExperienceError.invalidStoredData }
            selected = completed.first
        case .started:
            guard completed.isEmpty else { throw LessonExperienceError.invalidStoredData }
            selected = unfinished.first // a recovered V4 progress row may predate attempts
        case .dismissed:
            guard completed.isEmpty else { throw LessonExperienceError.invalidStoredData }
            selected = unfinished.first
        case .available:
            guard attempts.isEmpty else { throw LessonExperienceError.invalidStoredData }
            selected = nil
        }
        guard definitions.first != nil || row != nil else { throw LessonExperienceError.lessonNotFound }
        let progress = row.map { LessonProgressSnapshot(lessonID: $0.lessonID, status: status,
            firstShownAt: $0.firstShownAt, startedAt: $0.startedAt, completedAt: $0.completedAt,
            dismissedAt: $0.dismissedAt, lastOpenedAt: $0.lastOpenedAt) }
        let attempt = selected.map { LessonAttemptSnapshot(id: $0.id, lessonID: $0.lessonID,
            contentVersion: $0.contentVersion, answerDraft: $0.answerDraft,
            solutionRevealedAt: $0.solutionRevealedAt,
            selfCheckAcknowledgedAt: $0.selfCheckAcknowledgedAt, completedAt: $0.completedAt,
            completedContentSnapshot: $0.completedContentSnapshot,
            pinnedContentData: $0.pinnedContentData, revision: $0.revision) }
        let content: LessonStudiedContent
        if let attempt {
            content = try LessonExperience.studiedContent(attempt)
        } else if (status == .available || status == .dismissed), let definition = definitions.first {
            // A choice can be dismissed before it is opened. With no studied
            // attempt to pin, its installed definition remains read-only material.
            content = .current(Self.definitionSnapshot(definition))
        } else {
            content = .unavailable
        }
        return LessonDetailSnapshot(id: lessonID, progress: progress, attempt: attempt, content: content)
    }

    private func reconcile(in context: ModelContext, now: Date, commit: Bool = true) throws {
        let current = try snapshot(in: context)
        let desired = try LessonSelector.reconcile(definitions: current.definitions,
            concepts: current.concepts, progress: current.progress, slots: current.slots, now: now)
        guard desired != current.slots else { return }
        let desiredByKey = Dictionary(uniqueKeysWithValues: desired.map { ($0.key, $0) })
        let rows = try context.fetch(FetchDescriptor<LessonSlot>())
        // All persisted identities were checked by the selector before mutation.
        // Update a vacated key in place to avoid a delete/insert uniqueness race.
        for row in rows {
            if let replacement = desiredByKey[row.key] {
                if row.lessonID != replacement.lessonID {
                    row.lessonID = replacement.lessonID
                    row.assignedAt = replacement.assignedAt
                }
            } else {
                context.delete(row)
            }
        }
        let existingKeys = Set(rows.map(\.key))
        for slot in desired where !existingKeys.contains(slot.key) {
            context.insert(LessonSlot(topicID: slot.topicID, slotIndex: slot.slotIndex,
                                      lessonID: slot.lessonID, assignedAt: slot.assignedAt))
        }
        if commit {
            try beforeSave()
            try save(context)
        }
    }

    private func snapshot(in context: ModelContext) throws -> LearningCatalogSnapshot {
        let topics = try context.fetch(FetchDescriptor<Topic>()).map {
            LearningTopicSnapshot(id: $0.id, name: $0.name)
        }.sorted { $0.id < $1.id }
        let subtopics = try context.fetch(FetchDescriptor<Subtopic>()).map {
            LearningSubtopicSnapshot(id: $0.id, topicID: $0.topicID, name: $0.name)
        }.sorted { $0.id < $1.id }
        let concepts = try context.fetch(FetchDescriptor<Concept>()).map {
            LearningConceptSnapshot(id: $0.id, subtopicID: $0.subtopicID, name: $0.name,
                                    prerequisiteConceptIDs: $0.prerequisiteConceptIDs)
        }.sorted { $0.id < $1.id }
        let definitions = try context.fetch(FetchDescriptor<LessonDefinition>())
            .map(Self.definitionSnapshot).sorted { $0.id < $1.id }
        let progress = try context.fetch(FetchDescriptor<LessonProgress>()).map { item in
            LessonProgressSnapshot(lessonID: item.lessonID,
                status: LessonProgressStatus(rawValue: item.status.rawValue)!,
                firstShownAt: item.firstShownAt, startedAt: item.startedAt,
                completedAt: item.completedAt, dismissedAt: item.dismissedAt,
                lastOpenedAt: item.lastOpenedAt)
        }.sorted { $0.lessonID < $1.lessonID }
        let storedSlots: [LessonSlot] = try context.fetch(FetchDescriptor<LessonSlot>())
        let slots: [LessonSlotSnapshot] = storedSlots.map { row in
            LessonSlotSnapshot(key: row.key, topicID: row.topicID,
                               slotIndex: row.slotIndex, lessonID: row.lessonID,
                               assignedAt: row.assignedAt)
        }.sorted { lhs, rhs in
            if lhs.topicID == rhs.topicID { return lhs.slotIndex < rhs.slotIndex }
            return lhs.topicID < rhs.topicID
        }
        // Snapshot reads are a publication boundary, not just a projection. Do
        // not expose corrupt stored identities even when no write is requested.
        try LessonSelector.validateSlotIdentities(slots)
        return LearningCatalogSnapshot(topics: topics, subtopics: subtopics,
            concepts: concepts, definitions: definitions, progress: progress, slots: slots)
    }

    private static func definitionSnapshot(_ item: LessonDefinition) -> LessonDefinitionSnapshot {
        LessonDefinitionSnapshot(id: item.id, objectiveKey: item.objectiveKey,
            objective: item.objective, title: item.title, topicID: item.topicID,
            subtopicID: item.subtopicID, conceptIDs: item.conceptIDs,
            difficulty: item.difficulty, format: item.format,
            estimatedMinutes: item.estimatedMinutes,
            prerequisiteConceptIDs: item.prerequisiteConceptIDs,
            explanation: item.explanation, workedExample: item.workedExample,
            exercise: item.exercise, referenceAnswer: item.referenceAnswer,
            selfCheckCriteria: item.selfCheckCriteria, contentVersion: item.contentVersion,
            normalizedContentHash: item.normalizedContentHash, source: item.source,
            provenance: item.provenance)
    }

    // The content fingerprint covers teaching sections only. Metadata, including
    // the explicit objective, must also be unchanged at a fixed content version.
    private static func matches(_ stored: LessonDefinition, _ incoming: LessonDTO) -> Bool {
        stored.objectiveKey == incoming.objectiveKey &&
        stored.objective == incoming.objective &&
        stored.title == incoming.title &&
        stored.topicID == incoming.topicID &&
        stored.subtopicID == incoming.subtopicID &&
        stored.conceptIDs == incoming.conceptIDs &&
        stored.difficulty == incoming.difficulty &&
        stored.format == incoming.format &&
        stored.estimatedMinutes == incoming.estimatedMinutes &&
        stored.prerequisiteConceptIDs == incoming.prerequisiteConceptIDs &&
        stored.explanation == incoming.explanation &&
        stored.workedExample == incoming.workedExample &&
        stored.exercise == incoming.exercise &&
        stored.referenceAnswer == incoming.referenceAnswer &&
        stored.selfCheckCriteria == incoming.selfCheckCriteria &&
        stored.contentVersion == incoming.contentVersion &&
        stored.normalizedContentHash == incoming.normalizedContentHash &&
        stored.source == incoming.source &&
        stored.provenance == incoming.provenance
    }
}
