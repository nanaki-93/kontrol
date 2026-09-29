import Combine
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
private final class ReadingCatalogRepository: CatalogRepository {
    enum ReadError: Error { case unavailable }
    var value: LearningCatalogSnapshot
    var shouldFail = false
    var failCatalog = false
    var failDetail = false
    var failHistory = false
    var failCoverage = false
    var coverageValue: LearningCoverageSnapshot = .membershipUnavailable
    private(set) var coverageReads = 0
    var detailValue: LessonDetailSnapshot?
    var historyValue: [LessonHistorySnapshot] = []
    var mutationValue: LessonMutationResult?
    private(set) var reads = 0
    private(set) var writes = 0

    init(_ value: LearningCatalogSnapshot) { self.value = value }

    func loadSnapshot() throws -> LearningCatalogSnapshot {
        reads += 1
        if shouldFail || failCatalog { throw ReadError.unavailable }
        return value
    }

    func importIfNeeded(_ catalog: ValidatedCatalog) throws -> CatalogImportResult {
        writes += 1
        return .unchanged
    }

    func reconcileSlots(now: Date) throws -> LearningCatalogSnapshot {
        writes += 1
        return value
    }

    func openLesson(lessonID: String, now: Date) throws -> LessonMutationResult {
        writes += 1
        if shouldFail { throw ReadError.unavailable }
        return try XCTUnwrap(mutationValue)
    }

    func loadLesson(lessonID: String) throws -> LessonDetailSnapshot {
        reads += 1
        if shouldFail || failDetail { throw ReadError.unavailable }
        return try XCTUnwrap(detailValue)
    }

    func loadHistory() throws -> [LessonHistorySnapshot] {
        reads += 1
        if shouldFail || failHistory { throw ReadError.unavailable }
        return historyValue
    }

    func loadCoverage() throws -> LearningCoverageSnapshot {
        reads += 1
        coverageReads += 1
        if shouldFail || failCoverage { throw ReadError.unavailable }
        return coverageValue
    }

    func restoreDismissed(lessonID: String, now: Date) throws -> LessonMutationResult {
        writes += 1
        throw ReadError.unavailable
    }

    func saveAnswer(attemptID: UUID, expectedRevision: Int, answer: String) throws -> LessonMutationResult {
        writes += 1
        throw ReadError.unavailable
    }

    func revealSolution(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
        writes += 1
        throw ReadError.unavailable
    }

    func setSelfCheckAcknowledged(attemptID: UUID, expectedRevision: Int,
                                  acknowledged: Bool, now: Date) throws -> LessonMutationResult {
        writes += 1
        throw ReadError.unavailable
    }

    func complete(attemptID: UUID, expectedRevision: Int, now: Date) throws -> LessonMutationResult {
        writes += 1
        throw ReadError.unavailable
    }

    func dismiss(lessonID: String, expectedSlot: LessonSlotSnapshot, now: Date) throws -> LessonMutationResult {
        writes += 1
        throw ReadError.unavailable
    }
}

@MainActor
final class LearningCatalogStoreTests: XCTestCase {
    private func snapshot(withSlot: Bool = false) -> LearningCatalogSnapshot {
        LearningCatalogSnapshot(
            topics: [LearningTopicSnapshot(id: "go", name: "Go")],
            subtopics: [], concepts: [], definitions: [], progress: [],
            slots: withSlot ? [LessonSlotSnapshot(topicID: "go", slotIndex: 0,
                            lessonID: "go.example", assignedAt: Date(timeIntervalSince1970: 100))] : [])
    }

    func testFailedDetailAndHistoryRetainLastCommittedValuesButBlockMutations() throws {
        let repository = ReadingCatalogRepository(snapshot(withSlot: true))
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let detail = LessonDetailSnapshot(id: "go.example", progress: nil, attempt: nil, content: .unavailable)
        repository.detailValue = detail
        XCTAssertEqual(try store.loadDetail(lessonID: detail.id), detail)
        XCTAssertEqual(try store.loadHistory(), [])
        repository.shouldFail = true
        XCTAssertThrowsError(try store.loadDetail(lessonID: detail.id))
        XCTAssertEqual(store.detailState, .failed(lessonID: detail.id, stale: detail))
        XCTAssertEqual(store.error, .persistenceFailure)
        XCTAssertThrowsError(try store.openLesson(lessonID: detail.id)) { error in
            XCTAssertEqual(error as? LessonExperienceError, .invalidTransition)
        }
        XCTAssertEqual(repository.writes, 0)
        XCTAssertEqual(store.error, .persistenceFailure)
        repository.shouldFail = false
        _ = try store.loadDetail(lessonID: detail.id)
        XCTAssertThrowsError(try store.loadDetail(lessonID: "different"))
        // A read error for a different identity must not surface the previous detail.
        XCTAssertEqual(store.detailState, .failed(lessonID: "different", stale: nil))
        repository.shouldFail = true
        XCTAssertThrowsError(try store.loadHistory())
        XCTAssertEqual(store.historyState, .failed(stale: []))
        XCTAssertThrowsError(try store.openLesson(lessonID: detail.id))
        XCTAssertEqual(repository.writes, 0)
    }

    func testIndependentReadRetriesKeepOtherFailuresBlockingUntilTheirOwnSuccess() throws {
        let repository = ReadingCatalogRepository(snapshot(withSlot: true))
        let store = LearningCatalogStore(repository: repository)
        let id = "go.example"
        let detail = LessonDetailSnapshot(id: id, progress: nil, attempt: nil, content: .unavailable)
        repository.detailValue = detail
        repository.failCatalog = true
        repository.failDetail = true
        repository.failHistory = true
        store.loadIfNeeded()
        XCTAssertThrowsError(try store.loadDetail(lessonID: id))
        XCTAssertThrowsError(try store.loadHistory())
        XCTAssertEqual(store.state, .failed(stale: nil))
        XCTAssertEqual(store.detailState, .failed(lessonID: id, stale: nil))
        XCTAssertEqual(store.historyState, .failed(stale: nil))
        XCTAssertThrowsError(try store.retryDetail(lessonID: "another"))
        XCTAssertEqual(store.detailState, .failed(lessonID: id, stale: nil))
        repository.failCatalog = false
        store.retry()
        XCTAssertTrue(store.state.isAuthoritative)
        XCTAssertEqual(store.error, .persistenceFailure)
        XCTAssertThrowsError(try store.openLesson(lessonID: id))
        XCTAssertEqual(repository.writes, 0)
        repository.failDetail = false
        XCTAssertEqual(try store.retryDetail(lessonID: id), detail)
        XCTAssertThrowsError(try store.retryDetail(lessonID: id))
        XCTAssertEqual(store.error, .persistenceFailure) // History is still failed.
        XCTAssertThrowsError(try store.openLesson(lessonID: id))
        repository.failHistory = false
        XCTAssertEqual(try store.retryHistory(), [])
        XCTAssertNil(store.error)
        XCTAssertThrowsError(try store.retryHistory())
        XCTAssertEqual(repository.writes, 0)
    }

    func testFailedRetryRetainsSameIDDetailAndHistoryUntilSuccessfulRead() throws {
        let repository = ReadingCatalogRepository(snapshot(withSlot: true))
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let detail = LessonDetailSnapshot(id: "go.example", progress: nil, attempt: nil, content: .unavailable)
        repository.detailValue = detail
        _ = try store.loadDetail(lessonID: detail.id)
        _ = try store.loadHistory()
        repository.failDetail = true
        repository.failHistory = true
        XCTAssertThrowsError(try store.loadDetail(lessonID: detail.id))
        XCTAssertThrowsError(try store.loadHistory())
        XCTAssertThrowsError(try store.retryDetail(lessonID: detail.id))
        XCTAssertThrowsError(try store.retryHistory())
        XCTAssertEqual(store.detailState, .failed(lessonID: detail.id, stale: detail))
        XCTAssertEqual(store.historyState, .failed(stale: []))
        repository.failHistory = false
        XCTAssertEqual(try store.retryHistory(), [])
        XCTAssertEqual(store.error, .persistenceFailure)
        repository.failDetail = false
        XCTAssertEqual(try store.retryDetail(lessonID: detail.id), detail)
        XCTAssertNil(store.error)
    }

    func testCoverageReadFailureIsNotZeroAndRetryDoesNotClearOtherFailures() throws {
        let repository = ReadingCatalogRepository(snapshot(withSlot: true))
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        repository.detailValue = LessonDetailSnapshot(id: "go.example", progress: nil,
                                                       attempt: nil, content: .unavailable)
        let available: LearningCoverageSnapshot = .available(catalogID: "catalog", catalogVersion: 1,
                                                              subtopics: [], evidence: .complete)
        repository.coverageValue = available
        XCTAssertEqual(try store.loadCoverage(), available)
        XCTAssertEqual(store.coverageState, .current(available))
        repository.failCoverage = true
        XCTAssertThrowsError(try store.loadCoverage())
        XCTAssertEqual(store.coverageState, .failed(stale: available))
        XCTAssertTrue(store.coverageState.isStale)
        XCTAssertEqual(store.coverageState.snapshot, available) // display-only, never authoritative
        XCTAssertNil(store.error)
        XCTAssertTrue(store.state.isAuthoritative)
        XCTAssertEqual(try store.loadHistory(), []) // unrelated read-only navigation remains usable
        XCTAssertEqual(try store.loadDetail(lessonID: "go.example").id, "go.example")
        let reads = repository.coverageReads
        XCTAssertThrowsError(try store.retryCoverage())
        XCTAssertEqual(repository.coverageReads, reads + 1)
        XCTAssertEqual(store.coverageState, .failed(stale: available))
        XCTAssertThrowsError(try store.openLesson(lessonID: "go.example")) {
            XCTAssertEqual($0 as? LessonExperienceError, .invalidTransition)
        }
        XCTAssertEqual(repository.writes, 0)
        XCTAssertNil(store.error) // coverage failure is not a global catalog/detail error

        repository.failHistory = true
        XCTAssertThrowsError(try store.loadHistory())
        repository.failCoverage = false
        repository.coverageValue = .membershipUnavailable
        XCTAssertEqual(try store.retryCoverage(), .membershipUnavailable)
        XCTAssertEqual(store.coverageState, .current(.membershipUnavailable))
        XCTAssertFalse(store.coverageState.isStale)
        XCTAssertEqual(store.historyState, .failed(stale: []))
        XCTAssertEqual(store.error, .persistenceFailure) // History needs its own retry
        XCTAssertThrowsError(try store.retryCoverage())
        repository.failHistory = false
        XCTAssertEqual(try store.retryHistory(), [])
        XCTAssertNil(store.error)
        XCTAssertEqual(repository.writes, 0)
    }

    func testMutationUsesCommittedCoverageReceiptWithoutPostCommitCoverageRead() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let committed = SwiftDataCatalogRepository(container: container)
        _ = try committed.importIfNeeded(BundledCatalogLoader.load())
        let slot = try XCTUnwrap(committed.loadSnapshot().slots.first)
        let receipt = try committed.openLesson(lessonID: slot.lessonID, now: .distantPast)
        let repository = ReadingCatalogRepository(try committed.loadSnapshot())
        repository.mutationValue = receipt
        repository.failCoverage = true // a post-commit coverage refresh would fail
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let returned = try store.openLesson(lessonID: slot.lessonID)
        XCTAssertEqual(returned, receipt)
        XCTAssertEqual(store.coverageState, .current(receipt.coverage))
        XCTAssertEqual(store.state.snapshot, receipt.catalog)
        XCTAssertEqual(store.historyState, .current(receipt.history))
        XCTAssertEqual(repository.coverageReads, 0)
        XCTAssertEqual(repository.reads, 1)
        XCTAssertEqual(repository.writes, 1)
    }

    func testFirstCoverageFailureHasNoSyntheticEmptyValueAndDoesNotBlockHistory() throws {
        let repository = ReadingCatalogRepository(snapshot())
        let store = LearningCatalogStore(repository: repository)
        repository.failCoverage = true
        XCTAssertThrowsError(try store.loadCoverage())
        XCTAssertEqual(store.coverageState, .failed(stale: nil))
        XCTAssertNil(store.coverageState.snapshot)
        XCTAssertEqual(try store.loadHistory(), [])
        store.loadIfNeeded()
        XCTAssertEqual(store.state, .empty(snapshot()))
        XCTAssertThrowsError(try store.openLesson(lessonID: "go.example"))
        XCTAssertEqual(repository.writes, 0)
        repository.failCoverage = false
        XCTAssertEqual(try store.retryCoverage(), .membershipUnavailable)
    }

    func testEmptyIsSuccessfulAndReadFailureIsRetryableNotEmpty() {
        let repository = ReadingCatalogRepository(snapshot())
        repository.shouldFail = true
        let store = LearningCatalogStore(repository: repository)
        var observed: [LearningCatalogReadState] = []
        let subscription = store.$projection.map(\.catalog).removeDuplicates().sink { observed.append($0) }
        defer { subscription.cancel() }
        XCTAssertEqual(store.state, .notLoaded)
        store.loadIfNeeded()
        XCTAssertEqual(observed, [.notLoaded, .loading, .failed(stale: nil)])
        XCTAssertEqual(store.state, .failed(stale: nil))
        XCTAssertNil(store.state.snapshot)
        store.loadIfNeeded() // not an implicit retry on another consumer's appearance
        XCTAssertEqual(repository.reads, 1)
        repository.shouldFail = false
        store.retry()
        XCTAssertEqual(store.state, .empty(snapshot()))
        XCTAssertFalse(store.state.isStale)
        store.loadIfNeeded()
        store.retry() // no retry after a successful read
        XCTAssertEqual(repository.reads, 2)
        XCTAssertEqual(observed, [.notLoaded, .loading, .failed(stale: nil),
                                  .loading, .empty(snapshot())])
        XCTAssertEqual(repository.writes, 0)
    }

    func testRefreshPublishesWholeSnapshotAndMarksCachedFailureStale() {
        let initial = snapshot(withSlot: true)
        let repository = ReadingCatalogRepository(initial)
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        XCTAssertEqual(store.state, .current(initial))

        let updated = snapshot() // no partial slot array is published on a failed read
        repository.value = updated
        repository.shouldFail = true
        store.refresh()
        XCTAssertEqual(store.state, .failed(stale: initial))
        XCTAssertEqual(store.error, .persistenceFailure)
        XCTAssertEqual(store.state.snapshot?.slots, initial.slots)
        XCTAssertTrue(store.state.isStale)
        repository.shouldFail = false
        store.retry()
        XCTAssertEqual(store.state, .empty(updated))
        XCTAssertFalse(store.state.isStale)
        XCTAssertEqual(repository.reads, 3)
        XCTAssertEqual(repository.writes, 0)
    }

    func testInspectingCommittedSectionsIsReadOnlyAndScopedToSelectedSlot() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let snapshot = try XCTUnwrap(store.state.snapshot)
        let go = try XCTUnwrap(LearningView.choices(for: "go", in: snapshot).first)
        let selected = try XCTUnwrap(LearningView.inspectedLesson(go.id, for: "go", in: snapshot))
        XCTAssertEqual(selected, go)
        XCTAssertNil(LearningView.inspectedLesson(go.id, for: "java", in: snapshot))
        XCTAssertNil(LearningView.inspectedLesson("not-slotted", for: "go", in: snapshot))
        XCTAssertNil(LearningView.inspectedLesson(nil, for: "go", in: snapshot))
        let before = try repository.loadSnapshot()
        // Local selection, repeated inspection, and navigation only project the committed read.
        for topic in LearningView.orderedTopics(in: snapshot) {
            for choice in LearningView.choices(for: topic.id, in: snapshot) {
                let inspected = try XCTUnwrap(LearningView.inspectedLesson(choice.id, for: topic.id, in: snapshot))
                XCTAssertEqual(inspected, choice)
                XCTAssertFalse(inspected.selfCheckCriteria.isEmpty)
                for section in [inspected.explanation, inspected.workedExample, inspected.exercise,
                                inspected.referenceAnswer] + inspected.selfCheckCriteria {
                    XCTAssertFalse(section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, inspected.id)
                }
            }
        }
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }

    func testExhaustedAndPartialTopicsUseOnlyPersistedSlotsWithoutWrites() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let committedRepository = SwiftDataCatalogRepository(container: container)
        _ = try committedRepository.importIfNeeded(BundledCatalogLoader.load())
        let committed = try committedRepository.loadSnapshot()
        let goSlots = committed.slots.filter { $0.topicID == "go" }.sorted { $0.slotIndex < $1.slotIndex }
        XCTAssertEqual(goSlots.count, 4)
        let partial = LearningCatalogSnapshot(topics: committed.topics, subtopics: committed.subtopics,
            concepts: committed.concepts, definitions: committed.definitions, progress: committed.progress,
            slots: Array(goSlots.prefix(2)))
        let repository = ReadingCatalogRepository(partial)
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        XCTAssertEqual(store.state, .current(partial))
        XCTAssertEqual(LearningView.choices(for: "go", in: partial).map(\.id),
                       Array(goSlots.prefix(2)).map(\.lessonID))
        XCTAssertTrue(LearningView.choices(for: "java", in: partial).isEmpty)
        XCTAssertEqual(repository.writes, 0)

        let exhausted = LearningCatalogSnapshot(topics: committed.topics, subtopics: committed.subtopics,
            concepts: committed.concepts, definitions: committed.definitions, progress: committed.progress,
            slots: [])
        repository.value = exhausted
        store.refresh()
        XCTAssertEqual(store.state, .empty(exhausted))
        XCTAssertTrue(LearningView.choices(for: "go", in: exhausted).isEmpty)
        repository.shouldFail = true
        store.refresh()
        XCTAssertEqual(store.state, .failed(stale: exhausted))
        XCTAssertNotEqual(store.state, .empty(exhausted))
        XCTAssertEqual(repository.writes, 0)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }

    func testInspectionProjectionNeverCallsRepositoryWrites() throws {
        let repository = ReadingCatalogRepository(snapshot())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let snapshot = try XCTUnwrap(store.state.snapshot)
        XCTAssertNil(LearningView.inspectedLesson("go.example", for: "go", in: snapshot))
        XCTAssertEqual(repository.reads, 1)
        XCTAssertEqual(repository.writes, 0)
    }

    func testTwoConsumersShareCommittedSlotsWithoutPersonalWrites() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let dependencies = AppDependencies(container: container, catalogRepository: repository)
        let first = dependencies.learningCatalogStore
        let second = dependencies.learningCatalogStore
        XCTAssertTrue(first === second)
        XCTAssertEqual(first.state, .notLoaded)
        first.loadIfNeeded()
        let committed = try repository.loadSnapshot()
        XCTAssertEqual(first.state, .current(committed))
        XCTAssertEqual(second.state.snapshot?.slots, committed.slots)
        second.loadIfNeeded()
        first.refresh()
        XCTAssertEqual(first.state, .current(committed))
        XCTAssertEqual(first.state.snapshot?.slots.count, 20)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }
}
