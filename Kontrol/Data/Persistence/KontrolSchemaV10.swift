import Foundation
import SwiftData

// Additive general preferences only. Missing storage means defaults; opening or
// migrating a store must not insert a row or touch AI/News configuration.
enum KontrolSchemaV10: VersionedSchema {
    static var versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] {
        KontrolSchemaV9.models + [AppPreferencesRecord.self]
    }

    @Model
    final class AppPreferencesRecord {
        static let singletonKey = "app.preferences"

        @Attribute(.unique) var key: String
        var payloadVersion: Int
        var focusDefaultMinutes: Int
        var textSize: String
        var reduceMotion: String
        var revision: UUID

        init(key: String = "app.preferences", payloadVersion: Int = 1,
             focusDefaultMinutes: Int = 25, textSize: String = "system",
             reduceMotion: String = "system", revision: UUID = UUID()) {
            self.key = key
            self.payloadVersion = payloadVersion
            self.focusDefaultMinutes = focusDefaultMinutes
            self.textSize = textSize
            self.reduceMotion = reduceMotion
            self.revision = revision
        }
    }
}

typealias AppPreferencesRecord = KontrolSchemaV10.AppPreferencesRecord
