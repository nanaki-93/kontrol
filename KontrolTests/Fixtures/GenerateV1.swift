// Standalone fixture writer; compile against the released V1 app source files.
// Not part of either Xcode target. See Fixtures/README.md for the exact command.
import Foundation
import SwiftData

@main
struct GenerateV1 {
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
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(store))
            let context = ModelContext(container)
            context.insert(try TaskItem(
                id: UUID(uuidString: "D07A6D98-65ED-4B59-92B2-DA3CED39F3E5")!,
                title: "V1 reopen fixture", createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
            try context.save()
        }
        try writeAndClose()
        // Do not open the resulting store again here. Copy every file in output,
        // including any sidecars, only after this process exits.
    }
}
