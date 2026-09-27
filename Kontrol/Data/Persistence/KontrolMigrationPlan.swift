import SwiftData

enum KontrolMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [KontrolSchemaV1.self] }
    // There is no V0 store. Add a real migration stage with the next schema.
    static var stages: [MigrationStage] { [] }
}
