import SwiftData

enum KontrolMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KontrolSchemaV1.self, KontrolSchemaV2.self, KontrolSchemaV3.self, KontrolSchemaV4.self, KontrolSchemaV5.self, KontrolSchemaV6.self, KontrolSchemaV7.self, KontrolSchemaV8.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: KontrolSchemaV1.self, toVersion: KontrolSchemaV2.self),
         .lightweight(fromVersion: KontrolSchemaV2.self, toVersion: KontrolSchemaV3.self),
         .lightweight(fromVersion: KontrolSchemaV3.self, toVersion: KontrolSchemaV4.self),
         .lightweight(fromVersion: KontrolSchemaV4.self, toVersion: KontrolSchemaV5.self),
         .lightweight(fromVersion: KontrolSchemaV5.self, toVersion: KontrolSchemaV6.self),
         .lightweight(fromVersion: KontrolSchemaV6.self, toVersion: KontrolSchemaV7.self),
         .lightweight(fromVersion: KontrolSchemaV7.self, toVersion: KontrolSchemaV8.self)]
    }
}
