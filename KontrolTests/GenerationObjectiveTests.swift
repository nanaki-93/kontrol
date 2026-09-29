import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class GenerationObjectiveTests: XCTestCase {
    func testSheetCancellationAndRetryIgnoreSupersededCompletion() throws {
        var submission = GenerationSheetSubmission()
        let first = try XCTUnwrap(submission.begin())
        XCTAssertTrue(submission.isRunning)
        XCTAssertNil(submission.begin(), "A second click must not start another request")
        submission.retire() // Cancel or settings revision change, before transport returns.
        let retry = try XCTUnwrap(submission.begin()) // First lease has released.
        XCTAssertNotEqual(first, retry)
        XCTAssertFalse(submission.finish(first), "Late cancellation must not clear retry progress")
        XCTAssertTrue(submission.isRunning)
        XCTAssertNil(submission.begin(), "Late completion must not re-enable Generate")
        XCTAssertTrue(submission.finish(retry))
        XCTAssertFalse(submission.isRunning)
        XCTAssertFalse(submission.finish(retry), "Duplicate completion must not publish twice")
        let pending = try XCTUnwrap(submission.begin())
        submission.retire() // Dismiss before the task first runs.
        XCTAssertFalse(submission.finish(pending))
    }

    private func catalog() throws -> ValidatedCatalog { try BundledCatalogLoader.load() }

    private func membership(_ catalog: ValidatedCatalog) -> CurrentCatalogMembership {
        let value = catalog.value
        return CurrentCatalogMembership(catalogID: value.catalogID, catalogVersion: value.version,
            topicIDs: value.topics.map(\.id).sorted(), subtopicIDs: value.subtopics.map(\.id).sorted(),
            conceptIDs: value.concepts.map(\.id).sorted(), seededLessonIDs: value.lessons.map(\.id).sorted())
    }

    private func resource() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "generation-objectives", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func altered(_ change: (inout [String: Any], inout [[String: Any]]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: resource()) as? [String: Any])
        var entries = try XCTUnwrap(object["objectives"] as? [[String: Any]])
        change(&object, &entries)
        object["objectives"] = entries
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func rejects(_ change: (inout [String: Any], inout [[String: Any]]) -> Void,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let seed = try catalog()
        XCTAssertThrowsError(try GenerationObjectivesLoader.decodeAndValidate(altered(change),
            catalog: seed, membership: membership(seed)), file: file, line: line) {
            XCTAssertEqual($0 as? GenerationObjectivesError, .corrupt, file: file, line: line)
        }
    }

    func testBundledExpansionIsDistinctForEveryCurrentTopicAndExhaustsExplicitly() throws {
        let seed = try catalog()
        let registry = try GenerationObjectivesLoader.load(catalog: seed, membership: membership(seed))
        XCTAssertEqual(registry.version, 1)
        XCTAssertEqual(Set(registry.objectives.map(\.topicID)), Set(seed.value.topics.map(\.id)))
        XCTAssertTrue(Set(registry.objectives.map(\.key)).isDisjoint(with: Set(seed.value.lessons.map(\.objectiveKey))))
        for topic in seed.value.topics {
            let entries = try registry.unseen(topicID: topic.id, excluding: [])
            XCTAssertFalse(entries.isEmpty)
            XCTAssertThrowsError(try registry.unseen(topicID: topic.id, excluding: Set(entries.map(\.key)))) {
                XCTAssertEqual($0 as? GenerationObjectivesError, .exhausted)
                XCTAssertEqual(($0 as? GenerationObjectivesError)?.message, "No unseen generation objectives available")
            }
        }
    }

    func testInvalidRegistryAndRetiredMembershipFailClosed() throws {
        try rejects { object, _ in object["version"] = 2 }
        try rejects { _, entries in entries.append(entries[0]) }
        try rejects { _, entries in entries[0]["key"] = "go.concurrency.cancel-work" }
        try rejects { _, entries in entries[0]["text"] = " \n" }
        try rejects { _, entries in entries[0]["subtopicID"] = "java.concurrency" }
        try rejects { _, entries in entries[0]["conceptIDs"] = ["java.concurrency.shutdown"] }
        try rejects { _, entries in entries[0]["conceptIDs"] = ["go.concurrency.cancel-work", "go.concurrency.cancel-work"] }
        try rejects { _, entries in entries[0]["prerequisiteConceptIDs"] = ["unknown"] }
        try rejects { _, entries in entries[0]["prerequisiteConceptIDs"] = ["go.concurrency.cancel-work", "go.concurrency.cancel-work"] }
        try rejects { _, entries in entries[0]["formats"] = ["video"] }
        try rejects { _, entries in entries[0]["difficulties"] = ["expert"] }
        try rejects { _, entries in entries[0]["formats"] = [] }
        let seed = try catalog()
        let old = membership(seed)
        let retired = CurrentCatalogMembership(catalogID: old.catalogID, catalogVersion: old.catalogVersion,
            topicIDs: old.topicIDs.filter { $0 != "go" }, subtopicIDs: old.subtopicIDs,
            conceptIDs: old.conceptIDs, seededLessonIDs: old.seededLessonIDs)
        XCTAssertThrowsError(try GenerationObjectivesLoader.decodeAndValidate(resource(), catalog: seed, membership: retired)) {
            XCTAssertEqual($0 as? GenerationObjectivesError, .corrupt)
        }
        XCTAssertThrowsError(try GenerationObjectivesLoader.decodeAndValidate(Data("{".utf8), catalog: seed, membership: old)) {
            XCTAssertEqual($0 as? GenerationObjectivesError, .corrupt)
        }
        XCTAssertThrowsError(try GenerationObjectivesLoader.decodeAndValidate(Data(repeating: 0, count: GenerationObjectivesLoader.maximumBytes + 1), catalog: seed, membership: old)) {
            XCTAssertEqual($0 as? GenerationObjectivesError, .corrupt)
        }
        XCTAssertThrowsError(try GenerationObjectivesLoader.load(from: Bundle(for: Self.self), catalog: seed, membership: old)) {
            XCTAssertEqual($0 as? GenerationObjectivesError, .missing)
        }
    }

    private func generationContext(_ seed: ValidatedCatalog, completed: Set<String> = [],
                                   terminal: [TerminalLessonMatch] = []) -> LessonGenerationContext {
        LessonGenerationContext(catalog: seed, membership: membership(seed),
            completedConceptIDs: completed, terminal: terminal, definitions: [], startedPins: [])
    }

    private func terminal(_ key: String, topic: String = "go", status: LessonProgressStatus = .completed,
                          concepts: [String] = ["go.concurrency.cancel-work"], date: Date? = nil) -> TerminalLessonMatch {
        TerminalLessonMatch(status: status,
            metadata: LessonMatchMetadata(id: UUID().uuidString, objectiveKey: key,
                conceptIDs: concepts, contentHash: nil), topicID: topic, format: "code", date: date)
    }

    private func selection(_ key: String? = "expansion.go.concurrency.cancellation-race",
                           format: String = "code", difficulty: String = "intermediate") -> LessonGenerationSelection {
        LessonGenerationSelection(topicID: "go", objectiveKey: key, format: format, difficulty: difficulty)
    }

    func testRequestIsCanonicalDetachedAndPrivacyAllowlisted() throws {
        let seed = try catalog()
        let registry = try GenerationObjectivesLoader.load(catalog: seed, membership: membership(seed))
        let completed: Set<String> = ["go.concurrency.cancel-work", "java.concurrency.shutdown", "retired.concept"]
        let evidence = [terminal("old.go", date: Date(timeIntervalSince1970: 123)),
                        terminal("old.java", topic: "java", concepts: ["java.concurrency.shutdown"])]
        let context = generationContext(seed, completed: completed, terminal: evidence)
        let id = UUID()
        let request = try LessonGenerationRequestBuilder.make(selection: selection(), operationID: id,
            context: context, registry: registry)
        let canonical = try XCTUnwrap(registry.objectives.first { $0.key == request.objectiveKey })
        XCTAssertEqual(request.operationID, id)
        XCTAssertEqual(request.requestSchemaVersion, 1)
        XCTAssertEqual(request.catalogID, seed.value.catalogID)
        XCTAssertEqual(request.catalogVersion, seed.value.version)
        XCTAssertEqual(request.objectiveRegistryVersion, registry.version)
        XCTAssertEqual(request.objective, canonical.text)
        XCTAssertEqual(request.conceptIDs, canonical.conceptIDs)
        XCTAssertEqual(request.prerequisiteConceptIDs, canonical.prerequisiteConceptIDs)
        XCTAssertEqual(request.completedConceptIDs, ["go.concurrency.cancel-work"])
        XCTAssertEqual(request.excludedObjectives.map(\.key), ["old.go"])
        XCTAssertEqual(context.terminal.count, 2) // full local evidence not truncated or sent
        let bytes = try request.encodedData()
        XCTAssertLessThanOrEqual(bytes.count, LessonGenerationRequest.maximumBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["operationID", "requestSchemaVersion", "catalogID", "catalogVersion",
            "objectiveRegistryVersion", "topicID", "subtopicID", "conceptIDs", "objectiveKey", "objective",
            "difficulty", "format", "prerequisiteConceptIDs", "completedConceptIDs", "excludedObjectives"])
        let wire = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for forbidden in ["referenceAnswer", "answerDraft", "attempt", "completedAt", "date", "task", "project",
                          "schedule", "focus", "credential", "old.java", "retired.concept", "java.concurrency.shutdown"] {
            XCTAssertFalse(wire.lowercased().contains(forbidden.lowercased()), forbidden)
        }
    }

    func testSiblingSubtopicEvidenceStaysLocalAndRelevantPrerequisitesRemainRemote() throws {
        let seed = try catalog()
        let registry = try GenerationObjectivesLoader.load(catalog: seed, membership: membership(seed))
        let network = "go.network.deadline-boundaries"
        let records = [terminal(network, concepts: [network]),
                       terminal("historical.network", concepts: [network]),
                       terminal("historical.mixed", concepts: [network, "go.concurrency.cancel-work"]),
                       terminal("legacy.empty", concepts: []),
                       terminal("historical.prerequisite", concepts: ["go.concurrency.cancel-work"])]
        let context = generationContext(seed, completed: [network, "go.concurrency.cancel-work"], terminal: records)
        let request = try LessonGenerationRequestBuilder.make(selection: selection(), operationID: UUID(),
            context: context, registry: registry)
        let wire = try XCTUnwrap(String(data: request.encodedData(), encoding: .utf8))
        XCTAssertFalse(wire.contains("go.network"))
        XCTAssertFalse(wire.contains("historical.network"))
        XCTAssertFalse(wire.contains("legacy.empty"))
        XCTAssertEqual(request.completedConceptIDs, ["go.concurrency.cancel-work"])
        XCTAssertEqual(request.excludedObjectives.map(\.key), ["historical.mixed", "historical.prerequisite"])
        XCTAssertEqual(request.excludedObjectives.first?.conceptIDs, ["go.concurrency.cancel-work"])
        XCTAssertEqual(context.terminal.count, records.count)
        XCTAssertTrue(context.completedConceptIDs.contains(network))
        XCTAssertEqual(LessonDeduplication.decide(candidate: LessonMatchMetadata(id: "generated.fixture",
            objectiveKey: network, conceptIDs: [network],
            contentHash: "sha256:" + String(repeating: "a", count: 64)), terminal: context.terminal),
            .rejected(.objectiveConceptOverlap))
    }

    func testCompleteProviderEnvelopeMustFitAtSerializationBoundary() throws {
        struct ProviderBody: Encodable {
            let request: LessonGenerationRequest
            let instructions: String
        }
        let seed = try catalog()
        let registry = try GenerationObjectivesLoader.load(catalog: seed, membership: membership(seed))
        let request = try LessonGenerationRequestBuilder.make(selection: selection(), operationID: UUID(),
            context: generationContext(seed, completed: ["go.concurrency.cancel-work"]), registry: registry)
        let baseline = try LessonGenerationRequest.encodedProviderBody(
            ProviderBody(request: request, instructions: ""))
        let remaining = LessonGenerationRequest.maximumBytes - baseline.count
        let exact = try LessonGenerationRequest.encodedProviderBody(
            ProviderBody(request: request, instructions: String(repeating: "x", count: remaining)))
        XCTAssertEqual(exact.count, LessonGenerationRequest.maximumBytes)
        XCTAssertThrowsError(try LessonGenerationRequest.encodedProviderBody(
            ProviderBody(request: request, instructions: String(repeating: "x", count: remaining + 1)))) {
            XCTAssertEqual($0 as? LessonGenerationError, .oversizedRequest)
        }
        XCTAssertLessThanOrEqual(try request.encodedData().count, LessonGenerationRequest.maximumDomainBytes)
    }

    func testScopeAndPrerequisitesFailBeforeAnyProviderCall() throws {
        let seed = try catalog()
        let registry = try GenerationObjectivesLoader.load(catalog: seed, membership: membership(seed))
        let empty = generationContext(seed)
        func failure(_ selected: LessonGenerationSelection, _ context: LessonGenerationContext,
                     _ expected: LessonGenerationError, registry: GenerationObjectives? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try LessonGenerationRequestBuilder.make(selection: selected,
                operationID: UUID(), context: context, registry: registry ?? registryValue), file: file, line: line) {
                XCTAssertEqual($0 as? LessonGenerationError, expected, file: file, line: line)
            }
        }
        let registryValue = registry
        failure(selection(), empty, .unmetPrerequisites)
        let ready = generationContext(seed, completed: ["go.concurrency.cancel-work"])
        failure(selection(format: "design"), ready, .invalidScope)
        failure(selection(difficulty: "advanced"), ready, .invalidScope)
        failure(selection("not-authored"), ready, .invalidScope)
        failure(LessonGenerationSelection(topicID: "retired", objectiveKey: nil,
            format: "code", difficulty: "intermediate"), ready, .invalidScope)
        failure(selection(), generationContext(seed, completed: ["go.concurrency.cancel-work"],
            terminal: [terminal("expansion.go.concurrency.cancellation-race", status: .dismissed)]),
            .exhaustedObjectives)
        let wrong = CurrentCatalogMembership(catalogID: "other", catalogVersion: empty.membership.catalogVersion,
            topicIDs: empty.membership.topicIDs, subtopicIDs: empty.membership.subtopicIDs,
            conceptIDs: empty.membership.conceptIDs, seededLessonIDs: empty.membership.seededLessonIDs)
        let stale = LessonGenerationContext(catalog: seed, membership: wrong, completedConceptIDs: [],
            terminal: [], definitions: [], startedPins: [])
        failure(selection(), stale, .staleContext)
        let corrupt = try JSONDecoder().decode(GenerationObjectives.self, from: altered { object, _ in object["version"] = 9 })
        failure(selection(), ready, .corruptObjectives, registry: corrupt)
        // A provider receives only successfully constructed requests.
        XCTAssertNoThrow(try LessonGenerationRequestBuilder.make(selection: selection(),
            operationID: UUID(), context: ready, registry: registry))
    }

    func testRemoteExclusionsAreDeterministicallyBoundedWithoutDroppingLocalEvidence() throws {
        let seed = try catalog()
        let registry = try GenerationObjectivesLoader.load(catalog: seed, membership: membership(seed))
        let records = (0..<80).map { terminal(String(format: "prior.%03d", $0)) } +
            [terminal("unrelated", topic: "java")]
        let context = generationContext(seed, completed: ["go.concurrency.cancel-work"], terminal: records)
        let one = try LessonGenerationRequestBuilder.make(selection: selection(), operationID: UUID(uuidString:
            "00000000-0000-0000-0000-000000000001")!, context: context, registry: registry)
        let two = try LessonGenerationRequestBuilder.make(selection: selection(), operationID: one.operationID,
            context: generationContext(seed, completed: context.completedConceptIDs, terminal: records.reversed()),
            registry: registry)
        XCTAssertEqual(try one.encodedData(), try two.encodedData())
        XCTAssertEqual(one.excludedObjectives.count + one.completedConceptIDs.count, 50)
        XCTAssertEqual(one.excludedObjectives.first?.key, "prior.000")
        XCTAssertEqual(one.excludedObjectives.last?.key, "prior.049")
        XCTAssertEqual(context.terminal.count, 81)
        XCTAssertTrue(context.terminal.contains { $0.metadata.objectiveKey == "prior.079" })
        // Truncated remote hints never replace the full local acceptance evidence.
        let localCandidate = LessonMatchMetadata(id: "generated.fixture", objectiveKey: "prior.079",
            conceptIDs: ["go.concurrency.cancel-work"], contentHash: "sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(LessonDeduplication.decide(candidate: localCandidate, terminal: context.terminal),
            .rejected(.objectiveConceptOverlap))
        let huge = generationContext(seed, completed: ["go.concurrency.cancel-work"],
            terminal: [terminal(String(repeating: "z", count: 40_000)), terminal("small")])
        let bounded = try LessonGenerationRequestBuilder.make(selection: selection(), operationID: one.operationID,
            context: huge, registry: registry)
        XCTAssertLessThanOrEqual(try bounded.encodedData().count, 32 * 1024)
        XCTAssertEqual(bounded.excludedObjectives.map(\.key), ["small"])
        XCTAssertEqual(huge.terminal.count, 2)
    }

    func testOversizedCanonicalScopeFailsRatherThanSendingAnUnboundedRequest() throws {
        let seed = try catalog()
        let key = String(repeating: "x", count: 33_000)
        let data = try altered { _, entries in entries[0]["key"] = key }
        let registry = try GenerationObjectivesLoader.decodeAndValidate(data,
            catalog: seed, membership: membership(seed))
        let selected = LessonGenerationSelection(topicID: "go", objectiveKey: key,
            format: "code", difficulty: "intermediate")
        XCTAssertThrowsError(try LessonGenerationRequestBuilder.make(selection: selected,
            operationID: UUID(), context: generationContext(seed,
                completed: ["go.concurrency.cancel-work"]), registry: registry)) {
            XCTAssertEqual($0 as? LessonGenerationError, .oversizedRequest)
        }
    }

    func testSheetPreviewOffersScopeAfterSeedExhaustionWithoutWritingOrNetworking() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(catalog())
        let before = try repository.loadSnapshot()
        let context = try repository.generationContext(topicID: "go")
        let registry = try GenerationObjectivesLoader.load(catalog: context.catalog, membership: context.membership)
        let offered = LessonGenerationSheet.available(context, registry: registry, topicID: "go")
        XCTAssertFalse(offered.isEmpty)
        XCTAssertEqual(offered.first?.text, registry.objectives.first { $0.topicID == "go" }?.text)
        let consumed = generationContext(context.catalog, terminal: offered.map { terminal($0.key) })
        XCTAssertTrue(LessonGenerationSheet.available(consumed, registry: registry, topicID: "go").isEmpty)
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertEqual(LessonGenerationSheet.failureMessage(.rateLimited(retryAfter: Date())),
                       "OpenAI rate limited this request. Retry when permitted.")
        XCTAssertEqual(LessonGenerationSheet.failureMessage(.persistenceFailure),
                       "Lesson not saved. Check local storage and retry.")
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(LessonGenerationSheet.retryAllowed(at: now, notBefore: now.addingTimeInterval(1)))
        XCTAssertTrue(LessonGenerationSheet.retryAllowed(at: now, notBefore: now))
        XCTAssertTrue(LessonGenerationSheet.retryAllowed(at: now, notBefore: nil))
    }

    func testLoadingAndFailureNeverWriteLearningState() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let seed = try catalog()
        _ = try SwiftDataCatalogRepository(container: container).importIfNeeded(seed)
        let context = ModelContext(container)
        let before = try context.fetch(FetchDescriptor<LessonDefinition>()).count
        let slotsBefore = try context.fetch(FetchDescriptor<LessonSlot>()).map(\.key).sorted()
        let membershipBefore = try context.fetch(FetchDescriptor<CatalogMembership>()).map(\.payload)
        _ = try GenerationObjectivesLoader.load(catalog: seed, membership: membership(seed))
        XCTAssertThrowsError(try GenerationObjectivesLoader.decodeAndValidate(Data(), catalog: seed, membership: membership(seed)))
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonDefinition>()).count, before)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LessonProgress>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LessonSlot>()).map(\.key).sorted(), slotsBefore)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CatalogMembership>()).map(\.payload), membershipBefore)
    }
}
