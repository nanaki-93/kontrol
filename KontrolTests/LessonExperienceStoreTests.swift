import Combine
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class LessonExperienceStoreTests: XCTestCase {
    private enum Injected: Error { case save }

    func testCommittedReceiptsPublishChoicesDetailAndHistoryTogetherToBothConsumers() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let graph = AppDependencies(container: container, catalogRepository: repository)
        let first = graph.learningCatalogStore
        let second = graph.learningCatalogStore
        XCTAssertTrue(first === second)
        first.loadIfNeeded()
        let slot = try XCTUnwrap(first.state.snapshot?.slots.first)
        var publications: [LearningExperienceProjection] = []
        let subscription = second.$projection.sink { publications.append($0) }
        defer { subscription.cancel() }
        let opened = try second.openLesson(lessonID: slot.lessonID, now: .distantPast)
        let attempt = try XCTUnwrap(opened.detail.attempt)
        XCTAssertEqual(first.detailState, .current(opened.detail))
        let edited = try first.saveAnswer(attemptID: attempt.id, expectedRevision: attempt.revision, answer: "  🧪\n  exact\n")
        XCTAssertEqual(edited.detail.attempt?.answerDraft, "  🧪\n  exact\n")
        let revealed = try first.revealSolution(attemptID: attempt.id, expectedRevision: 1)
        XCTAssertNotNil(revealed.detail.attempt?.solutionRevealedAt)
        let acknowledged = try second.setSelfCheckAcknowledged(attemptID: attempt.id, expectedRevision: 2,
                                                                  acknowledged: true)
        XCTAssertNotNil(acknowledged.detail.attempt?.selfCheckAcknowledgedAt)
        let completed = try first.complete(attemptID: attempt.id, expectedRevision: 3)
        XCTAssertEqual(completed.detail.progress?.status, .completed)
        XCTAssertEqual(second.historyState, .current(completed.history))
        XCTAssertEqual(first.state.snapshot, completed.catalog)
        XCTAssertFalse(completed.catalog.slots.contains { $0.lessonID == slot.lessonID })
        XCTAssertEqual(completed.history.first?.attempt?.answerDraft, "  🧪\n  exact\n")
        XCTAssertEqual(publications.last?.detail, .current(completed.detail))
        XCTAssertEqual(publications.last?.history, .current(completed.history))
        XCTAssertEqual(publications.last?.catalog.snapshot, completed.catalog)
        XCTAssertEqual(try repository.loadSnapshot(), completed.catalog)
        XCTAssertEqual(try repository.loadHistory(), completed.history)
        // Reads of the new selection cannot retroactively make an earlier receipt stale.
        let repeated = try second.complete(attemptID: attempt.id, expectedRevision: 0)
        XCTAssertEqual(repeated.outcome, .unchanged)
        XCTAssertEqual(second.state.snapshot?.slots, completed.catalog.slots)
    }

    func testDismissAndRestorePublishOneConsistentProjection() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let slot = try XCTUnwrap(store.state.snapshot?.slots.first)
        let dismissed = try store.dismiss(lessonID: slot.lessonID, expectedSlot: slot)
        XCTAssertEqual(store.projection.catalog.snapshot, dismissed.catalog)
        XCTAssertEqual(store.detailState, .current(dismissed.detail))
        XCTAssertEqual(store.historyState, .current(dismissed.history))
        XCTAssertEqual(dismissed.history.first?.status, .dismissed)
        let restored = try store.restoreDismissed(lessonID: slot.lessonID)
        XCTAssertEqual(store.projection.catalog.snapshot, restored.catalog)
        XCTAssertEqual(store.detailState, .current(restored.detail))
        XCTAssertEqual(store.historyState, .current(restored.history))
        XCTAssertTrue(restored.history.isEmpty)
        XCTAssertEqual(try repository.loadSnapshot(), restored.catalog)
    }

    func testFailedSavePublishesOnlyErrorAndNoSpeculativeProjectionOrPostCommitRead() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var fail = false
        let repository = SwiftDataCatalogRepository(container: container, beforeSave: {
            if fail { throw Injected.save }
        })
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let id = try XCTUnwrap(store.state.snapshot?.slots.first?.lessonID)
        let opened = try store.openLesson(lessonID: id)
        let baseline = store.projection
        let attempt = try XCTUnwrap(opened.detail.attempt)
        fail = true
        XCTAssertThrowsError(try store.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "unsaved"))
        XCTAssertEqual(store.error, .persistenceFailure)
        XCTAssertEqual(store.projection.catalog, baseline.catalog)
        XCTAssertEqual(store.projection.detail, baseline.detail)
        XCTAssertEqual(store.projection.history, baseline.history)
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "")
        fail = false
        let saved = try store.saveAnswer(attemptID: attempt.id, expectedRevision: 0, answer: "saved")
        XCTAssertEqual(store.error, nil)
        XCTAssertEqual(store.detailState, .current(saved.detail))
        XCTAssertEqual(try repository.loadLesson(lessonID: id).attempt?.answerDraft, "saved")
    }
}
