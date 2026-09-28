import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class ScheduleRepositoryTests: XCTestCase {
    private enum Injected: Error { case failed }
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let base = Date(timeIntervalSince1970: 1_767_225_600)

    private func input(_ title: String, _ start: TimeInterval, _ end: TimeInterval,
                       note: String? = nil) -> ScheduleInput {
        ScheduleInput(title: title, startAt: base.addingTimeInterval(start),
                      endAt: base.addingTimeInterval(end), note: note)
    }

    private func repository(_ container: ModelContainer, id: UUID) -> SwiftDataScheduleRepository {
        SwiftDataScheduleRepository(container: container, makeID: { id })
    }

    private func rows(_ container: ModelContainer) throws -> [ScheduleSnapshot] {
        try SwiftDataScheduleRepository(container: container).fetchAll()
    }

    func testCreateNormalizesAndCommitsOnceWithoutPostSaveRead() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = 0
        var reads = 0
        var saves = 0
        let repository = SwiftDataScheduleRepository(container: container,
            makeID: { ids += 1; return self.first },
            fetch: { context in
                reads += 1
                if reads > 1 { throw Injected.failed }
                return try context.fetch(FetchDescriptor<ScheduleBlock>())
            }, save: { context in saves += 1; try context.save() })
        let saved = try repository.create(input: input("  Plan  \n", 0, 3600,
                                                      note: " \n Line one\nLine two  "))
        XCTAssertEqual(saved, ScheduleSnapshot(id: first, title: "Plan", startAt: base,
            endAt: base.addingTimeInterval(3600), note: "Line one\nLine two"))
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container), [saved])
        XCTAssertThrowsError(try repository.fetchAll()) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(try rows(container), [saved])
    }

    func testInvalidInputsNeverAllocateReadOrSave() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = 0
        var reads = 0
        var saves = 0
        let repository = SwiftDataScheduleRepository(container: container,
            makeID: { ids += 1; return self.first },
            fetch: { context in reads += 1; return try context.fetch(FetchDescriptor<ScheduleBlock>()) },
            save: { context in saves += 1; try context.save() })
        for (draft, error) in [
            (input(" \n ", 0, 1), ScheduleValidationError.emptyTitle),
            (input("Bad", 5, 5), .endNotAfterStart),
            (input("Bad", 5, 4), .endNotAfterStart),
            (ScheduleInput(title: "Bad", startAt: Date(timeIntervalSinceReferenceDate: .infinity),
                           endAt: base), .invalidStart),
            (ScheduleInput(title: "Bad", startAt: base,
                           endAt: Date(timeIntervalSinceReferenceDate: .nan)), .invalidEnd)
        ] {
            XCTAssertThrowsError(try repository.create(input: draft)) {
                XCTAssertEqual($0 as? ScheduleRepositoryError, .validation(error))
            }
            XCTAssertThrowsError(try repository.update(id: first, input: draft)) {
                XCTAssertEqual($0 as? ScheduleRepositoryError, .validation(error))
            }
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(try rows(container).isEmpty)
    }

    func testOverlapListsEveryPersistedConflictInOrderAndRejectsBothWrites() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let a = try repository(container, id: first).create(input: input("Early", -3600, 1800))
        let b = try repository(container, id: second).create(input: input("Late", 3600, 7200))
        let original = try rows(container)
        var ids = 0
        var saves = 0
        let guarded = SwiftDataScheduleRepository(container: container,
            makeID: { ids += 1; return self.third },
            save: { context in saves += 1; try context.save() })
        let crossing = input("Cross", 0, 5400)
        let expected = [ScheduleConflict(block: a, duration: 1800),
                        ScheduleConflict(block: b, duration: 1800)]
        XCTAssertThrowsError(try guarded.create(input: crossing, allowOverlap: false)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .overlap(expected))
        }
        XCTAssertThrowsError(try guarded.update(id: first, input: crossing, allowOverlap: false)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError,
                           .overlap([ScheduleConflict(block: b, duration: 1800)]))
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try rows(container), original)
        // Half-open touching is allowed, even when the neighbor starts on another day.
        let touching = try guarded.create(input: input("Touch", 1800, 3600))
        XCTAssertEqual(touching.id, third)
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container).count, 3)
    }

    func testEditMovesStableIdentityAndPreservesMissingLessonMetadataTasksAndPeers() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        seed.insert(ScheduleBlock(id: first, title: "Linked", startAt: base,
                                  endAt: base.addingTimeInterval(3600), note: "Old",
                                  lessonID: "deleted-lesson", linkedTitleSnapshot: "Old lesson"))
        seed.insert(ScheduleBlock(id: second, title: "Peer", startAt: base.addingTimeInterval(7200),
                                  endAt: base.addingTimeInterval(10_800)))
        seed.insert(try TaskItem(id: taskID, title: "Task", createdAt: base))
        try seed.save()
        var ids = 0
        var saves = 0
        let repository = SwiftDataScheduleRepository(container: container,
            makeID: { ids += 1; return self.third },
            save: { context in saves += 1; try context.save() })
        let peer = try XCTUnwrap(rows(container).first { $0.id == second })
        let moved = try repository.update(id: first, input: input("  Moved  ", 10_800, 14_400,
                                                                  note: " \n "))
        XCTAssertEqual(moved, ScheduleSnapshot(id: first, title: "Moved",
            startAt: base.addingTimeInterval(10_800), endAt: base.addingTimeInterval(14_400),
            lessonID: "deleted-lesson", linkedTitleSnapshot: "Old lesson"))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(try rows(container), [peer, moved])
        let taskContext = ModelContext(container)
        let tasks = try taskContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, taskID)
        XCTAssertEqual(tasks.first?.title, "Task")
    }

    func testUpdateReadsCurrentPeersAndNeverFetchesAfterCommit() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let original = try repository(container, id: first).create(input: input("Original", 0, 3600))
        // A second window saves a peer after the first window's draft was opened.
        let peer = try repository(container, id: second).create(input: input("New peer", 7200, 10_800))
        var reads = 0
        var saves = 0
        let editing = SwiftDataScheduleRepository(container: container,
            fetch: { context in
                reads += 1
                if reads > 1 { throw Injected.failed }
                return try context.fetch(FetchDescriptor<ScheduleBlock>())
            }, save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try editing.update(id: first, input: input("Move", 7200, 9000))) {
            XCTAssertEqual($0 as? ScheduleRepositoryError,
                           .overlap([ScheduleConflict(block: peer, duration: 1800)]))
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try rows(container), [original, peer])
        reads = 0
        let moved = try editing.update(id: first, input: input("Move", 10_800, 14_400))
        XCTAssertEqual(moved.id, first)
        XCTAssertEqual(moved.startAt, base.addingTimeInterval(10_800))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container), [peer, moved])
    }

    func testMissingEditNeverRecreatesAndReadFailureNeverAssumesNoConflict() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let saved = try repository(container, id: first).create(input: input("Keep", 0, 3600))
        var saves = 0
        var ids = 0
        let missing = SwiftDataScheduleRepository(container: container,
            makeID: { ids += 1; return self.second },
            save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try missing.update(id: second, input: input("Lost", 3600, 7200))) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(self.second))
        }
        let unreadable = SwiftDataScheduleRepository(container: container,
            makeID: { ids += 1; return self.second },
            fetch: { _ in throw Injected.failed },
            save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try unreadable.create(input: input("Maybe conflict", 0, 3600))) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertThrowsError(try unreadable.update(id: first, input: input("Maybe move", 7200, 10_800))) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try rows(container), [saved])
    }

    func testFailedCreateAndEditDiscardPrivateChangesWithoutTouchingOtherOwner() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let saved = try repository(container, id: first).create(input: input("Saved", 0, 3600))
        let independent = ModelContext(container)
        independent.autosaveEnabled = false
        let pending = try XCTUnwrap(independent.fetch(FetchDescriptor<ScheduleBlock>()).first)
        pending.note = "Another owner draft"
        var saves = 0
        let failing = SwiftDataScheduleRepository(container: container,
            makeID: { self.second }, save: { _ in saves += 1; throw Injected.failed })
        XCTAssertThrowsError(try failing.create(input: input("Failed", 3600, 7200))) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertThrowsError(try failing.update(id: first, input: input("Failed edit", 7200, 10_800))) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(saves, 2)
        XCTAssertTrue(independent.hasChanges)
        XCTAssertEqual(pending.title, "Saved")
        XCTAssertEqual(pending.note, "Another owner draft")
        XCTAssertEqual(try rows(container), [saved])
        try independent.save()
        XCTAssertEqual(try rows(container).first?.note, "Another owner draft")
        XCTAssertEqual(try rows(container).count, 1)
    }
}
