import Foundation
import SwiftData
import SQLite3
import XCTest
@testable import Kontrol

@MainActor
final class AppPreferencesMigrationTests: XCTestCase {
    private let factory = ModelContainerFactory()
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolPreferencesMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func files(in directory: URL) throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]).filter {
                try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
        return try Dictionary(uniqueKeysWithValues: urls.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    // Compare every persisted user field, including opaque payload bytes and the
    // primary row ID, rather than sampling only a title per feature. Internal
    // Core Data entity ordinals / optimistic-lock counters are not user data.
    private enum Cell: Equatable {
        case null, integer(Int64), real(Double), text(String), blob(Data)
    }
    private typealias StoreRows = [String: [[String: Cell]]]

    private func rows(at url: URL, tables: [String]? = nil) throws -> StoreRows {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            throw NSError(domain: "MigrationSnapshot", code: Int(opened))
        }
        func error(_ status: Int32, operation: String) -> NSError {
            NSError(domain: "MigrationSnapshot", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "\(operation): \(String(cString: sqlite3_errmsg(database)))"
            ])
        }
        // Core Data can briefly hold SQLite locks during store setup/checkpointing.
        // Wait for those locks, not a fixed sleep; permanent contention still fails.
        let timeout = sqlite3_busy_timeout(database, 5_000)
        guard timeout == SQLITE_OK else { throw error(timeout, operation: "busy timeout") }
        let begun = sqlite3_exec(database, "BEGIN DEFERRED TRANSACTION", nil, nil, nil)
        guard begun == SQLITE_OK else { throw error(begun, operation: "begin snapshot") }
        // All tables belong to one read snapshot. Always release it before close,
        // including on query errors, so the reader cannot block the next migration.
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        func query(_ sql: String) throws -> [[String: Cell]] {
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepared == SQLITE_OK, let statement else {
                throw error(prepared, operation: "prepare \(sql)")
            }
            defer { sqlite3_finalize(statement) }
            var result: [[String: Cell]] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                var row: [String: Cell] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    guard name != "Z_ENT", name != "Z_OPT" else { continue }
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        row[name] = .blob(count == 0 ? Data() : Data(
                            bytes: sqlite3_column_blob(statement, index)!, count: count))
                    default: row[name] = .null
                    }
                }
                result.append(row)
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else {
                throw error(status, operation: "step \(sql)")
            }
            return result
        }
        let names: [String]
        if let tables {
            names = tables
        } else {
            names = try query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .compactMap { row in
                    guard case .text(let name) = row["name"], name.hasPrefix("Z"),
                          !["Z_METADATA", "Z_MODELCACHE", "Z_PRIMARYKEY"].contains(name) else { return nil }
                    return name
                }
        }
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try query("SELECT * FROM \"\(name)\" ORDER BY Z_PK"))
        })
    }

    func testRichV9MigratesWithAllFieldsAndRowIdentitiesUnchangedAcrossReopen() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Kontrol.store")
        let taskID = UUID(), focusID = UUID(), feedID = UUID()
        let (identity, before): (PersistentIdentifier, StoreRows) = try autoreleasepool {
            let schema = Schema(versionedSchema: KontrolSchemaV9.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let task = try TaskItem(id: taskID, title: "Existing task", createdAt: when,
                notes: "Exact notes\n  preserved", dueAt: when.addingTimeInterval(3600),
                plannedDay: .init(calendarIdentifier: "gregorian", year: 2026, month: 9, day: 30),
                plannedTimeZoneID: "Pacific/Auckland", completedAt: when)
            context.insert(task)
            context.insert(ScheduleBlock(id: UUID(), title: "Plan", startAt: when,
                endAt: when.addingTimeInterval(3600), note: "Keep plan", lessonID: "lesson",
                linkedTitleSnapshot: "Original lesson"))
            context.insert(FocusSession(id: focusID, state: "paused", plannedSeconds: 900,
                accumulatedActiveSeconds: 23.5, pausedAt: when, startedAt: when,
                checkpointAt: when, recoveryRequired: true, linkedTaskID: taskID,
                linkedTitleSnapshot: "Original task"))
            context.insert(FocusSession(id: UUID(), state: "running", plannedSeconds: 3000,
                accumulatedActiveSeconds: 4.25, activeSegmentStartedAt: when,
                deadline: when.addingTimeInterval(2995.75), startedAt: when, checkpointAt: when,
                linkedLessonID: "lesson", linkedTitleSnapshot: "Original lesson"))
            context.insert(Topic(id: "go", name: "Learning Go"))
            context.insert(Subtopic(id: "go.base", topicID: "go", name: "Basics"))
            context.insert(Concept(id: "concept", subtopicID: "go.base", name: "Concept",
                prerequisiteConceptIDs: ["prior"]))
            context.insert(LessonDefinition(id: "lesson", objectiveKey: "objective", title: "Lesson",
                topicID: "go", subtopicID: "go.base", conceptIDs: ["concept"], difficulty: "basic",
                format: "learn", estimatedMinutes: 10, prerequisiteConceptIDs: ["prior"],
                explanation: "Existing explanation", workedExample: "Example", exercise: "Exercise",
                referenceAnswer: "Answer", selfCheckCriteria: ["Check"], contentVersion: 3,
                normalizedContentHash: "digest", source: "seed", provenance: "catalog", objective: "Goal"))
            context.insert(LessonProgress(lessonID: "lesson", status: .completed,
                firstShownAt: when, startedAt: when, completedAt: when, lastOpenedAt: when))
            let completed = KontrolSchemaV1.LessonContentSnapshot(title: "Original lesson",
                objectiveKey: "objective", conceptIDs: ["concept"], difficulty: "basic", format: "learn",
                explanation: "Old explanation", workedExample: "Old example", exercise: "Old exercise",
                referenceAnswer: "Old answer", selfCheckCriteria: ["Old check"])
            // Migration must preserve even opaque pins verbatim, not interpret or repair them.
            context.insert(LessonAttempt(id: UUID(), lessonID: "lesson", contentVersion: 2,
                answerDraft: "Exact answer\n  trailing  ", solutionRevealedAt: when,
                selfCheckAcknowledgedAt: when, completedAt: when, completedContentSnapshot: completed,
                pinnedContentData: Data([0, 1, 255, 42]), revision: 7))
            context.insert(CatalogImportState(catalogID: "starter", lastImportedVersion: 3))
            context.insert(LessonSlot(topicID: "go", slotIndex: 2, lessonID: "lesson", assignedAt: when))
            context.insert(try LessonTerminalRecord(metadata: LessonTerminalMetadata(
                lessonID: "lesson", provenance: .legacyCompletedPartial, title: "Original lesson",
                topicID: nil, subtopicID: nil, contentVersion: 2, objectiveKey: "objective",
                conceptIDs: ["concept"], normalizedContentHash: nil, format: nil,
                dismissalTimeDefinition: nil)))
            context.insert(try CatalogMembership(membership: CurrentCatalogMembership(
                catalogID: "starter", catalogVersion: 3, topicIDs: ["go"], subtopicIDs: ["go.base"],
                conceptIDs: ["concept"], seededLessonIDs: ["lesson"])))
            context.insert(AISettingsRecord(enabled: true, modelID: "model",
                credentialReference: "isolated-test-reference", revision: UUID()))
            context.insert(ProjectReference(manifestID: "project", bookmarkData: Data([0, 255, 42]),
                displayOrder: 2, displayNameHint: "Unavailable project", lastSuccessfulReadAt: when))
            let topics = try NewsRecordPayload.encodeTopics(["go"])
            context.insert(NewsPreferencesRecord(catalogVersion: 2, selectedTopicIDsPayload: topics,
                lastRefreshAt: when))
            context.insert(NewsFeedRecord(id: feedID, name: "Feed", endpoint: "https://example.com/rss",
                topicIDsPayload: topics, isEnabled: false, etag: "etag", lastModified: "modified",
                lastAttemptAt: when, lastSuccessAt: when, lastErrorCode: "offline",
                retryNotBefore: when.addingTimeInterval(60)))
            context.insert(NewsArticleRecord(url: "https://example.com/article",
                canonicalURL: "https://example.com/article", title: "Cached title", publishedAt: when,
                firstFetchedAt: when, summary: "Keep summary", provenancePayload:
                    try NewsRecordPayload.encodeContributions([.init(feedID: feedID, feedName: "Feed",
                        topicIDs: ["go"], guids: ["guid"], metadata: .init(
                            url: "https://example.com/article", canonicalURL: "https://example.com/article",
                            title: "Cached title", publishedAt: when, summary: "Keep summary"))])))
            try context.save()
            // Snapshot the saved disk rows while the owner is still alive. Merely
            // leaving an autoreleasepool does not await Core Data's async teardown.
            return try withExtendedLifetime(container) {
                (task.persistentModelID, try rows(at: url))
            }
        }
        XCTAssertEqual(before.count, KontrolSchemaV9.models.count)
        XCTAssertTrue(before.values.allSatisfy { !$0.isEmpty }, "Every V9 model must have preservation evidence")
        for _ in 0..<3 {
            try autoreleasepool {
                let container = try factory.makeContainer(mode: .persistent(url))
                let context = ModelContext(container)
                context.autosaveEnabled = false
                XCTAssertTrue(try context.fetch(FetchDescriptor<AppPreferencesRecord>()).isEmpty)
                let task = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
                XCTAssertEqual(task.id, taskID)
                XCTAssertEqual(task.persistentModelID.entityName, identity.entityName)
                XCTAssertEqual(task.persistentModelID.storeIdentifier, identity.storeIdentifier)
                XCTAssertEqual(try context.fetch(FetchDescriptor<FocusSession>()).count, 2)
                XCTAssertEqual(try context.fetch(FetchDescriptor<LessonTerminalRecord>()).first?.metadata().title,
                    "Original lesson")
                XCTAssertEqual(try context.fetch(FetchDescriptor<CatalogMembership>()).first?.membership().catalogVersion, 3)
                XCTAssertFalse(context.hasChanges)
                try withExtendedLifetime(container) {
                    XCTAssertEqual(try rows(at: url, tables: before.keys.sorted()), before)
                }
            }
        }
    }

    func testCopiedHistoricalFixturesOpenV10RepeatedlyWithoutChangingSourceBytes() throws {
        for version in ["V1", "V2", "V3", "V4"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: version, withExtension: nil))
            let original = try files(in: source)
            XCTAssertNotNil(original["Kontrol.store"])
            let folder = try directory()
            defer { try? FileManager.default.removeItem(at: folder) }
            // Include the complete SQLite sidecar set; never open the source fixture.
            for name in original.keys {
                try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                    to: folder.appendingPathComponent(name))
            }
            for _ in 0..<2 {
                try autoreleasepool {
                    let context = ModelContext(try factory.makeContainer(mode: .persistent(
                        folder.appendingPathComponent("Kontrol.store"))))
                    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
                    if version == "V4" {
                        XCTAssertTrue(tasks.isEmpty)
                        let definition = try XCTUnwrap(context.fetch(FetchDescriptor<LessonDefinition>()).first)
                        XCTAssertEqual(definition.id, "v4-lesson")
                        XCTAssertEqual(definition.objective, "Explain frozen V4 persistence")
                        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonSlot>()).first?.lessonID, "v4-lesson")
                    } else {
                        XCTAssertEqual(tasks.count, 1)
                        XCTAssertEqual(tasks.first?.title, version == "V1" ? "V1 reopen fixture" : "\(version) fixture task")
                    }
                    XCTAssertTrue(try context.fetch(FetchDescriptor<AppPreferencesRecord>()).isEmpty)
                    XCTAssertFalse(context.hasChanges)
                }
            }
            XCTAssertEqual(try files(in: source), original, "\(version) fixture files must remain byte-identical")
        }
    }

    func testV10PreferenceDefaultsAndCustomScalarValuesSurviveDistinctOpens() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Kontrol.store")
        let revision = UUID()
        try autoreleasepool {
            let context = ModelContext(try factory.makeContainer(mode: .persistent(url)))
            XCTAssertTrue(try context.fetch(FetchDescriptor<AppPreferencesRecord>()).isEmpty)
            let record = AppPreferencesRecord(revision: revision)
            XCTAssertEqual(record.key, AppPreferencesRecord.singletonKey)
            XCTAssertEqual(record.payloadVersion, AppPreferences.currentPayloadVersion)
            XCTAssertEqual(record.focusDefaultMinutes, AppPreferences.defaults.focusDefaultMinutes)
            XCTAssertEqual(record.textSize, AppPreferences.defaults.textSize.rawValue)
            XCTAssertEqual(record.reduceMotion, AppPreferences.defaults.reduceMotion.rawValue)
            record.focusDefaultMinutes = 37
            record.textSize = "large"
            record.reduceMotion = "reduce"
            context.insert(record)
            try context.save()
        }
        for _ in 0..<2 {
            try autoreleasepool {
                let context = ModelContext(try factory.makeContainer(mode: .persistent(url)))
                let records = try context.fetch(FetchDescriptor<AppPreferencesRecord>())
                XCTAssertEqual(records.count, 1)
                let record = try XCTUnwrap(records.first)
                XCTAssertEqual(record.key, "app.preferences")
                XCTAssertEqual(record.payloadVersion, 1)
                XCTAssertEqual(record.focusDefaultMinutes, 37)
                XCTAssertEqual(record.textSize, "large")
                XCTAssertEqual(record.reduceMotion, "reduce")
                XCTAssertEqual(record.revision, revision)
            }
        }
    }

    func testRepeatedFailedOpensPreserveStoreAndExistingSidecarBytes() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Kontrol.store", "Kontrol.store-wal", "Kontrol.store-shm"] {
            try Data("Invalid SQLite file: preserve \(name)".utf8).write(to: folder.appendingPathComponent(name))
        }
        let before = try files(in: folder)
        for _ in 0..<2 {
            XCTAssertThrowsError(try factory.makeContainer(mode: .persistent(folder.appendingPathComponent("Kontrol.store"))))
            let after = try files(in: folder)
            for (name, bytes) in before { XCTAssertEqual(after[name], bytes, "Do not replace \(name)") }
        }
    }
}
