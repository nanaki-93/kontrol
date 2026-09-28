import Combine
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
private final class ReadingCatalogRepository: CatalogRepository {
    enum ReadError: Error { case unavailable }
    var value: LearningCatalogSnapshot
    var shouldFail = false
    private(set) var reads = 0
    private(set) var writes = 0

    init(_ value: LearningCatalogSnapshot) { self.value = value }

    func loadSnapshot() throws -> LearningCatalogSnapshot {
        reads += 1
        if shouldFail { throw ReadError.unavailable }
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
        throw ReadError.unavailable
    }

    func loadLesson(lessonID: String) throws -> LessonDetailSnapshot {
        reads += 1
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

    func testEmptyIsSuccessfulAndReadFailureIsRetryableNotEmpty() {
        let repository = ReadingCatalogRepository(snapshot())
        repository.shouldFail = true
        let store = LearningCatalogStore(repository: repository)
        var observed: [LearningCatalogReadState] = []
        let subscription = store.$state.sink { observed.append($0) }
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
