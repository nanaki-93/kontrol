import Foundation
import SwiftData

/// A single-use decision for one exact draft, operation, and set of persisted peers.
/// Only the repository can issue a receipt; copying it shares its consumed state.
struct ScheduleOverlapReview: Equatable {
    let conflicts: [ScheduleConflict]
    fileprivate let input: ScheduleInput
    fileprivate let editingID: UUID?
    fileprivate let containerID: ObjectIdentifier
    fileprivate let approval = Approval()

    fileprivate final class Approval {
        var consumed = false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.editingID == rhs.editingID &&
            lhs.containerID == rhs.containerID && lhs.conflicts == rhs.conflicts &&
            lhs.approval === rhs.approval
    }
}

enum ScheduleRepositoryError: Error, Equatable {
    case validation(ScheduleValidationError)
    case notFound(UUID)
    case overlap(ScheduleOverlapReview)
    case persistence
}

@MainActor
protocol ScheduleRepository {
    func fetchAll() throws -> [ScheduleSnapshot]
    func create(input: ScheduleInput, allowOverlap: Bool, review: ScheduleOverlapReview?) throws -> ScheduleSnapshot
    func update(id: UUID, input: ScheduleInput, allowOverlap: Bool,
                review: ScheduleOverlapReview?) throws -> ScheduleSnapshot
    func delete(id: UUID) throws
}

/// All reads used for a decision and its write take place in the same private context.
/// A failure drops that context without saving or rolling back another owner's changes.
@MainActor
final class SwiftDataScheduleRepository: ScheduleRepository {
    private let container: ModelContainer
    private let makeID: () -> UUID
    private let fetch: (ModelContext) throws -> [ScheduleBlock]
    // Hooks fail before commit, not after it. Never report a committed write as failed.
    private let save: (ModelContext) throws -> Void

    init(container: ModelContainer, makeID: @escaping () -> UUID = UUID.init,
         fetch: @escaping (ModelContext) throws -> [ScheduleBlock] = {
             try $0.fetch(FetchDescriptor<ScheduleBlock>())
         }, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.makeID = makeID
        self.fetch = fetch
        self.save = save
    }

    func fetchAll() throws -> [ScheduleSnapshot] {
        let context = privateContext()
        return try snapshots(in: context)
    }

    func create(input: ScheduleInput, allowOverlap: Bool = false,
                review: ScheduleOverlapReview? = nil) throws -> ScheduleSnapshot {
        let clean = try validate(input)
        let context = privateContext()
        let existing = try snapshots(in: context)
        let approval = try requireOverlapDecision(for: input, clean: clean, against: existing,
                                                   excluding: nil, allowOverlap: allowOverlap,
                                                   review: review)
        let block = ScheduleBlock(id: makeID(), title: clean.title, startAt: clean.startAt,
                                  endAt: clean.endAt, note: clean.note)
        context.insert(block)
        try commit(context)
        approval?.approval.consumed = true
        return ScheduleSnapshot(block)
    }

    func update(id: UUID, input: ScheduleInput, allowOverlap: Bool = false,
                review: ScheduleOverlapReview? = nil) throws -> ScheduleSnapshot {
        let clean = try validate(input)
        let context = privateContext()
        // Fetch once so a failed read cannot be mistaken for a missing row or an empty
        // conflict set. Locate the target before considering any overlaps.
        let blocks = try persistedBlocks(in: context)
        guard let target = blocks.first(where: { $0.id == id }) else {
            throw ScheduleRepositoryError.notFound(id)
        }
        let approval = try requireOverlapDecision(for: input, clean: clean,
                                                   against: blocks.map(ScheduleSnapshot.init),
                                                   excluding: id, allowOverlap: allowOverlap,
                                                   review: review)
        target.title = clean.title
        target.startAt = clean.startAt
        target.endAt = clean.endAt
        target.note = clean.note
        // Do not touch id, lessonID, or linkedTitleSnapshot, even for missing lessons.
        try commit(context)
        approval?.approval.consumed = true
        return ScheduleSnapshot(target)
    }

    func delete(id: UUID) throws {
        let context = privateContext()
        // A failed fetch is not a missing block. Delete only the requested model
        // from this operation's context; failure discards the uncommitted deletion.
        guard let block = try persistedBlocks(in: context).first(where: { $0.id == id }) else {
            throw ScheduleRepositoryError.notFound(id)
        }
        context.delete(block)
        try commit(context)
    }

    private func privateContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func validate(_ input: ScheduleInput) throws -> ScheduleInput {
        do { return try input.validated() }
        catch let error as ScheduleValidationError { throw ScheduleRepositoryError.validation(error) }
    }

    private func persistedBlocks(in context: ModelContext) throws -> [ScheduleBlock] {
        do { return try fetch(context) }
        catch { throw ScheduleRepositoryError.persistence }
    }

    private func snapshots(in context: ModelContext) throws -> [ScheduleSnapshot] {
        ordered(try persistedBlocks(in: context).map(ScheduleSnapshot.init))
    }

    private func ordered(_ blocks: [ScheduleSnapshot]) -> [ScheduleSnapshot] {
        blocks.sorted {
            if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
            if $0.endAt != $1.endAt { return $0.endAt < $1.endAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// The fresh read and subsequent commit are synchronous on the main actor. A changed
    /// draft, peer snapshot (including metadata), or conflict membership requires a new
    /// decision. A vanished conflict returns an empty review; retry a normal save instead.
    private func requireOverlapDecision(for input: ScheduleInput, clean: ScheduleInput,
                                        against blocks: [ScheduleSnapshot], excluding id: UUID?,
                                        allowOverlap: Bool, review: ScheduleOverlapReview?) throws
        -> ScheduleOverlapReview? {
        let conflicts = ScheduleSelection.conflicts(for: clean, against: blocks, excluding: id)
        if allowOverlap {
            if let review = review, !review.approval.consumed,
               review.containerID == ObjectIdentifier(container), review.editingID == id,
               review.input == input, review.conflicts == conflicts, !conflicts.isEmpty {
                return review
            }
            review?.approval.consumed = true
            throw ScheduleRepositoryError.overlap(ScheduleOverlapReview(
                conflicts: conflicts, input: input, editingID: id,
                containerID: ObjectIdentifier(container)))
        }
        if !conflicts.isEmpty {
            throw ScheduleRepositoryError.overlap(ScheduleOverlapReview(
                conflicts: conflicts, input: input, editingID: id,
                containerID: ObjectIdentifier(container)))
        }
        return nil
    }

    private func commit(_ context: ModelContext) throws {
        do { try save(context) }
        catch { throw ScheduleRepositoryError.persistence }
    }
}
