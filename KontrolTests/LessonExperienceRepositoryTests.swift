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

    func testExactAnswerRevisionAndAcknowledgementAreCommittedTogether() throws {
        let (container, writer, id) = try setup()
        let other = SwiftDataCatalogRepository(container: container)
        let opened = try writer.openLesson(lessonID: id, now: first)
        let initial = try XCTUnwrap(opened.detail.attempt)
        let originalProgress = opened.detail.progress
        let originalSlots = opened.catalog.slots
        let originalPin = initial.pinnedContentData
        let exact = "  🧪答え\n    let value = 1\n\n"
        let saved = try other.saveAnswer(attemptID: initial.id, expectedRevision: 0, answer: exact)
        XCTAssertEqual(saved.outcome, .changed)
        XCTAssertEqual(saved.detail.attempt?.answerDraft, exact)
        XCTAssertEqual(saved.detail.attempt?.revision, 1)
        XCTAssertEqual(saved.detail.attempt?.pinnedContentData, originalPin)
        XCTAssertEqual(saved.detail.progress, originalProgress)
        XCTAssertEqual(saved.catalog.slots, originalSlots)
        XCTAssertTrue(saved.history.isEmpty)
        XCTAssertNil(saved.replacedSlot)
        XCTAssertEqual(try writer.loadLesson(lessonID: id), saved.detail)

        // Even a no-op with an old revision must not conceal a stale editor.
        for text in ["stale", exact] {
            XCTAssertThrowsError(try writer.saveAnswer(attemptID: initial.id, expectedRevision: 0, answer: text)) {
                XCTAssertEqual($0 as? LessonExperienceError, .staleRevision)
            }
        }
        enum Injected: Error { case unexpectedSave }
        let noSave = SwiftDataCatalogRepository(container: container,
            beforeSave: { throw Injected.unexpectedSave })
        let unchanged = try noSave.saveAnswer(attemptID: initial.id, expectedRevision: 1, answer: exact)
        XCTAssertEqual(unchanged.outcome, .unchanged)
        XCTAssertEqual(unchanged.detail, saved.detail)
        let blank = try writer.saveAnswer(attemptID: initial.id, expectedRevision: 1, answer: "")
        XCTAssertEqual(blank.detail.attempt?.answerDraft, "")
        XCTAssertEqual(blank.detail.attempt?.revision, 2)

        // An existing acknowledgement must be cleared in the *same* write as
        // new text; reveal remains durable and no other attempt field changes.
        let gated = ModelContext(container)
        let row = try XCTUnwrap(gated.fetch(FetchDescriptor<LessonAttempt>()).first { $0.id == initial.id })
        row.solutionRevealedAt = first
        row.selfCheckAcknowledgedAt = later
        row.revision = 3
        try gated.save()
        let changed = try other.saveAnswer(attemptID: initial.id, expectedRevision: 3, answer: exact)
        XCTAssertEqual(changed.detail.attempt?.answerDraft, exact)
        XCTAssertEqual(changed.detail.attempt?.revision, 4)
        XCTAssertEqual(changed.detail.attempt?.solutionRevealedAt, first)
        XCTAssertNil(changed.detail.attempt?.selfCheckAcknowledgedAt)
        XCTAssertNil(try XCTUnwrap(rows(LessonAttempt.self, in: container).first).selfCheckAcknowledgedAt)
        XCTAssertEqual(try noSave.saveAnswer(attemptID: initial.id, expectedRevision: 4,
                                             answer: exact).outcome, .unchanged)
    }

    func testDelayedWritesCannotReviveDismissedOrChangeCompletedAnswers() throws {
        let (container, writer, id) = try setup()
        let opened = try writer.openLesson(lessonID: id, now: first)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        _ = try writer.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "keep")
        let context = ModelContext(container)
        let progress = try XCTUnwrap(context.fetch(FetchDescriptor<LessonProgress>()).first { $0.lessonID == id })
        progress.status = .dismissed
        progress.dismissedAt = later
        try context.save()
        for revision in [0, 1] {
            XCTAssertThrowsError(try writer.saveAnswer(attemptID: attempt.id, expectedRevision: revision, answer: "late")) {
                XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
            }
        }
        XCTAssertEqual(try writer.loadLesson(lessonID: id).attempt?.answerDraft, "keep")
        let completed = ModelContext(container)
        let archived = try XCTUnwrap(completed.fetch(FetchDescriptor<LessonAttempt>()).first { $0.id == attempt.id })
        let completedProgress = try XCTUnwrap(completed.fetch(FetchDescriptor<LessonProgress>()).first { $0.lessonID == id })
        archived.completedAt = later
        archived.completedContentSnapshot = try PinnedLessonContent.decode(archived.pinnedContentData,
            lessonID: id, contentVersion: archived.contentVersion).completedSnapshot
        completedProgress.status = .completed
        completedProgress.completedAt = later
        try completed.save()
        XCTAssertThrowsError(try writer.saveAnswer(attemptID: attempt.id, expectedRevision: 1, answer: "late")) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
        }
        let read = try writer.loadLesson(lessonID: id)
        XCTAssertEqual(read.attempt?.answerDraft, "keep")
        XCTAssertEqual(read.attempt?.revision, 1)
        XCTAssertEqual(read.attempt?.completedAt, later)
        XCTAssertEqual(read.progress?.status, .completed)
        XCTAssertThrowsError(try writer.saveAnswer(attemptID: UUID(), expectedRevision: 0, answer: "x")) {
            XCTAssertEqual($0 as? LessonExperienceError, .attemptNotFound)
        }
    }

    func testInvalidPinOrReceiptCannotCommitAnAnswer() throws {
        let (container, writer, id) = try setup()
        let attempt = try XCTUnwrap(writer.openLesson(lessonID: id, now: first).detail.attempt)
        let broken = ModelContext(container)
        let row = try XCTUnwrap(broken.fetch(FetchDescriptor<LessonAttempt>()).first { $0.id == attempt.id })
        row.pinnedContentData = Data("invalid".utf8)
        try broken.save()
        XCTAssertThrowsError(try writer.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "new")) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        XCTAssertEqual(try XCTUnwrap(rows(LessonAttempt.self, in: container).first).answerDraft, "")
        let repaired = ModelContext(container)
        try XCTUnwrap(repaired.fetch(FetchDescriptor<LessonAttempt>()).first { $0.id == attempt.id })
            .pinnedContentData = attempt.pinnedContentData
        try repaired.save()

        // The result's History projection is also validated before save. A
        // broken unrelated terminal row must not turn a committed edit into a
        // reported error after the fact.
        let invalid = ModelContext(container)
        invalid.insert(LessonProgress(lessonID: "broken-history", status: .completed,
                                      completedAt: later))
        try invalid.save()
        XCTAssertThrowsError(try writer.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "new")) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidStoredData)
        }
        let persisted = try XCTUnwrap(rows(LessonAttempt.self, in: container).first { $0.id == attempt.id })
        XCTAssertEqual(persisted.answerDraft, "")
        XCTAssertEqual(persisted.revision, 0)
    }

    func testFailedAnswerSavePreservesCommittedTextAndRevisionAcrossReopen() throws {
        enum Injected: Error { case failure }
        for failBefore in [true, false] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "KontrolAnswerFailure-\(UUID().uuidString)/Kontrol.store")
            var attemptID = UUID()
            var committed: LessonDetailSnapshot?
            try autoreleasepool {
                let container = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let writer = SwiftDataCatalogRepository(container: container)
                _ = try writer.importIfNeeded(BundledCatalogLoader.load())
                let id = try XCTUnwrap(writer.loadSnapshot().slots.first?.lessonID)
                attemptID = try XCTUnwrap(writer.openLesson(lessonID: id, now: first).detail.attempt).id
                committed = try writer.saveAnswer(attemptID: attemptID, expectedRevision: 0,
                                                   answer: "  committed\n").detail
                let failing = SwiftDataCatalogRepository(container: container,
                    beforeSave: { if failBefore { throw Injected.failure } },
                    save: { _ in if !failBefore { throw Injected.failure } })
                XCTAssertThrowsError(try failing.saveAnswer(attemptID: attemptID,
                    expectedRevision: 1, answer: "  🧪\n    unsaved\n")) {
                    XCTAssertTrue($0 is Injected)
                }
                XCTAssertEqual(try writer.loadLesson(lessonID: id), committed)
                XCTAssertEqual(try XCTUnwrap(rows(LessonAttempt.self, in: container).first).revision, 1)
            }
            try autoreleasepool {
                let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(url))
                let reader = SwiftDataCatalogRepository(container: reopened)
                let id = try XCTUnwrap(committed?.id)
                XCTAssertEqual(try reader.loadLesson(lessonID: id), committed)
                XCTAssertEqual(try XCTUnwrap(rows(LessonAttempt.self, in: reopened).first).revision, 1)
                let retry = try reader.saveAnswer(attemptID: attemptID, expectedRevision: 1,
                                                  answer: "  🧪\n    unsaved\n")
                XCTAssertEqual(retry.detail.attempt?.revision, 2)
                XCTAssertEqual(retry.detail.attempt?.answerDraft, "  🧪\n    unsaved\n")
            }
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
