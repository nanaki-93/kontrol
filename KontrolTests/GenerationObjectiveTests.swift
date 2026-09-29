import Foundation
import SwiftData
import XCTest
@testable import Kontrol

@MainActor
final class GenerationObjectiveTests: XCTestCase {
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
