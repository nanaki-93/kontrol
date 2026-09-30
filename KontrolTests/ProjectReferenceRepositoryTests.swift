import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class ProjectReferenceRepositoryTests: XCTestCase {
    private func store() throws -> (ModelContainer, URL) {
        let directory = temporaryStoreDirectory()
        let url = directory.appendingPathComponent("Kontrol.store")
        return (try ModelContainerFactory().makeContainer(mode: .persistent(url)), directory)
    }

    private func input(_ id: UUID = UUID(), order: Int = 0,
                       bookmark: Data = Data([1])) -> NewProjectReference {
        NewProjectReference(id: id, manifestID: "same-manifest", bookmarkData: bookmark,
                            displayOrder: order, displayNameHint: "Local project")
    }

    func testTwoReferencesReopenWithDetachedOrderedReceipts() throws {
        let (container, directory) = try store()
        let url = directory.appendingPathComponent("Kontrol.store")
        let firstID = UUID(), secondID = UUID()
        try autoreleasepool {
            let repository = SwiftDataProjectReferenceRepository(container: container)
            let second = try repository.insert(input(secondID, order: 2, bookmark: Data([1])))
            let first = try repository.insert(input(firstID, order: 0, bookmark: Data([1])))
            XCTAssertEqual(first.id, firstID)
            XCTAssertEqual(second.id, secondID)
            XCTAssertNotEqual(first.revision, second.revision)
            // Identical bookmark bytes are not a repository-level duplicate decision.
            XCTAssertEqual(try repository.fetchAll().map(\.id), [firstID, secondID])
        }
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
        let rows = try SwiftDataProjectReferenceRepository(container: reopened).fetchAll()
        XCTAssertEqual(rows.map(\.id), [firstID, secondID])
        XCTAssertEqual(rows.map(\.manifestID), ["same-manifest", "same-manifest"])
        XCTAssertEqual(rows.map(\.bookmarkData), [Data([1]), Data([1])])
    }

    func testReconnectAndSuccessfulReadRequireCurrentRevisionAndPreserveIdentity() throws {
        let (container, directory) = try store()
        let repository = SwiftDataProjectReferenceRepository(container: container)
        let original = try repository.insert(input(order: 7))
        XCTAssertThrowsError(try repository.reconnect(id: original.id, expectedRevision: original.revision,
            input: ReconnectedProjectReference(manifestID: "other", bookmarkData: Data([2]),
                                               displayNameHint: "Other"))) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .manifestMismatch)
        }
        XCTAssertEqual(try repository.fetchAll(), [original])
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)
        let read = try repository.recordSuccessfulRead(id: original.id, expectedRevision: original.revision,
                                                       nameHint: "Updated name", readAt: readAt)
        XCTAssertEqual(read.lastSuccessfulReadAt, readAt)
        XCTAssertEqual(read.bookmarkData, original.bookmarkData)
        XCTAssertNotEqual(read.revision, original.revision)
        XCTAssertThrowsError(try repository.reconnect(id: original.id, expectedRevision: original.revision,
            input: ReconnectedProjectReference(manifestID: original.manifestID,
                                               bookmarkData: Data([2]), displayNameHint: "New"))) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .staleRevision)
        }
        XCTAssertThrowsError(try repository.recordSuccessfulRead(id: original.id,
            expectedRevision: original.revision, nameHint: "Stale", readAt: Date())) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .staleRevision)
        }
        XCTAssertEqual(try repository.fetchAll(), [read])
        let reconnected = try repository.reconnect(id: read.id, expectedRevision: read.revision,
            input: ReconnectedProjectReference(manifestID: read.manifestID,
                                               bookmarkData: Data([2]), displayNameHint: "Moved"))
        XCTAssertEqual(reconnected.id, original.id)
        XCTAssertEqual(reconnected.displayOrder, 7)
        XCTAssertEqual(reconnected.manifestID, original.manifestID)
        XCTAssertEqual(reconnected.bookmarkData, Data([2]))
        XCTAssertNil(reconnected.lastSuccessfulReadAt)
        XCTAssertNotEqual(reconnected.revision, read.revision)
        XCTAssertEqual(try repository.fetchAll(), [reconnected])
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll(), [reconnected])
        XCTAssertThrowsError(try repository.reconnect(id: read.id, expectedRevision: read.revision,
            input: ReconnectedProjectReference(manifestID: read.manifestID,
                                               bookmarkData: Data([4]), displayNameHint: "Late"))) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .staleRevision)
        }
        XCTAssertEqual(try repository.fetchAll(), [reconnected])
    }

    func testInjectedSaveFailuresDoNotPublishOrChangeDurableRowsOrOtherContexts() throws {
        enum SaveFailure: Error { case injected }
        let (container, directory) = try store()
        let working = SwiftDataProjectReferenceRepository(container: container)
        let inserted = try working.insert(input())
        let original = try working.recordSuccessfulRead(id: inserted.id,
            expectedRevision: inserted.revision, nameHint: "Previously verified",
            readAt: Date(timeIntervalSince1970: 1_700_000_000))
        let otherContext = ModelContext(container)
        otherContext.autosaveEnabled = false
        let failing = SwiftDataProjectReferenceRepository(container: container, beforeSave: { throw SaveFailure.injected })
        XCTAssertThrowsError(try failing.insert(input(order: 1)))
        XCTAssertThrowsError(try failing.reconnect(id: original.id, expectedRevision: original.revision,
            input: ReconnectedProjectReference(manifestID: original.manifestID,
                                               bookmarkData: Data([3]), displayNameHint: "Replacement"))) {
            XCTAssertTrue($0 is SaveFailure)
        }
        XCTAssertThrowsError(try failing.recordSuccessfulRead(id: original.id,
            expectedRevision: original.revision, nameHint: "Not saved", readAt: Date()))
        XCTAssertEqual(try working.fetchAll(), [original])
        let task = try TaskItem(id: UUID(), title: "Other context remains independent", createdAt: Date())
        otherContext.insert(task)
        try otherContext.save()
        XCTAssertEqual(try working.fetchAll(), [original])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count, 1)
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(
            directory.appendingPathComponent("Kontrol.store")))
        XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll(), [original])
        XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>()).count, 1)
    }

    private func temporaryStoreDirectory() -> URL {
        // Core Data worker-owned SQLite handles can outlive autoreleasepool.
        // Keep all repository fixtures until host exit, like preferences fixtures.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolProjectRemovalTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        print("Project removal test store cleanup after host exit: \(root.path)")
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func withDiskStore(_ body: (URL) throws -> Void) throws {
        try body(temporaryStoreDirectory().appendingPathComponent("Kontrol.store"))
    }

    func testMatchingRemovalWithUnresolvableBookmarkPreservesSurvivorsAndReopens() throws {
        try withDiskStore { url in
            let survivors = try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let repository = SwiftDataProjectReferenceRepository(container: container)
                let first = try repository.insert(input(order: 0))
                // These are opaque, malformed bookmark bytes, not a usable folder grant.
                // A removal must succeed without resolving, inspecting, or writing a folder.
                let removed = try repository.insert(input(order: 1, bookmark: Data("not a bookmark".utf8)))
                let last = try repository.insert(input(order: 2))
                let task = try TaskItem(id: UUID(), title: "Unrelated data", createdAt: Date())
                let context = ModelContext(container)
                context.autosaveEnabled = false
                context.insert(task)
                try context.save()
                var saves = 0
                let subject = SwiftDataProjectReferenceRepository(container: container, beforeSave: { saves += 1 })
                try subject.remove(id: removed.id, expectedRevision: removed.revision)
                XCTAssertEqual(saves, 1)
                XCTAssertEqual(try repository.fetchAll(), [first, last])
                XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).map(\.title), ["Unrelated data"])
                XCTAssertThrowsError(try subject.remove(id: removed.id, expectedRevision: removed.revision)) {
                    XCTAssertEqual($0 as? ProjectReferencePersistenceError, .notFound)
                }
                XCTAssertEqual(saves, 1)
                return [first, last]
            }
            try autoreleasepool {
                let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll(), survivors)
                XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>()).map(\.title),
                               ["Unrelated data"])
            }
        }
    }

    func testStaleRemovalAfterReadAndReconnectRetainsCurrentReferenceOnDisk() throws {
        try withDiskStore { url in
            let current = try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let repository = SwiftDataProjectReferenceRepository(container: container)
                let original = try repository.insert(input())
                var saves = 0
                let subject = SwiftDataProjectReferenceRepository(container: container, beforeSave: { saves += 1 })
                let read = try repository.recordSuccessfulRead(id: original.id, expectedRevision: original.revision,
                    nameHint: "New name", readAt: Date(timeIntervalSince1970: 1_700_000_000))
                XCTAssertThrowsError(try subject.remove(id: original.id, expectedRevision: original.revision)) {
                    XCTAssertEqual($0 as? ProjectReferencePersistenceError, .staleRevision)
                }
                XCTAssertEqual(try subject.fetchAll(), [read])
                let reconnected = try repository.reconnect(id: read.id, expectedRevision: read.revision,
                    input: ReconnectedProjectReference(manifestID: read.manifestID,
                        bookmarkData: Data([9]), displayNameHint: "Replacement grant"))
                XCTAssertThrowsError(try subject.remove(id: read.id, expectedRevision: read.revision)) {
                    XCTAssertEqual($0 as? ProjectReferencePersistenceError, .staleRevision)
                }
                XCTAssertEqual(saves, 0)
                XCTAssertEqual(try subject.fetchAll(), [reconnected])
                return reconnected
            }
            try autoreleasepool {
                let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll(), [current])
            }
        }
    }

    func testMissingRemovalDoesNotDeleteAnotherIdentityWithMatchingRevision() throws {
        try withDiskStore { url in
            let original = try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let repository = SwiftDataProjectReferenceRepository(container: container)
                let original = try repository.insert(input())
                var saves = 0
                let subject = SwiftDataProjectReferenceRepository(container: container, beforeSave: { saves += 1 })
                XCTAssertThrowsError(try subject.remove(id: UUID(), expectedRevision: original.revision)) {
                    XCTAssertEqual($0 as? ProjectReferencePersistenceError, .notFound)
                }
                XCTAssertEqual(saves, 0)
                XCTAssertEqual(try subject.fetchAll(), [original])
                return original
            }
            try autoreleasepool {
                let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll(), [original])
            }
        }
    }

    func testFailedRemovalRetainsRowsAndUnsavedOtherContextThenAllowsExplicitRetry() throws {
        enum SaveFailure: Error { case injected }
        try withDiskStore { url in
            let originals = try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let repository = SwiftDataProjectReferenceRepository(container: container)
                let target = try repository.insert(input())
                let survivor = try repository.insert(input(order: 1))
                let otherContext = ModelContext(container)
                otherContext.autosaveEnabled = false
                let task = try TaskItem(id: UUID(), title: "Pending other context", createdAt: Date())
                otherContext.insert(task)
                var saves = 0
                let subject = SwiftDataProjectReferenceRepository(container: container, beforeSave: {
                    saves += 1
                    throw SaveFailure.injected
                })
                XCTAssertThrowsError(try subject.remove(id: target.id, expectedRevision: target.revision)) {
                    XCTAssertTrue($0 is SaveFailure)
                }
                XCTAssertEqual(saves, 1)
                XCTAssertEqual(try subject.fetchAll(), [target, survivor])
                XCTAssertTrue(otherContext.hasChanges)
                XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
                try otherContext.save()
                XCTAssertEqual(try repository.fetchAll(), [target, survivor])
                return [target, survivor]
            }
            try autoreleasepool {
                let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let repository = SwiftDataProjectReferenceRepository(container: reopened)
                XCTAssertEqual(try repository.fetchAll(), originals)
                XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>()).map(\.title),
                               ["Pending other context"])
                try repository.remove(id: originals[0].id, expectedRevision: originals[0].revision)
                XCTAssertEqual(try repository.fetchAll(), [originals[1]])
            }
            try autoreleasepool {
                let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll(), [originals[1]])
            }
        }
    }

    func testCorruptExistingRowBlocksFetchAndTransactions() throws {
        let (container, _) = try store()
        let context = ModelContext(container)
        context.insert(ProjectReference(manifestID: "", bookmarkData: Data([1]),
                                        displayOrder: 0, displayNameHint: "Invalid"))
        try context.save()
        let repository = SwiftDataProjectReferenceRepository(container: container)
        XCTAssertThrowsError(try repository.fetchAll()) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .invalidReference)
        }
        XCTAssertThrowsError(try repository.insert(input())) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .invalidReference)
        }
    }

    func testInvalidAndMissingRowsAreRejectedBeforeSave() throws {
        let (container, _) = try store()
        let repository = SwiftDataProjectReferenceRepository(container: container)
        XCTAssertThrowsError(try repository.insert(input(order: -1))) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .invalidReference)
        }
        XCTAssertThrowsError(try repository.insert(input(bookmark: Data()))) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .invalidReference)
        }
        let original = try repository.insert(input())
        XCTAssertThrowsError(try repository.insert(input(original.id))) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .duplicateID)
        }
        XCTAssertThrowsError(try repository.recordSuccessfulRead(id: UUID(), expectedRevision: UUID(),
                                                                   nameHint: "Missing", readAt: Date())) {
            XCTAssertEqual($0 as? ProjectReferencePersistenceError, .notFound)
        }
        XCTAssertEqual(try repository.fetchAll(), [original])
    }
}
