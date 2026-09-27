import Foundation
import SwiftData
import XCTest
@testable import Kontrol

final class V1FixtureTests: XCTestCase {
    // These values are deliberately fixed: changing this test does not rewrite the
    // checked-in database. A future schema must reopen this V1 artifact unchanged.
    private static let fixtureID = UUID(uuidString: "D07A6D98-65ED-4B59-92B2-DA3CED39F3E5")!
    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let title = "V1 reopen fixture"
    private let factory = ModelContainerFactory()

    private func storeFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func assertFixtureRecord(at storeURL: URL) throws {
        // The same factory and migration plan used for production opens this copy.
        let container = try factory.makeContainer(mode: .persistent(storeURL))
        let context = ModelContext(container)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, Self.fixtureID)
        XCTAssertEqual(tasks.first?.title, Self.title)
        XCTAssertEqual(tasks.first?.createdAt, Self.createdAt)
        XCTAssertNil(tasks.first?.completedAt)
    }

    func testCopiedFrozenV1StoreReopensWithoutTouchingFixture() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "V1", withExtension: nil))
        let originalFiles = try storeFiles(in: fixture)
        XCTAssertTrue(originalFiles.contains { $0.lastPathComponent == "Kontrol.store" })
        let originalBytes = try Dictionary(uniqueKeysWithValues: originalFiles.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolV1Reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        // Copy the complete closed SQLite file set; a WAL/SHM or other sidecar
        // belongs with its database. Never open the bundle's read-only source.
        for file in originalFiles {
            try FileManager.default.copyItem(at: file, to: work.appendingPathComponent(file.lastPathComponent))
        }

        // Each call releases its ModelContext and ModelContainer before the next
        // open. This tests a real disk reopen, not a fetch against a live context.
        try assertFixtureRecord(at: work.appendingPathComponent("Kontrol.store"))
        try assertFixtureRecord(at: work.appendingPathComponent("Kontrol.store"))

        let afterFiles = try storeFiles(in: fixture)
        XCTAssertEqual(afterFiles.map(\.lastPathComponent), originalFiles.map(\.lastPathComponent))
        for file in afterFiles {
            XCTAssertEqual(try Data(contentsOf: file), originalBytes[file.lastPathComponent],
                           "Test must not mutate bundled fixture: \(file.lastPathComponent)")
        }
    }
}
