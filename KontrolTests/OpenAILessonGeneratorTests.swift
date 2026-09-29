import XCTest
@testable import Kontrol

final class OpenAILessonGeneratorTests: XCTestCase {
    private final class StreamProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "api.openai.com" &&
                (request.url == OpenAILessonGenerator.endpoint || request.url?.path.hasPrefix("/v1/models/") == true)
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            // Data is delivered in pieces; the transport must stop at its cap even
            // when a server sends a well-formed HTTP response of unlimited length.
            for _ in 0..<300 { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 1024)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class RedirectProtocol: URLProtocol {
        static var foreignRequests = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if request.url?.host != "api.openai.com" { Self.foreignRequests += 1 }
            let target = URLRequest(url: URL(string: "https://untrusted.example/collect")!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                headerFields: ["Location": target.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class FakeCredentials: CredentialStore {
        func read(reference: String) throws -> Data { Data("test-only-key".utf8) }
        func save(_ credential: Data, reference: String) throws {}
        func remove(reference: String) throws {}
    }

    private final class LateTransport: OpenAIHTTPTransport {
        var response = Data()
        func send(_ request: URLRequest, maximumBytes: Int) async throws -> (HTTPURLResponse, Data) {
            // Deliberately ignores cancellation, as a slow or misbehaving transport might.
            try? await Task.sleep(for: .milliseconds(100))
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, response)
        }
    }

    private final class Intercept: OpenAIHTTPTransport {
        var calls = 0
        var request: URLRequest?
        var limit = 0
        var status = 200
        var headers: [String: String] = [:]
        var responseURL = OpenAILessonGenerator.endpoint
        var body = Data()
        var failure: Error?
        func send(_ request: URLRequest, maximumBytes: Int) async throws -> (HTTPURLResponse, Data) {
            calls += 1
            self.request = request
            limit = maximumBytes
            if let failure { throw failure }
            return (HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: headers)!, body)
        }
    }

    private func request() -> LessonGenerationRequest {
        LessonGenerationRequest(operationID: UUID(), requestSchemaVersion: 1, catalogID: "catalog", catalogVersion: 1,
            objectiveRegistryVersion: 1, topicID: "topic", subtopicID: "subtopic", conceptIDs: ["concept"],
            objectiveKey: "objective", objective: "Canonical objective", difficulty: "basic", format: "learn",
            prerequisiteConceptIDs: [], completedConceptIDs: [], excludedObjectives: [])
    }

    private func candidate() -> [String: Any] {
        ["title": "One", "objectiveKey": "objective", "objective": "Canonical objective",
         "topicID": "topic", "subtopicID": "subtopic", "conceptIDs": ["concept"],
         "difficulty": "basic", "format": "learn", "estimatedMinutes": 10,
         "prerequisiteConceptIDs": [], "explanation": "Explain", "workedExample": "Example",
         "exercise": "Exercise", "referenceAnswer": "Answer", "selfCheckCriteria": ["Check"]]
    }

    private func envelope(_ candidate: [String: Any], status: String = "completed", type: String = "output_text") -> Data {
        let text = String(data: try! JSONSerialization.data(withJSONObject: candidate), encoding: .utf8)!
        return try! JSONSerialization.data(withJSONObject: ["status": status,
            "output": [["type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": type, "text": text]]]]])
    }

    private func generator(_ intercept: Intercept, model: String = "gpt-4o-mini") -> OpenAILessonGenerator {
        OpenAILessonGenerator(model: model, credentialReference: UUID().uuidString,
                              credentials: FakeCredentials(), transport: intercept)
    }

    func testExplicitMetadataLookupDoesNotGenerate() async throws {
        let intercept = Intercept()
        intercept.responseURL = OpenAILessonGenerator.modelsEndpoint.appendingPathComponent("gpt-4o-mini")
        intercept.body = Data(#"{"object":"model","id":"gpt-4o-mini"}"#.utf8)
        let adapter = generator(intercept)
        XCTAssertEqual(intercept.calls, 0) // construction does not contact the provider
        try await adapter.testConnection()
        XCTAssertEqual(intercept.calls, 1)
        XCTAssertEqual(intercept.request?.url, intercept.responseURL)
        XCTAssertEqual(intercept.request?.httpMethod, "GET")
        XCTAssertNil(intercept.request?.httpBody)
        XCTAssertEqual(intercept.request?.timeoutInterval, 30)
        XCTAssertEqual(intercept.request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        XCTAssertEqual(intercept.limit, 256 * 1024)
    }

    func testMetadataFailuresAreBoundedAndSanitized() async {
        let intercept = Intercept()
        intercept.responseURL = OpenAILessonGenerator.modelsEndpoint.appendingPathComponent("gpt-4o-mini")
        let adapter = generator(intercept)
        for (status, expected) in [(401, LessonGenerationError.authentication), (403, .authorization),
                                   (404, .unsupportedModel), (429, .rateLimited(retryAfter: nil)),
                                   (500, .providerFailure), (302, .providerFailure)] {
            intercept.status = status
            intercept.body = Data("secret provider error".utf8)
            await assertConnectionError(expected) { try await adapter.testConnection() }
        }
        intercept.status = 200
        for body in [Data("{".utf8), Data(#"{"object":"model","id":"different"}"#.utf8)] {
            intercept.body = body
            await assertConnectionError(.malformedResponse) { try await adapter.testConnection() }
        }
        intercept.body = Data(repeating: 0, count: 256 * 1024 + 1)
        await assertConnectionError(.oversizedResponse) { try await adapter.testConnection() }
        intercept.failure = URLError(.timedOut)
        await assertConnectionError(.timeout) { try await adapter.testConnection() }
        intercept.failure = URLError(.notConnectedToInternet)
        await assertConnectionError(.offline) { try await adapter.testConnection() }
        XCTAssertEqual(intercept.calls, 11)
        let invalid = generator(intercept, model: "unknown")
        await assertConnectionError(.unsupportedModel) { try await invalid.testConnection() }
        XCTAssertEqual(intercept.calls, 11)
    }

    func testMetadataStreamingCapIsEnforcedBeforeFullBodyArrives() async {
        let adapter = OpenAILessonGenerator(model: "gpt-4o-mini", credentialReference: UUID().uuidString,
            credentials: FakeCredentials(), transport: BoundedOpenAITransport(protocolClasses: [StreamProtocol.self]))
        await assertConnectionError(.oversizedResponse) { try await adapter.testConnection() }
    }

    func testMetadataRedirectDoesNotForwardCredential() async {
        RedirectProtocol.foreignRequests = 0
        let adapter = OpenAILessonGenerator(model: "gpt-4o-mini", credentialReference: UUID().uuidString,
            credentials: FakeCredentials(), transport: BoundedOpenAITransport(protocolClasses: [RedirectProtocol.self]))
        await assertConnectionError(.providerFailure) { try await adapter.testConnection() }
        XCTAssertEqual(RedirectProtocol.foreignRequests, 0)
    }

    func testMetadataLateResponseAfterCancellationIsDiscarded() async {
        let late = LateTransport()
        late.response = Data(#"{"object":"model","id":"gpt-4o-mini"}"#.utf8)
        // The transport returns a valid metadata URL despite ignoring cancellation.
        let adapter = OpenAILessonGenerator(model: "gpt-4o-mini", credentialReference: UUID().uuidString,
            credentials: FakeCredentials(), transport: late)
        let task = Task { try await adapter.testConnection() }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { try await task.value; XCTFail("Cancelled metadata result must not be published") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("Unclassified cancellation") }
    }

    func testSingleBoundedPrivateRequestAndStrictSchema() async throws {
        let intercept = Intercept()
        intercept.body = envelope(candidate())
        let result = try await generator(intercept).generate(request())
        XCTAssertEqual(result.title, "One")
        XCTAssertEqual(intercept.calls, 1)
        XCTAssertEqual(intercept.limit, 256 * 1024)
        let sent = try XCTUnwrap(intercept.request)
        XCTAssertEqual(sent.url, OpenAILessonGenerator.endpoint)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.timeoutInterval, 30)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: String]])
        let remote = try XCTUnwrap(input.last?["content"])
        for forbidden in ["test-only-key", "answerHistory", "attempts", "tasks", "projects", "focusHistory", "credential"] {
            XCTAssertFalse(remote.contains(forbidden))
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(sent.httpBody).count, 32 * 1024)
    }

    func testProductionTransportEnforcesStreamingCapWithLocalURLProtocol() async {
        let generator = OpenAILessonGenerator(model: "gpt-4o-mini", credentialReference: UUID().uuidString,
            credentials: FakeCredentials(), transport: BoundedOpenAITransport(protocolClasses: [StreamProtocol.self]))
        await assertError(.oversizedResponse) { try await generator.generate(self.request()) }
    }

    func testProductionTransportNeverFollowsRedirectToForeignHost() async {
        RedirectProtocol.foreignRequests = 0
        let generator = OpenAILessonGenerator(model: "gpt-4o-mini", credentialReference: UUID().uuidString,
            credentials: FakeCredentials(), transport: BoundedOpenAITransport(protocolClasses: [RedirectProtocol.self]))
        await assertError(.providerFailure) { try await generator.generate(self.request()) }
        XCTAssertEqual(RedirectProtocol.foreignRequests, 0)
    }

    func testLateTransportResultAfterCancellationIsDiscarded() async {
        let late = LateTransport()
        late.response = envelope(candidate())
        let generator = OpenAILessonGenerator(model: "gpt-4o-mini", credentialReference: UUID().uuidString,
            credentials: FakeCredentials(), transport: late)
        let task = Task { try await generator.generate(request()) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled result must not be used") }
        catch let error as LessonGenerationError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("Unclassified cancellation") }
    }

    func testInvalidModelRejectedBeforeCredentialAndNetwork() async {
        let intercept = Intercept()
        await assertError(.unsupportedModel) { try await self.generator(intercept, model: "unknown").generate(self.request()) }
        XCTAssertEqual(intercept.calls, 0)
    }

    func testRefusalTruncationUnknownAndMalformedCandidate() async {
        let intercept = Intercept()
        let generator = generator(intercept)
        intercept.body = envelope(candidate(), type: "refusal")
        await assertError(.refusal) { try await generator.generate(self.request()) }
        intercept.body = envelope(candidate(), status: "incomplete")
        await assertError(.incompleteResponse) { try await generator.generate(self.request()) }
        var unknown = candidate(); unknown["injectedID"] = "other"
        intercept.body = envelope(unknown)
        await assertError(.malformedResponse) { try await generator.generate(self.request()) }
        intercept.body = Data("{".utf8)
        await assertError(.malformedResponse) { try await generator.generate(self.request()) }
        intercept.body = Data("{}".utf8)
        await assertError(.malformedResponse) { try await generator.generate(self.request()) }
    }

    func testRateLimitHonorsValidRetryAfterWithoutRetryingOrExposingProviderPayload() async {
        let intercept = Intercept()
        intercept.status = 429
        intercept.body = Data("SECRET PROVIDER BODY".utf8)
        let generator = generator(intercept)
        let before = Date()
        intercept.headers = ["Retry-After": "120"]
        do { _ = try await generator.generate(request()); XCTFail("Expected rate limit") }
        catch let LessonGenerationError.rateLimited(retryAfter) {
            let permitted = try? XCTUnwrap(retryAfter)
            XCTAssertGreaterThanOrEqual(permitted?.timeIntervalSince(before) ?? -1, 120)
            XCTAssertLessThan(permitted?.timeIntervalSince(before) ?? .infinity, 125)
        } catch { XCTFail("Unclassified error: \(type(of: error))") }
        XCTAssertEqual(intercept.calls, 1) // The hint never schedules another request.

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        intercept.headers = ["retry-after": formatter.string(from: date)]
        do { _ = try await generator.generate(request()); XCTFail("Expected rate limit") }
        catch let LessonGenerationError.rateLimited(retryAfter) { XCTAssertEqual(retryAfter, date) }
        catch { XCTFail("Unclassified error: \(type(of: error))") }
        XCTAssertEqual(intercept.calls, 2)

        // RFC 9110 recipients also accept the two historical HTTP-date forms.
        let future = Date(timeIntervalSince1970: 1_900_000_000)
        for format in ["EEEE',' dd'-'MMM'-'yy HH':'mm':'ss 'GMT'", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            intercept.headers = ["Retry-After": formatter.string(from: future)]
            do { _ = try await generator.generate(request()); XCTFail("Expected rate limit") }
            catch let LessonGenerationError.rateLimited(retryAfter) {
                XCTAssertEqual(retryAfter, Date(timeIntervalSince1970: floor(future.timeIntervalSince1970)))
            } catch { XCTFail("Unclassified error: \(type(of: error))") }
        }
        XCTAssertEqual(intercept.calls, 4)
        // asctime pads single-digit days with two spaces.
        intercept.headers = ["Retry-After": "Sun Nov  6 08:49:37 2039"]
        do { _ = try await generator.generate(request()); XCTFail("Expected rate limit") }
        catch let LessonGenerationError.rateLimited(retryAfter) {
            XCTAssertNotNil(retryAfter)
            XCTAssertGreaterThan(retryAfter ?? .distantPast, Date())
        } catch { XCTFail("Unclassified error: \(type(of: error))") }
        XCTAssertEqual(intercept.calls, 5)

        for invalid in ["-1", "1.5", "NaN", "999999999999999999999999999999999", "120, 180", "tomorrow"] {
            intercept.headers = ["Retry-After": invalid]
            await assertError(.rateLimited(retryAfter: nil)) { try await generator.generate(self.request()) }
        }
        intercept.headers = [:]
        await assertError(.rateLimited(retryAfter: nil)) { try await generator.generate(self.request()) }
    }

    func testHTTPRedirectForeignHostOversizeAndSanitizedFailures() async {
        let intercept = Intercept()
        let generator = generator(intercept)
        let statuses: [(Int, LessonGenerationError)] = [(302, .providerFailure), (401, .authentication),
            (403, .authorization), (404, .unsupportedModel), (429, .rateLimited(retryAfter: nil)), (500, .providerFailure)]
        for (status, expected) in statuses {
            intercept.status = status
            intercept.body = Data("SECRET PROVIDER BODY".utf8)
            await assertError(expected) { try await generator.generate(self.request()) }
        }
        intercept.status = 200
        intercept.responseURL = URL(string: "https://untrusted.example/response")!
        await assertError(.providerFailure) { try await generator.generate(self.request()) }
        intercept.responseURL = OpenAILessonGenerator.endpoint
        intercept.body = Data(repeating: 0, count: 256 * 1024 + 1)
        await assertError(.oversizedResponse) { try await generator.generate(self.request()) }
        let failures: [(URLError, LessonGenerationError)] = [(URLError(.timedOut), .timeout),
            (URLError(.notConnectedToInternet), .offline), (URLError(.cancelled), .cancelled)]
        for (failure, expected) in failures {
            intercept.failure = failure
            await assertError(expected) { try await generator.generate(self.request()) }
        }
    }

    private func assertConnectionError(_ expected: LessonGenerationError, _ action: () async throws -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as LessonGenerationError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unclassified error", file: file, line: line) }
    }

    private func assertError(_ expected: LessonGenerationError, _ action: () async throws -> CandidateLesson,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as LessonGenerationError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unclassified error", file: file, line: line) }
    }
}
