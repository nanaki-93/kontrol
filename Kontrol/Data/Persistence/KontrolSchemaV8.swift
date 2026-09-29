import Foundation
import SwiftData

// Local authorization and ordering only; .kontrol files remain the source of project content.
enum KontrolSchemaV8: VersionedSchema {
    static var versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        KontrolSchemaV7.models + [ProjectReference.self]
    }

    @Model
    final class ProjectReference {
        @Attribute(.unique) var id: UUID
        var manifestID: String
        var bookmarkData: Data
        var displayOrder: Int
        // A disposable label for when access is unavailable, not a content cache.
        var displayNameHint: String
        var lastSuccessfulReadAt: Date?
        var revision: UUID

        init(id: UUID = UUID(), manifestID: String, bookmarkData: Data,
             displayOrder: Int, displayNameHint: String,
             lastSuccessfulReadAt: Date? = nil, revision: UUID = UUID()) {
            self.id = id
            self.manifestID = manifestID
            self.bookmarkData = bookmarkData
            self.displayOrder = displayOrder
            self.displayNameHint = displayNameHint
            self.lastSuccessfulReadAt = lastSuccessfulReadAt
            self.revision = revision
        }
    }
}

typealias ProjectReference = KontrolSchemaV8.ProjectReference
