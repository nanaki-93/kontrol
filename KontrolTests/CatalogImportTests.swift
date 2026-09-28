import Foundation
import SQLite3
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
        value.lessons[0].objective = "Corrected human-readable learning objective."
        value.lessons[0].contentVersion += 1
        value.lessons[0].explanation = "Updated explanation"
        value.lessons[0].normalizedContentHash = CatalogValidator.fingerprint(for: value.lessons[0])
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
        sameVersion.lessons[0].objective = "Not an imported objective"
        sameVersion.lessons[0].contentVersion += 1
        sameVersion.lessons[0].explanation = "Unreleased teaching revision"
        sameVersion.lessons[0].normalizedContentHash = CatalogValidator.fingerprint(for: sameVersion.lessons[0])
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(sameVersion)), .unchanged)
        let unchanged = try XCTUnwrap(records(LessonDefinition.self, in: container).first {
            $0.id == seed.value.lessons[0].id
        })
        XCTAssertEqual(unchanged.title, seed.value.lessons[0].title)
        XCTAssertEqual(unchanged.objective, seed.value.lessons[0].objective)
        XCTAssertEqual(unchanged.explanation, seed.value.lessons[0].explanation)
        XCTAssertEqual(unchanged.contentVersion, seed.value.lessons[0].contentVersion)
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
        let originalSlots = try repository.loadSnapshot().slots
        XCTAssertEqual(originalSlots.count, 20)
        let oldDefinition = try XCTUnwrap(records(LessonDefinition.self, in: container).first {
            $0.id == original.value.lessons[0].id
        })
        let oldTopic = try XCTUnwrap(records(Topic.self, in: container).first {
            $0.id == original.value.topics[0].id
        })
        XCTAssertEqual(oldDefinition.objective, original.value.lessons[0].objective)
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
        let startedID = original.value.lessons[1].id
        let dismissedID = original.value.lessons[2].id
        let availableID = original.value.lessons[3].id
        let draftID = UUID()
        personal.insert(LessonProgress(lessonID: startedID, status: .started,
                                       firstShownAt: timestamp, startedAt: timestamp, lastOpenedAt: timestamp))
        personal.insert(LessonProgress(lessonID: dismissedID, status: .dismissed,
                                       firstShownAt: timestamp, dismissedAt: timestamp, lastOpenedAt: timestamp))
        personal.insert(LessonProgress(lessonID: availableID, status: .available, firstShownAt: timestamp))
        personal.insert(LessonAttempt(id: draftID, lessonID: startedID,
                                      contentVersion: original.value.lessons[1].contentVersion,
                                      answerDraft: "unfinished private draft"))
        try personal.save()

        var updated = try revised(original).value
        let removedID = try XCTUnwrap(updated.lessons.last?.id)
        // Keep one lesson per topic in the updated bundle; historical rows must survive.
        if updated.lessons.count > 1 { updated.lessons.removeLast() }
        let upgrade = try CatalogValidator.validate(updated)
        XCTAssertEqual(try repository.importIfNeeded(upgrade), .imported)
        let upgradedSlots = try repository.loadSnapshot().slots
        let invalidatedKeys = Set(originalSlots.filter {
            $0.lessonID == lessonID || $0.lessonID == dismissedID
        }.map(\.key))
        XCTAssertEqual(upgradedSlots.filter { !invalidatedKeys.contains($0.key) },
                       originalSlots.filter { !invalidatedKeys.contains($0.key) })
        XCTAssertFalse(upgradedSlots.map(\.lessonID).contains(lessonID))
        XCTAssertFalse(upgradedSlots.map(\.lessonID).contains(dismissedID))
        let definitions = try records(LessonDefinition.self, in: container)
        XCTAssertEqual(definitions.count, original.value.lessons.count)
        let corrected = try XCTUnwrap(definitions.first { $0.id == lessonID })
        XCTAssertEqual(corrected.persistentModelID, oldIdentity)
        XCTAssertEqual(corrected.title, "Corrected lesson")
        XCTAssertEqual(corrected.objective, "Corrected human-readable learning objective.")
        XCTAssertEqual(corrected.explanation, "Updated explanation")
        XCTAssertEqual(corrected.contentVersion, original.value.lessons[0].contentVersion + 1)
        XCTAssertEqual(corrected.normalizedContentHash, CatalogValidator.fingerprint(for: updated.lessons[0]))
        XCTAssertEqual(try records(Topic.self, in: container).first { $0.id == oldTopic.id }?.persistentModelID, topicIdentity)
        XCTAssertEqual(try records(Topic.self, in: container).first { $0.id == oldTopic.id }?.name, "Corrected topic")
        XCTAssertEqual(try records(Subtopic.self, in: container).first { $0.id == updated.subtopics[0].id }?.name, "Corrected subtopic")
        XCTAssertEqual(try records(Concept.self, in: container).first { $0.id == updated.concepts[0].id }?.name, "Corrected concept")
        XCTAssertNotNil(definitions.first { $0.id == removedID })
        let allProgress = try records(LessonProgress.self, in: container)
        let allAttempts = try records(LessonAttempt.self, in: container)
        XCTAssertEqual(allProgress.count, 4)
        XCTAssertEqual(allAttempts.count, 2)
        let progress = try XCTUnwrap(allProgress.first { $0.lessonID == lessonID })
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.firstShownAt, timestamp)
        XCTAssertEqual(progress.startedAt, timestamp)
        XCTAssertEqual(progress.completedAt, timestamp)
        XCTAssertEqual(progress.lastOpenedAt, timestamp)
        let attempt = try XCTUnwrap(allAttempts.first { $0.id == attemptID })
        XCTAssertEqual(attempt.id, attemptID)
        XCTAssertEqual(attempt.answerDraft, "personal answer")
        XCTAssertEqual(attempt.contentVersion, original.value.lessons[0].contentVersion)
        XCTAssertEqual(attempt.solutionRevealedAt, timestamp)
        XCTAssertEqual(attempt.selfCheckAcknowledgedAt, timestamp)
        XCTAssertEqual(attempt.completedAt, timestamp)
        XCTAssertEqual(attempt.completedContentSnapshot, snapshot)
        let draft = try XCTUnwrap(allAttempts.first { $0.id == draftID })
        XCTAssertEqual(draft.lessonID, startedID)
        XCTAssertEqual(draft.contentVersion, original.value.lessons[1].contentVersion)
        XCTAssertEqual(draft.answerDraft, "unfinished private draft")
        XCTAssertNil(draft.completedAt)
        XCTAssertNil(draft.completedContentSnapshot)
        let started = try XCTUnwrap(allProgress.first { $0.lessonID == startedID })
        XCTAssertEqual(started.status, .started)
        XCTAssertEqual(started.firstShownAt, timestamp)
        XCTAssertEqual(started.startedAt, timestamp)
        XCTAssertEqual(started.lastOpenedAt, timestamp)
        let dismissed = try XCTUnwrap(allProgress.first { $0.lessonID == dismissedID })
        XCTAssertEqual(dismissed.status, .dismissed)
        XCTAssertEqual(dismissed.firstShownAt, timestamp)
        XCTAssertEqual(dismissed.dismissedAt, timestamp)
        XCTAssertEqual(dismissed.lastOpenedAt, timestamp)
        let available = try XCTUnwrap(allProgress.first { $0.lessonID == availableID })
        XCTAssertEqual(available.status, .available)
        XCTAssertEqual(available.firstShownAt, timestamp)
        XCTAssertNil(available.startedAt)
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [updated.version])
        XCTAssertThrowsError(try repository.importIfNeeded(original)) {
            XCTAssertEqual($0 as? CatalogImportError,
                           .downgrade(installed: updated.version, requested: original.value.version))
        }
        XCTAssertEqual(try records(LessonDefinition.self, in: container).first { $0.id == lessonID }?.title,
                       "Corrected lesson")
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [updated.version])
    }

    // Recreate the released five-lesson catalog import in a V1-only store, then
    // migrate its closed copy through the production factory before importing V2.
    // V1 had no objective; Java and Design also had older provenance strings.
    func testMigratedRealV1CatalogImportsPackagedV2WithoutLosingPersonalRecords() throws {
        let bundled = try catalog()
        let retainedIDs = ["go.concurrency.cancel-work.v1", "java.io.resource-ownership.v1",
                           "design.api.deduplicate-writes.v1", "perf.database.query-count.v1",
                           "security.api.object-access.v1"]
        let oldProvenance = [
            "java.io.resource-ownership.v1": "Original Kontrol starter lesson; docs/learning-curriculum.md: Java / Resource cleanup; Java AutoCloseable and try-with-resources semantics",
            "design.api.deduplicate-writes.v1": "Original Kontrol starter lesson; docs/learning-curriculum.md: System Design / API idempotency; design exercise, not a provider-specific guarantee"
        ]
        let historical = try retainedIDs.map { id in
            try XCTUnwrap(bundled.value.lessons.first { $0.id == id })
        }
        XCTAssertEqual(historical.map(\.contentVersion), [2, 2, 2, 2, 2],
                       "Every retained V1 definition gained an objective in V2")
        // Pin the released V1 teaching payloads, not merely the current bundle:
        // if any section changes again this test must not invent a fake V1 import.
        XCTAssertEqual(historical.map(\.normalizedContentHash), [
            "sha256:e752c4c155eb0a0f7b546726ff2e2f706c1e13ef77ceb0c81ded95df913b5ef7",
            "sha256:3a896f4abee568c12881fbce54f408e70df65621df21ecf25e92d0778a044b87",
            "sha256:3c0784dc9be939e19d8c07567c7feb6991def39b54683ddfcb0265abfb5e9b09",
            "sha256:48ca55e36d2add08c36abd665bc7359cc6c5a45bb7e422cc9bf6bec80171d921",
            "sha256:e9fc9e61a77c3fa51be8d9b4f26eeea61f4dc61ab1c54659e48215a7ecb34fb4"
        ])
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_003_600)
        let draftID = UUID(), completedID = UUID()
        let snapshot = KontrolSchemaV1.LessonContentSnapshot(
            title: historical[0].title, objectiveKey: historical[0].objectiveKey,
            conceptIDs: historical[0].conceptIDs, difficulty: historical[0].difficulty,
            format: historical[0].format, explanation: historical[0].explanation,
            workedExample: historical[0].workedExample, exercise: historical[0].exercise,
            referenceAnswer: historical[0].referenceAnswer,
            selfCheckCriteria: historical[0].selfCheckCriteria)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Kontrol-V1-Catalog-Upgrade-\(UUID().uuidString)", isDirectory: true)
        let writerURL = root.appendingPathComponent("writer/Kontrol.store")
        let copyURL = root.appendingPathComponent("copy/Kontrol.store")
        try FileManager.default.createDirectory(at: writerURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV1.self)
            let config = ModelConfiguration(schema: schema, url: writerURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let oldTopicIDs = Set(historical.map(\.topicID))
            let oldSubtopicIDs = Set(historical.map(\.subtopicID))
            let oldConceptIDs = Set(historical.flatMap(\.conceptIDs))
            for topic in bundled.value.topics where oldTopicIDs.contains(topic.id) {
                context.insert(Topic(id: topic.id, name: topic.name))
            }
            for subtopic in bundled.value.subtopics where oldSubtopicIDs.contains(subtopic.id) {
                context.insert(Subtopic(id: subtopic.id, topicID: subtopic.topicID, name: subtopic.name))
            }
            for concept in bundled.value.concepts where oldConceptIDs.contains(concept.id) {
                context.insert(Concept(id: concept.id, subtopicID: concept.subtopicID,
                                       name: concept.name, prerequisiteConceptIDs: concept.prerequisiteConceptIDs))
            }
            for item in historical {
                context.insert(KontrolSchemaV1.LessonDefinition(
                    id: item.id, objectiveKey: item.objectiveKey, title: item.title,
                    topicID: item.topicID, subtopicID: item.subtopicID, conceptIDs: item.conceptIDs,
                    difficulty: item.difficulty, format: item.format, estimatedMinutes: item.estimatedMinutes,
                    prerequisiteConceptIDs: item.prerequisiteConceptIDs, explanation: item.explanation,
                    workedExample: item.workedExample, exercise: item.exercise,
                    referenceAnswer: item.referenceAnswer, selfCheckCriteria: item.selfCheckCriteria,
                    contentVersion: 1, normalizedContentHash: item.normalizedContentHash,
                    source: item.source, provenance: oldProvenance[item.id] ?? item.provenance))
            }
            context.insert(CatalogImportState(catalogID: bundled.value.catalogID, lastImportedVersion: 1))
            for (index, status) in [KontrolSchemaV1.ProgressStatus.completed, .started, .dismissed, .available].enumerated() {
                context.insert(LessonProgress(lessonID: historical[index].id, status: status,
                    firstShownAt: time, startedAt: index < 2 ? later : nil,
                    completedAt: index == 0 ? later : nil,
                    dismissedAt: index == 2 ? later : nil, lastOpenedAt: later))
            }
            context.insert(LessonAttempt(id: completedID, lessonID: historical[0].id,
                contentVersion: 1, answerDraft: "kept completed answer",
                solutionRevealedAt: time, selfCheckAcknowledgedAt: later, completedAt: later,
                completedContentSnapshot: snapshot))
            context.insert(LessonAttempt(id: draftID, lessonID: historical[1].id,
                contentVersion: 1, answerDraft: "kept unfinished draft"))
            try context.save()
        }
        // SwiftData can retain WAL handles after the writer scope ends. SQLite
        // backup makes a transactionally complete closed copy for migration.
        func copyClosedV1() throws {
            var input: OpaquePointer?, output: OpaquePointer?
            guard sqlite3_open_v2(writerURL.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let input { sqlite3_close(input) }
                throw NSError(domain: "V1CatalogBackup", code: 1)
            }
            defer { sqlite3_close(input) }
            guard sqlite3_open_v2(copyURL.path, &output,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                if let output { sqlite3_close(output) }
                throw NSError(domain: "V1CatalogBackup", code: 2)
            }
            defer { sqlite3_close(output) }
            guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
                throw NSError(domain: "V1CatalogBackup", code: 3)
            }
            var step: Int32 = SQLITE_BUSY
            for _ in 0..<100 {
                step = sqlite3_backup_step(backup, -1)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_BUSY || step == SQLITE_LOCKED || step == SQLITE_OK else { break }
                sqlite3_sleep(10)
            }
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                throw NSError(domain: "V1CatalogBackup", code: Int(step))
            }
        }
        try copyClosedV1()

        func assertPersonal(_ container: ModelContainer) throws {
            let progress = try records(LessonProgress.self, in: container)
            XCTAssertEqual(progress.count, 4)
            for (index, status) in [KontrolSchemaV1.ProgressStatus.completed, .started, .dismissed, .available].enumerated() {
                let row = try XCTUnwrap(progress.first { $0.lessonID == historical[index].id })
                XCTAssertEqual(row.status, status)
                XCTAssertEqual(row.firstShownAt, time)
                XCTAssertEqual(row.startedAt, index < 2 ? later : nil)
                XCTAssertEqual(row.completedAt, index == 0 ? later : nil)
                XCTAssertEqual(row.dismissedAt, index == 2 ? later : nil)
                XCTAssertEqual(row.lastOpenedAt, later)
            }
            let attempts = try records(LessonAttempt.self, in: container)
            XCTAssertEqual(attempts.count, 2)
            let completed = try XCTUnwrap(attempts.first { $0.id == completedID })
            XCTAssertEqual(completed.lessonID, historical[0].id)
            XCTAssertEqual(completed.contentVersion, 1)
            XCTAssertEqual(completed.answerDraft, "kept completed answer")
            XCTAssertEqual(completed.solutionRevealedAt, time)
            XCTAssertEqual(completed.selfCheckAcknowledgedAt, later)
            XCTAssertEqual(completed.completedAt, later)
            XCTAssertEqual(completed.completedContentSnapshot, snapshot)
            let draft = try XCTUnwrap(attempts.first { $0.id == draftID })
            XCTAssertEqual(draft.lessonID, historical[1].id)
            XCTAssertEqual(draft.contentVersion, 1)
            XCTAssertEqual(draft.answerDraft, "kept unfinished draft")
            XCTAssertNil(draft.completedAt)
            XCTAssertNil(draft.completedContentSnapshot)
        }
        try autoreleasepool {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(copyURL))
            let before = try records(LessonDefinition.self, in: container)
            XCTAssertEqual(try records(Topic.self, in: container).count, 5)
            XCTAssertEqual(try records(Subtopic.self, in: container).count, 5)
            XCTAssertEqual(try records(Concept.self, in: container).count, 5)
            XCTAssertEqual(before.count, 5)
            for item in historical {
                let row = try XCTUnwrap(before.first { $0.id == item.id })
                XCTAssertEqual(row.objective, "")
                XCTAssertEqual(row.contentVersion, 1)
                XCTAssertEqual(row.provenance, oldProvenance[item.id] ?? item.provenance)
                XCTAssertEqual(row.normalizedContentHash, item.normalizedContentHash)
            }
            try assertPersonal(container)
            let identities = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.persistentModelID) })
            XCTAssertEqual(try SwiftDataCatalogRepository(container: container).importIfNeeded(bundled), .imported)
            XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [2])
            let after = try records(LessonDefinition.self, in: container)
            XCTAssertEqual(after.count, 40)
            for item in historical {
                let row = try XCTUnwrap(after.first { $0.id == item.id })
                XCTAssertEqual(row.persistentModelID, identities[item.id])
                XCTAssertEqual(row.objectiveKey, item.objectiveKey)
                XCTAssertEqual(row.objective, item.objective)
                XCTAssertEqual(row.contentVersion, 2)
                XCTAssertEqual(row.provenance, item.provenance)
            }
            try assertPersonal(container)
        }
        try autoreleasepool {
            let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(copyURL))
            XCTAssertEqual(try records(LessonDefinition.self, in: reopened).count, 40)
            XCTAssertEqual(try records(CatalogImportState.self, in: reopened).map(\.lastImportedVersion), [2])
            XCTAssertEqual(try SwiftDataCatalogRepository(container: reopened).importIfNeeded(bundled), .unchanged)
            try assertPersonal(reopened)
        }
        // Do not unlink the opened copy; SwiftData may still hold SQLite descriptors.
    }

    func testHigherVersionRejectsEveryDefinitionConflictBeforeMutatingAnything() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        var initial = try catalog().value
        initial.lessons[0].contentVersion += 1
        let seed = try CatalogValidator.validate(initial)
        XCTAssertEqual(try repository.importIfNeeded(seed), .imported)
        let id = seed.value.lessons[0].id
        let original = try XCTUnwrap(records(LessonDefinition.self, in: container).first { $0.id == id })
        let identity = original.persistentModelID

        func rejects(_ expected: CatalogImportError, _ change: (inout CatalogDTO) -> Void) throws {
            var candidate = seed.value
            candidate.version += 1
            candidate.topics[0].name = "Must not be partially updated"
            change(&candidate)
            let validated = try CatalogValidator.validate(candidate)
            XCTAssertThrowsError(try repository.importIfNeeded(validated)) {
                XCTAssertEqual($0 as? CatalogImportError, expected)
            }
            let retained = try XCTUnwrap(records(LessonDefinition.self, in: container).first { $0.id == id })
            XCTAssertEqual(retained.persistentModelID, identity)
            XCTAssertEqual(retained.title, seed.value.lessons[0].title)
            XCTAssertEqual(retained.objective, seed.value.lessons[0].objective)
            XCTAssertEqual(retained.contentVersion, seed.value.lessons[0].contentVersion)
            XCTAssertEqual(try records(Topic.self, in: container).first { $0.id == seed.value.topics[0].id }?.name,
                           seed.value.topics[0].name)
            XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion),
                           [seed.value.version])
        }

        try rejects(.lowerContentVersion) { $0.lessons[0].contentVersion -= 1 }
        try rejects(.unchangedContentVersionConflict) { $0.lessons[0].title = "Same-version title" }
        try rejects(.unchangedContentVersionConflict) { $0.lessons[0].objective = "Same-version objective" }
        try rejects(.unchangedContentVersionConflict) { $0.lessons[0].prerequisiteConceptIDs = [$0.lessons[0].conceptIDs[0]] }
        try rejects(.unchangedContentVersionConflict) {
            $0.lessons[0].explanation = "Changed teaching content"
            $0.lessons[0].normalizedContentHash = CatalogValidator.fingerprint(for: $0.lessons[0])
        }
        try rejects(.objectiveIdentityConflict) {
            $0.lessons[0].objectiveKey = "different.objective"
            $0.lessons[0].contentVersion += 1
        }

        // A future catalog may carry the identical definition without bumping its
        // per-lesson version; only the catalog release marker advances.
        var sameDefinition = seed.value
        sameDefinition.version += 1
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(sameDefinition)), .imported)
        XCTAssertEqual(try records(LessonDefinition.self, in: container).first { $0.id == id }?.persistentModelID,
                       identity)
    }

    func testGeneratedIDCollisionAndHistoricalEmptyObjectiveFallback() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let seed = try catalog()
        XCTAssertEqual(try repository.importIfNeeded(seed), .imported)
        let historicalID = seed.value.lessons[0].id
        let generatedID = seed.value.lessons[1].id
        let context = ModelContext(container)
        let stored = try context.fetch(FetchDescriptor<LessonDefinition>())
        let historical = try XCTUnwrap(stored.first { $0.id == historicalID })
        let generated = try XCTUnwrap(stored.first { $0.id == generatedID })
        historical.objective = "" // V3→V4 migrated definition, not a new import.
        generated.source = "generated"
        try context.save()
        let historicalIdentity = historical.persistentModelID
        let generatedIdentity = generated.persistentModelID

        var collision = seed.value
        collision.version += 1
        collision.lessons.removeAll { $0.id == historicalID }
        let collidedIndex = try XCTUnwrap(collision.lessons.firstIndex { $0.id == generatedID })
        collision.lessons[collidedIndex].contentVersion += 1
        XCTAssertThrowsError(try repository.importIfNeeded(CatalogValidator.validate(collision))) {
            XCTAssertEqual($0 as? CatalogImportError, .generatedIDCollision)
        }
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion),
                       [seed.value.version])
        XCTAssertEqual(try records(LessonDefinition.self, in: container).first { $0.id == generatedID }?.source,
                       "generated")
        XCTAssertEqual(try records(LessonDefinition.self, in: container).first { $0.id == generatedID }?.persistentModelID,
                       generatedIdentity)

        // Retained V3 rows can still display their objectiveKey as fallback. A
        // changed objective on an included row requires a content-version bump.
        var retained = seed.value
        retained.version += 1
        retained.lessons.removeAll { $0.id == historicalID || $0.id == generatedID }
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(retained)), .imported)
        let old = try XCTUnwrap(records(LessonDefinition.self, in: container).first { $0.id == historicalID })
        XCTAssertEqual(old.persistentModelID, historicalIdentity)
        XCTAssertEqual(old.objective, "")
        XCTAssertEqual(old.objective.isEmpty ? old.objectiveKey : old.objective, seed.value.lessons[0].objectiveKey)
        var premature = retained
        premature.version += 1
        premature.lessons.append(seed.value.lessons[0])
        XCTAssertThrowsError(try repository.importIfNeeded(CatalogValidator.validate(premature))) {
            XCTAssertEqual($0 as? CatalogImportError, .unchangedContentVersionConflict)
        }
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion),
                       [retained.version])
        var corrected = retained
        corrected.version += 1
        var revisedHistorical = seed.value.lessons[0]
        revisedHistorical.contentVersion += 1
        corrected.lessons.append(revisedHistorical)
        XCTAssertEqual(try repository.importIfNeeded(CatalogValidator.validate(corrected)), .imported)
        let updated = try XCTUnwrap(records(LessonDefinition.self, in: container).first { $0.id == historicalID })
        XCTAssertEqual(updated.persistentModelID, historicalIdentity)
        XCTAssertEqual(updated.objective, revisedHistorical.objective)
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
        XCTAssertThrowsError(try CatalogValidator.validate(malformed)) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.missingAnswer))
        }
        var altered = upgraded.value
        altered.lessons[1].exercise += " Unhashed revision."
        XCTAssertThrowsError(try CatalogValidator.validate(altered)) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.invalidFingerprint))
        }
        XCTAssertEqual(try records(LessonDefinition.self, in: container).count, seed.value.lessons.count)
        XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion), [seed.value.version])
        let committedSlots = try repository.loadSnapshot().slots
        XCTAssertEqual(committedSlots.count, 20)
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
            XCTAssertEqual(try repository.loadSnapshot().slots, committedSlots)
        }
        // A failed first import must not leave even a marker or a partial row.
        let empty = try ModelContainerFactory().makeContainer(mode: .inMemory)
        XCTAssertThrowsError(try SwiftDataCatalogRepository(container: empty,
                         save: { _ in throw Injected.failure }).importIfNeeded(seed))
        XCTAssertTrue(try records(Topic.self, in: empty).isEmpty)
        XCTAssertTrue(try records(CatalogImportState.self, in: empty).isEmpty)
        XCTAssertTrue(try records(LessonSlot.self, in: empty).isEmpty)
        XCTAssertEqual(try repository.importIfNeeded(upgraded), .imported)
        XCTAssertEqual(try repository.loadSnapshot().slots, committedSlots)
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
            XCTAssertEqual(try repository.loadSnapshot().slots.count, 20)
        }
        func reopenAndCheck() throws {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
            XCTAssertEqual(try records(CatalogImportState.self, in: container).map(\.lastImportedVersion),
                           [seed.value.version])
            XCTAssertEqual(try SwiftDataCatalogRepository(container: container).loadSnapshot().slots.count, 20)
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
