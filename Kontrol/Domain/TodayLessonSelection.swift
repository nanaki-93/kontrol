import Foundation

/// A read-only projection of committed, active assignments. Nil means eligibility
/// is unknown (including a failed read with cached rows), not an empty list.
enum TodayLessonSelection {
    struct Suggestion: Identifiable, Equatable {
        var id: String { lesson.id }
        let lesson: LessonDefinitionSnapshot
        let slot: LessonSlotSnapshot
        let started: Bool
    }

    private static let topicOrder = ["go", "java", "design", "perf", "security"]

    static func suggestions(from state: LearningCatalogReadState) -> [Suggestion]? {
        guard state.isAuthoritative, let snapshot = state.snapshot else { return nil }
        let definitions = Dictionary(snapshot.definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let progress = Dictionary(snapshot.progress.map { ($0.lessonID, $0.status) }, uniquingKeysWith: { first, _ in first })
        return Array(snapshot.slots.compactMap { slot -> Suggestion? in
            guard let lesson = definitions[slot.lessonID], lesson.topicID == slot.topicID,
                  progress[slot.lessonID] == nil || progress[slot.lessonID] == .available ||
                  progress[slot.lessonID] == .started else { return nil }
            return Suggestion(lesson: lesson, slot: slot, started: progress[slot.lessonID] == .started)
        }.sorted { lhs, rhs in
            if lhs.started != rhs.started { return lhs.started }
            let left = topicOrder.firstIndex(of: lhs.slot.topicID) ?? topicOrder.count
            let right = topicOrder.firstIndex(of: rhs.slot.topicID) ?? topicOrder.count
            if left != right { return left < right }
            if lhs.slot.topicID != rhs.slot.topicID { return lhs.slot.topicID < rhs.slot.topicID }
            if lhs.slot.slotIndex != rhs.slot.slotIndex { return lhs.slot.slotIndex < rhs.slot.slotIndex }
            return lhs.id < rhs.id
        }.prefix(2))
    }
}
