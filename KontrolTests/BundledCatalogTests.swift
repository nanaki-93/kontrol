import Foundation
import XCTest
@testable import Kontrol

final class BundledCatalogTests: XCTestCase {
    func testPackagedAppResourceContainsEightGoAndJavaLessonsAndThreeOtherUsableTopics() throws {
        // The hosted test loads the app bundle, not a source-tree fixture or test copy.
        let appBundle = Bundle.main
        XCTAssertNotNil(appBundle.url(forResource: "starter-catalog", withExtension: "json"))
        let catalog = try BundledCatalogLoader.load(from: appBundle).value
        XCTAssertEqual(catalog.catalogID, "kontrol.starter")
        XCTAssertEqual(catalog.version, 2)
        XCTAssertEqual(Set(catalog.topics.map(\.name)),
                       Set(["Go", "Java", "System Design", "Performance", "Security"]))
        XCTAssertEqual(catalog.lessons.count, 19)
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
        for topic in catalog.topics {
            let lessons = catalog.lessons.filter { $0.topicID == topic.id }
            XCTAssertEqual(lessons.count, ["go", "java"].contains(topic.id) ? 8 : 1,
                           "Unexpected inventory for \(topic.id)")
            for lesson in lessons {
                XCTAssertEqual(lesson.source, "seed")
                XCTAssertEqual(lesson.contentVersion, 1)
                XCTAssertEqual(lesson.normalizedContentHash, BundledCatalogLoader.fingerprint(for: lesson))
                XCTAssertEqual(lesson.objectiveKey, lesson.conceptIDs.first)
                XCTAssertFalse(lesson.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(lesson.provenance.isEmpty)
                XCTAssertGreaterThan(lesson.explanation.count, 150)
                XCTAssertGreaterThan(lesson.workedExample.count, 150)
                XCTAssertGreaterThan(lesson.exercise.count, 100)
                XCTAssertGreaterThan(lesson.referenceAnswer.count, 150)
                XCTAssertGreaterThanOrEqual(lesson.selfCheckCriteria.count, 3)
            }
        }
        XCTAssertEqual(Set(catalog.lessons.map(\.objectiveKey)).count, 19)
        // Both authored topics have four initial choices and four distinct reserves.
        for topicID in ["go", "java"] {
            XCTAssertEqual(catalog.lessons.filter {
                $0.topicID == topicID && $0.prerequisiteConceptIDs.isEmpty
            }.count, 8)
        }
    }

    func testPackagedResourceHasOnlyDefinitionsNotPersonalRecords() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "starter-catalog", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["catalogID", "version", "topics", "subtopics", "concepts", "lessons"]))
        for lesson in try XCTUnwrap(object["lessons"] as? [[String: Any]]) {
            XCTAssertTrue(Set(lesson.keys).isDisjoint(with: ["progress", "attempts", "activeSlots", "answerDraft", "completedAt"]))
        }
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
