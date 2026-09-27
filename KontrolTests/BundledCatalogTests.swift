import Foundation
import XCTest
@testable import Kontrol

final class BundledCatalogTests: XCTestCase {
    func testPackagedAppResourceContainsFiveUsableOfflineLessons() throws {
        // The hosted test loads the app bundle, not a source-tree fixture or test copy.
        let appBundle = Bundle.main
        XCTAssertNotNil(appBundle.url(forResource: "starter-catalog", withExtension: "json"))
        let catalog = try BundledCatalogLoader.load(from: appBundle).value
        XCTAssertEqual(catalog.catalogID, "kontrol.starter")
        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(Set(catalog.topics.map(\.name)),
                       Set(["Go", "Java", "System Design", "Performance", "Security"]))
        XCTAssertEqual(catalog.lessons.count, 5)
        for topic in catalog.topics {
            let lessons = catalog.lessons.filter { $0.topicID == topic.id }
            XCTAssertFalse(lessons.isEmpty, "No offline lesson for \(topic.id)")
            for lesson in lessons {
                XCTAssertEqual(lesson.source, "seed")
                XCTAssertEqual(lesson.contentVersion, 1)
                XCTAssertEqual(lesson.normalizedContentHash, BundledCatalogLoader.fingerprint(for: lesson))
                XCTAssertEqual(lesson.objectiveKey, lesson.conceptIDs.first)
                XCTAssertFalse(lesson.provenance.isEmpty)
                XCTAssertGreaterThan(lesson.explanation.count, 150)
                XCTAssertGreaterThan(lesson.workedExample.count, 150)
                XCTAssertGreaterThan(lesson.exercise.count, 100)
                XCTAssertGreaterThan(lesson.referenceAnswer.count, 150)
                XCTAssertGreaterThanOrEqual(lesson.selfCheckCriteria.count, 3)
            }
        }
        XCTAssertEqual(Set(catalog.lessons.map(\.objectiveKey)).count, 5)
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
        let validStructure = try CatalogValidator.validate(modified)
        XCTAssertThrowsError(try BundledCatalogLoader.verifyFingerprints(in: validStructure)) {
            XCTAssertEqual($0 as? BundledCatalogError, .invalidFingerprint)
        }
    }
}
