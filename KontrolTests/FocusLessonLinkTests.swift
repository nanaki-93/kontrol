import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class FocusLessonLinkTests: XCTestCase {
    private enum Injected: Error { case failed }
    private let lessonID = "lesson-1"
    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    private func input(_ lessonID: String = "lesson-1") -> FocusStartInput {
        FocusStartInput(plannedSeconds: 1500, startedAt: start, linkedLessonID: lessonID)
    }

    private func seed(_ container: ModelContainer, title: String = "Original title",
                      status: KontrolSchemaV1.ProgressStatus? = nil) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let content = LessonDTO(
            id: lessonID, objectiveKey: "objective", objective: "Objective", title: title,
            topicID: "go", subtopicID: "go-basics", conceptIDs: ["concept"],
            difficulty: "basic", format: "learn", estimatedMinutes: 20,
            prerequisiteConceptIDs: [], explanation: "Explanation", workedExample: "Example",
            exercise: "Exercise", referenceAnswer: "Answer", selfCheckCriteria: ["Check"],
            contentVersion: 1, normalizedContentHash: "", source: "seed", provenance: "Test")
        context.insert(LessonDefinition(
            id: content.id, objectiveKey: content.objectiveKey,
            title: content.title, topicID: content.topicID, subtopicID: content.subtopicID,
            conceptIDs: content.conceptIDs, difficulty: content.difficulty, format: content.format,
            estimatedMinutes: content.estimatedMinutes,
            prerequisiteConceptIDs: content.prerequisiteConceptIDs,
            explanation: content.explanation, workedExample: content.workedExample,
            exercise: content.exercise, referenceAnswer: content.referenceAnswer,
            selfCheckCriteria: content.selfCheckCriteria, contentVersion: content.contentVersion,
            normalizedContentHash: CatalogValidator.fingerprint(for: content),
            source: content.source, provenance: content.provenance, objective: content.objective))
        if let status { context.insert(LessonProgress(lessonID: lessonID, status: status)) }
        try context.save()
    }

    private func rows(_ container: ModelContainer) throws -> [FocusSessionSnapshot] {
        try SwiftDataFocusRepository(container: container).fetchAll()
    }

    func testConfigurationAndInputRejectDualOrBlankLinksButAllowNoLink() throws {
        XCTAssertEqual(try FocusConfiguration().plannedSeconds(), 1500)
        XCTAssertEqual(try FocusConfiguration(linkedLessonID: lessonID).plannedSeconds(), 1500)
        XCTAssertThrowsError(try FocusConfiguration(linkedTaskID: taskID,
            linkedLessonID: lessonID).plannedSeconds()) {
            XCTAssertEqual($0 as? FocusError, .invalidLinks)
        }
        XCTAssertThrowsError(try FocusConfiguration(linkedLessonID: " \n ").plannedSeconds()) {
            XCTAssertEqual($0 as? FocusError, .invalidLinks)
        }
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = 0
        var saves = 0
        let writer = SwiftDataFocusRepository(container: container,
            makeID: { ids += 1; return self.sessionID },
            save: { context in saves += 1; try context.save() })
        for bad in [FocusStartInput(plannedSeconds: 1500, startedAt: start,
                                    linkedTaskID: taskID, linkedLessonID: lessonID),
                    input(" \n ")] {
            XCTAssertThrowsError(try writer.create(input: bad)) {
                XCTAssertEqual($0 as? FocusError, .invalidLinks)
            }
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(try rows(container).isEmpty)
    }

    func testAvailableAndStartedSelectionsCaptureLatestTitleAndSurviveReopen() throws {
        let statuses: [KontrolSchemaV1.ProgressStatus?] = [nil, .available, .started]
        for status in statuses {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "KontrolFocusLesson-\(UUID().uuidString)", isDirectory: true)
            let url = directory.appendingPathComponent("Kontrol.store")
            var committed: FocusSessionSnapshot!
            try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                try seed(container, status: status)
                let editor = ModelContext(container)
                editor.autosaveEnabled = false
                let definition = try XCTUnwrap(editor.fetch(FetchDescriptor<LessonDefinition>()).first)
                definition.title = "Renamed at Start"
                try editor.save()
                let writer = SwiftDataFocusRepository(container: container, makeID: { self.sessionID })
                committed = try writer.create(input: input())
                XCTAssertEqual(committed.linkedLessonID, lessonID)
                XCTAssertNil(committed.linkedTaskID)
                XCTAssertEqual(committed.linkedTitleSnapshot, "Renamed at Start")
                XCTAssertEqual(try editor.fetch(FetchDescriptor<LessonProgress>()).first?.status, status)
                XCTAssertTrue(try editor.fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
            }
            try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                XCTAssertEqual(try rows(container), [committed])
            }
        }
    }

    func testMissingAndTerminalSelectionsNeverAllocateOrSaveAnUnlinkedSession() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var ids = 0
        var saves = 0
        let writer = SwiftDataFocusRepository(container: container,
            makeID: { ids += 1; return self.sessionID },
            save: { context in saves += 1; try context.save() })
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .unavailableLesson)
        }
        try seed(container)
        let editor = ModelContext(container)
        editor.autosaveEnabled = false
        let terminal: [KontrolSchemaV1.ProgressStatus] = [.completed, .dismissed]
        for status in terminal {
            let progress = try editor.fetch(FetchDescriptor<LessonProgress>())
            if let first = progress.first { first.status = status }
            else { editor.insert(LessonProgress(lessonID: lessonID, status: status)) }
            try editor.save()
            XCTAssertThrowsError(try writer.create(input: input())) {
                XCTAssertEqual($0 as? FocusError, .unavailableLesson)
            }
        }
        editor.delete(try XCTUnwrap(editor.fetch(FetchDescriptor<LessonDefinition>()).first))
        try editor.save()
        XCTAssertThrowsError(try writer.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .unavailableLesson)
        }
        XCTAssertEqual(ids, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(try rows(container).isEmpty)
    }

    func testCorruptAndUnreadableSelectionAndFailedSaveLeaveNoSession() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        try seed(container)
        var ids = 0
        var saves = 0
        let guarded = SwiftDataFocusRepository(container: container,
            makeID: { ids += 1; return self.sessionID },
            save: { _ in saves += 1; throw Injected.failed })
        XCTAssertThrowsError(try guarded.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .persistenceFailure)
        }
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(try rows(container).isEmpty)
        let unreadableDefinitions = SwiftDataFocusRepository(container: container,
            fetchLessons: { _ in throw Injected.failed })
        let unreadableProgress = SwiftDataFocusRepository(container: container,
            fetchProgress: { _ in throw Injected.failed })
        for writer in [unreadableDefinitions, unreadableProgress] {
            XCTAssertThrowsError(try writer.create(input: input())) {
                XCTAssertEqual($0 as? FocusError, .persistenceFailure)
            }
        }
        let editor = ModelContext(container)
        editor.autosaveEnabled = false
        let definition = try XCTUnwrap(editor.fetch(FetchDescriptor<LessonDefinition>()).first)
        definition.title = " \n "
        try editor.save()
        XCTAssertThrowsError(try guarded.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        definition.title = "Valid again"
        try editor.save()
        // Inject contradictory rows independently of SwiftData's unique index.
        let contradictory = SwiftDataFocusRepository(container: container,
            fetchProgress: { _ in
                let row = LessonProgress(lessonID: self.lessonID, status: .started)
                return [row, row]
            })
        XCTAssertThrowsError(try contradictory.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        editor.insert(LessonProgress(lessonID: lessonID, status: .started, completedAt: start))
        try editor.save()
        XCTAssertThrowsError(try guarded.create(input: input())) {
            XCTAssertEqual($0 as? FocusError, .invalidStoredData)
        }
        XCTAssertEqual(ids, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(try rows(container).isEmpty)
    }

    func testDamagedRequiredContentAndMetadataCannotStartLinkedSession() throws {
        let corruptions: [(String, (LessonDefinition) -> Void)] = [
            ("objective key", { $0.objectiveKey = " \n " }),
            ("objective", { $0.objective = " " }),
            ("topic", { $0.topicID = " " }),
            ("subtopic", { $0.subtopicID = " " }),
            ("concepts", { $0.conceptIDs = [] }),
            ("blank concept", { $0.conceptIDs = [" "] }),
            ("duplicate concepts", { $0.conceptIDs = ["concept", "concept"] }),
            ("duplicate prerequisites", { $0.prerequisiteConceptIDs = ["concept", "concept"] }),
            ("difficulty", { $0.difficulty = "unknown" }),
            ("format", { $0.format = "unknown" }),
            ("estimate", { $0.estimatedMinutes = 0 }),
            ("negative estimate", { $0.estimatedMinutes = -1 }),
            ("explanation", { $0.explanation = " \n " }),
            ("example", { $0.workedExample = " " }),
            ("exercise", { $0.exercise = "\n " }),
            ("reference answer", { $0.referenceAnswer = " " }),
            ("self check", { $0.selfCheckCriteria = [" "] }),
            ("missing self check", { $0.selfCheckCriteria = [] }),
            ("content version", { $0.contentVersion = 0 }),
            ("missing fingerprint", { $0.normalizedContentHash = " " }),
            ("fingerprint", { $0.normalizedContentHash = "stale" }),
            ("changed content without new fingerprint", { $0.exercise = "Changed exercise" }),
            ("source", { $0.source = "unknown" }),
            ("provenance", { $0.provenance = " " })
        ]
        for (name, corrupt) in corruptions {
            let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
            try seed(container)
            let editor = ModelContext(container)
            editor.autosaveEnabled = false
            corrupt(try XCTUnwrap(editor.fetch(FetchDescriptor<LessonDefinition>()).first))
            try editor.save()
            var ids = 0
            var saves = 0
            let writer = SwiftDataFocusRepository(container: container,
                makeID: { ids += 1; return self.sessionID },
                save: { context in saves += 1; try context.save() })
            XCTAssertThrowsError(try writer.create(input: input()), name) {
                XCTAssertEqual($0 as? FocusError, .invalidStoredData, name)
            }
            XCTAssertEqual(ids, 0, name)
            XCTAssertEqual(saves, 0, name)
            XCTAssertTrue(try rows(container).isEmpty, name)
        }
    }

    func testLaterLessonChangesDoNotRewriteOrStopCommittedSession() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        try seed(container, status: .started)
        let writer = SwiftDataFocusRepository(container: container, makeID: { self.sessionID })
        let running = try writer.create(input: input())
        let editor = ModelContext(container)
        editor.autosaveEnabled = false
        try XCTUnwrap(editor.fetch(FetchDescriptor<LessonProgress>()).first).status = .completed
        try XCTUnwrap(editor.fetch(FetchDescriptor<LessonDefinition>()).first).title = "Updated lesson"
        try editor.save()
        XCTAssertEqual(try rows(container), [running])
        let checkpoint = try writer.transition(id: sessionID, command: .checkpoint(
            FocusTransitionPayload(expectedCheckpointAt: running.checkpointAt,
                sampledAt: start.addingTimeInterval(10), accumulatedActiveSeconds: 10)))
        XCTAssertEqual(checkpoint.state, .running)
        XCTAssertEqual(checkpoint.linkedLessonID, lessonID)
        XCTAssertEqual(checkpoint.linkedTitleSnapshot, running.linkedTitleSnapshot)
        XCTAssertEqual(try rows(container), [checkpoint])
    }
}
