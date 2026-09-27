import Foundation
import SwiftData
import XCTest
@testable import Kontrol

final class ContainerFactoryTests: XCTestCase {
    private let factory = ModelContainerFactory()

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolContainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func taskIDs(in container: ModelContainer) throws -> [UUID] {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map(\.id)
    }

    func testInMemoryContainersAreIndependent() throws {
        let first = try factory.makeContainer(mode: .inMemory)
        let second = try factory.makeContainer(mode: .inMemory)
        let id = UUID()
        let context = ModelContext(first)
        context.insert(try TaskItem(id: id, title: "Only in memory", createdAt: Date()))
        try context.save()
        XCTAssertEqual(try taskIDs(in: first), [id])
        XCTAssertTrue(try taskIDs(in: second).isEmpty)
    }

    func testClosedDiskStoreReopensAtSameLocationButNotOtherDiskOrMemory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first/Kontrol.store")
        let otherURL = directory.appendingPathComponent("other/Kontrol.store")
        let id = UUID()

        // Scope both owners before reopening: no context or container from the
        // writing session may serve the read after this function returns.
        func writeAndClose() throws {
            let container = try factory.makeContainer(mode: .persistent(firstURL))
            let context = ModelContext(container)
            context.insert(try TaskItem(id: id, title: "Persisted", createdAt: Date()))
            try context.save()
        }
        try writeAndClose()

        func reopenAndCheck() throws {
            let reopened = try factory.makeContainer(mode: .persistent(firstURL))
            let records = try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>())
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.id, id)
            XCTAssertEqual(records.first?.title, "Persisted")
        }
        try reopenAndCheck()
        let other = try factory.makeContainer(mode: .persistent(otherURL))
        XCTAssertTrue(try taskIDs(in: other).isEmpty)
        let memory = try factory.makeContainer(mode: .inMemory)
        XCTAssertTrue(try taskIDs(in: memory).isEmpty)
    }

    func testOpenErrorPropagatesWithoutReplacingExistingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("Kontrol.store")
        let original = Data("not a SQLite database; preserve these bytes".utf8)
        try original.write(to: store)

        XCTAssertThrowsError(try factory.makeContainer(mode: .persistent(store)))
        XCTAssertEqual(try Data(contentsOf: store), original)
        // A bad disk store must not be replaced with a fresh empty database.
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.path)[.size] as? Int,
                       original.count)
    }

    func testProductionLocationIsStableAndAppSpecificWithoutOpeningStore() throws {
        let first = try StoreLocation.productionStoreURL()
        XCTAssertEqual(first, try StoreLocation.productionStoreURL())
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask, appropriateFor: nil,
                                                   create: false)
        XCTAssertEqual(first.deletingLastPathComponent().deletingLastPathComponent(), support)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Kontrol")
        XCTAssertEqual(first.lastPathComponent, "Kontrol.store")
    }
}
