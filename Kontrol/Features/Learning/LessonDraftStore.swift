import Foundation

/// A scheduler returns a cancellation hook. Callbacks may still arrive after cancellation;
/// the attempt ID and edit generation are checked again on delivery.
@MainActor
final class LessonDraftStore: ObservableObject {
    enum SaveStatus: Equatable {
        case saving
        case saved
        case notSaved(LessonExperienceError) // Not saved — Retry
    }

    struct Buffer: Equatable {
        let attemptID: UUID
        let lessonID: String
        var text: String
        var expectedRevision: Int
        var status: SaveStatus
        var isDirty: Bool
    }

    typealias Scheduler = (_ deadline: Date, _ callback: @escaping () -> Void) -> () -> Void

    @Published private(set) var buffers: [UUID: Buffer] = [:]
    private let learning: LearningCatalogStore
    private let clock: () -> Date
    private let schedule: Scheduler
    private var generations: [UUID: UInt64] = [:]
    private var cancellations: [UUID: () -> Void] = [:]

    init(learning: LearningCatalogStore, clock: @escaping () -> Date = Date.init,
         schedule: @escaping Scheduler = { deadline, callback in
             let item = DispatchWorkItem(block: callback)
             DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
             return { item.cancel() }
         }) {
        self.learning = learning
        self.clock = clock
        self.schedule = schedule
    }

    /// Both windows use the same buffer. An incoming receipt may advance the
    /// durable baseline but must never replace locally dirty text.
    func observe(_ detail: LessonDetailSnapshot) {
        guard let attempt = detail.attempt else { return }
        if var existing = buffers[attempt.id] {
            guard existing.lessonID == detail.id else { return }
            if !existing.isDirty && attempt.revision >= existing.expectedRevision {
                existing.text = attempt.answerDraft
                existing.expectedRevision = attempt.revision
                existing.status = .saved
                buffers[attempt.id] = existing
            }
        } else {
            buffers[attempt.id] = Buffer(attemptID: attempt.id, lessonID: detail.id,
                                         text: attempt.answerDraft, expectedRevision: attempt.revision,
                                         status: .saved, isDirty: false)
        }
    }

    func edit(_ text: String, attemptID: UUID) {
        guard var buffer = buffers[attemptID] else { return }
        cancelPending(attemptID)
        advance(attemptID)
        buffer.text = text
        buffer.isDirty = true
        buffer.status = .saving
        buffers[attemptID] = buffer
        let generation = generations[attemptID]!
        cancellations[attemptID] = schedule(clock().addingTimeInterval(0.5)) { [weak self] in
            guard let self, self.generations[attemptID] == generation else { return }
            self.cancellations[attemptID] = nil
            _ = try? self.flush(attemptID: attemptID)
        }
    }

    /// Synchronous save barrier for navigation and reveal/acknowledge/complete.
    /// A failed flush leaves the route owner free to keep its current location.
    @discardableResult
    func flush(attemptID: UUID) throws -> LessonMutationResult? {
        cancelPending(attemptID)
        // Invalidate a callback that raced cancellation, including a manual flush.
        advance(attemptID)
        guard let buffer = buffers[attemptID], buffer.isDirty else { return nil }
        let generation = generations[attemptID, default: 0]
        do {
            let receipt = try learning.saveAnswer(attemptID: attemptID,
                                                   expectedRevision: buffer.expectedRevision, answer: buffer.text)
            if var current = buffers[attemptID] {
                if let saved = receipt.detail.attempt, saved.id == attemptID {
                    current.expectedRevision = saved.revision
                }
                if generations[attemptID] == generation {
                    current.isDirty = false
                    current.status = .saved
                }
                buffers[attemptID] = current
            }
            return receipt
        } catch {
            if var current = buffers[attemptID], generations[attemptID] == generation {
                current.status = .notSaved((error as? LessonExperienceError) ?? .persistenceFailure)
                buffers[attemptID] = current
            }
            throw error
        }
    }

    /// Save every dirty buffer before a route or lifecycle boundary. On failure
    /// unvisited buffers remain dirty and no caller should proceed with navigation.
    func flushAll() throws {
        for id in buffers.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try flush(attemptID: id)
        }
    }

    @discardableResult
    func retry(attemptID: UUID) throws -> LessonMutationResult? {
        try flush(attemptID: attemptID)
    }

    /// Fetch the durable baseline after a conflict. Keep the user's dirty text
    /// and do not silently adopt a new revision: Retry cannot overwrite someone
    /// else's answer until the user explicitly chooses to reconcile it.
    @discardableResult
    func reload(attemptID: UUID) throws -> LessonDetailSnapshot {
        guard let buffer = buffers[attemptID] else { throw LessonExperienceError.attemptNotFound }
        let detail = try learning.loadDetail(lessonID: buffer.lessonID)
        guard detail.attempt?.id == attemptID else { throw LessonExperienceError.attemptNotFound }
        observe(detail)
        return detail
    }

    /// Explicitly choose to replace the reloaded durable answer with the retained
    /// local draft. This does not write until Retry/flush; never discard the draft.
    func reconcileForRetry(attemptID: UUID, with detail: LessonDetailSnapshot) throws {
        guard var buffer = buffers[attemptID], buffer.isDirty,
              detail.id == buffer.lessonID, let attempt = detail.attempt,
              attempt.id == attemptID, attempt.completedAt == nil,
              detail.progress?.status == .started else { throw LessonExperienceError.invalidTransition }
        // The caller must have just loaded this authoritative detail.
        guard case .current(let loaded) = learning.detailState, loaded == detail else {
            throw LessonExperienceError.invalidTransition
        }
        cancelPending(attemptID)
        advance(attemptID)
        buffer.expectedRevision = attempt.revision
        buffer.status = .notSaved(.staleRevision)
        buffers[attemptID] = buffer
    }

    @discardableResult
    func revealSolution(attemptID: UUID, now: Date = Date()) throws -> LessonMutationResult {
        try flush(attemptID: attemptID)
        let receipt = try learning.revealSolution(attemptID: attemptID,
                                                  expectedRevision: try revision(attemptID), now: now)
        observe(receipt.detail)
        return receipt
    }

    @discardableResult
    func setSelfCheckAcknowledged(attemptID: UUID, acknowledged: Bool, now: Date = Date()) throws -> LessonMutationResult {
        try flush(attemptID: attemptID)
        let receipt = try learning.setSelfCheckAcknowledged(attemptID: attemptID,
                                                            expectedRevision: try revision(attemptID),
                                                            acknowledged: acknowledged, now: now)
        observe(receipt.detail)
        return receipt
    }

    @discardableResult
    func complete(attemptID: UUID, now: Date = Date()) throws -> LessonMutationResult {
        try flush(attemptID: attemptID)
        let receipt = try learning.complete(attemptID: attemptID, expectedRevision: try revision(attemptID), now: now)
        observe(receipt.detail)
        return receipt
    }

    @discardableResult
    func dismiss(lessonID: String, expectedSlot: LessonSlotSnapshot, attemptID: UUID?, now: Date = Date()) throws -> LessonMutationResult {
        if let attemptID, buffers[attemptID]?.lessonID != lessonID {
            throw LessonExperienceError.invalidTransition
        }
        for id in buffers.values.filter({ $0.lessonID == lessonID && $0.isDirty }).map(\.attemptID) {
            try flush(attemptID: id)
        }
        return try learning.dismiss(lessonID: lessonID, expectedSlot: expectedSlot, now: now)
    }

    private func revision(_ id: UUID) throws -> Int {
        guard let buffer = buffers[id], !buffer.isDirty else { throw LessonExperienceError.invalidTransition }
        return buffer.expectedRevision
    }

    private func advance(_ id: UUID) {
        generations[id, default: 0] &+= 1
    }

    private func cancelPending(_ id: UUID) {
        cancellations.removeValue(forKey: id)?()
    }
}
