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

/// Pure initial, vacancy, and one-slot replacement selection.
/// This never changes progress or attempts.
/// The caller persists the returned rows in the same transaction as its other writes.
enum LessonSelector {
    static let slotsPerTopic = 4
    private static let supportedFormats: Set<String> = ["learn", "code", "question", "design"]
    private static let supportedDifficulties: Set<String> = ["basic", "intermediate", "advanced"]
    private static let supportedSources: Set<String> = ["seed", "generated"]

    // A read must reject contradictory stored identities too; only missing or
    // wrong-topic assignments are ordinary vacancies for the write reconciler.
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

    /// Rotates only the confirmed assignment. Missing candidates leave that key vacant;
    /// other slots (including existing vacancies) are never repaired here.
    static func replace(consumedSlot: LessonSlotSnapshot,
                        definitions: [LessonDefinitionSnapshot],
                        concepts: [LearningConceptSnapshot],
                        progress: [LessonProgressSnapshot],
                        slots: [LessonSlotSnapshot],
                        terminalAttempts: [LessonAttemptSnapshot],
                        now: Date) throws -> [LessonSlotSnapshot] {
        try validateInputs(definitions: definitions, concepts: concepts,
                           progress: progress, slots: slots)
        guard slots.contains(consumedSlot) else { throw LessonSelectionError.staleConsumedSlot }
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let byConcept = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
        let status = Dictionary(uniqueKeysWithValues: progress.map { ($0.lessonID, $0.status) })
        let finished = Set(progress.compactMap {
            $0.status == .completed || $0.status == .dismissed ? $0.lessonID : nil
        })
        guard finished.contains(consumedSlot.lessonID) else {
            throw LessonSelectionError.consumedLessonNotTerminal
        }
        let remaining = slots.filter { $0.key != consumedSlot.key }
        var usedContent = Set(definitions.filter { finished.contains($0.id) }.map(content))
        // Installed definitions may have changed since practice. A terminal attempt's
        // studied version still blocks an exact repeat; never substitute a bad pin.
        for attempt in terminalAttempts where finished.contains(attempt.lessonID) {
            if let data = attempt.pinnedContentData {
                let studied = try PinnedLessonContent.decode(data, lessonID: attempt.lessonID,
                                                             contentVersion: attempt.contentVersion)
                usedContent.insert(content(studied.definition))
            } else if let snapshot = attempt.completedContentSnapshot {
                usedContent.insert(content(explanation: snapshot.explanation,
                    workedExample: snapshot.workedExample, exercise: snapshot.exercise,
                    referenceAnswer: snapshot.referenceAnswer,
                    criteria: snapshot.selfCheckCriteria))
            }
        }
        for slot in remaining {
            if let definition = byID[slot.lessonID], definition.topicID == slot.topicID,
               !finished.contains(slot.lessonID) {
                usedContent.insert(content(definition))
            }
        }
        let active = remaining.compactMap { slot -> LessonDefinitionSnapshot? in
            guard slot.topicID == consumedSlot.topicID,
                  let definition = byID[slot.lessonID], definition.topicID == slot.topicID,
                  !finished.contains(slot.lessonID) else { return nil }
            return definition
        }
        let practiced = practicedConcepts(finished: finished, status: status,
                                          definitions: byID, concepts: byConcept)
        let usedIDs = Set(remaining.map(\.lessonID))
        let candidates = definitions.filter { lesson in
            lesson.topicID == consumedSlot.topicID && !usedIDs.contains(lesson.id) &&
            !finished.contains(lesson.id) && supportedFormats.contains(lesson.format) &&
            supportedDifficulties.contains(lesson.difficulty) &&
            supportedSources.contains(lesson.source) &&
            lesson.prerequisiteConceptIDs.allSatisfy(practiced.contains) &&
            !usedContent.contains(content(lesson))
        }
        if let chosen = rankedCandidate(candidates, active: active, status: status) {
            return (remaining + [LessonSlotSnapshot(topicID: consumedSlot.topicID,
                slotIndex: consumedSlot.slotIndex, lessonID: chosen.id, assignedAt: now)])
                .sorted(by: slotOrder)
        }
        return remaining.sorted(by: slotOrder)
    }

    static func reconcile(definitions: [LessonDefinitionSnapshot],
                          concepts: [LearningConceptSnapshot],
                          progress: [LessonProgressSnapshot],
                          slots: [LessonSlotSnapshot], now: Date) throws -> [LessonSlotSnapshot] {
        try validateInputs(definitions: definitions, concepts: concepts,
                           progress: progress, slots: slots)
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let byConcept = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
        let status = Dictionary(uniqueKeysWithValues: progress.map { ($0.lessonID, $0.status) })

        let finished: Set<String> = Set(progress.compactMap {
            $0.status == .completed || $0.status == .dismissed ? $0.lessonID : nil
        })
        let practiced = practicedConcepts(finished: finished, status: status,
                                          definitions: byID, concepts: byConcept)
        var usedContent = Set(definitions.filter { finished.contains($0.id) }.map(content))
        var result = slots.filter { slot in
            guard let definition = byID[slot.lessonID] else { return false }
            return definition.topicID == slot.topicID && !finished.contains(slot.lessonID)
        }
        var usedIDs = Set(result.map(\.lessonID))
        // Existing valid slots always survive, including started work after a
        // prerequisite change. Their content blocks new exact repeats.
        for slot in result {
            if let definition = byID[slot.lessonID] { usedContent.insert(content(definition)) }
        }

        for topicID in Set(definitions.map(\.topicID)).sorted() {
            for index in 0..<slotsPerTopic {
                if result.contains(where: { $0.topicID == topicID && $0.slotIndex == index }) {
                    continue
                }
                let active = result.compactMap { slot -> LessonDefinitionSnapshot? in
                    guard slot.topicID == topicID else { return nil }
                    return byID[slot.lessonID]
                }
                let candidates = definitions.filter { lesson in
                    lesson.topicID == topicID && !usedIDs.contains(lesson.id) &&
                    !finished.contains(lesson.id) &&
                    supportedFormats.contains(lesson.format) &&
                    supportedDifficulties.contains(lesson.difficulty) &&
                    supportedSources.contains(lesson.source) &&
                    lesson.prerequisiteConceptIDs.allSatisfy(practiced.contains) &&
                    !usedContent.contains(content(lesson))
                }
                guard let chosen = rankedCandidate(candidates, active: active, status: status) else {
                    continue
                }
                result.append(LessonSlotSnapshot(topicID: topicID, slotIndex: index,
                                                 lessonID: chosen.id, assignedAt: now))
                usedIDs.insert(chosen.id)
                usedContent.insert(content(chosen))
            }
        }
        return result.sorted(by: slotOrder)
    }

    private static func validateInputs(definitions: [LessonDefinitionSnapshot],
                                       concepts: [LearningConceptSnapshot],
                                       progress: [LessonProgressSnapshot],
                                       slots: [LessonSlotSnapshot]) throws {
        guard Set(definitions.map(\.id)).count == definitions.count else {
            throw LessonSelectionError.duplicateDefinition
        }
        guard Set(concepts.map(\.id)).count == concepts.count else {
            throw LessonSelectionError.duplicateConcept
        }
        guard Set(progress.map(\.lessonID)).count == progress.count else {
            throw LessonSelectionError.duplicateProgress
        }
        try validateSlotIdentities(slots)
    }

    private static func practicedConcepts(finished: Set<String>,
                                          status: [String: LessonProgressStatus],
                                          definitions: [String: LessonDefinitionSnapshot],
                                          concepts: [String: LearningConceptSnapshot]) -> Set<String> {
        var practiced = Set<String>()
        for id in finished where status[id] == .completed {
            if let lesson = definitions[id] { practiced.formUnion(lesson.conceptIDs) }
        }
        // A completed concept satisfies transitive prerequisites; cycles cannot hang.
        var pending = Array(practiced)
        while let id = pending.popLast() {
            for prerequisite in concepts[id]?.prerequisiteConceptIDs ?? [] {
                if practiced.insert(prerequisite).inserted { pending.append(prerequisite) }
            }
        }
        return practiced
    }

    private static func content(_ lesson: LessonDefinitionSnapshot) -> String {
        content(explanation: lesson.explanation, workedExample: lesson.workedExample,
                exercise: lesson.exercise, referenceAnswer: lesson.referenceAnswer,
                criteria: lesson.selfCheckCriteria)
    }

    private static func content(explanation: String, workedExample: String, exercise: String,
                                referenceAnswer: String, criteria: [String]) -> String {
        ([explanation, workedExample, exercise, referenceAnswer] + criteria)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping }
            .joined(separator: "\u{001F}")
    }

    private static func rankedCandidate(_ candidates: [LessonDefinitionSnapshot],
                                        active: [LessonDefinitionSnapshot],
                                        status: [String: LessonProgressStatus]) -> LessonDefinitionSnapshot? {
        let subtopics = Set(active.map(\.subtopicID))
        let formats = Set(active.map(\.format))
        // Stable ID is the final tie-break, never fetch position or localized order.
        return candidates.min { lhs, rhs in
            let lhsRank = (status[lhs.id] == .started ? 0 : 1,
                           subtopics.contains(lhs.subtopicID) ? 1 : 0,
                           formats.contains(lhs.format) ? 1 : 0)
            let rhsRank = (status[rhs.id] == .started ? 0 : 1,
                           subtopics.contains(rhs.subtopicID) ? 1 : 0,
                           formats.contains(rhs.format) ? 1 : 0)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id < rhs.id
        }
    }

    private static func slotOrder(_ lhs: LessonSlotSnapshot, _ rhs: LessonSlotSnapshot) -> Bool {
        lhs.topicID == rhs.topicID ? lhs.slotIndex < rhs.slotIndex : lhs.topicID < rhs.topicID
    }
}
