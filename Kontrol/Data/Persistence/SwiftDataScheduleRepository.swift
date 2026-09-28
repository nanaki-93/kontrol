import Foundation
import SwiftData

enum ScheduleRepositoryError: Error, Equatable {
    case validation(ScheduleValidationError)
    case notFound(UUID)
    case overlap([ScheduleConflict])
    case persistence
}

@MainActor
protocol ScheduleRepository {
    func fetchAll() throws -> [ScheduleSnapshot]
    func create(input: ScheduleInput, allowOverlap: Bool) throws -> ScheduleSnapshot
    func update(id: UUID, input: ScheduleInput, allowOverlap: Bool) throws -> ScheduleSnapshot
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

    func create(input: ScheduleInput, allowOverlap: Bool = false) throws -> ScheduleSnapshot {
        let clean = try validate(input)
        let context = privateContext()
        let existing = try snapshots(in: context)
        try requireOverlapDecision(for: clean, against: existing, excluding: nil,
                                   allowOverlap: allowOverlap)
        let block = ScheduleBlock(id: makeID(), title: clean.title, startAt: clean.startAt,
                                  endAt: clean.endAt, note: clean.note)
        context.insert(block)
        try commit(context)
        return ScheduleSnapshot(block)
    }

    func update(id: UUID, input: ScheduleInput, allowOverlap: Bool = false) throws -> ScheduleSnapshot {
        let clean = try validate(input)
        let context = privateContext()
        // Fetch once so a failed read cannot be mistaken for a missing row or an empty
        // conflict set. Locate the target before considering any overlaps.
        let blocks = try persistedBlocks(in: context)
        guard let target = blocks.first(where: { $0.id == id }) else {
            throw ScheduleRepositoryError.notFound(id)
        }
        try requireOverlapDecision(for: clean, against: blocks.map(ScheduleSnapshot.init),
                                   excluding: id, allowOverlap: allowOverlap)
        target.title = clean.title
        target.startAt = clean.startAt
        target.endAt = clean.endAt
        target.note = clean.note
        // Do not touch id, lessonID, or linkedTitleSnapshot, even for missing lessons.
        try commit(context)
        return ScheduleSnapshot(target)
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

    private func requireOverlapDecision(for input: ScheduleInput, against blocks: [ScheduleSnapshot],
                                        excluding id: UUID?, allowOverlap: Bool) throws {
        let conflicts = ScheduleSelection.conflicts(for: input, against: blocks, excluding: id)
        if !allowOverlap && !conflicts.isEmpty { throw ScheduleRepositoryError.overlap(conflicts) }
    }

    private func commit(_ context: ModelContext) throws {
        do { try save(context) }
        catch { throw ScheduleRepositoryError.persistence }
    }
}
