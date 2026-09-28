// Standalone V4-only fixture writer. Not an app or test source; never use the production factory.
// Capture only once, after the process exits, into a separate frozen V4 directory.
import Foundation
import SwiftData

@main
struct GenerateV4 {
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
            let schema = Schema(versionedSchema: KontrolSchemaV4.self)
            let configuration = ModelConfiguration(
                schema: schema, url: output.appendingPathComponent("Kontrol.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(Topic(id: "v4-topic", name: "Frozen V4 topic"))
            context.insert(Subtopic(id: "v4-subtopic", topicID: "v4-topic", name: "Frozen V4 subtopic"))
            context.insert(Concept(id: "v4-concept", subtopicID: "v4-subtopic", name: "Frozen V4 concept"))
            context.insert(KontrolSchemaV4.LessonDefinition(
                id: "v4-lesson", objectiveKey: "v4-objective", title: "Frozen V4 lesson",
                topicID: "v4-topic", subtopicID: "v4-subtopic", conceptIDs: ["v4-concept"],
                difficulty: "basic", format: "learn", estimatedMinutes: 19,
                explanation: "V4 explanation", workedExample: "V4 example", exercise: "V4 exercise",
                referenceAnswer: "V4 answer", selfCheckCriteria: ["V4 check"], contentVersion: 2,
                normalizedContentHash: "sha256:frozen-v4", source: "seed", provenance: "V4 fixture",
                objective: "Explain frozen V4 persistence"))
            context.insert(CatalogImportState(catalogID: "v4-catalog", lastImportedVersion: 23))
            context.insert(KontrolSchemaV4.LessonSlot(topicID: "v4-topic", slotIndex: 2,
                                                       lessonID: "v4-lesson",
                                                       assignedAt: Date(timeIntervalSince1970: 1_730_000_000)))
            try context.save()
        }
        try writeAndClose()
    }
}
