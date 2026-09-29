import Foundation
import SwiftData

enum StoreMode {
    case persistent(URL)
    case inMemory
}

struct ModelContainerFactory {
    func makeProductionContainer() throws -> ModelContainer {
        try makeContainer(mode: .persistent(StoreLocation.productionStoreURL()))
    }

    func makeContainer(mode: StoreMode) throws -> ModelContainer {
        let schema = Schema(versionedSchema: KontrolSchemaV8.self)
        let configuration: ModelConfiguration
        switch mode {
        case .inMemory:
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        case .persistent(let url):
            // Only create a missing parent directory. Never remove, rename, truncate,
            // or replace a store (including its SQLite sidecars) on open failure.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url,
                                               cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: KontrolMigrationPlan.self,
                                  configurations: [configuration])
    }
}
