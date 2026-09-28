import Foundation
import XCTest
@testable import Kontrol

final class BundledCatalogTests: XCTestCase {
    func testPackagedAppResourceContainsReviewedFortyLessonContract() throws {
        // The hosted test loads the app bundle, not a source-tree fixture or test copy.
        let appBundle = Bundle.main
        XCTAssertNotNil(appBundle.url(forResource: "starter-catalog", withExtension: "json"))
        let catalog = try BundledCatalogLoader.load(from: appBundle).value
        XCTAssertEqual(catalog.catalogID, "kontrol.starter")
        XCTAssertEqual(catalog.version, 2)
        XCTAssertEqual(catalog.topics.map(\.name),
                       ["Go", "Java", "System Design", "Performance", "Security"])
        XCTAssertEqual(catalog.lessons.count, 40)
        XCTAssertEqual(catalog.topics.map(\.id), ["go", "java", "design", "perf", "security"])
        let goKeys: Set<String> = [
            "go.concurrency.cancel-work", "go.testing.case-design",
            "go.interfaces.consumer-contract", "go.performance.comparable-benchmarks",
            "go.concurrency.leak-diagnosis", "go.concurrency.channel-close-owner",
            "go.errors.preserve-context", "go.network.deadline-boundaries"
        ]
        XCTAssertEqual(Set(catalog.lessons.filter { $0.topicID == "go" }.map(\.objectiveKey)), goKeys)
        XCTAssertTrue(catalog.lessons.contains { $0.id == "go.concurrency.cancel-work.v1" })
        let javaKeys: Set<String> = [
            "java.concurrency.task-lifecycle", "java.collections.key-contract",
            "java.testing.case-design", "java.jvm.profile-interpretation",
            "java.io.resource-ownership", "java.language.value-boundaries",
            "java.concurrency.shutdown", "java.spring.transaction-scope"
        ]
        XCTAssertEqual(Set(catalog.lessons.filter { $0.topicID == "java" }.map(\.objectiveKey)), javaKeys)
        XCTAssertTrue(catalog.lessons.contains { $0.id == "java.io.resource-ownership.v1" })
        let designKeys: Set<String> = [
            "design.api.rate-limit-consistency", "design.queues.delivery-guarantees",
            "design.reliability.retry-budget", "design.cache.freshness",
            "design.api.deduplicate-writes", "design.queues.bounded-load",
            "design.storage.partition-key", "design.reliability.recovery-plan"
        ]
        XCTAssertEqual(Set(catalog.lessons.filter { $0.topicID == "design" }.map(\.objectiveKey)), designKeys)
        XCTAssertTrue(catalog.lessons.contains { $0.id == "design.api.deduplicate-writes.v1" })
        let perfKeys: Set<String> = [
            "perf.database.query-count", "perf.cpu.hot-path", "perf.memory.allocations",
            "perf.network.tail-latency", "perf.database.index-access",
            "perf.cache.hit-rate-tradeoff", "perf.testing.representative-load",
            "perf.concurrency.queueing"
        ]
        let perfLessons = catalog.lessons.filter { $0.topicID == "perf" }
        XCTAssertEqual(Set(perfLessons.map(\.objectiveKey)), perfKeys)
        XCTAssertTrue(perfLessons.contains { $0.id == "perf.database.query-count.v1" })
        XCTAssertEqual(Set(perfLessons.map(\.exercise)).count, 8)
        XCTAssertEqual(Set(perfLessons.map(\.referenceAnswer)).count, 8)
        XCTAssertTrue(perfLessons.allSatisfy { $0.selfCheckCriteria.count >= 3 })
        let securityKeys: Set<String> = [
            "security.auth.token-validation", "security.api.object-access",
            "security.secrets.lifecycle", "security.design.trust-boundaries",
            "security.input.boundary-validation", "security.auth.session-lifecycle",
            "security.dependencies.risk-review", "security.observability.safe-audit"
        ]
        let securityLessons = catalog.lessons.filter { $0.topicID == "security" }
        XCTAssertEqual(Set(securityLessons.map(\.objectiveKey)), securityKeys)
        XCTAssertTrue(securityLessons.contains { $0.id == "security.api.object-access.v1" })
        XCTAssertEqual(Set(securityLessons.map(\.exercise)).count, 8)
        XCTAssertEqual(Set(securityLessons.map(\.referenceAnswer)).count, 8)
        let rateLimit = try XCTUnwrap(catalog.lessons.first { $0.id == "design.api.rate-limit-consistency.v1" })
        XCTAssertTrue(rateLimit.workedExample.contains("one token every 12 seconds"))
        XCTAssertTrue(rateLimit.workedExample.contains("not enforce a strict maximum of five attempts in any rolling minute"))
        let designLessons = catalog.lessons.filter { $0.topicID == "design" }
        XCTAssertEqual(Set(designLessons.map(\.exercise)).count, 8)
        XCTAssertEqual(Set(designLessons.map(\.referenceAnswer)).count, 8)
        XCTAssertTrue(designLessons.allSatisfy { lesson in
            lesson.selfCheckCriteria.count >= 3 &&
            lesson.selfCheckCriteria.allSatisfy { $0.count >= 60 } &&
            lesson.referenceAnswer.count > lesson.exercise.count
        })
        // Retained V1 identities gained explicit objectives (and two changed
        // provenance); all other definitions are new in this release.
        let upgradedV1IDs: Set<String> = [
            "go.concurrency.cancel-work.v1", "java.io.resource-ownership.v1",
            "design.api.deduplicate-writes.v1", "perf.database.query-count.v1",
            "security.api.object-access.v1"
        ]
        for topic in catalog.topics {
            let lessons = catalog.lessons.filter { $0.topicID == topic.id }
            XCTAssertEqual(lessons.count, 8,
                           "Unexpected inventory for \(topic.id)")
            for lesson in lessons {
                XCTAssertEqual(lesson.source, "seed")
                XCTAssertEqual(lesson.contentVersion, upgradedV1IDs.contains(lesson.id) ? 2 : 1)
                XCTAssertEqual(lesson.normalizedContentHash, BundledCatalogLoader.fingerprint(for: lesson))
                XCTAssertEqual(lesson.objectiveKey, lesson.conceptIDs.first)
                XCTAssertFalse(lesson.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(lesson.provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertGreaterThan(lesson.explanation.count, 150)
                XCTAssertGreaterThan(lesson.workedExample.count, 150)
                XCTAssertGreaterThan(lesson.exercise.count, 100)
                XCTAssertGreaterThan(lesson.referenceAnswer.count, 150)
                XCTAssertGreaterThanOrEqual(lesson.selfCheckCriteria.count, 3)
                XCTAssertTrue(lesson.selfCheckCriteria.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            }
        }
        let expectedKeys = goKeys.union(javaKeys).union(designKeys).union(perfKeys).union(securityKeys)
        XCTAssertEqual(expectedKeys.count, 40)
        XCTAssertEqual(Set(catalog.lessons.map(\.objectiveKey)), expectedKeys)
        XCTAssertEqual(Set(catalog.lessons.map(\.id)).count, 40)
        XCTAssertEqual(Set(catalog.lessons.map(\.normalizedContentHash)).count, 40)
        // Four initial choices and four distinct eligible reserves per topic.
        for topicID in ["go", "java", "design", "perf", "security"] {
            XCTAssertEqual(catalog.lessons.filter {
                $0.topicID == topicID && $0.prerequisiteConceptIDs.isEmpty
            }.count, 8)
        }
    }

    func testPackagedResourceHasOnlyDefinitionsNotPersonalRecords() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "starter-catalog", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["catalogID", "version", "topics", "subtopics", "concepts", "lessons"]))
        let personalFields: Set<String> = [
            "progress", "attempts", "activeSlots", "slots", "answerDraft", "answerText",
            "completedAt", "dismissedAt", "startedAt", "assignedAt", "userID", "userEmail"
        ]
        func assertDefinitionOnly(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                XCTAssertTrue(Set(dictionary.keys).isDisjoint(with: personalFields))
                dictionary.values.forEach(assertDefinitionOnly)
            } else if let array = value as? [Any] {
                array.forEach(assertDefinitionOnly)
            }
        }
        assertDefinitionOnly(object)
    }

    func testChangedTeachingTextInvalidatesFingerprint() throws {
        let catalog = try BundledCatalogLoader.load(from: Bundle.main)
        var lesson = try XCTUnwrap(catalog.value.lessons.first)
        lesson.exercise += " Change after publishing."
        XCTAssertNotEqual(lesson.normalizedContentHash, BundledCatalogLoader.fingerprint(for: lesson))
        var modified = catalog.value
        modified.lessons[0] = lesson
        XCTAssertThrowsError(try CatalogValidator.validate(modified)) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.invalidFingerprint))
        }
        // The resource loader uses the same whole-input boundary; it cannot
        // accept an altered teaching section with the old fingerprint either.
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KontrolCatalog-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let resource = resources.appendingPathComponent("starter-catalog.json")
        let originalData = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "starter-catalog", withExtension: "json")))
        let alteredData = try XCTUnwrap(String(data: originalData, encoding: .utf8))
            .replacingOccurrences(of: lesson.exercise.replacingOccurrences(of: " Change after publishing.", with: ""),
                                  with: lesson.exercise)
        try Data(alteredData.utf8).write(to: resource)
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertThrowsError(try BundledCatalogLoader.load(from: bundle)) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.invalidFingerprint))
        }
    }
}
