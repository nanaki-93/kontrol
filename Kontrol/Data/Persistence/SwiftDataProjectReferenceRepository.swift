import Foundation
import SwiftData

// These values cross the persistence boundary without carrying SwiftData models or project content.
struct ProjectReferenceSnapshot: Equatable {
    let id: UUID
    let manifestID: String
    let bookmarkData: Data
    let displayOrder: Int
    let displayNameHint: String
    let lastSuccessfulReadAt: Date?
    let revision: UUID
}

struct NewProjectReference {
    let id: UUID
    let manifestID: String
    let bookmarkData: Data
    let displayOrder: Int
    let displayNameHint: String
}

struct ReconnectedProjectReference {
    let manifestID: String
    let bookmarkData: Data
    let displayNameHint: String
}

enum ProjectReferencePersistenceError: Error, Equatable {
    case invalidReference
    case duplicateID
    case notFound
    case staleRevision
    case manifestMismatch
}

@MainActor
protocol ProjectReferenceRepository {
    func fetchAll() throws -> [ProjectReferenceSnapshot]
    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot
    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot
    func recordSuccessfulRead(id: UUID, expectedRevision: UUID,
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot
}

@MainActor
final class SwiftDataProjectReferenceRepository: ProjectReferenceRepository {
    private let container: ModelContainer
    // A failing pre-commit hook exercises rollback without allowing a test double
    // to report a successful save that never reached durable storage.
    private let beforeSave: () throws -> Void

    init(container: ModelContainer, beforeSave: @escaping () throws -> Void = {}) {
        self.container = container
        self.beforeSave = beforeSave
    }

    private func commit(_ context: ModelContext) throws {
        try beforeSave()
        try context.save()
    }

    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func valid(_ manifestID: String, _ bookmarkData: Data, _ name: String) -> Bool {
        !manifestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bookmarkData.isEmpty &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func snapshot(_ row: ProjectReference) throws -> ProjectReferenceSnapshot {
        guard row.displayOrder >= 0,
              valid(row.manifestID, row.bookmarkData, row.displayNameHint),
              row.lastSuccessfulReadAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            throw ProjectReferencePersistenceError.invalidReference
        }
        return ProjectReferenceSnapshot(id: row.id, manifestID: row.manifestID,
                                        bookmarkData: row.bookmarkData, displayOrder: row.displayOrder,
                                        displayNameHint: row.displayNameHint,
                                        lastSuccessfulReadAt: row.lastSuccessfulReadAt, revision: row.revision)
    }

    private func rows(in context: ModelContext) throws -> [ProjectReference] {
        let rows = try context.fetch(FetchDescriptor<ProjectReference>())
        guard Set(rows.map(\.id)).count == rows.count else {
            throw ProjectReferencePersistenceError.duplicateID
        }
        for row in rows { _ = try snapshot(row) }
        return rows
    }

    func fetchAll() throws -> [ProjectReferenceSnapshot] {
        try rows(in: context()).map(snapshot).sorted {
            if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func insert(_ input: NewProjectReference) throws -> ProjectReferenceSnapshot {
        let context = context()
        let existing = try rows(in: context)
        guard valid(input.manifestID, input.bookmarkData, input.displayNameHint),
              input.displayOrder >= 0 else { throw ProjectReferencePersistenceError.invalidReference }
        guard !existing.contains(where: { $0.id == input.id }) else {
            throw ProjectReferencePersistenceError.duplicateID
        }
        // Folder identity is checked by the access/store layer, not by comparing opaque bookmarks.
        let row = ProjectReference(id: input.id, manifestID: input.manifestID,
                                   bookmarkData: input.bookmarkData, displayOrder: input.displayOrder,
                                   displayNameHint: input.displayNameHint)
        context.insert(row)
        let receipt = try snapshot(row)
        try commit(context)
        return receipt
    }

    private func row(id: UUID, expectedRevision: UUID, in context: ModelContext) throws -> ProjectReference {
        guard let row = try rows(in: context).first(where: { $0.id == id }) else {
            throw ProjectReferencePersistenceError.notFound
        }
        guard row.revision == expectedRevision else { throw ProjectReferencePersistenceError.staleRevision }
        return row
    }

    func reconnect(id: UUID, expectedRevision: UUID,
                   input: ReconnectedProjectReference) throws -> ProjectReferenceSnapshot {
        let context = context()
        let row = try row(id: id, expectedRevision: expectedRevision, in: context)
        guard row.manifestID == input.manifestID else { throw ProjectReferencePersistenceError.manifestMismatch }
        guard valid(input.manifestID, input.bookmarkData, input.displayNameHint) else {
            throw ProjectReferencePersistenceError.invalidReference
        }
        row.bookmarkData = input.bookmarkData
        row.displayNameHint = input.displayNameHint
        // A new grant needs a fresh successful inspection; old metadata is not fresh.
        row.lastSuccessfulReadAt = nil
        row.revision = UUID()
        let receipt = try snapshot(row)
        try commit(context)
        return receipt
    }

    func recordSuccessfulRead(id: UUID, expectedRevision: UUID,
                              nameHint: String, readAt: Date) throws -> ProjectReferenceSnapshot {
        let context = context()
        let row = try row(id: id, expectedRevision: expectedRevision, in: context)
        guard !nameHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              readAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProjectReferencePersistenceError.invalidReference
        }
        row.displayNameHint = nameHint
        row.lastSuccessfulReadAt = readAt
        row.revision = UUID()
        let receipt = try snapshot(row)
        try commit(context)
        return receipt
    }
}
