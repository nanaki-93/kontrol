import SwiftData

enum KontrolMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KontrolSchemaV1.self, KontrolSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: KontrolSchemaV1.self, toVersion: KontrolSchemaV2.self)]
    }
}
