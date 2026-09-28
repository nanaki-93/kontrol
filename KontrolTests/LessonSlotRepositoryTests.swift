import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LessonSlotRepositoryTests: XCTestCase {
    private func seed() throws -> ValidatedCatalog { try BundledCatalogLoader.load(from: Bundle.main) }

    private func rows<T: PersistentModel>(_ type: T.Type, _ container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func testFreshImportAndEqualVersionRepairRemainStableWithoutPersonalRecords() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let catalog = try seed()
        XCTAssertEqual(try repository.importIfNeeded(catalog), .imported)
        let first = try repository.loadSnapshot()
        XCTAssertEqual(first.definitions.count, 40)
        XCTAssertEqual(first.slots.count, 20)
        for topic in catalog.value.topics {
            XCTAssertEqual(first.slots.filter { $0.topicID == topic.id }.map(\.slotIndex), [0, 1, 2, 3])
        }
        XCTAssertEqual(Set(first.slots.map(\.key)).count, 20)
        XCTAssertEqual(Set(first.slots.map(\.lessonID)).count, 20)
        XCTAssertTrue(first.progress.isEmpty)
        XCTAssertTrue(try rows(LessonAttempt.self, container).isEmpty)
        XCTAssertEqual(try repository.importIfNeeded(catalog), .unchanged)
        XCTAssertEqual(try repository.reconcileSlots(now: Date.distantFuture).slots, first.slots)

        // An equal-version import repairs an empty legacy slot table, without
        // reimporting even a valid same-version definition edit.
        let context = ModelContext(container)
        let removed = try XCTUnwrap(try context.fetch(FetchDescriptor<LessonSlot>()).first)
        let vacancy = removed.key
        context.delete(removed)
        try context.save()
        var altered = catalog.value
        altered.lessons[0].title = "Unreleased title"
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(altered)), .unchanged)
        let repaired = try repository.loadSnapshot()
        XCTAssertEqual(repaired.slots.count, 20)
        XCTAssertEqual(repaired.slots.filter { $0.key != vacancy }, first.slots.filter { $0.key != vacancy })
        XCTAssertEqual(repaired.definitions.first { $0.id == altered.lessons[0].id }?.title,
                       catalog.value.lessons[0].title)
        XCTAssertTrue(repaired.progress.isEmpty)
        XCTAssertTrue(try rows(LessonAttempt.self, container).isEmpty)
    }

    func testCompletedDismissedAndStartedRecoveryPreserveOtherAssignments() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let catalog = try seed()
        try repository.importIfNeeded(catalog)
        let initial = try repository.loadSnapshot().slots
        let go = initial.filter { $0.topicID == "go" }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: go[0].lessonID, status: .completed, completedAt: timestamp))
        context.insert(LessonProgress(lessonID: go[1].lessonID, status: .dismissed, dismissedAt: timestamp))
        // Recover started work from a reserve ID without creating an attempt.
        let reserve = try XCTUnwrap(catalog.value.lessons.first {
            $0.topicID == "go" && !go.map(\.lessonID).contains($0.id) && $0.prerequisiteConceptIDs.isEmpty
        })
        context.insert(LessonProgress(lessonID: reserve.id, status: .started, startedAt: timestamp))
        try context.save()
        let after = try repository.reconcileSlots(now: timestamp)
        XCTAssertEqual(after.slots.count, 20)
        XCTAssertEqual(after.slots.filter { $0.key != go[0].key && $0.key != go[1].key },
                       initial.filter { $0.key != go[0].key && $0.key != go[1].key })
        XCTAssertEqual(after.slots.first { $0.key == go[0].key }?.lessonID, reserve.id)
        XCTAssertFalse(after.slots.map(\.lessonID).contains(go[0].lessonID))
        XCTAssertFalse(after.slots.map(\.lessonID).contains(go[1].lessonID))
        XCTAssertEqual(after.progress.count, 3)
        XCTAssertTrue(try rows(LessonAttempt.self, container).isEmpty)
        XCTAssertEqual(try repository.reconcileSlots(now: Date.distantFuture).slots, after.slots)
    }

    func testExhaustedPoolDoesNotInventChoices() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let catalog = try seed()
        try repository.importIfNeeded(catalog)
        let before = try repository.loadSnapshot().slots
        let context = ModelContext(container)
        for lesson in catalog.value.lessons where lesson.topicID == "go" {
            context.insert(LessonProgress(lessonID: lesson.id, status: .dismissed))
        }
        try context.save()
        let after = try repository.reconcileSlots(now: Date())
        XCTAssertTrue(after.slots.filter { $0.topicID == "go" }.isEmpty)
        XCTAssertEqual(after.slots.filter { $0.topicID != "go" }, before.filter { $0.topicID != "go" })
        XCTAssertEqual(after.progress.count, 8)
        XCTAssertTrue(try rows(LessonAttempt.self, container).isEmpty)
    }

    func testMalformedPersistedSlotIdentitiesRejectWithoutChangingAssignments() throws {
        for corruption in 0..<3 {
            let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
            let repository = SwiftDataCatalogRepository(container: container)
            let catalog = try seed()
            try repository.importIfNeeded(catalog)
            let context = ModelContext(container)
            let slots = try context.fetch(FetchDescriptor<LessonSlot>())
            let target = try XCTUnwrap(slots.first)
            switch corruption {
            case 0: target.key = "bad-key"
            case 1: target.slotIndex = 5
            default: target.topicID = "wrong-topic"
            }
            try context.save()
            let stored = try rows(LessonSlot.self, container).map {
                LessonSlotSnapshot(key: $0.key, topicID: $0.topicID,
                    slotIndex: $0.slotIndex, lessonID: $0.lessonID, assignedAt: $0.assignedAt)
            }.sorted { $0.key < $1.key }
            XCTAssertThrowsError(try repository.loadSnapshot()) {
                XCTAssertEqual($0 as? LessonSelectionError, .invalidSlotIdentity)
            }
            XCTAssertThrowsError(try repository.reconcileSlots(now: Date())) {
                XCTAssertEqual($0 as? LessonSelectionError, .invalidSlotIdentity)
            }
            XCTAssertThrowsError(try repository.importIfNeeded(catalog)) {
                XCTAssertEqual($0 as? LessonSelectionError, .invalidSlotIdentity)
            }
            let retained = try rows(LessonSlot.self, container).map {
                LessonSlotSnapshot(key: $0.key, topicID: $0.topicID,
                    slotIndex: $0.slotIndex, lessonID: $0.lessonID, assignedAt: $0.assignedAt)
            }.sorted { $0.key < $1.key }
            XCTAssertEqual(retained, stored)
            XCTAssertEqual(try rows(CatalogImportState.self, container).map(\.lastImportedVersion), [catalog.value.version])
        }
    }

    func testWrongTopicAssignmentIsVacatedWithoutMovingOtherSlots() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let catalog = try seed()
        try repository.importIfNeeded(catalog)
        let original = try repository.loadSnapshot().slots
        let goSlot = try XCTUnwrap(original.first { $0.topicID == "go" })
        let javaIDs = Set(original.filter { $0.topicID == "java" }.map(\.lessonID))
        let javaReserve = try XCTUnwrap(catalog.value.lessons.first {
            $0.topicID == "java" && !javaIDs.contains($0.id)
        })
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<LessonSlot>()).first {
            $0.key == goSlot.key
        })
        row.lessonID = javaReserve.id // canonical key/index remain intact
        try context.save()
        let after = try repository.reconcileSlots(now: Date())
        XCTAssertEqual(after.slots.count, 20)
        XCTAssertEqual(after.slots.filter { $0.key != goSlot.key },
                       original.filter { $0.key != goSlot.key })
        XCTAssertEqual(after.slots.first { $0.key == goSlot.key }?.lessonID, goSlot.lessonID)
        XCTAssertTrue(after.progress.isEmpty)
    }

    func testFailedReplacementDoesNotCommitSlotsOrPersonalChangesAcrossReopen() throws {
        enum Injected: Error { case failure }
        let catalog = try seed()
        for failBeforeSave in [true, false] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "KontrolSlotFailure-\(UUID().uuidString)/Kontrol.store")
            var previous: [LessonSlotSnapshot] = []
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let attemptID = UUID()
            try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let repository = SwiftDataCatalogRepository(container: container)
                try repository.importIfNeeded(catalog)
                previous = try repository.loadSnapshot().slots
                let victim = try XCTUnwrap(previous.first { $0.topicID == "go" })
                let personal = ModelContext(container)
                personal.insert(LessonProgress(lessonID: victim.lessonID, status: .completed,
                    firstShownAt: timestamp, startedAt: timestamp, completedAt: timestamp))
                personal.insert(LessonAttempt(id: attemptID, lessonID: victim.lessonID,
                    contentVersion: 2, answerDraft: "preserved answer", completedAt: timestamp))
                try personal.save()
                let independent = ModelContext(container)
                independent.autosaveEnabled = false
                let draft = try TaskItem(id: UUID(), title: "Pending task", createdAt: timestamp)
                independent.insert(draft)
                let failing = SwiftDataCatalogRepository(container: container,
                    beforeSave: { if failBeforeSave { throw Injected.failure } },
                    save: { context in
                        if !failBeforeSave { throw Injected.failure }
                        try context.save()
                    })
                XCTAssertThrowsError(try failing.reconcileSlots(now: timestamp)) {
                    XCTAssertTrue($0 is Injected)
                }
                XCTAssertTrue(independent.hasChanges)
                XCTAssertEqual(try repository.loadSnapshot().slots, previous)
                XCTAssertEqual(try rows(CatalogImportState.self, container).map(\.lastImportedVersion), [2])
                XCTAssertTrue(try rows(TaskItem.self, container).isEmpty)
                try autoreleasepool {
                    let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                    XCTAssertEqual(try SwiftDataCatalogRepository(container: reopened).loadSnapshot().slots, previous)
                    XCTAssertEqual(try rows(CatalogImportState.self, reopened).map(\.lastImportedVersion), [2])
                    XCTAssertTrue(try rows(TaskItem.self, reopened).isEmpty)
                    let progress = try XCTUnwrap(try rows(LessonProgress.self, reopened).first)
                    XCTAssertEqual(progress.lessonID, victim.lessonID)
                    XCTAssertEqual(progress.completedAt, timestamp)
                    let attempt = try XCTUnwrap(try rows(LessonAttempt.self, reopened).first)
                    XCTAssertEqual(attempt.id, attemptID)
                    XCTAssertEqual(attempt.answerDraft, "preserved answer")
                    XCTAssertEqual(attempt.completedAt, timestamp)
                }
                XCTAssertTrue(independent.hasChanges)
                try independent.save()
            }
            try autoreleasepool {
                let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let repository = SwiftDataCatalogRepository(container: reopened)
                XCTAssertEqual(try repository.loadSnapshot().slots, previous)
                XCTAssertEqual(try rows(TaskItem.self, reopened).count, 1)
                let repaired = try repository.reconcileSlots(now: timestamp)
                XCTAssertEqual(repaired.slots.count, 20)
                XCTAssertFalse(repaired.slots.map(\.lessonID).contains(previous.first {
                    $0.topicID == "go"
                }!.lessonID))
                XCTAssertEqual(repaired.progress.first?.completedAt, timestamp)
                XCTAssertEqual(try rows(LessonAttempt.self, reopened).first?.id, attemptID)
            }
        }
    }

    func testDiskReopenPreservesSlotsAndAssignments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolSlot-\(UUID().uuidString)/Kontrol.store")
        let catalog = try seed()
        var first: [LessonSlotSnapshot] = []
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let repository = SwiftDataCatalogRepository(container: container)
            XCTAssertEqual(try repository.importIfNeeded(catalog), .imported)
            first = try repository.loadSnapshot().slots
        }
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let repository = SwiftDataCatalogRepository(container: container)
            XCTAssertEqual(try repository.loadSnapshot().slots, first)
            XCTAssertEqual(try repository.importIfNeeded(catalog), .unchanged)
            XCTAssertEqual(try repository.loadSnapshot().slots, first)
            XCTAssertTrue(try rows(LessonProgress.self, container).isEmpty)
            XCTAssertTrue(try rows(LessonAttempt.self, container).isEmpty)
        }
    }
}
