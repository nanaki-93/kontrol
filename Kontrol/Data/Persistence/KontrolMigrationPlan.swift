import SwiftData

enum KontrolMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KontrolSchemaV1.self, KontrolSchemaV2.self, KontrolSchemaV3.self, KontrolSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: KontrolSchemaV1.self, toVersion: KontrolSchemaV2.self),
         .lightweight(fromVersion: KontrolSchemaV2.self, toVersion: KontrolSchemaV3.self),
         .lightweight(fromVersion: KontrolSchemaV3.self, toVersion: KontrolSchemaV4.self)]
    }
}
