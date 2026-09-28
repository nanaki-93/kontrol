// Standalone V3-only fixture writer. Never link into an Xcode target or use the latest factory.
// See Fixtures/README.md for the one-time capture procedure.
import Foundation
import SwiftData

@main
struct GenerateV3 {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "FixtureWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Pass a new temporary directory"])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        guard output.standardizedFileURL.path.hasPrefix(root.path + "/"),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "FixtureWriter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Use a nonexistent directory under the system temp root"])
        }
        func writeAndClose() throws {
            let schema = Schema(versionedSchema: KontrolSchemaV3.self)
            let configuration = ModelConfiguration(
                schema: schema, url: output.appendingPathComponent("Kontrol.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let taskID = UUID(uuidString: "0C8C76A6-085B-47D7-A820-43EA0BDAB311")!
            context.insert(try TaskItem(id: taskID, title: "V3 fixture task",
                                        createdAt: Date(timeIntervalSince1970: 1_720_000_000),
                                        notes: "Retained task", dueAt: Date(timeIntervalSince1970: 1_720_086_400)))
            context.insert(ScheduleBlock(
                id: UUID(uuidString: "88E80A72-F92B-4E9E-A38A-338F54818D9B")!,
                title: "V3 fixture block", startAt: Date(timeIntervalSince1970: 1_820_000_000),
                endAt: Date(timeIntervalSince1970: 1_820_001_800), note: "Manual"))
            context.insert(FocusSession(
                id: UUID(uuidString: "83B6B103-03BA-4CD5-8D54-90E3398F6E00")!,
                state: "ended", plannedSeconds: 1500, accumulatedActiveSeconds: 72.5,
                startedAt: Date(timeIntervalSince1970: 1_720_000_000),
                endedAt: Date(timeIntervalSince1970: 1_720_000_073),
                checkpointAt: Date(timeIntervalSince1970: 1_720_000_073),
                linkedTaskID: taskID, linkedTitleSnapshot: "V3 fixture task"))
            try context.save()
        }
        try writeAndClose()
        // The complete closed SQLite file set is captured only after this process exits.
    }
}
