import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class CatalogImportTests: XCTestCase {
    private enum Injected: Error { case failure }

    private func catalog() throws -> ValidatedCatalog {
        try BundledCatalogLoader.load(from: Bundle.main)
    }

    private func revised(_ original: ValidatedCatalog) throws -> ValidatedCatalog {
        var value = original.value
        value.version += 1
        value.topics[0].name = "Corrected topic"
        value.subtopics[0].name = "Corrected subtopic"
        value.concepts[0].name = "Corrected concept"
        value.lessons[0].title = "Corrected lesson"
        value.lessons[0].contentVersion += 1
        value.lessons[0].explanation = "Updated explanation"
        value.lessons[0].normalizedContentHash = "sha256:corrected"
        return try CatalogValidator.validate(value)
    }

    private func records<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func testSeedAndRepeatDoNotCreatePersonalRecordsOrDuplicateDefinitions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let seed = try catalog()
        XCTAssertEqual(try repository.importIfNeeded(seed), .imported)
        XCTAssertEqual(try repository.importIfNeeded(seed), .unchanged)
        var sameVersion = seed.value
        sameVersion.lessons[0].title = "Not a new release"
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(sameVersion)), .unchanged)
        XCTAssertEqual(try records(LessonDefinition.self, in: container).first {
            $0.id == seed.value.lessons[0].id
        }?.title, seed.value.lessons[0].title)
        XCTAssertEqual(try records(Topic.self, in: container).count, seed.value.topics.count)
        XCTAssertEqual(try records(Subtopic.self, in: container).count, seed.value.subtopics.count)
        XCTAssertEqual(try records(Concept.self, in: container).count, seed.value.concepts.count)
        XCTAssertEqual(try records(LessonDefinition.self, in: container).count, seed.value.lessons.count)
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [seed.value.version])
        XCTAssertTrue(try records(LessonProgress.self, in: container).isEmpty)
        XCTAssertTrue(try records(LessonAttempt.self, in: container).isEmpty)
        XCTAssertTrue(try records(TaskItem.self, in: container).isEmpty)
    }

    func testUpgradeKeepsIdentityPersonalDataAndAbsentHistoricalDefinitions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let original = try catalog()
        XCTAssertEqual(try repository.importIfNeeded(original), .imported)
        let oldDefinition = try XCTUnwrap(records(LessonDefinition.self, in: container).first {
            $0.id == original.value.lessons[0].id
        })
        let oldTopic = try XCTUnwrap(records(Topic.self, in: container).first {
            $0.id == original.value.topics[0].id
        })
        let lessonID = oldDefinition.id
        let oldIdentity = oldDefinition.persistentModelID
        let topicIdentity = oldTopic.persistentModelID
        let timestamp = Date(timeIntervalSince1970: 123_456)
        let attemptID = UUID()
        let snapshot = KontrolSchemaV1.LessonContentSnapshot(
            title: oldDefinition.title, objectiveKey: oldDefinition.objectiveKey,
            conceptIDs: oldDefinition.conceptIDs, difficulty: oldDefinition.difficulty,
            format: oldDefinition.format, explanation: oldDefinition.explanation,
            workedExample: oldDefinition.workedExample, exercise: oldDefinition.exercise,
            referenceAnswer: oldDefinition.referenceAnswer,
            selfCheckCriteria: oldDefinition.selfCheckCriteria)
        let personal = ModelContext(container)
        personal.insert(LessonProgress(lessonID: lessonID, status: .completed,
                                       firstShownAt: timestamp, startedAt: timestamp,
                                       completedAt: timestamp, lastOpenedAt: timestamp))
        personal.insert(LessonAttempt(id: attemptID, lessonID: lessonID,
                                      contentVersion: oldDefinition.contentVersion,
                                      answerDraft: "personal answer", solutionRevealedAt: timestamp,
                                      selfCheckAcknowledgedAt: timestamp, completedAt: timestamp,
                                      completedContentSnapshot: snapshot))
        try personal.save()

        var updated = try revised(original).value
        let removedID = try XCTUnwrap(updated.lessons.last?.id)
        // Keep one lesson per topic in the updated bundle; historical rows must survive.
        if updated.lessons.count > 1 { updated.lessons.removeLast() }
        let upgrade = try CatalogValidator.validate(updated)
        XCTAssertEqual(try repository.importIfNeeded(upgrade), .imported)
        let definitions = try records(LessonDefinition.self, in: container)
        XCTAssertEqual(definitions.count, original.value.lessons.count)
        let corrected = try XCTUnwrap(definitions.first { $0.id == lessonID })
        XCTAssertEqual(corrected.persistentModelID, oldIdentity)
        XCTAssertEqual(corrected.title, "Corrected lesson")
        XCTAssertEqual(corrected.explanation, "Updated explanation")
        XCTAssertEqual(corrected.contentVersion, original.value.lessons[0].contentVersion + 1)
        XCTAssertEqual(corrected.normalizedContentHash, "sha256:corrected")
        XCTAssertEqual(try records(Topic.self, in: container).first { $0.id == oldTopic.id }?.persistentModelID, topicIdentity)
        XCTAssertEqual(try records(Topic.self, in: container).first { $0.id == oldTopic.id }?.name, "Corrected topic")
        XCTAssertEqual(try records(Subtopic.self, in: container).first { $0.id == updated.subtopics[0].id }?.name, "Corrected subtopic")
        XCTAssertEqual(try records(Concept.self, in: container).first { $0.id == updated.concepts[0].id }?.name, "Corrected concept")
        XCTAssertNotNil(definitions.first { $0.id == removedID })
        let progress = try XCTUnwrap(records(LessonProgress.self, in: container).first)
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.firstShownAt, timestamp)
        XCTAssertEqual(progress.startedAt, timestamp)
        XCTAssertEqual(progress.completedAt, timestamp)
        XCTAssertEqual(progress.lastOpenedAt, timestamp)
        let attempt = try XCTUnwrap(records(LessonAttempt.self, in: container).first)
        XCTAssertEqual(attempt.id, attemptID)
        XCTAssertEqual(attempt.answerDraft, "personal answer")
        XCTAssertEqual(attempt.contentVersion, original.value.lessons[0].contentVersion)
        XCTAssertEqual(attempt.solutionRevealedAt, timestamp)
        XCTAssertEqual(attempt.selfCheckAcknowledgedAt, timestamp)
        XCTAssertEqual(attempt.completedAt, timestamp)
        XCTAssertEqual(attempt.completedContentSnapshot, snapshot)
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [updated.version])
        XCTAssertThrowsError(try repository.importIfNeeded(original)) {
            XCTAssertEqual($0 as? CatalogImportError,
                           .downgrade(installed: updated.version, requested: original.value.version))
        }
        XCTAssertEqual(try records(LessonDefinition.self, in: container).first { $0.id == lessonID }?.title,
                       "Corrected lesson")
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [updated.version])
    }

    func testValidationAndBothInjectedFailuresLeaveMarkerAndDefinitionsCommittedTogether() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = try catalog()
        var changed = try revised(seed).value
        var newLesson = changed.lessons[0]
        newLesson.id += ".additional"
        changed.lessons.append(newLesson)
        let upgraded = try CatalogValidator.validate(changed)
        let lessonID = seed.value.lessons[0].id
        let repository = SwiftDataCatalogRepository(container: container)
        XCTAssertEqual(try repository.importIfNeeded(seed), .imported)
        var malformed = upgraded.value
        malformed.lessons[0].referenceAnswer = "  "
        XCTAssertThrowsError(try CatalogValidator.validate(malformed))
        // There is no import API accepting an unvalidated DTO.
        for failing in [SwiftDataCatalogRepository(container: container,
                                                    beforeSave: { throw Injected.failure }),
                        SwiftDataCatalogRepository(container: container,
                                                   save: { _ in throw Injected.failure })] {
            XCTAssertThrowsError(try failing.importIfNeeded(upgraded)) {
                XCTAssertTrue($0 is Injected)
            }
            XCTAssertEqual(try records(LessonDefinition.self, in: container).first { $0.id == lessonID }?.title,
                           seed.value.lessons[0].title)
            XCTAssertEqual(try records(Topic.self, in: container).first { $0.id == seed.value.topics[0].id }?.name,
                           seed.value.topics[0].name)
            XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [seed.value.version])
            XCTAssertEqual(try records(LessonDefinition.self, in: container).count, seed.value.lessons.count)
            XCTAssertFalse(try records(LessonDefinition.self, in: container).contains { $0.id == newLesson.id })
        }
        // A failed first import must not leave even a marker or a partial row.
        let empty = try ModelContainerFactory().makeContainer(mode: .inMemory)
        XCTAssertThrowsError(try SwiftDataCatalogRepository(container: empty,
                         save: { _ in throw Injected.failure }).importIfNeeded(seed))
        XCTAssertTrue(try records(Topic.self, in: empty).isEmpty)
        XCTAssertTrue(try records(CatalogImportState.self, in: empty).isEmpty)
        XCTAssertEqual(try repository.importIfNeeded(upgraded), .imported)
    }

    func testFailedUpgradeRemainsAbsentAfterClosingAndReopeningDiskStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolCatalogImport-\(UUID().uuidString)", isDirectory: true)
        // SwiftData may keep SQLite file descriptors open after all model owners
        // deallocate. Never unlink this store inside the test host; the system
        // can reclaim this UUID-isolated temporary directory after the process exits.
        let url = directory.appendingPathComponent("Kontrol.store")
        let seed = try catalog()
        let upgraded = try revised(seed)
        weak var lastContainer: ModelContainer?
        func writeAndClose() throws {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            let repository = SwiftDataCatalogRepository(container: container)
            XCTAssertEqual(try repository.importIfNeeded(seed), .imported)
            XCTAssertThrowsError(try SwiftDataCatalogRepository(container: container,
                             save: { _ in throw Injected.failure }).importIfNeeded(upgraded))
        }
        func reopenAndCheck() throws {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion),
                           [seed.value.version])
            XCTAssertEqual(try records(LessonDefinition.self, in: container).first {
                $0.id == seed.value.lessons[0].id
            }?.title, seed.value.lessons[0].title)
            XCTAssertEqual(try SwiftDataCatalogRepository(container: container).importIfNeeded(upgraded), .imported)
        }
        func verifyCommittedUpgrade() throws {
            let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            lastContainer = reopened
            XCTAssertEqual(try records(CatalogImportState.self, in: reopened).map(\.lastImportedVersion),
                           [upgraded.value.version])
            XCTAssertEqual(try records(LessonDefinition.self, in: reopened).first {
                $0.id == seed.value.lessons[0].id
            }?.title, "Corrected lesson")
        }
        // SwiftData/Core Data can autorelease store owners after their Swift
        // scopes end. Drain them before the outer defer unlinks SQLite files.
        try autoreleasepool {
            try writeAndClose()
            try reopenAndCheck()
            try verifyCommittedUpgrade()
        }
        XCTAssertNil(lastContainer, "Final SwiftData container must deallocate before the test returns")
    }

    func testPrivateContextNeverSavesOrRollsBackUnrelatedUnsavedWork() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let independent = ModelContext(container)
        independent.autosaveEnabled = false
        let draft = try TaskItem(id: UUID(), title: "Unrelated edit", createdAt: Date())
        independent.insert(draft)
        let seed = try catalog()
        XCTAssertThrowsError(try SwiftDataCatalogRepository(container: container,
                         beforeSave: { throw Injected.failure }).importIfNeeded(seed))
        XCTAssertTrue(independent.hasChanges)
        XCTAssertTrue(try records(TaskItem.self, in: container).isEmpty)
        XCTAssertEqual(try SwiftDataCatalogRepository(container: container).importIfNeeded(seed), .imported)
        XCTAssertTrue(try records(TaskItem.self, in: container).isEmpty)
        try independent.save()
        XCTAssertEqual(try records(TaskItem.self, in: container).map(\.id), [draft.id])
    }
}
