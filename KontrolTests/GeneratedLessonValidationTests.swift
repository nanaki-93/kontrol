import Foundation
import XCTest
@testable import Kontrol

final class GeneratedLessonValidationTests: XCTestCase {
    private func setupScope() throws -> (LessonGenerationRequest, LessonGenerationContext, GenerationObjectives) {
        let catalog = try BundledCatalogLoader.load()
        let value = catalog.value
        let membership = CurrentCatalogMembership(catalogID: value.catalogID, catalogVersion: value.version,
            topicIDs: value.topics.map(\.id).sorted(), subtopicIDs: value.subtopics.map(\.id).sorted(),
            conceptIDs: value.concepts.map(\.id).sorted(), seededLessonIDs: value.lessons.map(\.id).sorted())
        let registry = try GenerationObjectivesLoader.load(catalog: catalog, membership: membership)
        let context = LessonGenerationContext(catalog: catalog, membership: membership,
            completedConceptIDs: ["go.concurrency.cancel-work"], terminal: [], definitions: [], startedPins: [])
        let request = try LessonGenerationRequestBuilder.make(selection: LessonGenerationSelection(topicID: "go",
            objectiveKey: "expansion.go.concurrency.cancellation-race", format: "code", difficulty: "intermediate"),
            operationID: UUID(), context: context, registry: registry)
        return (request, context, registry)
    }

    private func payload(_ request: LessonGenerationRequest) -> [String: Any] {
        ["title": "A lesson", "objectiveKey": request.objectiveKey, "objective": request.objective,
         "topicID": request.topicID, "subtopicID": request.subtopicID,
         "conceptIDs": request.conceptIDs, "prerequisiteConceptIDs": request.prerequisiteConceptIDs,
         "difficulty": request.difficulty, "format": request.format, "estimatedMinutes": 20,
         "explanation": "A safe explanation", "workedExample": "```go\nfmt.Println(1)\n```",
         "exercise": "Write a test", "referenceAnswer": "A reference answer",
         "selfCheckCriteria": ["Check cancellation"]]
    }

    private func candidate(_ object: [String: Any]) throws -> CandidateLesson {
        try GeneratedLessonValidator.decode(JSONSerialization.data(withJSONObject: object))
    }

    private func validated(_ object: [String: Any], scope: (LessonGenerationRequest, LessonGenerationContext, GenerationObjectives)) throws -> ValidatedGeneratedLesson {
        try GeneratedLessonValidator.validate(candidate(object), request: scope.0, context: scope.1,
            registry: scope.2, requestedModel: "gpt-4o-2024-08-06", now: Date(timeIntervalSince1970: 100))
    }

    func testStrictJSONShapeAndTypesHaveNoPersistableResult() throws {
        let scope = try setupScope()
        let baseline = payload(scope.0)
        for key in baseline.keys {
            var object = baseline
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try candidate(object), "missing \(key)") {
                XCTAssertEqual($0 as? LessonGenerationError, .malformedResponse)
            }
        }
        for key in ["id", "source", "provenance", "normalizedContentHash", "contentVersion", "toolCalls"] {
            var object = baseline
            object[key] = "injected"
            XCTAssertThrowsError(try candidate(object), "unexpected \(key)") {
                XCTAssertEqual($0 as? LessonGenerationError, .malformedResponse)
            }
        }
        for raw in ["[]", "null", "{}", "{", "{\"estimatedMinutes\":true}"] {
            XCTAssertThrowsError(try GeneratedLessonValidator.decode(Data(raw.utf8))) {
                XCTAssertEqual($0 as? LessonGenerationError, .malformedResponse)
            }
        }
        var wrong = baseline
        wrong["estimatedMinutes"] = "20"
        XCTAssertThrowsError(try candidate(wrong))
        wrong["estimatedMinutes"] = 20.5
        XCTAssertThrowsError(try candidate(wrong))
        wrong["estimatedMinutes"] = true
        XCTAssertThrowsError(try candidate(wrong))
        let decimal = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: baseline, options: [.sortedKeys]), encoding: .utf8))
            .replacingOccurrences(of: "\"estimatedMinutes\":20", with: "\"estimatedMinutes\":20.0")
        XCTAssertThrowsError(try GeneratedLessonValidator.decode(Data(decimal.utf8)))
        XCTAssertThrowsError(try GeneratedLessonValidator.decode(Data(repeating: 0, count: GeneratedLessonValidator.maximumResponseBytes + 1)))
    }

    func testCanonicalIdentityProvenanceAndInertSections() throws {
        let scope = try setupScope()
        var object = payload(scope.0)
        object["objective"] = "Provider rewrite, not an identity"
        object["explanation"] = "<script>alert('inert')</script>\n![remote](https://invalid.example/img)"
        object["workedExample"] = "```sh\nrm -rf /not-executed\n```"
        let result = try validated(object, scope: scope)
        let lesson = result.definition
        XCTAssertEqual(lesson.id, "generated.\(scope.0.operationID.uuidString.lowercased())")
        XCTAssertEqual(lesson.objective, scope.0.objective)
        XCTAssertEqual(lesson.objectiveKey, scope.0.objectiveKey)
        XCTAssertEqual(lesson.source, "generated")
        XCTAssertEqual(lesson.contentVersion, 1)
        XCTAssertEqual(lesson.explanation, object["explanation"] as? String)
        XCTAssertEqual(lesson.workedExample, object["workedExample"] as? String)
        XCTAssertEqual(lesson.normalizedContentHash, CatalogValidator.fingerprint(
            explanation: lesson.explanation, workedExample: lesson.workedExample,
            exercise: lesson.exercise, referenceAnswer: lesson.referenceAnswer,
            selfCheckCriteria: lesson.selfCheckCriteria))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lesson.provenance.utf8)) as? [String: Any])
        XCTAssertEqual(Set(provenance.keys), ["version", "provider", "requestedModel", "generatedAt",
            "operationID", "requestSchemaVersion", "objectiveRegistryVersion"])
        XCTAssertEqual(provenance["provider"] as? String, "openai")
        XCTAssertEqual(provenance["version"] as? Int, 1)
        XCTAssertFalse(lesson.provenance.contains("Provider rewrite"))
        XCTAssertFalse(lesson.provenance.contains("script"))
        XCTAssertEqual(result.operationID, scope.0.operationID)
        XCTAssertThrowsError(try GeneratedLessonValidator.validate(candidate(object), request: scope.0,
            context: scope.1, registry: scope.2, requestedModel: "gpt-4o",
            returnedModel: "key with spaces", now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .invalidCandidate)
        }
    }

    func testScopeReferencesRequiredConceptsAndDuration() throws {
        let scope = try setupScope()
        let base = payload(scope.0)
        let cases: [(String, Any)] = [
            ("objectiveKey", "provider.relabel"), ("topicID", "java"), ("subtopicID", "java.concurrency"),
            ("conceptIDs", [scope.0.conceptIDs[0]]),
            ("conceptIDs", [scope.0.conceptIDs[0], "unknown"]),
            ("conceptIDs", [scope.0.conceptIDs[0], scope.0.conceptIDs[0]]),
            ("prerequisiteConceptIDs", ["unknown"]),
            ("prerequisiteConceptIDs", [scope.0.prerequisiteConceptIDs[0], scope.0.prerequisiteConceptIDs[0]]),
            ("difficulty", "advanced"), ("format", "video"),
            ("estimatedMinutes", 0), ("estimatedMinutes", 121)]
        for (key, value) in cases {
            var object = base
            object[key] = value
            XCTAssertThrowsError(try validated(object, scope: scope), "\(key): \(value)")
        }
        for value in [1, 120] {
            var object = base
            object["estimatedMinutes"] = value
            XCTAssertEqual(try validated(object, scope: scope).definition.estimatedMinutes, value)
        }
        var object = base
        object["conceptIDs"] = Array(repeating: scope.0.conceptIDs[0], count: 21)
        XCTAssertThrowsError(try validated(object, scope: scope))
        object = base
        object["prerequisiteConceptIDs"] = Array(repeating: scope.0.prerequisiteConceptIDs[0], count: 21)
        XCTAssertThrowsError(try validated(object, scope: scope))
    }

    func testUnicodeScalarLimitsBlankSectionsAndNFCFingerprint() throws {
        let scope = try setupScope()
        let base = payload(scope.0)
        for (key, maximum) in [("title", 200), ("objective", 1_000),
                               ("explanation", 12_000), ("workedExample", 12_000),
                               ("exercise", 12_000), ("referenceAnswer", 12_000)] {
            var object = base
            object[key] = String(repeating: "🧪", count: maximum)
            XCTAssertNoThrow(try validated(object, scope: scope), key)
            object[key] = String(repeating: "🧪", count: maximum + 1)
            XCTAssertThrowsError(try validated(object, scope: scope), key)
            object[key] = " \n\t"
            XCTAssertThrowsError(try validated(object, scope: scope), key)
        }
        for count in [0, 11] {
            var object = base
            object["selfCheckCriteria"] = Array(repeating: "Check", count: count)
            XCTAssertThrowsError(try validated(object, scope: scope))
        }
        var object = base
        object["selfCheckCriteria"] = [" \n"]
        XCTAssertThrowsError(try validated(object, scope: scope))
        object["selfCheckCriteria"] = [String(repeating: "🧪", count: 1_000)]
        XCTAssertNoThrow(try validated(object, scope: scope))
        object["selfCheckCriteria"] = [String(repeating: "🧪", count: 1_001)]
        XCTAssertThrowsError(try validated(object, scope: scope))
        object = base
        object["explanation"] = "  cafe\u{301}\n"
        let lesson = try validated(object, scope: scope).definition
        XCTAssertEqual(lesson.normalizedContentHash, CatalogValidator.fingerprint(explanation: "café",
            workedExample: lesson.workedExample, exercise: lesson.exercise,
            referenceAnswer: lesson.referenceAnswer, selfCheckCriteria: lesson.selfCheckCriteria))
    }

    func testExactContentTerminalOverlapAndStableIDCollision() throws {
        let scope = try setupScope()
        let base = payload(scope.0)
        let lesson = try validated(base, scope: scope).definition
        let metadata = LessonMatchMetadata(lesson)
        func context(terminal: [TerminalLessonMatch] = [], definitions: [LessonDefinitionSnapshot] = []) -> LessonGenerationContext {
            LessonGenerationContext(catalog: scope.1.catalog, membership: scope.1.membership,
                completedConceptIDs: scope.1.completedConceptIDs, terminal: terminal,
                definitions: definitions, startedPins: [])
        }
        let exact = TerminalLessonMatch(status: .completed, metadata: LessonMatchMetadata(id: "old",
            objectiveKey: "different", conceptIDs: ["other"], contentHash: metadata.contentHash))
        XCTAssertThrowsError(try GeneratedLessonValidator.validate(candidate(base), request: scope.0,
            context: context(terminal: [exact]), registry: scope.2, requestedModel: "gpt-4o", now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateContent)
        }
        XCTAssertThrowsError(try GeneratedLessonValidator.validate(candidate(base), request: scope.0,
            context: context(definitions: [lesson]), registry: scope.2, requestedModel: "gpt-4o", now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateIdentity)
        }
        var other = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(lesson)) as? [String: Any])
        other["id"] = "prior.generated"
        let installed = try JSONDecoder().decode(LessonDefinitionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: other))
        XCTAssertThrowsError(try GeneratedLessonValidator.validate(candidate(base), request: scope.0,
            context: context(definitions: [installed]), registry: scope.2, requestedModel: "gpt-4o", now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateContent)
        }
        let pinned = LessonGenerationContext(catalog: scope.1.catalog, membership: scope.1.membership,
            completedConceptIDs: scope.1.completedConceptIDs, terminal: [], definitions: [], startedPins: [installed])
        XCTAssertThrowsError(try GeneratedLessonValidator.validate(candidate(base), request: scope.0,
            context: pinned, registry: scope.2, requestedModel: "gpt-4o", now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateContent)
        }
        var edited = base
        edited["exercise"] = "A distinct exercise"
        let overlap = TerminalLessonMatch(status: .dismissed, metadata: LessonMatchMetadata(id: "old",
            objectiveKey: scope.0.objectiveKey, conceptIDs: scope.0.conceptIDs,
            contentHash: "sha256:" + String(repeating: "a", count: 64)))
        // The request builder will exclude this exact objective; it is never
        // permissible to relabel an excluded objective to bypass the matcher.
        XCTAssertThrowsError(try GeneratedLessonValidator.validate(candidate(edited), request: scope.0,
            context: context(terminal: [overlap]), registry: scope.2, requestedModel: "gpt-4o", now: .now)) {
            XCTAssertEqual($0 as? LessonGenerationError, .duplicateObjective)
        }
        let nearBoundary = TerminalLessonMatch(status: .completed, metadata: LessonMatchMetadata(id: "old",
            objectiveKey: scope.0.objectiveKey, conceptIDs: scope.0.conceptIDs + ["extra"],
            contentHash: "sha256:" + String(repeating: "a", count: 64)))
        XCTAssertEqual(LessonDeduplication.decide(candidate: metadata, terminal: [nearBoundary]), .eligible)
        let boundary = LessonMatchMetadata(id: "new", objectiveKey: scope.0.objectiveKey,
            conceptIDs: ["a", "b", "c", "d"], contentHash: metadata.contentHash)
        let fourOfFive = TerminalLessonMatch(status: .completed, metadata: LessonMatchMetadata(id: "old",
            objectiveKey: scope.0.objectiveKey, conceptIDs: ["a", "b", "c", "d", "e"],
            contentHash: "sha256:" + String(repeating: "a", count: 64)))
        let threeOfFive = TerminalLessonMatch(status: .dismissed, metadata: LessonMatchMetadata(id: "old",
            objectiveKey: scope.0.objectiveKey, conceptIDs: ["a", "b", "c", "e"],
            contentHash: "sha256:" + String(repeating: "a", count: 64)))
        XCTAssertEqual(LessonDeduplication.decide(candidate: boundary, terminal: [fourOfFive]),
                       .rejected(.objectiveConceptOverlap))
        XCTAssertEqual(LessonDeduplication.decide(candidate: boundary, terminal: [threeOfFive]), .eligible)
    }
}
