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

    private func seedLesson(_ container: ModelContainer, id: String = "lesson-1",
                            title: String = "Original lesson") throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(LessonDefinition(
            id: id, objectiveKey: "objective", title: title, topicID: "go",
            subtopicID: "go-basics", conceptIDs: [], difficulty: "beginner",
            format: "learn", estimatedMinutes: 20, explanation: "Explanation",
            workedExample: "Example", exercise: "Exercise", referenceAnswer: "Answer",
            selfCheckCriteria: ["Check"], contentVersion: 1,
            normalizedContentHash: "hash", source: "bundle", provenance: "Test"))
        try context.save()
    }

    private func repository(_ container: ModelContainer, id: UUID) -> SwiftDataScheduleRepository {
        SwiftDataScheduleRepository(container: container, makeID: { id })
    }

    private func rows(_ container: ModelContainer) throws -> [ScheduleSnapshot] {
        try SwiftDataScheduleRepository(container: container).fetchAll()
    }

    private func warning(_ action: () throws -> ScheduleSnapshot) throws -> ScheduleOverlapReview {
        do {
            _ = try action()
            XCTFail("Expected an overlap decision")
            throw Injected.failed
        } catch let ScheduleRepositoryError.overlap(review) {
            return review
        }
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

    func testLinkedCreateResolvesDefinitionAndCapturesTitleWithoutChangingLesson() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        try seedLesson(container)
        let writer = repository(container, id: first)
        let linked = try writer.create(input: ScheduleInput(title: "  Study  ", startAt: base,
            endAt: base.addingTimeInterval(3600), lessonID: "lesson-1"))
        XCTAssertEqual(linked.lessonID, "lesson-1")
        XCTAssertEqual(linked.linkedTitleSnapshot, "Original lesson")
        XCTAssertEqual(linked.title, "Study")
        XCTAssertEqual(try rows(container), [linked])
        let context = ModelContext(container)
        let definitions = try context.fetch(FetchDescriptor<LessonDefinition>())
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(definitions.first?.title, "Original lesson")
        XCTAssertTrue(try context.fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        let progress = LessonProgress(lessonID: "lesson-1", status: .completed)
        context.insert(progress)
        try context.save()
        XCTAssertEqual(try rows(container), [linked], "completion cannot move or unlink a block")
        progress.status = .dismissed
        try context.save()
        XCTAssertEqual(try rows(container), [linked], "dismissal cannot move or unlink a block")
        // A changed or removed definition does not alter the captured block.
        let definition = try XCTUnwrap(definitions.first)
        definition.title = "Revised lesson"
        try context.save()
        XCTAssertEqual(try rows(container), [linked])
        context.delete(definition)
        try context.save()
        XCTAssertEqual(try rows(container), [linked])
        let edited = try writer.update(id: first, input: ScheduleInput(
            title: "Moved", startAt: base.addingTimeInterval(3600),
            endAt: base.addingTimeInterval(7200), lessonID: "nonexistent-edit-link"))
        XCTAssertEqual(edited.lessonID, linked.lessonID)
        XCTAssertEqual(edited.linkedTitleSnapshot, linked.linkedTitleSnapshot)
        XCTAssertEqual(edited.startAt, base.addingTimeInterval(3600))
    }

    func testMissingUnreadableAndFailedLinkedWritesNeverCreateUnlinkedBlock() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let linked = ScheduleInput(title: "Study", startAt: base,
            endAt: base.addingTimeInterval(3600), lessonID: "lesson-1")
        var saves = 0
        let writer = SwiftDataScheduleRepository(container: container, makeID: { self.first },
            save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try writer.create(input: linked)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .lessonNotFound("lesson-1"))
        }
        try seedLesson(container, title: "  ")
        XCTAssertThrowsError(try writer.create(input: linked)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .lessonUnreadable("lesson-1"))
        }
        let context = ModelContext(container)
        try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first).title = "Ready"
        try context.save()
        let unreadable = SwiftDataScheduleRepository(container: container,
            fetchLessons: { _ in throw Injected.failed })
        XCTAssertThrowsError(try unreadable.create(input: linked)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .lessonUnreadable("lesson-1"))
        }
        let failing = SwiftDataScheduleRepository(container: container, makeID: { self.first },
            save: { _ in throw Injected.failed })
        XCTAssertThrowsError(try failing.create(input: linked)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(try rows(container).isEmpty)
        XCTAssertEqual(try writer.create(input: linked).linkedTitleSnapshot, "Ready")
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container).count, 1)
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
        XCTAssertEqual(try warning { try guarded.create(input: crossing) }.conflicts, expected)
        XCTAssertEqual(try warning { try guarded.update(id: first, input: crossing) }.conflicts,
                       [ScheduleConflict(block: b, duration: 1800)])
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
        XCTAssertEqual(try warning { try editing.update(id: first, input: input("Move", 7200, 9000)) }
                       .conflicts, [ScheduleConflict(block: peer, duration: 1800)])
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

    func testKeepBothRequiresMatchingDraftAndSingleUseReceiptForCreate() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let peer = try repository(container, id: first).create(input: input("Peer", 0, 3600))
        var ids = 0
        var saves = 0
        let writer = SwiftDataScheduleRepository(container: container,
            makeID: { ids += 1; return self.second },
            save: { context in saves += 1; try context.save() })
        let draft = input("New", 1800, 5400, note: "Original")
        let expected = [ScheduleConflict(block: peer, duration: 1800)]
        XCTAssertEqual(try warning { try writer.create(input: draft, allowOverlap: true) }.conflicts,
                       expected)
        let review = try warning { try writer.create(input: draft) }
        XCTAssertEqual(review.conflicts, expected)
        // Every editable field is part of the receipt, even if normalization would
        // result in the same persisted value.
        for changed in [input("New ", 1800, 5400, note: "Original"),
                        input("Other", 1800, 5400, note: "Original"),
                        input("New", 1801, 5400, note: "Original"),
                        input("New", 1800, 5399, note: "Original"),
                        input("New", 1800, 5400, note: "Changed")] {
            XCTAssertEqual(try warning {
                try writer.create(input: changed, allowOverlap: true, review: review)
            }.conflicts.count, 1)
            XCTAssertEqual(try rows(container), [peer])
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        // A rejected draft invalidates its old receipt; request a fresh warning.
        XCTAssertEqual(try warning {
            try writer.create(input: draft, allowOverlap: true, review: review)
        }.conflicts, expected)
        let fresh = try warning { try writer.create(input: draft) }
        let saved = try writer.create(input: draft, allowOverlap: true, review: fresh)
        XCTAssertEqual(saved.id, second)
        XCTAssertEqual(try rows(container), [peer, saved])
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try warning {
            try writer.create(input: draft, allowOverlap: true, review: fresh)
        }.conflicts.count, 2)
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container), [peer, saved])
    }

    func testChangingLessonInvalidatesKeepBothAndFailedResolutionRetainsPeers() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        try seedLesson(container)
        try seedLesson(container, id: "lesson-2", title: "Second lesson")
        let peer = try repository(container, id: first).create(input: input("Peer", 0, 3600))
        let writer = repository(container, id: second)
        func linked(_ id: String) -> ScheduleInput {
            ScheduleInput(title: "Study", startAt: base.addingTimeInterval(1800),
                          endAt: base.addingTimeInterval(5400), lessonID: id)
        }
        let old = try warning { try writer.create(input: linked("lesson-1")) }
        XCTAssertEqual(try warning {
            try writer.create(input: linked("lesson-2"), allowOverlap: true, review: old)
        }.conflicts.count, 1)
        XCTAssertEqual(try rows(container), [peer])
        XCTAssertThrowsError(try writer.create(input: linked("missing"), allowOverlap: true,
                                                review: old)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .lessonNotFound("missing"))
        }
        XCTAssertEqual(try rows(container), [peer])
        let fresh = try warning { try writer.create(input: linked("lesson-2")) }
        let saved = try writer.create(input: linked("lesson-2"), allowOverlap: true, review: fresh)
        XCTAssertEqual(saved.lessonID, "lesson-2")
        XCTAssertEqual(saved.linkedTitleSnapshot, "Second lesson")
        XCTAssertEqual(try rows(container), [peer, saved])
    }

    func testKeepBothRechecksChangedRemovedAndAddedPeersIncludingMetadata() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let a = try repository(container, id: first).create(input: input("A", 0, 1800))
        let b = try repository(container, id: second).create(input: input("B", 3600, 5400))
        let draft = input("Cross", 900, 4500)
        let writer = repository(container, id: third)
        let initial = try warning { try writer.create(input: draft) }
        XCTAssertEqual(initial.conflicts, [ScheduleConflict(block: a, duration: 900),
                                           ScheduleConflict(block: b, duration: 900)])
        let mutation = ModelContext(container)
        mutation.autosaveEnabled = false
        let models = try mutation.fetch(FetchDescriptor<ScheduleBlock>())
        let changed = try XCTUnwrap(models.first { $0.id == first })
        changed.linkedTitleSnapshot = "Changed link"
        try mutation.save()
        let changedReview = try warning {
            try writer.create(input: draft, allowOverlap: true, review: initial)
        }
        XCTAssertEqual(changedReview.conflicts.count, 2)
        XCTAssertEqual(changedReview.conflicts[0].block.linkedTitleSnapshot, "Changed link")
        XCTAssertEqual(changedReview.conflicts[1].block, b)
        mutation.delete(try XCTUnwrap(models.first { $0.id == second }))
        try mutation.save()
        let removedReview = try warning {
            try writer.create(input: draft, allowOverlap: true, review: changedReview)
        }
        XCTAssertEqual(removedReview.conflicts.count, 1)
        let added = ModelContext(container)
        added.autosaveEnabled = false
        let fourth = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        added.insert(ScheduleBlock(id: fourth, title: "Added", startAt: base.addingTimeInterval(2000),
                                   endAt: base.addingTimeInterval(3000)))
        try added.save()
        let addedReview = try warning {
            try writer.create(input: draft, allowOverlap: true, review: removedReview)
        }
        XCTAssertEqual(addedReview.conflicts.map(\.block.title), ["A", "Added"])
        added.insert(ScheduleBlock(id: second, title: "Replacement", startAt: base.addingTimeInterval(4000),
                                   endAt: base.addingTimeInterval(5000)))
        try added.save()
        let replacementReview = try warning {
            try writer.create(input: draft, allowOverlap: true, review: addedReview)
        }
        XCTAssertEqual(replacementReview.conflicts.map(\.block.title), ["A", "Added", "Replacement"])
        let before = try rows(container)
        let saved = try writer.create(input: draft, allowOverlap: true, review: replacementReview)
        XCTAssertEqual(saved.id, third)
        XCTAssertEqual(try rows(container), (before + [saved]).sorted { $0.startAt < $1.startAt })
    }

    func testEditConfirmationExcludesSelfPreservesPeersAndRejectsWrongTarget() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let original = try repository(container, id: first).create(input: input("Original", 0, 3600))
        let peer = try repository(container, id: second).create(input: input("Peer", 3600, 7200))
        let draft = input("Moved", 5400, 9000)
        let writer = repository(container, id: third)
        let review = try warning { try writer.update(id: first, input: draft) }
        XCTAssertEqual(review.conflicts, [ScheduleConflict(block: peer, duration: 1800)])
        XCTAssertTrue(try warning {
            try writer.update(id: second, input: draft, allowOverlap: true, review: review)
        }.conflicts.isEmpty)
        XCTAssertEqual(try rows(container), [original, peer])
        let fresh = try warning { try writer.update(id: first, input: draft) }
        let moved = try writer.update(id: first, input: draft, allowOverlap: true, review: fresh)
        XCTAssertEqual(moved.id, first)
        XCTAssertEqual(try rows(container), [peer, moved])
        XCTAssertEqual(try warning {
            try writer.update(id: first, input: draft, allowOverlap: true, review: fresh)
        }.conflicts, [ScheduleConflict(block: peer, duration: 1800)])
        XCTAssertEqual(try rows(container), [peer, moved])
    }

    func testFailedConfirmedSaveRetainsReceiptForExplicitRetry() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let peer = try repository(container, id: first).create(input: input("Peer", 0, 3600))
        let draft = input("Confirmed", 1800, 5400)
        var saves = 0
        let writer = SwiftDataScheduleRepository(container: container, makeID: { self.second },
            save: { context in
                saves += 1
                if saves == 1 { throw Injected.failed }
                try context.save()
            })
        let review = try warning { try writer.create(input: draft) }
        XCTAssertThrowsError(try writer.create(input: draft, allowOverlap: true, review: review)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(try rows(container), [peer])
        let saved = try writer.create(input: draft, allowOverlap: true, review: review)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(try rows(container), [peer, saved])
        XCTAssertEqual(try warning {
            try writer.create(input: draft, allowOverlap: true, review: review)
        }.conflicts.count, 2)
    }

    func testEditReceiptRejectsMissingTargetAndFailedSaveAllowsRetry() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let peer = try repository(container, id: first).create(input: input("Peer", 0, 3600))
        let target = try repository(container, id: second).create(input: input("Target", 3600, 7200))
        let draft = input("Move", 1800, 5400)
        var saves = 0
        let writer = SwiftDataScheduleRepository(container: container,
            save: { context in
                saves += 1
                if saves == 1 { throw Injected.failed }
                try context.save()
            })
        let review = try warning { try writer.update(id: second, input: draft) }
        XCTAssertEqual(review.conflicts, [ScheduleConflict(block: peer, duration: 1800)])
        XCTAssertThrowsError(try writer.update(id: second, input: draft, allowOverlap: true,
                                               review: review)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(try rows(container), [peer, target])
        let moved = try writer.update(id: second, input: draft, allowOverlap: true, review: review)
        XCTAssertEqual(moved.id, second)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(try rows(container), [peer, moved])

        let deletion = ModelContext(container)
        deletion.autosaveEnabled = false
        deletion.delete(try XCTUnwrap(deletion.fetch(FetchDescriptor<ScheduleBlock>())
            .first { $0.id == second }))
        try deletion.save()
        XCTAssertThrowsError(try writer.update(id: second, input: draft, allowOverlap: true,
                                               review: review)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(self.second))
        }
        XCTAssertEqual(try rows(container), [peer])
    }

    func testDeleteIsSelectiveAndMissingOrFailedOperationsLeaveNoPartialWrite() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let kept = try repository(container, id: first).create(input: input("Keep", 0, 3600))
        let target = try repository(container, id: second).create(input: input("Delete", 3600, 7200))
        let independent = ModelContext(container)
        independent.autosaveEnabled = false
        let draft = try XCTUnwrap(independent.fetch(FetchDescriptor<ScheduleBlock>())
            .first { $0.id == first })
        draft.note = "Unsaved other owner"
        var saves = 0
        var reads = 0
        let failing = SwiftDataScheduleRepository(container: container,
            fetch: { context in
                reads += 1
                return try context.fetch(FetchDescriptor<ScheduleBlock>())
            }, save: { _ in saves += 1; throw Injected.failed })
        XCTAssertThrowsError(try failing.delete(id: third)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(self.third))
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(reads, 1)
        XCTAssertThrowsError(try failing.delete(id: second)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container), [kept, target])
        XCTAssertTrue(independent.hasChanges)
        XCTAssertEqual(draft.note, "Unsaved other owner")
        let unreadable = SwiftDataScheduleRepository(container: container,
            fetch: { _ in throw Injected.failed }, save: { _ in saves += 1; throw Injected.failed })
        XCTAssertThrowsError(try unreadable.delete(id: second)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
        }
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try rows(container), [kept, target])
        try independent.save()
        let updatedKept = try XCTUnwrap(rows(container).first { $0.id == first })
        XCTAssertEqual(updatedKept.note, "Unsaved other owner")
        try SwiftDataScheduleRepository(container: container).delete(id: second)
        XCTAssertEqual(try rows(container), [updatedKept])
        XCTAssertThrowsError(try SwiftDataScheduleRepository(container: container).delete(id: second)) {
            XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(self.second))
        }
        XCTAssertEqual(try rows(container), [updatedKept])
    }

    func testDiskLifecycleSurvivesDistinctOpensAndFailuresPreserveTasksAndPeers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolScheduleLifecycle-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Kontrol.store")
        // Keep the isolated store until the test host exits: SwiftData can retain
        // SQLite descriptors after the explicit container owners leave scope.
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let due = base.addingTimeInterval(86_400)
        let day = KontrolSchemaV1.PlannedDayComponents(calendarIdentifier: "gregorian",
                                                        year: 2026, month: 1, day: 2)
        let task = try TaskItem(id: taskID, title: "Unchanged task", createdAt: base,
                                notes: "Task details", dueAt: due, plannedDay: day,
                                plannedTimeZoneID: "UTC", completedAt: due)
        let expectedTask = TaskSnapshot(task)
        let peer = ScheduleSnapshot(id: second, title: "Linked peer", startAt: base.addingTimeInterval(7200),
                                    endAt: base.addingTimeInterval(10_800), note: "Peer note",
                                    lessonID: "missing-lesson", linkedTitleSnapshot: "Archived title")
        let created = ScheduleSnapshot(id: first, title: "New", startAt: base,
                                       endAt: base.addingTimeInterval(3600), note: "Original note")
        let moved = ScheduleSnapshot(id: first, title: "Moved", startAt: base.addingTimeInterval(10_800),
                                     endAt: base.addingTimeInterval(14_400), note: "Moved note")
        let overlapping = ScheduleSnapshot(id: first, title: "Confirmed", startAt: base.addingTimeInterval(9000),
                                           endAt: base.addingTimeInterval(12_600), note: "Final note")

        func open(_ check: (ModelContainer) throws -> Void) throws {
            try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                try check(container)
            }
        }
        func assertDisk(_ container: ModelContainer, _ expected: [ScheduleSnapshot]) throws {
            XCTAssertEqual(try rows(container), expected)
            let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            XCTAssertEqual(tasks.count, 1)
            XCTAssertEqual(try XCTUnwrap(tasks.first).id, taskID)
            XCTAssertEqual(try XCTUnwrap(tasks.first).title, expectedTask.title)
            XCTAssertEqual(try XCTUnwrap(tasks.first).notes, expectedTask.notes)
            XCTAssertEqual(try XCTUnwrap(tasks.first).createdAt, expectedTask.createdAt)
            XCTAssertEqual(try XCTUnwrap(tasks.first).dueAt, expectedTask.dueAt)
            XCTAssertEqual(try XCTUnwrap(tasks.first).plannedDay, expectedTask.plannedDay)
            XCTAssertEqual(try XCTUnwrap(tasks.first).plannedTimeZoneID, expectedTask.plannedTimeZoneID)
            XCTAssertEqual(try XCTUnwrap(tasks.first).completedAt, expectedTask.completedAt)
        }
        try open { container in
            let seed = ModelContext(container)
            seed.autosaveEnabled = false
            seed.insert(task)
            seed.insert(ScheduleBlock(id: peer.id, title: peer.title, startAt: peer.startAt,
                                      endAt: peer.endAt, note: peer.note, lessonID: peer.lessonID,
                                      linkedTitleSnapshot: peer.linkedTitleSnapshot))
            try seed.save()
            let failing = SwiftDataScheduleRepository(container: container, makeID: { self.first },
                save: { _ in throw Injected.failed })
            XCTAssertThrowsError(try failing.create(input: input("Uncommitted", 0, 3600))) {
                XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
            }
            try assertDisk(container, [peer])
        }
        try open { container in
            try assertDisk(container, [peer]) // failed create did not reach disk
            let writer = repository(container, id: first)
            XCTAssertEqual(try writer.create(input: input(" New ", 0, 3600,
                                                          note: " Original note ")), created)
            try assertDisk(container, [created, peer])
        }
        try open { container in
            let failed = SwiftDataScheduleRepository(container: container,
                save: { _ in throw Injected.failed })
            XCTAssertThrowsError(try failed.update(id: first, input: input("Failed", 10_800, 14_400))) {
                XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
            }
            try assertDisk(container, [created, peer])
            XCTAssertEqual(try repository(container, id: third).update(id: first,
                input: input("Moved", 10_800, 14_400, note: "Moved note")), moved)
            try assertDisk(container, [peer, moved])
        }
        try open { container in
            try assertDisk(container, [peer, moved]) // failed edit did not reach disk
            let writer = repository(container, id: third)
            let draft = input("Confirmed", 9000, 12_600, note: "Final note")
            let review = try warning { try writer.update(id: first, input: draft) }
            XCTAssertEqual(review.conflicts, [ScheduleConflict(block: peer, duration: 1800)])
            try assertDisk(container, [peer, moved])
            XCTAssertEqual(try writer.update(id: first, input: draft, allowOverlap: true,
                                             review: review), overlapping)
            try assertDisk(container, [peer, overlapping])
        }
        try open { container in
            let failing = SwiftDataScheduleRepository(container: container,
                save: { _ in throw Injected.failed })
            XCTAssertThrowsError(try failing.delete(id: first)) {
                XCTAssertEqual($0 as? ScheduleRepositoryError, .persistence)
            }
            try assertDisk(container, [peer, overlapping])
            XCTAssertThrowsError(try failing.delete(id: third)) {
                XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(self.third))
            }
            try assertDisk(container, [peer, overlapping])
        }
        try open { container in
            try assertDisk(container, [peer, overlapping])
            try SwiftDataScheduleRepository(container: container).delete(id: first)
            try assertDisk(container, [peer])
        }
        try open { container in
            try assertDisk(container, [peer])
            XCTAssertThrowsError(try SwiftDataScheduleRepository(container: container).delete(id: first)) {
                XCTAssertEqual($0 as? ScheduleRepositoryError, .notFound(self.first))
            }
            try assertDisk(container, [peer])
        }
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
