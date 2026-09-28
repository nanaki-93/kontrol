import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LessonExperienceRepositoryTests: XCTestCase {
    private let first = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_100)

    private func setup() throws -> (ModelContainer, SwiftDataCatalogRepository, String) {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let id = try XCTUnwrap(repository.loadSnapshot().slots.first?.lessonID)
        return (container, repository, id)
    }

    private func rows<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func testPreviewIsWriteFreeAndTwoConsumersResumeOnePinnedAttempt() throws {
        let (container, writer, id) = try setup()
        let other = SwiftDataCatalogRepository(container: container)
        let original = try writer.loadSnapshot()
        let preview = try writer.loadLesson(lessonID: id)
        XCTAssertNil(preview.attempt)
        XCTAssertNil(preview.progress)
        XCTAssertEqual(preview.content, .current(try XCTUnwrap(original.definitions.first { $0.id == id })))
        XCTAssertEqual(try writer.loadSnapshot(), original)
        XCTAssertTrue(try rows(LessonAttempt.self, in: container).isEmpty)
        XCTAssertTrue(try rows(LessonProgress.self, in: container).isEmpty)

        let opened = try writer.openLesson(lessonID: id, now: first)
        XCTAssertEqual(opened.outcome, .changed)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        XCTAssertEqual(attempt.revision, 0)
        XCTAssertEqual(attempt.answerDraft, "")
        XCTAssertEqual(opened.detail.progress?.startedAt, first)
        XCTAssertEqual(opened.detail.progress?.firstShownAt, first)
        XCTAssertEqual(opened.detail.progress?.lastOpenedAt, first)
        let definition = try XCTUnwrap(original.definitions.first { $0.id == id })
        XCTAssertEqual(opened.detail.content, .pinned(definition))
        XCTAssertEqual(try PinnedLessonContent.decode(attempt.pinnedContentData,
            lessonID: id, contentVersion: definition.contentVersion).definition, definition)
        XCTAssertEqual(opened.catalog.slots, original.slots)
        XCTAssertTrue(opened.history.isEmpty)
        XCTAssertNil(opened.replacedSlot)

        let resumed = try other.openLesson(lessonID: id, now: later)
        XCTAssertEqual(resumed.detail.attempt, attempt)
        XCTAssertEqual(resumed.detail.progress?.startedAt, first)
        XCTAssertEqual(resumed.detail.progress?.firstShownAt, first)
        XCTAssertEqual(resumed.detail.progress?.lastOpenedAt, later)
        XCTAssertEqual(try rows(LessonAttempt.self, in: container).count, 1)
        XCTAssertEqual(try rows(LessonProgress.self, in: container).count, 1)
        let late = try writer.openLesson(lessonID: id, now: first) // late caller cannot regress lastOpenedAt
        XCTAssertEqual(late.outcome, .unchanged)
        XCTAssertEqual(try other.loadLesson(lessonID: id).progress?.lastOpenedAt, later)
        // Replacing the installed definition cannot replace the exercise already studied.
        let edited = ModelContext(container)
        let definitionRow = try XCTUnwrap(edited.fetch(FetchDescriptor<LessonDefinition>()).first { $0.id == id })
        definitionRow.exercise = "Changed exercise"
        definitionRow.contentVersion += 1
        try edited.save()
        let afterUpgrade = try other.openLesson(lessonID: id, now: later)
        XCTAssertEqual(afterUpgrade.outcome, .unchanged)
        XCTAssertEqual(afterUpgrade.detail.content, .pinned(definition))
        XCTAssertEqual(afterUpgrade.detail.attempt, attempt)
        enum Injected: Error { case unexpectedSave }
        let noSave = SwiftDataCatalogRepository(container: container,
            beforeSave: { throw Injected.unexpectedSave })
        XCTAssertEqual(try noSave.openLesson(lessonID: id, now: later).outcome, .unchanged)
    }

    func testSameVersionImportLeavesLegacyDraftForAtomicOpenBackfill() throws {
        let (container, writer, id) = try setup()
        let definition = try XCTUnwrap(writer.loadSnapshot().definitions.first { $0.id == id })
        let originalID = UUID()
        let answer = "  Unicode 🧪\n    indented\n\n"
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: id, status: .started,
                                      firstShownAt: first, startedAt: first, lastOpenedAt: first))
        context.insert(LessonAttempt(id: originalID, lessonID: id,
                                     contentVersion: definition.contentVersion, answerDraft: answer))
        try context.save()
        // A same-version import reconciles slots but never runs upgrade backfill.
        XCTAssertEqual(try writer.importIfNeeded(BundledCatalogLoader.load()), .unchanged)
        XCTAssertNil(try XCTUnwrap(rows(LessonAttempt.self, in: container).first).pinnedContentData)
        XCTAssertEqual(try writer.loadLesson(lessonID: id).content, .unavailable)

        enum Injected: Error { case save }
        let failing = SwiftDataCatalogRepository(container: container, beforeSave: { throw Injected.save })
        XCTAssertThrowsError(try failing.openLesson(lessonID: id, now: later)) {
            XCTAssertTrue($0 is Injected)
        }
        let afterFailure = try XCTUnwrap(rows(LessonAttempt.self, in: container).first)
        XCTAssertNil(afterFailure.pinnedContentData)
        XCTAssertEqual(afterFailure.id, originalID)
        XCTAssertEqual(afterFailure.answerDraft, answer)
        XCTAssertEqual(try writer.loadLesson(lessonID: id).progress?.lastOpenedAt, first)

        let opened = try writer.openLesson(lessonID: id, now: later)
        XCTAssertEqual(opened.outcome, .changed)
        XCTAssertEqual(opened.detail.content, .pinned(definition))
        XCTAssertEqual(opened.detail.attempt?.id, originalID)
        XCTAssertEqual(opened.detail.attempt?.answerDraft, answer)
        XCTAssertEqual(opened.detail.attempt?.revision, 0)
        XCTAssertEqual(opened.detail.progress?.startedAt, first)
        XCTAssertEqual(opened.detail.progress?.firstShownAt, first)
        XCTAssertEqual(opened.detail.progress?.lastOpenedAt, later)
        XCTAssertEqual(try rows(LessonAttempt.self, in: container).count, 1)
        XCTAssertEqual(try PinnedLessonContent.decode(
            XCTUnwrap(rows(LessonAttempt.self, in: container).first).pinnedContentData,
            lessonID: id, contentVersion: definition.contentVersion).definition, definition)
        let repeatOpen = try SwiftDataCatalogRepository(container: container).openLesson(lessonID: id, now: later)
        XCTAssertEqual(repeatOpen.outcome, .unchanged)
        XCTAssertEqual(repeatOpen.detail, opened.detail)
    }

    func testRecoveredStartedProgressCreatesOneAttemptWithoutResettingStart() throws {
        let (container, writer, id) = try setup()
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: id, status: .started,
                                      firstShownAt: first, startedAt: first, lastOpenedAt: first))
        try context.save()
        let detail = try writer.loadLesson(lessonID: id)
        XCTAssertNil(detail.attempt)
        XCTAssertEqual(detail.content, .unavailable)
        let opened = try writer.openLesson(lessonID: id, now: later)
        XCTAssertEqual(opened.detail.progress?.startedAt, first)
        XCTAssertEqual(opened.detail.progress?.firstShownAt, first)
        XCTAssertEqual(opened.detail.progress?.lastOpenedAt, later)
        XCTAssertNotNil(opened.detail.attempt)
        XCTAssertEqual(try rows(LessonAttempt.self, in: container).count, 1)
    }

    func testReadOnlyTerminalDetailsAndUnchangedOpensDoNotWrite() throws {
        let (container, writer, id) = try setup()
        let definitions = try writer.loadSnapshot().definitions
        let second = try XCTUnwrap(definitions.first { $0.id != id })
        let context = ModelContext(container)
        let archived = KontrolSchemaV1.LessonContentSnapshot(title: "Studied title", objectiveKey: "old",
            conceptIDs: [], difficulty: "basic", format: "code", explanation: "Studied explanation",
            workedExample: "Example", exercise: "Studied exercise", referenceAnswer: "Solution",
            selfCheckCriteria: ["Check"])
        context.insert(LessonProgress(lessonID: id, status: .completed, startedAt: first,
                                      completedAt: later, lastOpenedAt: first))
        context.insert(LessonAttempt(id: UUID(), lessonID: id, contentVersion: 1,
            answerDraft: "  saved\n", completedAt: later, completedContentSnapshot: archived))
        context.insert(LessonProgress(lessonID: second.id, status: .dismissed,
                                      dismissedAt: later, lastOpenedAt: first))
        let pin = try PinnedLessonContent(definition: second).encoded()
        let draftID = UUID()
        context.insert(LessonAttempt(id: draftID, lessonID: second.id,
            contentVersion: second.contentVersion, answerDraft: "dismissed", pinnedContentData: pin))
        try context.save()
        enum Injected: Error { case save }
        let reader = SwiftDataCatalogRepository(container: container, beforeSave: { throw Injected.save })
        let completed = try reader.loadLesson(lessonID: id)
        XCTAssertEqual(completed.content, .legacyCompleted(archived))
        XCTAssertEqual(completed.attempt?.answerDraft, "  saved\n")
        let dismissed = try reader.loadLesson(lessonID: second.id)
        XCTAssertEqual(dismissed.content, .pinned(second))
        XCTAssertEqual(dismissed.attempt?.id, draftID)
        for lessonID in [id, second.id] {
            let receipt = try reader.openLesson(lessonID: lessonID, now: Date.distantFuture)
            XCTAssertEqual(receipt.outcome, .unchanged)
            XCTAssertEqual(receipt.detail, lessonID == id ? completed : dismissed)
            XCTAssertEqual(receipt.history.count, 2)
        }
        XCTAssertEqual(try rows(LessonAttempt.self, in: container).count, 2)
        XCTAssertEqual(try rows(LessonProgress.self, in: container).count, 2)
    }

    func testDismissedBeforeOpenUsesCurrentDefinitionWithoutStartingWork() throws {
        let (container, writer, id) = try setup()
        let definition = try XCTUnwrap(writer.loadSnapshot().definitions.first { $0.id == id })
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: id, status: .dismissed,
                                      firstShownAt: first, dismissedAt: later, lastOpenedAt: first))
        try context.save()

        enum Injected: Error { case save }
        let reader = SwiftDataCatalogRepository(container: container, beforeSave: { throw Injected.save })
        let detail = try reader.loadLesson(lessonID: id)
        XCTAssertEqual(detail.progress?.status, .dismissed)
        XCTAssertEqual(detail.progress?.dismissedAt, later)
        XCTAssertEqual(detail.progress?.lastOpenedAt, first)
        XCTAssertNil(detail.attempt)
        XCTAssertEqual(detail.content, .current(definition))
        for time in [first, Date.distantFuture] {
            let receipt = try reader.openLesson(lessonID: id, now: time)
            XCTAssertEqual(receipt.outcome, .unchanged)
            XCTAssertEqual(receipt.detail, detail)
            XCTAssertEqual(receipt.history.count, 1)
            XCTAssertEqual(receipt.history.first?.content, .current(definition))
            XCTAssertNil(receipt.history.first?.attempt)
        }
        XCTAssertEqual(try writer.loadLesson(lessonID: id), detail)
        XCTAssertTrue(try rows(LessonAttempt.self, in: container).isEmpty)
        XCTAssertEqual(try rows(LessonProgress.self, in: container).count, 1)
    }

    func testMissingOrContradictoryBaselineAndUnavailablePinsAreClassifiedWithoutWrites() throws {
        let (container, writer, id) = try setup()
        XCTAssertThrowsError(try writer.loadLesson(lessonID: "missing")) {
            XCTAssertEqual($0 as? LessonExperienceError, .lessonNotFound)
        }
        XCTAssertThrowsError(try writer.openLesson(lessonID: "missing", now: first)) {
            XCTAssertEqual($0 as? LessonExperienceError, .contentUnavailable)
        }
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: id, status: .started, startedAt: first))
        context.insert(LessonAttempt(id: UUID(), lessonID: id, contentVersion: 99, answerDraft: "keep"))
        try context.save()
        XCTAssertEqual(try writer.loadLesson(lessonID: id).content, .unavailable)
        XCTAssertThrowsError(try writer.openLesson(lessonID: id, now: later)) {
            XCTAssertEqual($0 as? LessonExperienceError, .contentUnavailable)
        }
        let corrupt = ModelContext(container)
        corrupt.insert(LessonAttempt(id: UUID(), lessonID: id, contentVersion: 99))
        try corrupt.save()
        XCTAssertThrowsError(try writer.loadLesson(lessonID: id)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertThrowsError(try writer.openLesson(lessonID: id, now: later)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertEqual(try rows(LessonProgress.self, in: container).first?.lastOpenedAt, nil)
    }

    func testInvalidStoredPinAndContradictoryTerminalStateAreNotSilentlyRepaired() throws {
        let (container, writer, id) = try setup()
        let context = ModelContext(container)
        context.insert(LessonProgress(lessonID: id, status: .started, startedAt: first))
        let attempt = LessonAttempt(id: UUID(), lessonID: id, contentVersion: 1,
                                    pinnedContentData: Data("invalid".utf8))
        context.insert(attempt)
        try context.save()
        for operation in [{ try writer.loadLesson(lessonID: id) as Any },
                          { try writer.openLesson(lessonID: id, now: self.later) as Any }] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
            }
        }
        let conflicting = ModelContext(container)
        let progress = try XCTUnwrap(conflicting.fetch(FetchDescriptor<LessonProgress>()).first)
        progress.status = .completed
        progress.completedAt = later
        try conflicting.save()
        XCTAssertThrowsError(try writer.loadLesson(lessonID: id)) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
    }

    func testPreSaveAndSaveFailureLeaveNoAttemptProgressOrReceipt() throws {
        for failBefore in [true, false] {
            let (container, writer, id) = try setup()
            enum Injected: Error { case failure }
            let failing = SwiftDataCatalogRepository(container: container,
                beforeSave: { if failBefore { throw Injected.failure } },
                save: { _ in if !failBefore { throw Injected.failure } })
            XCTAssertThrowsError(try failing.openLesson(lessonID: id, now: first)) {
                XCTAssertTrue($0 is Injected)
            }
            XCTAssertTrue(try rows(LessonAttempt.self, in: container).isEmpty)
            XCTAssertTrue(try rows(LessonProgress.self, in: container).isEmpty)
            XCTAssertNil(try writer.loadLesson(lessonID: id).attempt)
            let committed = try writer.openLesson(lessonID: id, now: first)
            XCTAssertThrowsError(try failing.openLesson(lessonID: id, now: later)) {
                XCTAssertTrue($0 is Injected)
            }
            XCTAssertEqual(try writer.loadLesson(lessonID: id), committed.detail)
            XCTAssertEqual(try rows(LessonAttempt.self, in: container).count, 1)
        }
    }
}
