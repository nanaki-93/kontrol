import Foundation
import SwiftData
import XCTest
@testable import Kontrol

/// Detached domain validation and durable, revision-checked persistence.
@MainActor
final class AppPreferencesRepositoryTests: XCTestCase {
    private let factory = ModelContainerFactory()

    private func temporaryStoreDirectory() -> URL {
        // SwiftData has no public synchronous close. Even after autoreleasepool
        // drains, Core Data can still own SQLite handles on its worker queue.
        // Keep isolated files until the test host exits; the QA command removes
        // this exact process-owned root afterwards, never a live store/sidecar.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KontrolPreferencesTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        print("Preferences test store cleanup after host exit: \(root.path)")
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func withStore(_ operation: (ModelContainer, URL) throws -> Void) throws {
        let directory = temporaryStoreDirectory()
        try autoreleasepool {
            try operation(reopen(directory), directory)
        }
    }

    private func reopen(_ directory: URL) throws -> ModelContainer {
        try factory.makeContainer(mode: .persistent(directory.appendingPathComponent("Kontrol.store")))
    }

    // SQLite's shared-memory lock/read marks are not durable data. Check the
    // database and WAL bytes before reopening (which may checkpoint the WAL).
    private func durableBytes(_ directory: URL) throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent == "Kontrol.store" || $0.lastPathComponent == "Kontrol.store-wal"
            }
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "Kontrol.store" })
        return try Dictionary(uniqueKeysWithValues: urls.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    private struct StoredRow: Equatable {
        let key: String
        let payloadVersion: Int
        let focusDefaultMinutes: Int
        let textSize: String
        let reduceMotion: String
        let revision: UUID
    }

    private func storedRows(_ container: ModelContainer) throws -> [StoredRow] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try context.fetch(FetchDescriptor<AppPreferencesRecord>()).map {
            StoredRow(key: $0.key, payloadVersion: $0.payloadVersion,
                focusDefaultMinutes: $0.focusDefaultMinutes, textSize: $0.textSize,
                reduceMotion: $0.reduceMotion, revision: $0.revision)
        }.sorted { $0.key < $1.key }
    }

    private func draft(_ minutes: String = "17", textSize: AppTextSize = .large,
                       motion: AppReduceMotion = .reduce) -> AppPreferencesDraft {
        var draft = AppPreferencesDraft()
        draft.focusDefaultMinutes = minutes
        draft.textSize = textSize
        draft.reduceMotion = motion
        return draft
    }

    func testAbsentLoadsDefaultsWithoutInsertingOrChangingBytesAcrossReopen() throws {
        try withStore { container, directory in
            var saves = 0
            let repository = SwiftDataAppPreferencesRepository(container: container, beforeSave: { saves += 1 })
            let before = try durableBytes(directory)
            for _ in 0..<3 { XCTAssertEqual(try repository.load(), .defaults) }
            XCTAssertEqual(saves, 0)
            XCTAssertEqual(try storedRows(container), [])
            XCTAssertEqual(try durableBytes(directory), before)
            let reopened = try reopen(directory)
            XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: reopened).load(), .defaults)
            XCTAssertEqual(try storedRows(reopened), [])
        }
    }

    func testFirstSaveAndUpdateReturnDurableReceiptsAcrossClosedContainerReopen() throws {
        let directory = temporaryStoreDirectory()
        let first = try autoreleasepool {
            let container = try reopen(directory)
            let repository = SwiftDataAppPreferencesRepository(container: container)
            let first = try repository.save(draft(), expectedRevision: nil)
            XCTAssertNotNil(first.revision)
            XCTAssertEqual(first.preferences, try draft().validated())
            XCTAssertEqual(try repository.load(), first)
            XCTAssertEqual(try storedRows(container).count, 1)
            return first
        }
        let second = try autoreleasepool {
            let container = try reopen(directory)
            let repository = SwiftDataAppPreferencesRepository(container: container)
            XCTAssertEqual(try repository.load(), first)
            let second = try repository.save(draft("50", textSize: .system, motion: .system),
                                             expectedRevision: first.revision)
            XCTAssertNotNil(second.revision)
            XCTAssertNotEqual(second.revision, first.revision)
            XCTAssertEqual(second.preferences, try AppPreferences(focusDefaultMinutes: 50))
            XCTAssertEqual(try repository.load(), second)
            XCTAssertEqual(try storedRows(container).count, 1)
            return second
        }
        try autoreleasepool {
            let container = try reopen(directory)
            XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: container).load(), second)
            let rows = try storedRows(container)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.key, AppPreferencesRecord.singletonKey)
            XCTAssertEqual(rows.first?.revision, second.revision)
        }
    }

    func testTwoEditorsRejectStaleInitialAndUpdateSavesAndReloadFreshState() throws {
        try withStore { container, directory in
            let editorA = SwiftDataAppPreferencesRepository(container: container)
            var savesB = 0
            let editorB = SwiftDataAppPreferencesRepository(container: container, beforeSave: { savesB += 1 })
            XCTAssertEqual(try editorA.load(), .defaults)
            XCTAssertEqual(try editorB.load(), .defaults)
            invalid({ try editorB.save(self.draft(), expectedRevision: UUID()) }, .staleRevision)
            XCTAssertEqual(try storedRows(container), [])
            let first = try editorA.save(draft(), expectedRevision: nil)
            let before = try durableBytes(directory)
            invalid({ try editorB.save(self.draft("15"), expectedRevision: nil) }, .staleRevision)
            invalid({ try editorB.save(self.draft("15"), expectedRevision: UUID()) }, .staleRevision)
            XCTAssertEqual(try durableBytes(directory), before)
            XCTAssertEqual(try editorB.load(), first)
            let second = try editorA.save(draft("51"), expectedRevision: first.revision)
            let updatedBytes = try durableBytes(directory)
            invalid({ try editorB.save(self.draft("15"), expectedRevision: first.revision) }, .staleRevision)
            XCTAssertEqual(try durableBytes(directory), updatedBytes)
            XCTAssertEqual(savesB, 0)
            XCTAssertEqual(try editorB.load(), second)
            let reviewed = try editorB.save(draft("15"), expectedRevision: second.revision)
            XCTAssertEqual(savesB, 1)
            XCTAssertEqual(try editorA.load(), reviewed)
            XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: reopen(directory)).load(), reviewed)
        }
    }

    func testFailedInsertAndUpdatePreserveBytesAndStateWithoutLeakingIntoOtherContextSaves() throws {
        enum Failure: Error { case injected }
        try withStore { container, directory in
            let working = SwiftDataAppPreferencesRepository(container: container)
            var attempts = 0
            let failing = SwiftDataAppPreferencesRepository(container: container, beforeSave: {
                attempts += 1
                throw Failure.injected
            })
            let emptyBytes = try durableBytes(directory)
            invalid({ try failing.save(self.draft(), expectedRevision: nil) }, .persistenceFailure)
            XCTAssertEqual(try durableBytes(directory), emptyBytes)
            XCTAssertEqual(try working.load(), .defaults)
            XCTAssertEqual(try storedRows(container), [])
            XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: reopen(directory)).load(), .defaults)

            let original = try working.save(draft(), expectedRevision: nil)
            let rows = try storedRows(container)
            let bytes = try durableBytes(directory)
            invalid({ try failing.save(self.draft("50", textSize: .system, motion: .system),
                                       expectedRevision: original.revision) }, .persistenceFailure)
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(try durableBytes(directory), bytes)
            XCTAssertEqual(try storedRows(container), rows)
            XCTAssertEqual(try failing.load(), original)
            XCTAssertEqual(try working.load(), original)
            let otherContext = ModelContext(container)
            otherContext.autosaveEnabled = false
            otherContext.insert(try TaskItem(id: UUID(), title: "Independent transaction", createdAt: Date()))
            try otherContext.save()
            XCTAssertEqual(try storedRows(container), rows)
            let reopened = try reopen(directory)
            XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: reopened).load(), original)
            XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>()).count, 1)
            let retried = try working.save(draft("50"), expectedRevision: original.revision)
            XCTAssertEqual(try working.load(), retried)
            XCTAssertNotEqual(retried.revision, original.revision)
        }
    }

    func testInvalidDraftsNeverCommitOrReplaceExistingPreferences() throws {
        try withStore { container, directory in
            var saves = 0
            let repository = SwiftDataAppPreferencesRepository(container: container, beforeSave: { saves += 1 })
            let values = ["", "0", "-1", "+5", "1.5", "1e2", "１２", "١٢"]
            let before = try durableBytes(directory)
            for value in values {
                invalid({ try repository.save(self.draft(value), expectedRevision: nil) },
                        .invalidFocusDuration(.invalidCustomMinutes))
            }
            XCTAssertEqual(try storedRows(container), [])
            XCTAssertEqual(try durableBytes(directory), before)
            XCTAssertEqual(saves, 0)
            let original = try repository.save(draft(), expectedRevision: nil)
            let savedBytes = try durableBytes(directory)
            for value in values {
                invalid({ try repository.save(self.draft(value), expectedRevision: original.revision) },
                        .invalidFocusDuration(.invalidCustomMinutes))
            }
            invalid({ try repository.save(self.draft(String(Int.max / 60 + 1)),
                                          expectedRevision: original.revision) },
                    .invalidFocusDuration(.durationOverflow))
            XCTAssertEqual(saves, 1)
            XCTAssertEqual(try durableBytes(directory), savedBytes)
            XCTAssertEqual(try repository.load(), original)
            XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: reopen(directory)).load(), original)
        }
    }

    func testCorruptAndUnsupportedStoredRowsBlockBothLoadAndSaveWithoutReplacement() throws {
        let cases: [(() -> AppPreferencesRecord, AppPreferencesError)] = [
            ({ AppPreferencesRecord(key: "foreign.preferences") }, .invalidStoredData),
            ({ AppPreferencesRecord(payloadVersion: 0) }, .unsupportedPayloadVersion(0)),
            ({ AppPreferencesRecord(payloadVersion: 2) }, .unsupportedPayloadVersion(2)),
            ({ AppPreferencesRecord(textSize: "Large") }, .unsupportedTextSize("Large")),
            ({ AppPreferencesRecord(reduceMotion: "off") }, .unsupportedReduceMotion("off")),
            ({ AppPreferencesRecord(focusDefaultMinutes: 0) }, .invalidFocusDuration(.invalidCustomMinutes)),
            ({ AppPreferencesRecord(focusDefaultMinutes: -1) }, .invalidFocusDuration(.invalidCustomMinutes)),
            ({ AppPreferencesRecord(focusDefaultMinutes: Int.max) }, .invalidFocusDuration(.durationOverflow))
        ]
        for (makeRow, error) in cases {
            try withStore { container, directory in
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let row = makeRow()
                context.insert(row)
                try context.save()
                let rows = try storedRows(container)
                let bytes = try durableBytes(directory)
                var saves = 0
                let repository = SwiftDataAppPreferencesRepository(container: container, beforeSave: { saves += 1 })
                invalid({ try repository.load() }, error)
                // Even knowing the stored revision does not authorize repairing corrupt data.
                invalid({ try repository.save(self.draft(), expectedRevision: row.revision) }, error)
                invalid({ try repository.save(self.draft(), expectedRevision: nil) }, error)
                XCTAssertEqual(saves, 0)
                XCTAssertEqual(try durableBytes(directory), bytes)
                XCTAssertEqual(try storedRows(container), rows)
                let reopened = try reopen(directory)
                invalid({ try SwiftDataAppPreferencesRepository(container: reopened).load() }, error)
                XCTAssertEqual(try storedRows(reopened), rows)
            }
        }
    }

    func testMultipleSingletonRowsAreRejectedRatherThanSelectingCanonicalRow() throws {
        try withStore { container, directory in
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let canonical = AppPreferencesRecord()
            context.insert(canonical)
            // Unique keys prevent duplicate canonical keys but not extra singleton rows.
            context.insert(AppPreferencesRecord(key: "other.preferences", focusDefaultMinutes: 50))
            try context.save()
            let before = try durableBytes(directory)
            let rows = try storedRows(container)
            XCTAssertEqual(rows.count, 2)
            var saves = 0
            let repository = SwiftDataAppPreferencesRepository(container: container, beforeSave: { saves += 1 })
            invalid({ try repository.load() }, .duplicateRecords)
            invalid({ try repository.save(self.draft(), expectedRevision: canonical.revision) }, .duplicateRecords)
            invalid({ try repository.save(self.draft(), expectedRevision: nil) }, .duplicateRecords)
            XCTAssertEqual(saves, 0)
            XCTAssertEqual(try durableBytes(directory), before)
            let reopened = try reopen(directory)
            invalid({ try SwiftDataAppPreferencesRepository(container: reopened).load() }, .duplicateRecords)
            XCTAssertEqual(try storedRows(reopened), rows)
        }
    }

    func testRepositoryDoesNotReadOrSaveUncommittedMainContextWork() throws {
        try withStore { container, directory in
            container.mainContext.autosaveEnabled = false
            container.mainContext.insert(AppPreferencesRecord(focusDefaultMinutes: 50))
            container.mainContext.insert(try TaskItem(id: UUID(), title: "Unsaved task", createdAt: Date()))
            let repository = SwiftDataAppPreferencesRepository(container: container)
            XCTAssertEqual(try repository.load(), .defaults)
            let receipt = try repository.save(draft(), expectedRevision: nil)
            XCTAssertEqual(try repository.load(), receipt)
            XCTAssertEqual(try storedRows(container).count, 1)
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count, 0)
            XCTAssertTrue(container.mainContext.hasChanges)
            container.mainContext.rollback()
            let reopened = try reopen(directory)
            XCTAssertEqual(try SwiftDataAppPreferencesRepository(container: reopened).load(), receipt)
            XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<TaskItem>()).count, 0)
        }
    }

    private func invalid(_ operation: () throws -> Any, _ expected: AppPreferencesError,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? AppPreferencesError, expected, file: file, line: line)
        }
    }

    func testDefaultsAreValidatedAndHaveNoStoredRevision() throws {
        let defaults = AppPreferences.defaults
        XCTAssertEqual(defaults.payloadVersion, 1)
        XCTAssertEqual(AppPreferences.currentPayloadVersion, 1)
        XCTAssertEqual(defaults.focusDefaultMinutes, 25)
        XCTAssertEqual(defaults.textSize, .system)
        XCTAssertEqual(defaults.reduceMotion, .system)
        XCTAssertEqual(defaults.focusDuration, .default)
        XCTAssertEqual(try defaults.focusDuration.seconds(), 1500)
        XCTAssertEqual(try AppPreferencesDraft().validated(), defaults)
        XCTAssertEqual(AppPreferencesSnapshot.defaults.preferences, defaults)
        XCTAssertNil(AppPreferencesSnapshot.defaults.revision)
    }

    func testPresetsRetainFocusIdentityAndCustomMinutesAreSupported() throws {
        for (minutes, duration) in [(15, FocusDuration.fifteen), (25, .twentyFive), (50, .fifty)] {
            let preferences = try AppPreferences(focusDefaultMinutes: minutes)
            XCTAssertEqual(preferences.focusDuration, duration)
            XCTAssertEqual(try preferences.focusDuration.seconds(), minutes * 60)
            XCTAssertEqual(try AppPreferencesDraft(preferences: preferences).validated(), preferences)
        }
        for minutes in [1, 17, 51, 1440, Int.max / 60] {
            let preferences = try AppPreferences(focusDefaultMinutes: minutes,
                                                 textSize: .large, reduceMotion: .reduce)
            XCTAssertEqual(preferences.focusDuration, .custom(String(minutes)))
            XCTAssertEqual(try preferences.focusDuration.seconds(), minutes * 60)
            XCTAssertEqual(try AppPreferencesDraft(preferences: preferences).validated(), preferences)
        }
    }

    func testCustomTextUsesExistingFocusWhitespaceAndLeadingZeroRules() throws {
        var draft = AppPreferencesDraft()
        for text in ["17", "0017", " \n 17 \t"] {
            draft.focusDefaultMinutes = text
            XCTAssertEqual(try draft.validated().focusDefaultMinutes, 17)
            XCTAssertEqual(draft.focusDefaultMinutes, text)
        }
    }

    func testInvalidCustomInputIsRejectedWithoutChangingDraft() {
        var draft = AppPreferencesDraft()
        for text in ["", " \t\n", "0", "000", "-1", "+5", "1.5", "1e2", "1E2",
                     "NaN", "Infinity", "１２", "١٢", "1 0", "2\n3", "0x10", "1_000"] {
            draft.focusDefaultMinutes = text
            invalid({ try draft.validated() }, .invalidFocusDuration(.invalidCustomMinutes))
            XCTAssertEqual(draft.focusDefaultMinutes, text)
        }
    }

    func testOverflowUsesCheckedFocusMultiplicationWithNoSmallerLimit() throws {
        var draft = AppPreferencesDraft()
        draft.focusDefaultMinutes = String(Int.max / 60)
        XCTAssertEqual(try draft.validated().focusDefaultMinutes, Int.max / 60)
        for text in [String(Int.max / 60 + 1), String(Int.max), String(repeating: "9", count: 100)] {
            draft.focusDefaultMinutes = text
            invalid({ try draft.validated() }, .invalidFocusDuration(.durationOverflow))
            XCTAssertEqual(draft.focusDefaultMinutes, text)
        }
        invalid({ try AppPreferences(focusDefaultMinutes: Int.max / 60 + 1) },
                .invalidFocusDuration(.durationOverflow))
        invalid({ try AppPreferences(focusDefaultMinutes: Int.max) },
                .invalidFocusDuration(.durationOverflow))
    }

    func testTypedAndStoredMinutesMustAlsoBeValidated() {
        for minutes in [0, -1, Int.min] {
            invalid({ try AppPreferences(focusDefaultMinutes: minutes) },
                    .invalidFocusDuration(.invalidCustomMinutes))
            invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: minutes,
                                          textSizeCode: "system", reduceMotionCode: "system") },
                    .invalidFocusDuration(.invalidCustomMinutes))
        }
        invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: Int.max,
                                      textSizeCode: "system", reduceMotionCode: "system") },
                .invalidFocusDuration(.durationOverflow))
    }

    func testUnsupportedPayloadVersionsAreNotCoerced() {
        for version in [Int.min, -1, 0, 2, Int.max] {
            invalid({ try AppPreferences(payloadVersion: version, focusDefaultMinutes: 25,
                                          textSizeCode: "system", reduceMotionCode: "system") },
                    .unsupportedPayloadVersion(version))
        }
    }

    func testOnlyExactSupportedEnumCodesAreAccepted() throws {
        XCTAssertEqual(AppTextSize.allCases.map(\.rawValue), ["system", "large"])
        XCTAssertEqual(AppReduceMotion.allCases.map(\.rawValue), ["system", "reduce"])
        for textSize in AppTextSize.allCases {
            for reduceMotion in AppReduceMotion.allCases {
                let preferences = try AppPreferences(payloadVersion: 1, focusDefaultMinutes: 17,
                    textSizeCode: textSize.rawValue, reduceMotionCode: reduceMotion.rawValue)
                XCTAssertEqual(preferences.textSize, textSize)
                XCTAssertEqual(preferences.reduceMotion, reduceMotion)
                XCTAssertEqual(preferences.payloadVersion, 1)
            }
        }
        for code in ["", "System", " system", "large ", "small", "reduce"] {
            invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: 25,
                                          textSizeCode: code, reduceMotionCode: "system") },
                    .unsupportedTextSize(code))
        }
        for code in ["", "System", "system ", " reduce", "off", "large"] {
            invalid({ try AppPreferences(payloadVersion: 1, focusDefaultMinutes: 25,
                                          textSizeCode: "system", reduceMotionCode: code) },
                    .unsupportedReduceMotion(code))
        }
    }

    func testDraftAndSnapshotAreIndependentDetachedValues() throws {
        let revision = UUID()
        let preferences = try AppPreferences(focusDefaultMinutes: 50, textSize: .large,
                                             reduceMotion: .reduce)
        let snapshot = AppPreferencesSnapshot(preferences: preferences, revision: revision)
        let original = AppPreferencesDraft(preferences: snapshot.preferences)
        var edited = original
        edited.focusDefaultMinutes = "7"
        edited.textSize = .system
        edited.reduceMotion = .system
        XCTAssertEqual(snapshot.preferences, preferences)
        XCTAssertEqual(snapshot.revision, revision)
        XCTAssertEqual(original.focusDefaultMinutes, "50")
        XCTAssertEqual(original.textSize, .large)
        XCTAssertEqual(original.reduceMotion, .reduce)
        XCTAssertEqual(try edited.validated(), try AppPreferences(focusDefaultMinutes: 7))
    }
}
