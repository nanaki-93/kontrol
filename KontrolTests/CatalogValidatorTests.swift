import Foundation
import XCTest
@testable import Kontrol

final class CatalogValidatorTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Catalog", withExtension: nil))
        return try Data(contentsOf: directory.appendingPathComponent(name + ".json"))
    }

    private func valid() throws -> CatalogDTO {
        try JSONDecoder().decode(CatalogDTO.self, from: fixture("valid"))
    }

    private func rejects(_ expected: CatalogValidationError.Issue,
                         _ change: (inout CatalogDTO) -> Void,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        var value = try valid()
        change(&value)
        XCTAssertThrowsError(try CatalogValidator.validate(value), file: file, line: line) { error in
            XCTAssertEqual(error as? CatalogValidationError, .invalid(expected), file: file, line: line)
        }
    }

    func testValidFixtureDecodesAndValidatesWithoutAStore() throws {
        let result = try CatalogValidator.decodeAndValidate(fixture("valid"))
        XCTAssertEqual(result.value.catalogID, "starter")
        XCTAssertEqual(result.value.lessons.count, 1)
    }

    func testMalformedAndMissingJSONFieldsAreBoundedErrors() throws {
        XCTAssertThrowsError(try CatalogValidator.decodeAndValidate(fixture("malformed"))) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.malformedJSON))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("valid")) as? [String: Any])
        object.removeValue(forKey: "lessons")
        XCTAssertThrowsError(try CatalogValidator.decodeAndValidate(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.malformedJSON))
        }
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("valid")) as? [String: Any])
        var lessons = try XCTUnwrap(object["lessons"] as? [[String: Any]])
        lessons[0].removeValue(forKey: "objective")
        object["lessons"] = lessons
        XCTAssertThrowsError(try CatalogValidator.decodeAndValidate(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.malformedJSON))
        }
        XCTAssertThrowsError(try CatalogValidator.decodeAndValidate(Data(repeating: 0, count: CatalogValidator.maximumBytes + 1))) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.oversizedCatalog))
        }
    }

    func testEntryBoundPrecedesGraphAndFingerprintWalks() throws {
        try rejects(.oversizedCatalog) { value in
            value.lessons = Array(repeating: value.lessons[0], count: 10_000)
        }
    }

    func testIdentifiersAndParents() throws {
        try rejects(.invalidCatalogIdentity) { $0.catalogID = " \n" }
        try rejects(.invalidVersion) { $0.version = 0 }
        try rejects(.emptyCollection) { $0.topics = [] }
        try rejects(.duplicateID) { $0.topics.append($0.topics[0]) }
        try rejects(.duplicateID) { $0.subtopics.append($0.subtopics[0]) }
        try rejects(.duplicateID) { $0.concepts.append($0.concepts[0]) }
        try rejects(.duplicateID) { $0.lessons.append($0.lessons[0]) }
        try rejects(.duplicateID) { $0.lessons[0].id = $0.concepts[0].id }
        try rejects(.invalidIdentity) { $0.concepts[0].id = " " }
        try rejects(.invalidParent) { $0.subtopics[0].topicID = "unknown" }
        try rejects(.invalidParent) { $0.concepts[0].subtopicID = "unknown" }
        try rejects(.invalidParent) { $0.lessons[0].subtopicID = "unknown" }
        try rejects(.invalidParent) { $0.lessons[0].topicID = "unknown" }
        try rejects(.missingMetadata) { $0.topics[0].name = " " }
    }

    func testConceptAndPrerequisiteGraphs() throws {
        try rejects(.invalidConceptReference) { $0.concepts[0].prerequisiteConceptIDs = ["unknown"] }
        try rejects(.invalidConceptReference) { $0.lessons[0].conceptIDs = ["unknown"] }
        try rejects(.invalidConceptReference) { $0.lessons[0].prerequisiteConceptIDs = ["unknown"] }
        try rejects(.emptyConceptSet) { $0.lessons[0].conceptIDs = [] }
        try rejects(.duplicateReference) { $0.lessons[0].conceptIDs = ["go.cancel", "go.cancel"] }
        try rejects(.duplicateReference) { $0.concepts[1].prerequisiteConceptIDs = ["go.cancel", "go.cancel"] }
        try rejects(.cyclicPrerequisites) { $0.concepts[0].prerequisiteConceptIDs = ["go.cancel"] }
        try rejects(.cyclicPrerequisites) { $0.concepts[0].prerequisiteConceptIDs = ["go.deadline"] }
        try rejects(.invalidConceptReference) {
            $0.topics.append(TopicDTO(id: "java", name: "Java"))
            $0.subtopics.append(SubtopicDTO(id: "java.core", topicID: "java", name: "Core"))
            $0.concepts[1].subtopicID = "java.core"
        }
    }

    func testLaterInvalidDefinitionRejectsTheEntireCatalog() throws {
        try rejects(.missingAnswer) {
            var second = $0.lessons[0]
            second.id = "go.cancel.2"
            second.referenceAnswer = "  "
            $0.lessons.append(second)
        }
        try rejects(.invalidFingerprint) {
            var second = $0.lessons[0]
            second.id = "go.cancel.2"
            second.exercise += " Altered after signing."
            $0.lessons.append(second)
        }
    }

    func testDirectAndDecodedValidationRejectUnchangedHashAfterContentEdit() throws {
        var value = try valid()
        value.lessons[0].workedExample += " Changed."
        XCTAssertThrowsError(try CatalogValidator.validate(value)) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.invalidFingerprint))
        }
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("valid")) as? [String: Any])
        var lessons = try XCTUnwrap(raw["lessons"] as? [[String: Any]])
        lessons[0]["workedExample"] = value.lessons[0].workedExample
        raw["lessons"] = lessons
        XCTAssertThrowsError(try CatalogValidator.decodeAndValidate(JSONSerialization.data(withJSONObject: raw))) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalid(.invalidFingerprint))
        }
    }

    func testNormalizationAndMetadataDoNotChangeTeachingFingerprint() throws {
        var value = try valid()
        let original = value.lessons[0].normalizedContentHash
        value.lessons[0].objective = "An edited learning objective"
        value.lessons[0].title = "Edited title"
        value.lessons[0].explanation = "  \n" + value.lessons[0].explanation + "\t"
        XCTAssertEqual(CatalogValidator.fingerprint(for: value.lessons[0]), original)
        XCTAssertNoThrow(try CatalogValidator.validate(value))
        try rejects(.invalidFingerprint) { $0.lessons[0].normalizedContentHash = original.uppercased() }
    }

    func testLessonMetadataAndEveryRequiredSection() throws {
        try rejects(.unsupportedDifficulty) { $0.lessons[0].difficulty = "expert" }
        try rejects(.unsupportedFormat) { $0.lessons[0].format = "video" }
        try rejects(.unsupportedSource) { $0.lessons[0].source = "remote" }
        try rejects(.invalidEstimate) { $0.lessons[0].estimatedMinutes = 0 }
        try rejects(.invalidContentVersion) { $0.lessons[0].contentVersion = 0 }
        try rejects(.missingMetadata) { $0.lessons[0].objectiveKey = " " }
        try rejects(.missingMetadata) { $0.lessons[0].objective = " \n" }
        try rejects(.missingMetadata) { $0.lessons[0].normalizedContentHash = "\n" }
        try rejects(.missingMetadata) { $0.lessons[0].provenance = " " }
        try rejects(.missingExplanation) { $0.lessons[0].explanation = " \n" }
        try rejects(.missingExample) { $0.lessons[0].workedExample = "" }
        try rejects(.missingExercise) { $0.lessons[0].exercise = " " }
        try rejects(.missingAnswer) { $0.lessons[0].referenceAnswer = "\t" }
        try rejects(.missingSelfCheck) { $0.lessons[0].selfCheckCriteria = [] }
        try rejects(.missingSelfCheck) { $0.lessons[0].selfCheckCriteria = [" "] }
    }
}
