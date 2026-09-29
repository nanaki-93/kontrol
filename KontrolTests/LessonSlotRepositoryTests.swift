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
                _ = try repository.importIfNeeded(catalog)
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

    func testUpgradeRetainsStartedPinAndExcludesArchivedRepeatAndRetiredSeed() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let original = try seed()
        try repository.importIfNeeded(original)
        let before = try repository.loadSnapshot().slots
        let started = try XCTUnwrap(before.first { $0.topicID == "go" })
        let completed = try XCTUnwrap(before.first { $0.topicID == "go" && $0.key != started.key })
        let completedDTO = try XCTUnwrap(original.value.lessons.first { $0.id == completed.lessonID })
        let startedDTO = try XCTUnwrap(original.value.lessons.first { $0.id == started.lessonID })
        let definitions = try repository.loadSnapshot().definitions
        let oldCompleted = try XCTUnwrap(definitions.first { $0.id == completed.lessonID })
        let oldStarted = try XCTUnwrap(definitions.first { $0.id == started.lessonID })
        let date = Date(timeIntervalSinceReferenceDate: 400)
        let personal = ModelContext(container)
        personal.insert(LessonProgress(lessonID: started.lessonID, status: .started, startedAt: date))
        personal.insert(LessonProgress(lessonID: completed.lessonID, status: .completed, completedAt: date))
        personal.insert(LessonAttempt(id: UUID(), lessonID: started.lessonID,
            contentVersion: oldStarted.contentVersion,
            pinnedContentData: try PinnedLessonContent(definition: oldStarted).encoded()))
        personal.insert(LessonAttempt(id: UUID(), lessonID: completed.lessonID,
            contentVersion: oldCompleted.contentVersion, completedAt: date,
            pinnedContentData: try PinnedLessonContent(definition: oldCompleted).encoded()))
        // Backfill recovers the old version before import overwrites its definition.
        try personal.save()
        var next = original.value
        next.version += 1
        next.lessons.removeAll { $0.id == started.lessonID }
        let index = try XCTUnwrap(next.lessons.firstIndex { $0.id == completed.lessonID })
        next.lessons[index].contentVersion += 1
        next.lessons[index].explanation = "Revised installed text"
        next.lessons[index].normalizedContentHash = CatalogValidator.fingerprint(for: next.lessons[index])
        let spare = try XCTUnwrap(next.lessons.firstIndex { $0.topicID == "go" &&
            !before.map(\.lessonID).contains($0.id) })
        let repeatedID = next.lessons[spare].id
        next.lessons[spare].contentVersion += 1
        next.lessons[spare].explanation = completedDTO.explanation
        next.lessons[spare].workedExample = completedDTO.workedExample
        next.lessons[spare].exercise = completedDTO.exercise
        next.lessons[spare].referenceAnswer = completedDTO.referenceAnswer
        next.lessons[spare].selfCheckCriteria = completedDTO.selfCheckCriteria
        next.lessons[spare].normalizedContentHash = CatalogValidator.fingerprint(for: next.lessons[spare])
        XCTAssertEqual(startedDTO.id, started.lessonID)
        try repository.importIfNeeded(CatalogValidator.validate(next))
        let after = try repository.loadSnapshot().slots
        XCTAssertEqual(after.first { $0.key == started.key }, started)
        XCTAssertFalse(after.map(\.lessonID).contains(completed.lessonID))
        XCTAssertFalse(after.map(\.lessonID).contains(repeatedID))
        XCTAssertEqual(try repository.reconcileSlots(now: .distantFuture).slots, after)
    }

    func testCatalogUpgradeVacatesOnlyLaterRetainedExactContentDuplicate() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let original = try seed()
        try repository.importIfNeeded(original)
        let initial = try repository.loadSnapshot().slots
        let go = initial.filter { $0.topicID == "go" }
        let first = try XCTUnwrap(go.first)
        let laterSlot = try XCTUnwrap(go.dropFirst().first)
        let firstDTO = try XCTUnwrap(original.value.lessons.first { $0.id == first.lessonID })
        var upgrade = original.value
        upgrade.version += 1
        let index = try XCTUnwrap(upgrade.lessons.firstIndex { $0.id == laterSlot.lessonID })
        XCTAssertNotEqual(CatalogValidator.fingerprint(for: upgrade.lessons[index]),
                          CatalogValidator.fingerprint(for: firstDTO))
        upgrade.lessons[index].contentVersion += 1
        upgrade.lessons[index].explanation = firstDTO.explanation
        upgrade.lessons[index].workedExample = firstDTO.workedExample
        upgrade.lessons[index].exercise = firstDTO.exercise
        upgrade.lessons[index].referenceAnswer = firstDTO.referenceAnswer
        upgrade.lessons[index].selfCheckCriteria = firstDTO.selfCheckCriteria
        upgrade.lessons[index].normalizedContentHash = CatalogValidator.fingerprint(for: upgrade.lessons[index])
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(upgrade)), .imported)
        let after = try repository.loadSnapshot().slots
        XCTAssertEqual(after.first { $0.key == first.key }, first)
        XCTAssertEqual(after.filter { $0.key != laterSlot.key }, initial.filter { $0.key != laterSlot.key })
        XCTAssertFalse(after.contains { $0.lessonID == laterSlot.lessonID })
        XCTAssertNotNil(after.first { $0.key == laterSlot.key })
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(upgrade)), .unchanged)
        XCTAssertEqual(try repository.reconcileSlots(now: .distantFuture).slots, after)
    }

    func testRestoreVacancyUsesStartedPinAgainstTerminalHistoryAfterUpgrade() throws {
        let original = try seed()
        for (matchPinned, shouldOffer) in [(true, false), (false, true)] {
            let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
            let repository = SwiftDataCatalogRepository(container: container)
            try repository.importIfNeeded(original)
            let initial = try repository.loadSnapshot()
            let goSlots = initial.slots.filter { $0.topicID == "go" }
            let started = try XCTUnwrap(initial.definitions.first { $0.topicID == "go" &&
                !goSlots.map(\.lessonID).contains($0.id) && $0.prerequisiteConceptIDs.isEmpty })
            let other = try XCTUnwrap(initial.slots.first { $0.topicID == "java" })
            let originalHash = LessonMatchMetadata(started).contentHash
            let context = ModelContext(container)
            context.insert(LessonProgress(lessonID: started.id, status: .dismissed))
            context.insert(LessonAttempt(id: UUID(), lessonID: started.id,
                contentVersion: started.contentVersion,
                pinnedContentData: try PinnedLessonContent(definition: started).encoded()))
            let completedAt = Date(timeIntervalSinceReferenceDate: 450)
            context.insert(LessonProgress(lessonID: other.lessonID, status: .completed,
                                          completedAt: completedAt))
            context.insert(LessonAttempt(id: UUID(), lessonID: other.lessonID,
                contentVersion: 1, completedAt: completedAt))
            try context.save()

            var upgrade = original.value
            upgrade.version += 1
            let index = try XCTUnwrap(upgrade.lessons.firstIndex { $0.id == started.id })
            upgrade.lessons[index].contentVersion += 1
            upgrade.lessons[index].explanation = "Upgraded lesson content for restore"
            upgrade.lessons[index].normalizedContentHash = CatalogValidator.fingerprint(for: upgrade.lessons[index])
            try repository.importIfNeeded(CatalogValidator.validate(upgrade))
            let changed = try XCTUnwrap(try repository.loadSnapshot().definitions.first { $0.id == started.id })
            let changedHash = LessonMatchMetadata(changed).contentHash
            XCTAssertNotEqual(originalHash, changedHash)
            let archive = LessonTerminalMetadata(lessonID: other.lessonID,
                provenance: .legacyCompletedPartial, title: nil, topicID: nil, subtopicID: nil,
                contentVersion: nil, objectiveKey: nil, conceptIDs: nil,
                normalizedContentHash: matchPinned ? originalHash : changedHash,
                format: nil, dismissalTimeDefinition: nil)
            let evidence = ModelContext(container)
            evidence.insert(try LessonTerminalRecord(metadata: archive))
            let vacancy = try XCTUnwrap(try evidence.fetch(FetchDescriptor<LessonSlot>()).first {
                $0.topicID == "go"
            })
            let key = vacancy.key
            evidence.delete(vacancy)
            try evidence.save()
            let before = try repository.loadSnapshot().slots
            XCTAssertFalse(before.contains { $0.key == key })
            let receipt = try repository.restoreDismissed(lessonID: started.id, now: Date())
            XCTAssertEqual(receipt.catalog.slots.first { $0.key == key }?.lessonID,
                           shouldOffer ? started.id : nil)
            XCTAssertEqual(receipt.catalog.slots.filter { $0.key != key }, before)
            XCTAssertEqual(receipt.detail.progress?.status, .started)
            let relaunched = try repository.reconcileSlots(now: .distantFuture).slots
            XCTAssertEqual(relaunched.first { $0.lessonID == started.id }?.key,
                           shouldOffer ? key : nil)
        }
    }

    func testReconcileRanksVacanciesUsingArchivedTerminalFormatsWithoutMovingOtherTopics() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        try repository.importIfNeeded(seed())
        let initial = try repository.loadSnapshot().slots
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<LessonSlot>()) where row.topicID == "go" {
            context.delete(row)
        }
        try context.save()
        let baseline = try repository.reconcileSlots(now: Date(timeIntervalSinceReferenceDate: 100))
        let first = try XCTUnwrap(baseline.slots.first { $0.topicID == "go" })
        let format = try XCTUnwrap(baseline.definitions.first { $0.id == first.lessonID }?.format)
        // Return to the same vacancies. The next reconciliation must consult
        // archived history rather than current definitions for these absent IDs.
        let evidence = ModelContext(container)
        for row in try evidence.fetch(FetchDescriptor<LessonSlot>()) where row.topicID == "go" {
            evidence.delete(row)
        }
        let date = Date(timeIntervalSinceReferenceDate: 200)
        for id in ["archived-a", "archived-b", "archived-c", "archived-d"] {
            evidence.insert(LessonProgress(lessonID: id, status: .dismissed, dismissedAt: date))
            evidence.insert(try LessonTerminalRecord(metadata: .init(lessonID: id,
                provenance: .legacyCompletedPartial, title: nil, topicID: "go", subtopicID: nil,
                contentVersion: nil, objectiveKey: nil, conceptIDs: nil,
                normalizedContentHash: nil, format: format, dismissalTimeDefinition: nil)))
        }
        try evidence.save()
        let ranked = try repository.reconcileSlots(now: date)
        let newFirst = try XCTUnwrap(ranked.slots.first { $0.topicID == "go" })
        XCTAssertNotEqual(newFirst.lessonID, first.lessonID)
        XCTAssertEqual(ranked.slots.filter { $0.topicID != "go" },
                       initial.filter { $0.topicID != "go" })
        XCTAssertEqual(try repository.reconcileSlots(now: .distantFuture).slots, ranked.slots)
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
