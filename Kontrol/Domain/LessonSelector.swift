import Foundation

enum LessonSelectionError: Error, Equatable {
    case duplicateDefinition
    case duplicateConcept
    case duplicateProgress
    case duplicateSlotKey
    case duplicateSlottedLesson
    case invalidSlotIdentity
}

/// Pure initial and vacancy selection. This never changes progress or attempts.
/// The caller persists the returned rows in the same transaction as its other writes.
enum LessonSelector {
    static let slotsPerTopic = 4
    private static let supportedFormats: Set<String> = ["learn", "code", "question", "design"]
    private static let supportedDifficulties: Set<String> = ["basic", "intermediate", "advanced"]
    private static let supportedSources: Set<String> = ["seed", "generated"]

    static func reconcile(definitions: [LessonDefinitionSnapshot],
                          concepts: [LearningConceptSnapshot],
                          progress: [LessonProgressSnapshot],
                          slots: [LessonSlotSnapshot], now: Date) throws -> [LessonSlotSnapshot] {
        guard Set(definitions.map(\.id)).count == definitions.count else {
            throw LessonSelectionError.duplicateDefinition
        }
        guard Set(concepts.map(\.id)).count == concepts.count else {
            throw LessonSelectionError.duplicateConcept
        }
        guard Set(progress.map(\.lessonID)).count == progress.count else {
            throw LessonSelectionError.duplicateProgress
        }
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let byConcept = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
        let status = Dictionary(uniqueKeysWithValues: progress.map { ($0.lessonID, $0.status) })

        // Check ALL stored rows before vacating any of them. A duplicate or malformed
        // identity is not a choice between two persisted winners, even if one is stale.
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

        let finished: Set<String> = Set(progress.compactMap {
            $0.status == .completed || $0.status == .dismissed ? $0.lessonID : nil
        })
        var practiced = Set<String>()
        for id in finished where status[id] == .completed {
            if let lesson = byID[id] { practiced.formUnion(lesson.conceptIDs) }
        }
        // A completed concept satisfies its transitive prerequisites. Cycles in a
        // malformed stored graph cannot hang selection; catalog validation prevents
        // such graphs on import.
        var pending = Array(practiced)
        while let id = pending.popLast() {
            for prerequisite in byConcept[id]?.prerequisiteConceptIDs ?? [] {
                if practiced.insert(prerequisite).inserted { pending.append(prerequisite) }
            }
        }

        func content(_ lesson: LessonDefinitionSnapshot) -> String {
            ([lesson.explanation, lesson.workedExample, lesson.exercise,
              lesson.referenceAnswer] + lesson.selfCheckCriteria)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .precomposedStringWithCanonicalMapping }
                .joined(separator: "\u{001F}")
        }
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
                let subtopics = Set(active.map(\.subtopicID))
                let formats = Set(active.map(\.format))
                let candidates = definitions.filter { lesson in
                    lesson.topicID == topicID && !usedIDs.contains(lesson.id) &&
                    !finished.contains(lesson.id) &&
                    supportedFormats.contains(lesson.format) &&
                    supportedDifficulties.contains(lesson.difficulty) &&
                    supportedSources.contains(lesson.source) &&
                    lesson.prerequisiteConceptIDs.allSatisfy(practiced.contains) &&
                    !usedContent.contains(content(lesson))
                }
                // Stable ID is the final tie-break, never fetch position or localized order.
                guard let chosen = candidates.min(by: { lhs, rhs in
                    let lhsRank = (status[lhs.id] == .started ? 0 : 1,
                                   subtopics.contains(lhs.subtopicID) ? 1 : 0,
                                   formats.contains(lhs.format) ? 1 : 0)
                    let rhsRank = (status[rhs.id] == .started ? 0 : 1,
                                   subtopics.contains(rhs.subtopicID) ? 1 : 0,
                                   formats.contains(rhs.format) ? 1 : 0)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    return lhs.id < rhs.id
                }) else { continue }
                result.append(LessonSlotSnapshot(topicID: topicID, slotIndex: index,
                                                 lessonID: chosen.id, assignedAt: now))
                usedIDs.insert(chosen.id)
                usedContent.insert(content(chosen))
            }
        }
        return result.sorted {
            $0.topicID == $1.topicID ? $0.slotIndex < $1.slotIndex : $0.topicID < $1.topicID
        }
    }
}
