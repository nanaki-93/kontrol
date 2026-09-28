// Standalone V2-only fixture writer. Not part of the app or test targets.
// See Fixtures/README.md for the compile command and capture procedure.
import Foundation
import SwiftData

@main
struct GenerateV2 {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "FixtureWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Pass a new temporary directory"])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        guard output.standardizedFileURL.path.hasPrefix(temporaryRoot.path + "/"),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "FixtureWriter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Use a nonexistent directory under the system temp root"])
        }
        let store = output.appendingPathComponent("Kontrol.store")
        func writeAndClose() throws {
            // Open V2 directly, not via the production factory or a V1 migration.
            let schema = Schema(versionedSchema: KontrolSchemaV2.self)
            let configuration = ModelConfiguration(schema: schema, url: store,
                                                   cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(try TaskItem(
                id: UUID(uuidString: "6E9D469D-49F7-4D66-9084-2E1AA79E5FF2")!,
                title: "V2 fixture task", createdAt: Date(timeIntervalSince1970: 1_710_000_000),
                notes: "Keep for upgrade", dueAt: Date(timeIntervalSince1970: 1_710_086_400)))
            context.insert(ScheduleBlock(
                id: UUID(uuidString: "9BA7AB1F-6349-4CDD-AF43-08FE8BA9DB13")!,
                title: "V2 fixture block", startAt: Date(timeIntervalSince1970: 1_800_000_000),
                endAt: Date(timeIntervalSince1970: 1_800_005_400), note: "Manual plan"))
            try context.save()
        }
        try writeAndClose()
        // Copy the entire closed file set only after this process exits.
    }
}
