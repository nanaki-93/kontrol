import Foundation
import SwiftData

@MainActor
protocol CatalogRepository {
    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult
    func loadSnapshot() throws -> LearningCatalogSnapshot
    func generationContext(topicID: String) throws -> LessonGenerationContext
    func acceptGeneratedLesson(_ lesson: ValidatedGeneratedLesson, now: Date) throws -> GeneratedLessonInsertionResult
    func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot
    func openLesson(lessonID: String, now: Date) throws -> LessonMutationResult
    func openConceptLesson(lessonID: String, expectedSlot: LessonSlotSnapshot?, expectedConceptID: String, now: Date) throws -> LessonMutationResult
    func loadLesson(lessonID: String) throws -> LessonDetailSnapshot
    func loadHistory() throws -> [LessonHistorySnapshot]
    func loadCoverage() throws -> LearningCoverageSnapshot
    func restoreDismissed(lessonID: String, now: Date) throws -> LessonMutationResult
    func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult
    /// Draft-only save when Coverage is unreadable. No selection or Coverage receipt is authorized.
    func saveDraftAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonDetailSnapshot
    func revealSolution(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult
    func setSelfCheckAcknowledged(attemptID: UUID, expectedRevision: Int,
                                  acknowledged: Bool, now: Date) throws -> LessonMutationResult
    func complete(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult
    func dismiss(lessonID: String, expectedSlot: LessonSlotSnapshot, now: Date) throws -> LessonMutationResult
}

// Test doubles that have not implemented the new read cannot accidentally
// present an empty or authoritative coverage projection. The production
// repository overrides this requirement with a detached, read-only projection.
extension CatalogRepository {
    func generationContext(topicID: String) throws -> LessonGenerationContext {
        throw GenerationContextError.unavailable
    }

    func acceptGeneratedLesson(_ lesson: ValidatedGeneratedLesson, now: Date) throws -> GeneratedLessonInsertionResult {
        throw LessonGenerationError.persistenceFailure
    }

    func loadCoverage() throws -> LearningCoverageSnapshot {
        throw LessonExperienceError.persistenceFailure
    }

    func openConceptLesson(lessonID: String, expectedSlot: LessonSlotSnapshot?, expectedConceptID: String, now: Date) throws -> LessonMutationResult {
        throw LessonExperienceError.staleSlot
    }

    func saveDraftAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonDetailSnapshot {
        throw LessonExperienceError.invalidTransition
    }
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
                // A V6 container may have migrated without terminal records. Backfill
                // even when the installed release has not changed, in one write context.
                let recovered = try backfillTerminalEvidence(in: context)
                let membershipChanged = try persistMembership(catalog, in: context)
                let previousSlots = try snapshot(in: context).slots
                try reconcile(in: context, now: Date(), commit: false)
                let slotsChanged = try snapshot(in: context).slots != previousSlots
                if recovered || membershipChanged || slotsChanged {
                    try beforeSave()
                    try save(context)
                }
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

        // Recover terminal evidence against the retained definitions, never the
        // incoming catalog. Any failure discards this private, non-autosaving context.
        _ = try backfillTerminalEvidence(in: context)

        // Capture the installed version before any definition is overwritten. A
        // migrated V4 draft has no pin; a newer catalog is never evidence of
        // what its author saw. Persist an empty pin for an unmatched version so
        // a future catalog cannot accidentally make that old attempt recoverable.
        // Nil remains reserved for drafts not yet checked against an upgrade.
        for attempt in try context.fetch(FetchDescriptor<LessonAttempt>())
            where attempt.completedAt == nil && attempt.pinnedContentData == nil {
            if let installed = lessons[attempt.lessonID],
               installed.contentVersion == attempt.contentVersion {
                attempt.pinnedContentData = try PinnedLessonContent(
                    definition: Self.definitionSnapshot(installed)).encoded()
            } else {
                attempt.pinnedContentData = Data()
            }
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
        _ = try persistMembership(catalog, in: context)
        // Re-fetch within this private write context, including newly inserted
        // definitions. One commit owns the definitions, slots, and version marker.
        try reconcile(in: context, now: Date(), commit: false)
        try beforeSave()
        try save(context)
        return .imported
    }

    // A migrated marker alone cannot establish the contents of an old release.
    // Only an exact-version validated import can create this evidence.
    func loadMembership(catalogID: String) throws -> CatalogMembershipAvailability {
        let context = ModelContext(container)
        let states = try EvidenceIdentity.requireUnique(
            context.fetch(FetchDescriptor<CatalogImportState>()), id: { $0.catalogID })
        let rows = try context.fetch(FetchDescriptor<CatalogMembership>())
        guard let version = states[catalogID]?.lastImportedVersion else {
            // Still validate corrupt evidence instead of masking it as unavailable.
            _ = try EvidenceIdentity.requireUnique(rows, id: { $0.catalogID })
            for row in rows { _ = try row.membership() }
            return .unavailable
        }
        return try EvidenceIdentity.membership(rows, catalogID: catalogID, installedVersion: version)
    }

    // Return true only when a missing or stale membership was actually written.
    // Never derive current sets from retained taxonomy or definition rows.
    private func persistMembership(_ catalog: ValidatedCatalog, in context: ModelContext) throws -> Bool {
        let rows = try EvidenceIdentity.requireUnique(
            context.fetch(FetchDescriptor<CatalogMembership>()), id: { $0.catalogID })
        for row in rows.values { _ = try row.membership() }
        let value = catalog.value
        if try rows[value.catalogID]?.membership().catalogVersion == value.version { return false }
        let membership = CurrentCatalogMembership(catalogID: value.catalogID,
            catalogVersion: value.version,
            topicIDs: value.topics.map(\.id).sorted(),
            subtopicIDs: value.subtopics.map(\.id).sorted(),
            conceptIDs: value.concepts.map(\.id).sorted(),
            seededLessonIDs: value.lessons.filter { $0.source == "seed" }.map(\.id).sorted())
        if let row = rows[value.catalogID] {
            row.payload = try CatalogMembership(membership: membership).payload
        } else {
            context.insert(try CatalogMembership(membership: membership))
        }
        return true
    }

    func loadSnapshot() throws -> LearningCatalogSnapshot {
        let context = ModelContext(container)
        return try snapshot(in: context)
    }

    func generationContext(topicID: String) throws -> LessonGenerationContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try generationContext(topicID: topicID, in: context)
    }

    private func generationContext(topicID: String, in context: ModelContext) throws -> LessonGenerationContext {
        // Never call import, backfill, reconcile, or save from this read. The
        // same private context supplies all membership and personal evidence.
        do {
            let projection = try snapshot(in: context)
            let evidence = try selectionEvidence(in: context, catalog: projection)
            guard case .available(let membership) = evidence.membership else {
                throw GenerationContextError.unavailable
            }
            guard membership.topicIDs.contains(topicID) else {
                throw GenerationContextError.invalidScope
            }
            // A retained taxonomy row or former seeded lesson cannot authorize
            // a request. Missing/contradictory current rows fail closed instead.
            let topics = projection.topics.filter { membership.topicIDs.contains($0.id) }
            let subtopics = projection.subtopics.filter { membership.subtopicIDs.contains($0.id) }
            let concepts = projection.concepts.filter { membership.conceptIDs.contains($0.id) }
            let seeded = projection.definitions.filter { membership.seededLessonIDs.contains($0.id) }
            guard topics.count == membership.topicIDs.count,
                  subtopics.count == membership.subtopicIDs.count,
                  concepts.count == membership.conceptIDs.count,
                  seeded.count == membership.seededLessonIDs.count,
                  seeded.allSatisfy({ $0.source == "seed" }) else {
                throw GenerationContextError.invalidEvidence
            }
            let installed = CatalogDTO(catalogID: membership.catalogID, version: membership.catalogVersion,
                topics: topics.map { TopicDTO(id: $0.id, name: $0.name) },
                subtopics: subtopics.map { SubtopicDTO(id: $0.id, topicID: $0.topicID, name: $0.name) },
                concepts: concepts.map { ConceptDTO(id: $0.id, subtopicID: $0.subtopicID,
                    name: $0.name, prerequisiteConceptIDs: $0.prerequisiteConceptIDs) },
                lessons: seeded.map { LessonDTO(id: $0.id, objectiveKey: $0.objectiveKey,
                    objective: $0.objective, title: $0.title, topicID: $0.topicID,
                    subtopicID: $0.subtopicID, conceptIDs: $0.conceptIDs,
                    difficulty: $0.difficulty, format: $0.format,
                    estimatedMinutes: $0.estimatedMinutes,
                    prerequisiteConceptIDs: $0.prerequisiteConceptIDs,
                    explanation: $0.explanation, workedExample: $0.workedExample,
                    exercise: $0.exercise, referenceAnswer: $0.referenceAnswer,
                    selfCheckCriteria: $0.selfCheckCriteria, contentVersion: $0.contentVersion,
                    normalizedContentHash: $0.normalizedContentHash, source: $0.source,
                    provenance: $0.provenance) })
            return LessonGenerationContext(catalog: try ValidatedCatalog.validating(installed),
                membership: membership, completedConceptIDs: evidence.completed,
                terminal: evidence.terminal, definitions: projection.definitions,
                startedPins: projection.startedPins, slots: projection.slots)
        } catch let error as GenerationContextError {
            throw error
        } catch is CatalogValidationError {
            throw GenerationContextError.invalidEvidence
        } catch is LearningEvidenceError {
            throw GenerationContextError.invalidEvidence
        } catch is LessonSelectionError {
            throw GenerationContextError.invalidEvidence
        } catch is LessonExperienceError {
            throw GenerationContextError.invalidEvidence
        } catch {
            throw GenerationContextError.readFailure
        }
    }

    func acceptGeneratedLesson(_ lesson: ValidatedGeneratedLesson, now: Date) throws -> GeneratedLessonInsertionResult {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw LessonGenerationError.invalidCandidate }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let definition = lesson.definition
        let current: LessonGenerationContext
        do {
            current = try generationContext(topicID: definition.topicID, in: context)
        } catch GenerationContextError.invalidScope {
            throw LessonGenerationError.staleContext
        } catch GenerationContextError.unavailable {
            throw LessonGenerationError.staleContext
        } catch {
            throw LessonGenerationError.persistenceFailure
        }
        // Reconstruct and revalidate the *original* candidate against the latest
        // evidence. The locally minted ID and provenance cannot change on retry.
        let checked = try GeneratedLessonValidator.validate(lesson.candidate, request: lesson.request,
            context: current, registry: lesson.registry, requestedModel: lesson.requestedModel,
            returnedModel: lesson.returnedModel, now: lesson.validatedAt)
        guard checked.definition == definition,
              lesson.catalogID == current.membership.catalogID,
              lesson.catalogVersion == current.membership.catalogVersion,
              lesson.objectiveRegistryVersion == lesson.registry.version else {
            throw LessonGenerationError.staleContext
        }
        // Validate selector eligibility using the same fresh evidence before
        // assigning only this lesson to the first vacant index. No reconcile.
        let before = try snapshot(in: context)
        let evidence = try selectionEvidence(in: context, catalog: before)
        let vacancy = (0..<LessonSelector.slotsPerTopic).first { index in
            !before.slots.contains { $0.topicID == definition.topicID && $0.slotIndex == index }
        }
        var assigned: LessonSlotSnapshot?
        if let vacancy {
            let eligible = try LessonSelector.restoredVacancy(lessonID: definition.id,
                definitions: before.definitions + [definition], concepts: before.concepts,
                subtopics: before.subtopics,
                progress: before.progress + [LessonProgressSnapshot(lessonID: definition.id, status: .available)],
                slots: before.slots, terminal: evidence.terminal,
                completedConceptIDs: evidence.completed, membership: evidence.membership,
                activePins: evidence.activePins, now: now)
            // A vacancy is offered only when the candidate is eligible. Never
            // fill a later vacancy if the first one cannot accept this lesson.
            if eligible?.slotIndex == vacancy { assigned = eligible }
        }
        context.insert(LessonDefinition(id: definition.id, objectiveKey: definition.objectiveKey,
            title: definition.title, topicID: definition.topicID, subtopicID: definition.subtopicID,
            conceptIDs: definition.conceptIDs, difficulty: definition.difficulty, format: definition.format,
            estimatedMinutes: definition.estimatedMinutes, prerequisiteConceptIDs: definition.prerequisiteConceptIDs,
            explanation: definition.explanation, workedExample: definition.workedExample,
            exercise: definition.exercise, referenceAnswer: definition.referenceAnswer,
            selfCheckCriteria: definition.selfCheckCriteria, contentVersion: definition.contentVersion,
            normalizedContentHash: definition.normalizedContentHash, source: definition.source,
            provenance: definition.provenance, objective: definition.objective))
        if let assigned {
            context.insert(LessonSlot(topicID: assigned.topicID, slotIndex: assigned.slotIndex,
                                      lessonID: assigned.lessonID, assignedAt: assigned.assignedAt))
        }
        let catalog = try snapshot(in: context)
        let receipt = GeneratedLessonInsertionResult(lessonID: definition.id, assignedSlot: assigned,
            catalog: catalog, history: try history(in: context, catalog: catalog),
            coverage: try coverage(in: context, catalog: catalog))
        do {
            try beforeSave()
            try save(context)
        } catch { throw LessonGenerationError.persistenceFailure }
        return receipt
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

    func loadHistory() throws -> [LessonHistorySnapshot] {
        let context = ModelContext(container)
        return try history(in: context)
    }

    func loadCoverage() throws -> LearningCoverageSnapshot {
        let context = ModelContext(container)
        return try coverage(in: context, catalog: snapshot(in: context))
    }

    func restoreDismissed(lessonID: String, now: Date) throws -> LessonMutationResult {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw LessonExperienceError.invalidTransition
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let current = try detail(lessonID: lessonID, in: context)
        guard let progress = current.progress else { throw LessonExperienceError.invalidTransition }
        if progress.status == .completed { throw LessonExperienceError.invalidTransition }
        if progress.status != .dismissed {
            guard progress.dismissedAt != nil else { throw LessonExperienceError.invalidTransition }
            // A repeated Restore does not rewrite provenance or fill a slot
            // later when inventory changes. It is an unchanged receipt.
            return try result(.unchanged, detail: current, in: context)
        }
        let rows = try context.fetch(FetchDescriptor<LessonProgress>()).filter { $0.lessonID == lessonID }
        guard rows.count == 1, let row = rows.first else { throw LessonExperienceError.invalidStoredData }
        let catalog = try snapshot(in: context)
        guard !catalog.slots.contains(where: { $0.lessonID == lessonID }) else {
            throw LessonExperienceError.invalidStoredData
        }
        row.status = current.attempt == nil ? .available : .started
        // dismissedAt and the entire attempt (including its original pin and
        // revision) are provenance. Restore must never edit either one.
        let updated = try snapshot(in: context)
        // Unrecoverable legacy work remains accessible in detail, but must not
        // advertise an upgraded exercise as a usable active choice.
        let canOfferChoice: Bool
        switch current.content {
        case .pinned, .current: canOfferChoice = true
        case .legacyCompleted, .unavailable: canOfferChoice = false
        }
        let evidence = try selectionEvidence(in: context, catalog: updated)
        if canOfferChoice, let choice = try LessonSelector.restoredVacancy(lessonID: lessonID,
            definitions: updated.definitions, concepts: updated.concepts,
            subtopics: updated.subtopics, progress: updated.progress, slots: updated.slots,
            terminal: evidence.terminal, completedConceptIDs: evidence.completed,
            membership: evidence.membership, activePins: evidence.activePins, now: now) {
            context.insert(LessonSlot(topicID: choice.topicID, slotIndex: choice.slotIndex,
                                      lessonID: choice.lessonID, assignedAt: choice.assignedAt))
        }
        let detail = try self.detail(lessonID: lessonID, in: context)
        let receipt = try result(.changed, detail: detail, in: context)
        try beforeSave()
        try save(context)
        return receipt
    }

    func openLesson(lessonID: String, now: Date) throws -> LessonMutationResult {
        try openLesson(lessonID: lessonID, expectedSlot: nil, expectedConceptID: nil, now: now)
    }

    func openConceptLesson(lessonID: String, expectedSlot: LessonSlotSnapshot?, expectedConceptID: String, now: Date) throws -> LessonMutationResult {
        try openLesson(lessonID: lessonID, expectedSlot: expectedSlot, expectedConceptID: expectedConceptID, now: now)
    }

    private func openLesson(lessonID: String, expectedSlot: LessonSlotSnapshot?,
                            expectedConceptID: String?, now: Date) throws -> LessonMutationResult {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw LessonExperienceError.invalidTransition
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        if expectedConceptID != nil {
            let catalog = try snapshot(in: context)
            if let expectedSlot {
                guard expectedSlot.lessonID == lessonID,
                      catalog.slots.contains(expectedSlot) else { throw LessonExperienceError.staleSlot }
            } else {
                // Only explicitly restored started work may be opened without
                // an assignment. A consumed/externally replaced slot is stale.
                guard !catalog.slots.contains(where: { $0.lessonID == lessonID }),
                      catalog.progress.contains(where: { $0.lessonID == lessonID &&
                          $0.status == .started && $0.dismissedAt != nil }) else {
                    throw LessonExperienceError.staleSlot
                }
            }
        }
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
        if let expectedConceptID {
            // The displayed choice is only a hint. Use the studied pin for
            // started work and the installed definition for unopened work, in
            // this write context, before creating an attempt or progress row.
            let content: LessonDefinitionSnapshot?
            if progressStatus == .started {
                if let attempt = unfinished.first, let data = attempt.pinnedContentData, !data.isEmpty {
                    content = try PinnedLessonContent.decode(data, lessonID: lessonID,
                        contentVersion: attempt.contentVersion).definition
                } else { content = nil }
            } else {
                content = definitions.first.map(Self.definitionSnapshot)
            }
            guard let content, let ids = LessonDeduplication.canonicalConcepts(content.conceptIDs),
                  ids.contains(expectedConceptID) else { throw LessonExperienceError.staleSlot }
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

    /// Only the answer changes. Validate the identity/revision and detached detail
    /// before committing; unlike slot commands, this does not need Coverage evidence.
    func saveDraftAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonDetailSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let matches = try context.fetch(FetchDescriptor<LessonAttempt>()).filter { $0.id == attemptID }
        guard matches.count <= 1 else { throw LessonExperienceError.invalidStoredData }
        guard let row = matches.first else { throw LessonExperienceError.attemptNotFound }
        let current = try detail(lessonID: row.lessonID, in: context)
        guard let attempt = current.attempt, attempt.id == attemptID,
              let progress = current.progress else { throw LessonExperienceError.invalidStoredData }
        let edited = try LessonExperience.edit(attempt, status: progress.status,
                                               expectedRevision: expectedRevision, answer: answer)
        if edited == attempt { return current }
        row.answerDraft = edited.answerDraft
        row.selfCheckAcknowledgedAt = edited.selfCheckAcknowledgedAt
        row.revision = edited.revision
        let updated = try detail(lessonID: row.lessonID, in: context)
        try beforeSave()
        try save(context)
        return updated
    }

    func revealSolution(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
        try transition(attemptID: attemptID) { attempt, status in
            try LessonExperience.reveal(attempt, status: status, expectedRevision: expectedRevision, now: now)
        }
    }

    func setSelfCheckAcknowledged(attemptID: UUID, expectedRevision: Int,
                                  acknowledged: Bool, now: Date) throws -> LessonMutationResult {
        try transition(attemptID: attemptID) { attempt, status in
            try LessonExperience.acknowledge(attempt, status: status, expectedRevision: expectedRevision,
                                             acknowledged: acknowledged, now: now)
        }
    }

    func complete(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let matches = try context.fetch(FetchDescriptor<LessonAttempt>()).filter { $0.id == attemptID }
        guard matches.count <= 1 else { throw LessonExperienceError.invalidStoredData }
        guard let row = matches.first else { throw LessonExperienceError.attemptNotFound }
        let current = try detail(lessonID: row.lessonID, in: context)
        guard let attempt = current.attempt, attempt.id == attemptID,
              let progress = current.progress else { throw LessonExperienceError.invalidStoredData }
        // The domain gate recognizes this *same* completed attempt before checking
        // the caller's revision. No slot is consumed twice, even by a stale caller.
        let finished = try LessonExperience.complete(attempt, progress: progress,
                                                      expectedRevision: expectedRevision, now: now)
        if finished == attempt { return try result(.unchanged, detail: current, in: context) }

        let progressRows = try context.fetch(FetchDescriptor<LessonProgress>()).filter { $0.lessonID == row.lessonID }
        guard progressRows.count == 1, let progressRow = progressRows.first else {
            throw LessonExperienceError.invalidStoredData
        }
        let before = try snapshot(in: context)
        // An attempt can be resumed outside the four slots after Restore. Only an
        // assignment actually held by this lesson may be consumed.
        let consumed = before.slots.first { $0.lessonID == row.lessonID }
        let archive = try Self.terminalMetadata(lessonID: row.lessonID, attempt: finished,
                                                 provenance: .studiedPin)
        try storeTerminal(archive, in: context)
        row.completedAt = finished.completedAt
        row.completedContentSnapshot = finished.completedContentSnapshot
        row.revision = finished.revision
        progressRow.status = .completed
        progressRow.completedAt = now

        if let consumed {
            let updated = try snapshot(in: context)
            let evidence = try selectionEvidence(in: context, catalog: updated)
            let desired = try LessonSelector.replace(consumedSlot: consumed,
                definitions: updated.definitions, concepts: updated.concepts,
                subtopics: updated.subtopics, progress: updated.progress, slots: updated.slots,
                terminal: evidence.terminal, completedConceptIDs: evidence.completed,
                membership: evidence.membership, activePins: evidence.activePins, now: now)
            let slots = try context.fetch(FetchDescriptor<LessonSlot>()).filter { $0.key == consumed.key }
            guard slots.count == 1, let slot = slots.first else { throw LessonExperienceError.staleSlot }
            if let replacement = desired.first(where: { $0.key == consumed.key }) {
                slot.lessonID = replacement.lessonID
                slot.assignedAt = replacement.assignedAt
            } else {
                context.delete(slot)
            }
        }
        // Both History and choices are projected before the single commit. A
        // failed projection or save cannot publish a partially completed outcome.
        let detail = try self.detail(lessonID: row.lessonID, in: context)
        let receipt = try result(.changed, detail: detail, in: context, replacedSlot: consumed)
        try beforeSave()
        try save(context)
        return receipt
    }

    func dismiss(lessonID: String, expectedSlot: LessonSlotSnapshot, now: Date) throws -> LessonMutationResult {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw LessonExperienceError.invalidTransition
        }
        // The confirmation carries the entire assignment, not merely its index.
        // Compare the timestamp as well as the occupant to reject a slot reused
        // since the confirmation was shown.
        try LessonSelector.validateSlotIdentities([expectedSlot])
        guard expectedSlot.lessonID == lessonID else { throw LessonExperienceError.staleSlot }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let before = try snapshot(in: context)
        let assigned = before.slots.first { $0.key == expectedSlot.key }
        let current = try detail(lessonID: lessonID, in: context)
        if current.progress?.status == .dismissed {
            // A repeated confirmation for the already dismissed lesson is a no-op,
            // even if its former slot now holds a replacement. A subsequently
            // restored/reassigned lesson cannot be dismissed by that old dialog.
            guard !before.slots.contains(where: { $0.lessonID == lessonID }) else {
                throw LessonExperienceError.staleSlot
            }
            return try result(.unchanged, detail: current, in: context)
        }
        guard let definition = before.definitions.first(where: { $0.id == lessonID }),
              definition.topicID == expectedSlot.topicID, assigned == expectedSlot else {
            throw LessonExperienceError.staleSlot
        }
        guard current.progress?.status == nil || current.progress?.status == .available ||
              current.progress?.status == .started else {
            throw LessonExperienceError.invalidTransition
        }
        let progressRows = try context.fetch(FetchDescriptor<LessonProgress>()).filter { $0.lessonID == lessonID }
        guard progressRows.count <= 1 else { throw LessonExperienceError.invalidStoredData }
        let record: LessonProgress
        if let existing = progressRows.first {
            record = existing
        } else {
            record = LessonProgress(lessonID: lessonID)
            context.insert(record)
        }
        let archive: LessonTerminalMetadata
        if let attempt = current.attempt {
            archive = try Self.terminalMetadata(lessonID: lessonID, attempt: attempt,
                                                provenance: .dismissalPin)
        } else {
            archive = Self.terminalMetadata(definition: definition, provenance: .dismissalReference,
                                            reference: definition)
        }
        try storeTerminal(archive, in: context)
        record.status = .dismissed
        record.dismissedAt = now
        if record.firstShownAt == nil { record.firstShownAt = now }

        let updated = try snapshot(in: context)
        let evidence = try selectionEvidence(in: context, catalog: updated)
        let desired = try LessonSelector.replace(consumedSlot: expectedSlot,
            definitions: updated.definitions, concepts: updated.concepts,
            subtopics: updated.subtopics, progress: updated.progress, slots: updated.slots,
            terminal: evidence.terminal, completedConceptIDs: evidence.completed,
            membership: evidence.membership, activePins: evidence.activePins, now: now)
        let slots = try context.fetch(FetchDescriptor<LessonSlot>()).filter { $0.key == expectedSlot.key }
        guard slots.count == 1, let slot = slots.first,
              slot.lessonID == expectedSlot.lessonID, slot.assignedAt == expectedSlot.assignedAt else {
            throw LessonExperienceError.staleSlot
        }
        if let replacement = desired.first(where: { $0.key == expectedSlot.key }) {
            slot.lessonID = replacement.lessonID
            slot.assignedAt = replacement.assignedAt
        } else {
            context.delete(slot)
        }
        let detail = try self.detail(lessonID: lessonID, in: context)
        let receipt = try result(.changed, detail: detail, in: context, replacedSlot: expectedSlot)
        try beforeSave()
        try save(context)
        return receipt
    }

    private func transition(attemptID: UUID,
                            apply: (LessonAttemptSnapshot, LessonProgressStatus) throws -> LessonAttemptSnapshot
    ) throws -> LessonMutationResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let matches = try context.fetch(FetchDescriptor<LessonAttempt>()).filter { $0.id == attemptID }
        guard matches.count <= 1 else { throw LessonExperienceError.invalidStoredData }
        guard let row = matches.first else { throw LessonExperienceError.attemptNotFound }
        // Validate the unique progress/attempt pairing and pin even for no-ops.
        let current = try detail(lessonID: row.lessonID, in: context)
        guard let attempt = current.attempt, attempt.id == attemptID,
              let progress = current.progress else { throw LessonExperienceError.invalidStoredData }
        let next = try apply(attempt, progress.status)
        if next == attempt { return try result(.unchanged, detail: current, in: context) }
        row.solutionRevealedAt = next.solutionRevealedAt
        row.selfCheckAcknowledgedAt = next.selfCheckAcknowledgedAt
        row.revision = next.revision
        // Validate every receipt projection before committing; never report a
        // successful save as failed due to a later read.
        let updated = try detail(lessonID: row.lessonID, in: context)
        let receipt = try result(.changed, detail: updated, in: context)
        try beforeSave()
        try save(context)
        return receipt
    }

    private func result(_ outcome: LessonMutationOutcome, detail: LessonDetailSnapshot,
                        in context: ModelContext, replacedSlot: LessonSlotSnapshot? = nil) throws -> LessonMutationResult {
        let catalog = try snapshot(in: context)
        // Project History before commit; never turn a committed save into a
        // reported failure because of a fallible post-commit read.
        let history = try self.history(in: context, catalog: catalog)
        let coverage = try self.coverage(in: context, catalog: catalog)
        return LessonMutationResult(outcome: outcome, catalog: catalog, detail: detail,
                                    history: history, coverage: coverage, replacedSlot: replacedSlot)
    }

    private func history(in context: ModelContext,
                         catalog existing: LearningCatalogSnapshot? = nil) throws -> [LessonHistorySnapshot] {
        let catalog = try existing ?? snapshot(in: context)
        let archives = try EvidenceIdentity.terminalMetadata(context.fetch(FetchDescriptor<LessonTerminalRecord>()))
        var entries: [LessonHistorySnapshot] = []
        for progress in catalog.progress where progress.status == .completed || progress.status == .dismissed {
            let item = try detail(lessonID: progress.lessonID, in: context)
            let timestamp = progress.status == .completed ? progress.completedAt : progress.dismissedAt
            guard let date = timestamp, date.timeIntervalSinceReferenceDate.isFinite else {
                throw LessonExperienceError.invalidStoredData
            }
            // Missing archives are legacy gaps until import backfill (Step 2.2).
            // Do not infer their labels or taxonomy from an installed definition.
            let metadata = archives[progress.lessonID]
            let content: LessonStudiedContent
            if progress.status == .dismissed && item.attempt == nil {
                content = metadata?.dismissalTimeDefinition.map(LessonStudiedContent.current) ?? .unavailable
            } else if progress.status == .completed,
                      item.attempt?.pinnedContentData?.isEmpty == true,
                      let legacy = item.attempt?.completedContentSnapshot {
                // An empty pin is the legacy upgrade sentinel, not a corrupt
                // pin. Its separately recorded reduced snapshot remains usable.
                content = .legacyCompleted(legacy)
            } else {
                content = item.content
            }
            let legacyTitle: String?
            if case .legacyCompleted(let snapshot) = content { legacyTitle = snapshot.title }
            else { legacyTitle = nil }
            entries.append(LessonHistorySnapshot(lessonID: progress.lessonID, status: progress.status,
                                                  date: date, title: metadata?.title ?? legacyTitle ?? progress.lessonID,
                                                  topicID: metadata?.topicID,
                                                  contentVersion: metadata?.contentVersion ?? item.attempt?.contentVersion,
                                                  provenance: metadata?.provenance, metadata: metadata,
                                                  content: content, attempt: item.attempt))
        }
        return entries.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.lessonID < rhs.lessonID : lhs.date > rhs.date
        }
    }

    // This is a detached projection only: neither the read nor receipt creation
    // reconciles slots or edits attempts/progress. Reads use a fresh context;
    // receipts use the caller's private write context before its single save.
    private func coverage(in context: ModelContext,
                          catalog: LearningCatalogSnapshot) throws -> LearningCoverageSnapshot {
        let archives = try EvidenceIdentity.terminalMetadata(
            context.fetch(FetchDescriptor<LessonTerminalRecord>()))
        let completions = catalog.progress.filter { $0.status == .completed }.map { row in
            CoverageCompletionEvidence(lessonID: row.lessonID, status: row.status,
                completedAt: row.completedAt, metadata: archives[row.lessonID])
        }
        return try LearningCoverage.aggregate(membership: membership(in: context),
            topics: catalog.topics, subtopics: catalog.subtopics, concepts: catalog.concepts,
            completions: completions)
    }

    // Legacy terminal recovery precedes every definition update, including a
    // matching-version retry. An existing archive is authoritative and never
    // rewritten. A corrupt pin is not permission to use a reduced snapshot.
    private func backfillTerminalEvidence(in context: ModelContext) throws -> Bool {
        let existing = try EvidenceIdentity.terminalMetadata(
            context.fetch(FetchDescriptor<LessonTerminalRecord>()))
        let definitions = try EvidenceIdentity.requireUnique(
            context.fetch(FetchDescriptor<LessonDefinition>()), id: { $0.id })
        let progress = try EvidenceIdentity.requireUnique(
            context.fetch(FetchDescriptor<LessonProgress>()), id: { $0.lessonID })
        let attempts = try context.fetch(FetchDescriptor<LessonAttempt>())
        var changed = false
        for (id, row) in progress.sorted(by: { $0.key < $1.key })
            where (row.status == .completed || row.status == .dismissed) && existing[id] == nil {
            let matching = attempts.filter { $0.lessonID == id }
            guard matching.count <= 1 else { throw LessonExperienceError.invalidStoredData }
            let metadata: LessonTerminalMetadata
            if let attempt = matching.first {
                guard (row.status == .completed) == (attempt.completedAt != nil) else {
                    throw LessonExperienceError.invalidStoredData
                }
                let snapshot = LessonAttemptSnapshot(id: attempt.id, lessonID: id,
                    contentVersion: attempt.contentVersion, answerDraft: attempt.answerDraft,
                    solutionRevealedAt: attempt.solutionRevealedAt,
                    selfCheckAcknowledgedAt: attempt.selfCheckAcknowledgedAt,
                    completedAt: attempt.completedAt,
                    completedContentSnapshot: attempt.completedContentSnapshot,
                    pinnedContentData: attempt.pinnedContentData, revision: attempt.revision)
                if let pin = attempt.pinnedContentData, !pin.isEmpty {
                    // Decode even when a legacy snapshot exists. A malformed pin
                    // must fail explicitly instead of being silently superseded.
                    let definition = try PinnedLessonContent.decode(pin, lessonID: id,
                        contentVersion: attempt.contentVersion).definition
                    metadata = Self.recoveredMetadata(definition: definition,
                        provenance: row.status == .completed ? .studiedPin : .dismissalPin)
                } else if row.status == .completed, attempt.completedContentSnapshot != nil {
                    metadata = try Self.terminalMetadata(lessonID: id, attempt:
                        LessonAttemptSnapshot(id: snapshot.id, lessonID: id,
                            contentVersion: snapshot.contentVersion, completedAt: snapshot.completedAt,
                            completedContentSnapshot: snapshot.completedContentSnapshot),
                        provenance: .legacyCompletedPartial)
                } else {
                    // The original version is not recoverable. Do not use today's
                    // definition as proof of studied or dismissed content.
                    metadata = LessonTerminalMetadata(lessonID: id,
                        provenance: row.status == .completed ? .legacyCompletedPartial : .legacyRecoveredReference,
                        title: nil, topicID: nil, subtopicID: nil,
                        contentVersion: attempt.contentVersion, objectiveKey: nil,
                        conceptIDs: nil, normalizedContentHash: nil, format: nil,
                        dismissalTimeDefinition: nil)
                }
            } else if row.status == .dismissed, let definition = definitions[id] {
                let reference = Self.definitionSnapshot(definition)
                metadata = Self.recoveredMetadata(definition: reference,
                    provenance: .legacyRecoveredReference, reference: reference)
            } else {
                metadata = LessonTerminalMetadata(lessonID: id,
                    provenance: row.status == .completed ? .legacyCompletedPartial : .legacyRecoveredReference,
                    title: nil, topicID: nil, subtopicID: nil, contentVersion: nil,
                    objectiveKey: nil, conceptIDs: nil, normalizedContentHash: nil,
                    format: nil, dismissalTimeDefinition: nil)
            }
            context.insert(try LessonTerminalRecord(metadata: metadata))
            changed = true
        }
        return changed
    }

    // Older stored definitions can predate canonical hash validation. Their
    // recorded teaching sections, not an arbitrary legacy digest, are the
    // recoverable matching evidence. Never edit the original pin or definition.
    private static func recoveredMetadata(definition: LessonDefinitionSnapshot,
                                          provenance: TerminalMetadataProvenance,
                                          reference: LessonDefinitionSnapshot? = nil) -> LessonTerminalMetadata {
        LessonTerminalMetadata(lessonID: definition.id, provenance: provenance,
            title: definition.title, topicID: definition.topicID, subtopicID: definition.subtopicID,
            contentVersion: definition.contentVersion, objectiveKey: definition.objectiveKey,
            conceptIDs: Array(Set(definition.conceptIDs)).sorted(),
            normalizedContentHash: CatalogValidator.fingerprint(
                explanation: definition.explanation, workedExample: definition.workedExample,
                exercise: definition.exercise, referenceAnswer: definition.referenceAnswer,
                selfCheckCriteria: definition.selfCheckCriteria), format: definition.format,
            dismissalTimeDefinition: reference)
    }

    // Replace a prior dismissal archive only when the restored lesson is actually
    // completed. All other terminal writes create exactly one detached record.
    private func storeTerminal(_ metadata: LessonTerminalMetadata, in context: ModelContext) throws {
        try metadata.validate()
        let rows = try context.fetch(FetchDescriptor<LessonTerminalRecord>())
        _ = try EvidenceIdentity.terminalMetadata(rows)
        if let row = rows.first(where: { $0.lessonID == metadata.lessonID }) {
            row.payload = try LessonTerminalRecord(metadata: metadata).payload
        } else {
            context.insert(try LessonTerminalRecord(metadata: metadata))
        }
    }

    private static func terminalMetadata(definition: LessonDefinitionSnapshot,
                                         provenance: TerminalMetadataProvenance,
                                         reference: LessonDefinitionSnapshot? = nil) -> LessonTerminalMetadata {
        LessonTerminalMetadata(lessonID: definition.id, provenance: provenance,
            title: definition.title, topicID: definition.topicID, subtopicID: definition.subtopicID,
            contentVersion: definition.contentVersion, objectiveKey: definition.objectiveKey,
            conceptIDs: Array(Set(definition.conceptIDs)).sorted(),
            normalizedContentHash: definition.normalizedContentHash, format: definition.format,
            dismissalTimeDefinition: reference)
    }

    private static func terminalMetadata(lessonID: String, attempt: LessonAttemptSnapshot,
                                         provenance: TerminalMetadataProvenance) throws -> LessonTerminalMetadata {
        switch try LessonExperience.studiedContent(attempt) {
        case .pinned(let definition):
            return terminalMetadata(definition: definition, provenance: provenance)
        case .legacyCompleted(let snapshot):
            let ids = Array(Set(snapshot.conceptIDs)).sorted()
            return LessonTerminalMetadata(lessonID: lessonID, provenance: .legacyCompletedPartial,
                title: snapshot.title, topicID: nil, subtopicID: nil,
                contentVersion: attempt.contentVersion,
                objectiveKey: snapshot.objectiveKey.isEmpty ? nil : snapshot.objectiveKey,
                conceptIDs: ids.isEmpty ? nil : ids,
                normalizedContentHash: CatalogValidator.fingerprint(
                    explanation: snapshot.explanation, workedExample: snapshot.workedExample,
                    exercise: snapshot.exercise, referenceAnswer: snapshot.referenceAnswer,
                    selfCheckCriteria: snapshot.selfCheckCriteria), format: snapshot.format,
                dismissalTimeDefinition: nil)
        case .current, .unavailable:
            throw LessonExperienceError.contentUnavailable
        }
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

    private func selectionEvidence(in context: ModelContext, catalog: LearningCatalogSnapshot) throws ->
        (terminal: [TerminalLessonMatch], completed: Set<String>,
         membership: CatalogMembershipAvailability, activePins: [StartedLessonEvidence]) {
        let archives = try EvidenceIdentity.terminalMetadata(
            context.fetch(FetchDescriptor<LessonTerminalRecord>()))
        let progress = Dictionary(uniqueKeysWithValues: catalog.progress.map { ($0.lessonID, $0.status) })
        let terminal = catalog.progress.filter { $0.status == .completed || $0.status == .dismissed }
            .map { row in
                let metadata = archives[row.lessonID]
                return TerminalLessonMatch(status: row.status, metadata: LessonMatchMetadata(
                    id: row.lessonID, objectiveKey: metadata?.objectiveKey,
                    conceptIDs: metadata?.conceptIDs, contentHash: metadata?.normalizedContentHash),
                    topicID: metadata?.topicID, format: metadata?.format,
                    date: row.status == .completed ? row.completedAt : row.dismissedAt)
            }
        let completed = Set(catalog.progress.filter { $0.status == .completed }
            .flatMap { archives[$0.lessonID]?.conceptIDs ?? [] })
        let membership = try membership(in: context)
        var activePins: [StartedLessonEvidence] = []
        for attempt in try context.fetch(FetchDescriptor<LessonAttempt>())
            where progress[attempt.lessonID] == .started && attempt.completedAt == nil {
            guard let data = attempt.pinnedContentData, !data.isEmpty else { continue }
            let pin = try PinnedLessonContent.decode(data, lessonID: attempt.lessonID,
                                                      contentVersion: attempt.contentVersion)
            activePins.append(StartedLessonEvidence(pin.definition))
        }
        return (terminal, completed, membership, activePins)
    }

    private func membership(in context: ModelContext) throws -> CatalogMembershipAvailability {
        let states = try EvidenceIdentity.requireUnique(
            context.fetch(FetchDescriptor<CatalogImportState>()), id: { $0.catalogID })
        let memberships = try context.fetch(FetchDescriptor<CatalogMembership>())
        guard let state = states.values.first else {
            let unique = try EvidenceIdentity.requireUnique(memberships, id: { $0.catalogID })
            for row in unique.values { _ = try row.membership() }
            return .unavailable
        }
        // There is only one installed learning catalog. Multiple distinct import
        // markers cannot identify an authoritative denominator for this read.
        guard states.count == 1 else { throw LearningEvidenceError.duplicateIdentity }
        return try EvidenceIdentity.membership(memberships, catalogID: state.catalogID,
                                               installedVersion: state.lastImportedVersion)
    }

    private func reconcile(in context: ModelContext, now: Date, commit: Bool = true) throws {
        let current = try snapshot(in: context)
        let evidence = try selectionEvidence(in: context, catalog: current)
        let desired = try LessonSelector.reconcile(definitions: current.definitions,
            concepts: current.concepts, subtopics: current.subtopics,
            progress: current.progress, slots: current.slots,
            terminal: evidence.terminal, completedConceptIDs: evidence.completed,
            membership: evidence.membership, activePins: evidence.activePins, now: now)
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
        let progressRows = try context.fetch(FetchDescriptor<LessonProgress>())
        guard Set(progressRows.map(\.lessonID)).count == progressRows.count else {
            throw LessonExperienceError.invalidStoredData
        }
        let progress = try progressRows.map { item -> LessonProgressSnapshot in
            guard let status = LessonProgressStatus(rawValue: item.status.rawValue) else {
                throw LessonExperienceError.invalidStoredData
            }
            return LessonProgressSnapshot(lessonID: item.lessonID, status: status,
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
        var pins: [LessonDefinitionSnapshot] = []
        let startedIDs = Set(progress.filter { $0.status == .started }.map(\.lessonID))
        for attempt in try context.fetch(FetchDescriptor<LessonAttempt>())
            where startedIDs.contains(attempt.lessonID) && attempt.completedAt == nil {
            guard let data = attempt.pinnedContentData, !data.isEmpty else { continue }
            let pin = try PinnedLessonContent.decode(data, lessonID: attempt.lessonID,
                                                      contentVersion: attempt.contentVersion)
            pins.append(pin.definition)
        }
        guard Set(pins.map(\.id)).count == pins.count else { throw LessonExperienceError.invalidStoredData }
        return LearningCatalogSnapshot(topics: topics, subtopics: subtopics,
            concepts: concepts, definitions: definitions, progress: progress, slots: slots,
            startedPins: pins.sorted { $0.id < $1.id })
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
