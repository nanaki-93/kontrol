import Foundation

enum LessonSelectionError: Error, Equatable {
    case duplicateDefinition
    case duplicateConcept
    case duplicateProgress
    case duplicateSlotKey
    case duplicateSlottedLesson
    case invalidSlotIdentity
    case staleConsumedSlot
    case consumedLessonNotTerminal
}

/// Pure initial, vacancy, and one-slot replacement selection. No progress or attempts are changed.
enum LessonSelector {
    static let slotsPerTopic = 4
    private static let supportedFormats: Set<String> = ["learn", "code", "question", "design"]
    private static let supportedDifficulties: Set<String> = ["basic", "intermediate", "advanced"]
    private static let supportedSources: Set<String> = ["seed", "generated"]

    static func validateSlotIdentities(_ slots: [LessonSlotSnapshot]) throws {
        var keys = Set<String>()
        var lessonIDs = Set<String>()
        for slot in slots {
            guard slot.slotIndex >= 0, slot.slotIndex < slotsPerTopic,
                  slot.key == LessonSlotSnapshot.canonicalKey(topicID: slot.topicID,
                                                               slotIndex: slot.slotIndex),
                  !slot.topicID.isEmpty, !slot.lessonID.isEmpty,
                  slot.assignedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw LessonSelectionError.invalidSlotIdentity
            }
            guard keys.insert(slot.key).inserted else { throw LessonSelectionError.duplicateSlotKey }
            guard lessonIDs.insert(slot.lessonID).inserted else {
                throw LessonSelectionError.duplicateSlottedLesson
            }
        }
    }

    /// `membership == nil` is for detached legacy callers with no catalog identity.
    /// Repository callers always pass explicit availability; unavailable evidence
    /// cannot authorize a new seeded assignment.
    static func replace(consumedSlot: LessonSlotSnapshot,
                        definitions: [LessonDefinitionSnapshot],
                        concepts: [LearningConceptSnapshot],
                        subtopics: [LearningSubtopicSnapshot],
                        progress: [LessonProgressSnapshot],
                        slots: [LessonSlotSnapshot],
                        terminal: [TerminalLessonMatch] = [],
                        completedConceptIDs: Set<String> = [],
                        membership: CatalogMembershipAvailability? = nil,
                        activePins: [LessonMatchMetadata] = [],
                        now: Date) throws -> [LessonSlotSnapshot] {
        try validateInputs(definitions: definitions, concepts: concepts, progress: progress, slots: slots)
        guard slots.contains(consumedSlot) else { throw LessonSelectionError.staleConsumedSlot }
        guard progress.contains(where: { $0.lessonID == consumedSlot.lessonID &&
            ($0.status == .completed || $0.status == .dismissed) }) else {
            throw LessonSelectionError.consumedLessonNotTerminal
        }
        let remaining = slots.filter { $0.key != consumedSlot.key }
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let status = Dictionary(uniqueKeysWithValues: progress.map { ($0.lessonID, $0.status) })
        let active = remaining.compactMap { byID[$0.lessonID] }.filter { $0.topicID == consumedSlot.topicID }
        let candidates = definitions.filter { $0.topicID == consumedSlot.topicID &&
            eligible($0, concepts: concepts, subtopics: subtopics, progress: progress, slots: remaining,
                     terminal: terminal, completedConceptIDs: completedConceptIDs,
                     membership: membership, definitions: definitions, activePins: activePins) }
        if let chosen = rankedCandidate(candidates, active: active, status: status) {
            return (remaining + [LessonSlotSnapshot(topicID: consumedSlot.topicID,
                slotIndex: consumedSlot.slotIndex, lessonID: chosen.id, assignedAt: now)])
                .sorted(by: slotOrder)
        }
        return remaining.sorted(by: slotOrder)
    }

    static func restoredVacancy(lessonID: String,
                                definitions: [LessonDefinitionSnapshot],
                                concepts: [LearningConceptSnapshot],
                                subtopics: [LearningSubtopicSnapshot],
                                progress: [LessonProgressSnapshot],
                                slots: [LessonSlotSnapshot],
                                terminal: [TerminalLessonMatch] = [],
                                completedConceptIDs: Set<String> = [],
                                membership: CatalogMembershipAvailability? = nil,
                                activePins: [LessonMatchMetadata] = [],
                                now: Date) throws -> LessonSlotSnapshot? {
        try validateInputs(definitions: definitions, concepts: concepts, progress: progress, slots: slots)
        guard let candidate = definitions.first(where: { $0.id == lessonID }),
              progress.contains(where: { $0.lessonID == lessonID &&
                  ($0.status == .started || $0.status == .available) }),
              eligible(candidate, concepts: concepts, subtopics: subtopics, progress: progress, slots: slots,
                       terminal: terminal, completedConceptIDs: completedConceptIDs,
                       membership: membership, definitions: definitions, activePins: activePins) else { return nil }
        for index in 0..<slotsPerTopic where !slots.contains(where: {
            $0.topicID == candidate.topicID && $0.slotIndex == index
        }) {
            return LessonSlotSnapshot(topicID: candidate.topicID, slotIndex: index,
                                      lessonID: lessonID, assignedAt: now)
        }
        return nil
    }

    static func reconcile(definitions: [LessonDefinitionSnapshot],
                          concepts: [LearningConceptSnapshot],
                          subtopics: [LearningSubtopicSnapshot],
                          progress: [LessonProgressSnapshot],
                          slots: [LessonSlotSnapshot],
                          terminal: [TerminalLessonMatch] = [],
                          completedConceptIDs: Set<String> = [],
                          membership: CatalogMembershipAvailability? = nil,
                          activePins: [LessonMatchMetadata] = [],
                          now: Date) throws -> [LessonSlotSnapshot] {
        try validateInputs(definitions: definitions, concepts: concepts, progress: progress, slots: slots)
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let status = Dictionary(uniqueKeysWithValues: progress.map { ($0.lessonID, $0.status) })
        // Started assignments own their pinned version even if an upgrade removed
        // the definition. Reserve them first; never evict pinned work for an
        // unstarted choice whose new definition now matches that pin.
        var result = slots.filter { status[$0.lessonID] == .started }
        // Retain valid unstarted slots in canonical slot order, comparing each
        // against the assignments already retained. Otherwise two upgraded rows
        // with identical teaching content could both survive reconciliation.
        for slot in slots.sorted(by: slotOrder) where status[slot.lessonID] != .started {
            guard let definition = byID[slot.lessonID], definition.topicID == slot.topicID,
                  eligible(definition, concepts: concepts, subtopics: subtopics, progress: progress,
                           slots: result, terminal: terminal,
                           completedConceptIDs: completedConceptIDs, membership: membership,
                           definitions: definitions, activePins: activePins) else { continue }
            result.append(slot)
        }
        let topics: [String]
        if case .available(let value) = membership {
            topics = value.topicIDs
        } else {
            topics = Array(Set(definitions.map(\.topicID))).sorted()
        }
        for topicID in topics.sorted() {
            for index in 0..<slotsPerTopic {
                if result.contains(where: { $0.topicID == topicID && $0.slotIndex == index }) { continue }
                let active = result.compactMap { slot -> LessonDefinitionSnapshot? in
                    guard slot.topicID == topicID else { return nil }
                    return byID[slot.lessonID]
                }
                let candidates = definitions.filter { $0.topicID == topicID &&
                    eligible($0, concepts: concepts, subtopics: subtopics, progress: progress, slots: result,
                             terminal: terminal, completedConceptIDs: completedConceptIDs,
                             membership: membership, definitions: definitions, activePins: activePins) }
                guard let chosen = rankedCandidate(candidates, active: active, status: status) else { continue }
                result.append(LessonSlotSnapshot(topicID: topicID, slotIndex: index,
                                                 lessonID: chosen.id, assignedAt: now))
            }
        }
        return result.sorted(by: slotOrder)
    }

    private static func eligible(_ lesson: LessonDefinitionSnapshot,
                                 concepts: [LearningConceptSnapshot],
                                 subtopics: [LearningSubtopicSnapshot],
                                 progress: [LessonProgressSnapshot], slots: [LessonSlotSnapshot],
                                 terminal: [TerminalLessonMatch], completedConceptIDs: Set<String>,
                                 membership: CatalogMembershipAvailability?,
                                 definitions: [LessonDefinitionSnapshot],
                                 activePins: [LessonMatchMetadata]) -> Bool {
        guard supportedFormats.contains(lesson.format), supportedDifficulties.contains(lesson.difficulty),
              supportedSources.contains(lesson.source),
              let ids = LessonDeduplication.canonicalConcepts(lesson.conceptIDs), !ids.isEmpty,
              lesson.prerequisiteConceptIDs.allSatisfy({ !($0.isEmpty) &&
                  $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }),
              !slots.contains(where: { $0.lessonID == lesson.id }) else { return false }
        let status = progress.first { $0.lessonID == lesson.id }?.status
        if let membership, status != .started {
            guard case .available(let current) = membership,
                  current.topicIDs.contains(lesson.topicID),
                  current.subtopicIDs.contains(lesson.subtopicID),
                  ids.isSubset(of: Set(current.conceptIDs)),
                  lesson.source != "seed" || current.seededLessonIDs.contains(lesson.id) else { return false }
        }
        let known = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
        let parentTopic = Dictionary(uniqueKeysWithValues: subtopics.map { ($0.id, $0.topicID) })
        guard parentTopic[lesson.subtopicID] == lesson.topicID else { return false }
        // A lesson can span subtopics, but neither its taught nor required concepts
        // may cross the topic boundary. Do not infer parentage from ID existence.
        let belongsToTopic: (String) -> Bool = { id in
            guard let concept = known[id] else { return false }
            return parentTopic[concept.subtopicID] == lesson.topicID
        }
        guard ids.allSatisfy(belongsToTopic),
              lesson.prerequisiteConceptIDs.allSatisfy(belongsToTopic) else { return false }
        var satisfied = completedConceptIDs
        var pending = Array(satisfied)
        while let id = pending.popLast() {
            for parent in known[id]?.prerequisiteConceptIDs ?? [] where satisfied.insert(parent).inserted {
                pending.append(parent)
            }
        }
        guard lesson.prerequisiteConceptIDs.allSatisfy(satisfied.contains) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let pins = Dictionary(uniqueKeysWithValues: activePins.map { ($0.id, $0) })
        let active = slots.map { slot -> LessonMatchMetadata in
            if progress.contains(where: { $0.lessonID == slot.lessonID && $0.status == .started }),
               let pin = pins[slot.lessonID] { return pin }
            if let definition = byID[slot.lessonID] { return LessonMatchMetadata(definition) }
            return LessonMatchMetadata(id: slot.lessonID, objectiveKey: nil,
                                       conceptIDs: nil, contentHash: nil)
        }
        // Unslotted started work (including Restore) must be compared using what
        // the learner actually opened, not an upgraded installed definition.
        let candidate = status == .started ? pins[lesson.id] ?? LessonMatchMetadata(lesson)
                                           : LessonMatchMetadata(lesson)
        return LessonDeduplication.decide(candidate: candidate,
            terminal: terminal, active: active) == .eligible
    }

    private static func validateInputs(definitions: [LessonDefinitionSnapshot],
                                       concepts: [LearningConceptSnapshot],
                                       progress: [LessonProgressSnapshot],
                                       slots: [LessonSlotSnapshot]) throws {
        guard Set(definitions.map(\.id)).count == definitions.count else { throw LessonSelectionError.duplicateDefinition }
        guard Set(concepts.map(\.id)).count == concepts.count else { throw LessonSelectionError.duplicateConcept }
        guard Set(progress.map(\.lessonID)).count == progress.count else { throw LessonSelectionError.duplicateProgress }
        try validateSlotIdentities(slots)
    }

    private static func rankedCandidate(_ candidates: [LessonDefinitionSnapshot],
                                        active: [LessonDefinitionSnapshot],
                                        status: [String: LessonProgressStatus]) -> LessonDefinitionSnapshot? {
        let subtopics = Set(active.map(\.subtopicID))
        let formats = Set(active.map(\.format))
        return candidates.min { lhs, rhs in
            let l = (status[lhs.id] == .started ? 0 : 1, subtopics.contains(lhs.subtopicID) ? 1 : 0,
                     formats.contains(lhs.format) ? 1 : 0)
            let r = (status[rhs.id] == .started ? 0 : 1, subtopics.contains(rhs.subtopicID) ? 1 : 0,
                     formats.contains(rhs.format) ? 1 : 0)
            if l != r { return l < r }
            return lhs.id < rhs.id
        }
    }

    private static func slotOrder(_ lhs: LessonSlotSnapshot, _ rhs: LessonSlotSnapshot) -> Bool {
        lhs.topicID == rhs.topicID ? lhs.slotIndex < rhs.slotIndex : lhs.topicID < rhs.topicID
    }
}
