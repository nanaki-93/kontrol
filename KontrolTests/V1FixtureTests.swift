import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
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

    private func withCopiedFixture(_ body: (URL) throws -> Void) throws {
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

        try body(work.appendingPathComponent("Kontrol.store"))

        let afterFiles = try storeFiles(in: fixture)
        XCTAssertEqual(afterFiles.map(\.lastPathComponent), originalFiles.map(\.lastPathComponent))
        for file in afterFiles {
            XCTAssertEqual(try Data(contentsOf: file), originalBytes[file.lastPathComponent],
                           "Test must not mutate bundled fixture: \(file.lastPathComponent)")
        }
    }

    func testCopiedFrozenV1StoreReopensWithoutTouchingFixture() throws {
        try withCopiedFixture { storeURL in
            // Each call releases its ModelContext and ModelContainer before the
            // next open. This is not a fetch against a live context.
            try assertFixtureRecord(at: storeURL)
            try assertFixtureRecord(at: storeURL)
        }
    }

    func testCopiedFrozenV1StoreAcceptsTaskMutationsAcrossDistinctOpens() throws {
        let editedDue = Date(timeIntervalSince1970: 1_800_000_000)
        let completion = Date(timeIntervalSince1970: 1_800_003_600)
        let plan = PlannedDay(components: .init(calendarIdentifier: "gregorian",
                                                 year: 2027, month: 1, day: 15),
                              timeZoneID: "Pacific/Auckland")
        let secondID = UUID()

        try withCopiedFixture { storeURL in
            @MainActor
            func withDistinctOpen(_ body: (SwiftDataTaskRepository) throws -> Void) throws {
                // No repository, context, model, snapshot, or container from a
                // previous open escapes this scope. SwiftData may retain its own
                // internal SQLite owners after the explicit owners are released.
                try autoreleasepool {
                    let container = try factory.makeContainer(mode: .persistent(storeURL))
                    let repository = SwiftDataTaskRepository(container: container,
                        now: { completion }, makeID: { secondID })
                    try body(repository)
                }
            }

            @MainActor
            func assertHistorical(_ repository: SwiftDataTaskRepository,
                                  completedAt: Date?, secondExists: Bool = false) throws {
                let rows = try repository.fetchAll().map(TaskSnapshot.init)
                XCTAssertEqual(rows.count, secondExists ? 2 : 1,
                               "The V1 row must survive second-task creation and deletion")
                let historical = try XCTUnwrap(rows.first { $0.id == Self.fixtureID })
                XCTAssertEqual(historical.id, Self.fixtureID)
                XCTAssertEqual(historical.title, "Edited V1 task")
                XCTAssertEqual(historical.notes, "Historical\nnotes")
                XCTAssertEqual(historical.dueAt, editedDue)
                XCTAssertEqual(historical.plannedDay, plan.components)
                XCTAssertEqual(historical.plannedTimeZoneID, plan.timeZoneID)
                XCTAssertEqual(historical.createdAt, Self.createdAt)
                XCTAssertEqual(historical.completedAt, completedAt)
                if secondExists {
                    let second = try XCTUnwrap(rows.first { $0.id == secondID })
                    XCTAssertEqual(second.title, "Temporary task")
                    XCTAssertEqual(second.createdAt, completion)
                } else {
                    XCTAssertFalse(rows.contains { $0.id == secondID })
                }
            }

            try withDistinctOpen { repository in
                let original = try repository.fetchAll().map(TaskSnapshot.init)
                XCTAssertEqual(original.count, 1)
                XCTAssertEqual(original.first?.id, Self.fixtureID)
                XCTAssertEqual(original.first?.title, Self.title)
                XCTAssertEqual(original.first?.createdAt, Self.createdAt)
                XCTAssertNil(original.first?.completedAt)
                let edited = try repository.update(id: Self.fixtureID,
                    input: TaskInput(title: "  Edited V1 task  ", notes: "Historical\nnotes",
                                     dueAt: editedDue, plannedFor: plan))
                XCTAssertEqual(edited.id, Self.fixtureID)
                XCTAssertEqual(edited.createdAt, Self.createdAt)
                XCTAssertNil(edited.completedAt)
                let completed = try repository.setCompleted(id: Self.fixtureID, completed: true)
                XCTAssertEqual(completed.completedAt, completion)
            }
            try withDistinctOpen { repository in
                try assertHistorical(repository, completedAt: completion)
                let second = try repository.create(input: TaskInput(title: "Temporary task"))
                XCTAssertEqual(second.id, secondID)
                XCTAssertEqual(try repository.fetchAll().count, 2)
            }
            try withDistinctOpen { repository in
                try assertHistorical(repository, completedAt: completion, secondExists: true)
                try repository.delete(id: secondID)
            }
            try withDistinctOpen { repository in
                try assertHistorical(repository, completedAt: completion)
                let reopened = try repository.setCompleted(id: Self.fixtureID, completed: false)
                XCTAssertEqual(reopened.id, Self.fixtureID)
                XCTAssertEqual(reopened.createdAt, Self.createdAt)
                XCTAssertNil(reopened.completedAt)
            }
            try withDistinctOpen { repository in
                try assertHistorical(repository, completedAt: nil)
            }
        }
    }
}
