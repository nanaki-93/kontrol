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
    var insertionValue: GeneratedLessonInsertionResult?
    var insertionError: Error?
    private(set) var reads = 0
    private(set) var writes = 0

    init(_ value: LearningCatalogSnapshot) { self.value = value }

    func acceptGeneratedLesson(_ lesson: ValidatedGeneratedLesson, now: Date) throws -> GeneratedLessonInsertionResult {
        writes += 1
        if let insertionError { throw insertionError }
        return try XCTUnwrap(insertionValue)
    }

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

    private func generatedFixture(_ repository: SwiftDataCatalogRepository, container: ModelContainer) throws -> ValidatedGeneratedLesson {
        let initial = try repository.generationContext(topicID: "go")
        let source = try XCTUnwrap(initial.definitions.first {
            $0.conceptIDs.contains("go.concurrency.cancel-work") &&
                $0.objectiveKey != "expansion.go.concurrency.cancellation-race"
        })
        let writer = ModelContext(container)
        let date = Date(timeIntervalSince1970: 20)
        writer.insert(LessonProgress(lessonID: source.id, status: .completed, completedAt: date))
        writer.insert(LessonAttempt(id: UUID(), lessonID: source.id, contentVersion: source.contentVersion,
            completedAt: date, pinnedContentData: try PinnedLessonContent(definition: source).encoded()))
        writer.insert(try LessonTerminalRecord(metadata: LessonTerminalMetadata(lessonID: source.id,
            provenance: .studiedPin, title: source.title, topicID: source.topicID,
            subtopicID: source.subtopicID, contentVersion: source.contentVersion,
            objectiveKey: source.objectiveKey, conceptIDs: source.conceptIDs.sorted(),
            normalizedContentHash: source.normalizedContentHash, format: source.format,
            dismissalTimeDefinition: nil)))
        try writer.save()
        let context = try repository.generationContext(topicID: "go")
        let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
        let request = try LessonGenerationRequestBuilder.make(selection: LessonGenerationSelection(topicID: "go",
            objectiveKey: "expansion.go.concurrency.cancellation-race", format: "code",
            difficulty: "intermediate"), operationID: UUID(), context: context, registry: registry)
        let candidate = CandidateLesson(title: "Cancellation race", objectiveKey: request.objectiveKey,
            objective: request.objective, topicID: request.topicID, subtopicID: request.subtopicID,
            conceptIDs: request.conceptIDs, difficulty: request.difficulty, format: request.format,
            estimatedMinutes: 20, prerequisiteConceptIDs: request.prerequisiteConceptIDs,
            explanation: "Distinct cancellation explanation", workedExample: "Distinct worked example",
            exercise: "Distinct exercise", referenceAnswer: "Distinct reference",
            selfCheckCriteria: ["Check distinct behavior"])
        return try GeneratedLessonValidator.validate(candidate, request: request, context: context,
            registry: registry, requestedModel: "gpt-4o-2024-08-06", now: Date(timeIntervalSince1970: 30))
    }

    func testGeneratedVacancyPublishesOneCommittedCatalogWithoutReadingOrChangingOtherStates() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let committed = SwiftDataCatalogRepository(container: container)
        _ = try committed.importIfNeeded(BundledCatalogLoader.load())
        let lesson = try generatedFixture(committed, container: container)
        let writer = ModelContext(container)
        let slot = try XCTUnwrap(writer.fetch(FetchDescriptor<LessonSlot>()).first { $0.topicID == "go" })
        writer.delete(slot)
        try writer.save()
        let before = try committed.loadSnapshot()
        let repository = ReadingCatalogRepository(before)
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let detail = LessonDetailSnapshot(id: before.slots[0].lessonID, progress: nil,
                                          attempt: nil, content: .unavailable)
        repository.detailValue = detail
        _ = try store.loadDetail(lessonID: detail.id)
        _ = try store.loadHistory()
        _ = try store.loadCoverage()
        let unchanged = store.projection
        let readsBeforeInsertion = repository.reads
        let committedReceipt = try committed.acceptGeneratedLesson(lesson, now: Date(timeIntervalSince1970: 40))
        repository.insertionValue = committedReceipt
        repository.failCatalog = true
        repository.failHistory = true
        repository.failCoverage = true
        var published: [LearningExperienceProjection] = []
        let subscription = store.$projection.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }
        let returned = try store.acceptGeneratedLesson(lesson)
        XCTAssertEqual(returned.lessonID, lesson.definition.id)
        XCTAssertEqual(returned.assignedSlot?.slotIndex, slot.slotIndex)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(store.state.snapshot, committedReceipt.catalog)
        XCTAssertEqual(store.detailState, unchanged.detail)
        XCTAssertEqual(store.historyState, unchanged.history)
        XCTAssertEqual(store.coverageState, unchanged.coverage)
        XCTAssertEqual(repository.reads, readsBeforeInsertion) // no post-commit read
        XCTAssertEqual(repository.coverageReads, 1)
        XCTAssertEqual(repository.writes, 1)
    }

    func testRealGeneratedVacancyPublishesOnlyAfterCommitAndRetainsCurrentDetail() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let lesson = try generatedFixture(repository, container: container)
        let writer = ModelContext(container)
        let vacant = try XCTUnwrap(writer.fetch(FetchDescriptor<LessonSlot>()).first { $0.topicID == "go" })
        writer.delete(vacant)
        try writer.save()
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let before = try XCTUnwrap(store.state.snapshot)
        let detailID = try XCTUnwrap(before.slots.first?.lessonID)
        let detail = try store.loadDetail(lessonID: detailID)
        var publications: [LearningExperienceProjection] = []
        let subscription = store.$projection.dropFirst().sink { publications.append($0) }
        defer { subscription.cancel() }
        let result = try store.acceptGeneratedLesson(lesson, now: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(result.assignedSlot?.slotIndex, vacant.slotIndex)
        XCTAssertEqual(store.state.snapshot, try repository.loadSnapshot())
        XCTAssertEqual(store.state.snapshot?.slots.filter { $0.lessonID == result.lessonID }.count, 1)
        XCTAssertEqual(store.state.snapshot?.slots.filter { $0.lessonID != result.lessonID }, before.slots)
        XCTAssertEqual(store.detailState, .current(detail))
        XCTAssertEqual(store.historyState, .notLoaded)
        XCTAssertEqual(store.coverageState, .notLoaded)
    }

    func testGeneratedFailureNeverPublishesPrecommitReceiptOrRepairsIndependentFailures() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let committed = SwiftDataCatalogRepository(container: container)
        _ = try committed.importIfNeeded(BundledCatalogLoader.load())
        let lesson = try generatedFixture(committed, container: container)
        let repository = ReadingCatalogRepository(try committed.loadSnapshot())
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        repository.failHistory = true
        repository.failCoverage = true
        XCTAssertThrowsError(try store.loadHistory())
        XCTAssertThrowsError(try store.loadCoverage())
        let baseline = store.projection
        repository.insertionError = LessonGenerationError.persistenceFailure
        repository.insertionValue = GeneratedLessonInsertionResult(lessonID: lesson.definition.id,
            assignedSlot: nil, catalog: baseline.catalog.snapshot!, history: [], coverage: .membershipUnavailable)
        var published = 0
        let subscription = store.$projection.dropFirst().sink { _ in published += 1 }
        defer { subscription.cancel() }
        XCTAssertThrowsError(try store.acceptGeneratedLesson(lesson)) {
            XCTAssertEqual($0 as? LessonGenerationError, .persistenceFailure)
        }
        XCTAssertEqual(published, 0)
        XCTAssertEqual(store.projection, baseline)
        repository.insertionError = nil
        _ = try store.acceptGeneratedLesson(lesson)
        XCTAssertEqual(store.historyState, baseline.history)
        XCTAssertEqual(store.coverageState, baseline.coverage)
        XCTAssertEqual(store.error, baseline.error)
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

    func testCurrentTopicProjectionUsesCurrentIDAndScopesSlotOrderedChoicesWithoutWrites() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let committedRepository = SwiftDataCatalogRepository(container: container)
        _ = try committedRepository.importIfNeeded(BundledCatalogLoader.load())
        let committed = try committedRepository.loadSnapshot()
        let goSlots = Array(committed.slots.filter { $0.topicID == "go" }
            .sorted { $0.slotIndex < $1.slotIndex }.prefix(2))
        let javaSlots = Array(committed.slots.filter { $0.topicID == "java" }
            .sorted { $0.slotIndex < $1.slotIndex }.prefix(1))
        XCTAssertEqual(goSlots.count, 2)
        XCTAssertEqual(javaSlots.count, 1)
        // Present slots out of order, leave design vacant, and reverse topic input order.
        let fixture = LearningCatalogSnapshot(topics: Array(committed.topics.reversed()),
            subtopics: committed.subtopics, concepts: committed.concepts,
            definitions: committed.definitions, progress: committed.progress,
            slots: Array(goSlots.reversed()) + javaSlots)
        let repository = ReadingCatalogRepository(fixture)
        let store = LearningCatalogStore(repository: repository)
        store.loadIfNeeded()
        let snapshot = try XCTUnwrap(store.state.snapshot)
        let selections: [(String?, String, [String])] = [
            (nil, "go", goSlots.map(\.lessonID)),
            ("missing", "go", goSlots.map(\.lessonID)),
            ("java", "java", javaSlots.map(\.lessonID)),
            ("design", "design", []),
            ("go", "go", goSlots.map(\.lessonID)),
            ("java", "java", javaSlots.map(\.lessonID))
        ]
        for (requested, expected, lessonIDs) in selections {
            let projection = try XCTUnwrap(LearningView.topicProjection(for: requested, in: snapshot))
            XCTAssertEqual(projection.topics.map(\.id), ["go", "java", "design", "perf", "security"])
            XCTAssertEqual(projection.selected.id, expected)
            XCTAssertEqual(LearningView.choices(for: projection.selected.id, in: snapshot).map(\.id), lessonIDs)
        }
        XCTAssertEqual(repository.reads, 1)
        XCTAssertEqual(repository.writes, 0)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
    }

    func testEmptyTopicProjectionHasNoFallbackAndDoesNotReadOrWrite() {
        let empty = LearningCatalogSnapshot(topics: [], subtopics: [], concepts: [],
                                            definitions: [], progress: [], slots: [])
        let repository = ReadingCatalogRepository(empty)
        XCTAssertNil(LearningView.topicProjection(for: nil, in: empty))
        XCTAssertNil(LearningView.topicProjection(for: "missing", in: empty))
        XCTAssertEqual(repository.reads, 0)
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
