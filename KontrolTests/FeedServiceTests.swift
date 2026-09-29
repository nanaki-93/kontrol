import Foundation
import XCTest
@testable import Kontrol

private actor ServiceTransport: FeedFetching {
    private var pending: [String: CheckedContinuation<FeedFetchResponse, Error>] = [:]
    private(set) var requests: [FeedFetchRequest] = []
    private(set) var peak = 0
    private var active = 0

    func fetch(_ request: FeedFetchRequest) async throws -> FeedFetchResponse {
        let key = request.url.lastPathComponent
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(request)
                active += 1
                peak = max(peak, active)
                pending[key] = continuation
                if Task.isCancelled { finish(key, with: .failure(FeedFetchError.canceled)) }
            }
        } onCancel: { Task { await self.finish(key, with: .failure(FeedFetchError.canceled)) } }
    }

    func finish(_ key: String, with result: Result<FeedFetchResponse, Error>) {
        guard let continuation = pending.removeValue(forKey: key) else { return }
        active -= 1
        continuation.resume(with: result)
    }

    func has(_ key: String) -> Bool { pending[key] != nil }
    var count: Int { requests.count }
    var inFlight: Int { active }
}

final class FeedServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let xml = Data("<rss><channel><item><title>Story</title><link>https://news.test/story</link></item></channel></rss>".utf8)
    private let emptyXML = Data("<rss><channel/></rss>".utf8)

    private func feed(_ path: String, revision: UUID = UUID(), enabled: Bool = true,
                      retry: Date? = nil) -> FeedSourceSnapshot {
        FeedSourceSnapshot(id: UUID(), name: path, url: URL(string: "https://news.test/\(path)")!,
                           topicIDs: ["go"], isEnabled: enabled, configurationRevision: revision,
                           etag: "\"v1\"", lastModified: "Wed, 01 Jan 2025 00:00:00 GMT",
                           lastAttemptAt: nil, lastSuccessAt: nil, lastError: nil, retryNotBefore: retry)
    }

    private func draft(_ path: String, revision: UUID = UUID()) -> FeedDraft {
        FeedDraft(id: nil, name: " Source ", urlText: "https://news.test/\(path)",
                  topicIDs: ["go"], isEnabled: true, expectedRevision: nil, draftRevision: revision)
    }

    private func waitFor(_ condition: @escaping () async -> Bool, file: StaticString = #filePath,
                         line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for transport", file: file, line: line)
    }

    func testMixedResultsDedupeRevisionValidatorsAndNoRetry() async {
        let transport = ServiceTransport()
        let service = FeedService(fetcher: transport, clock: { self.now })
        let good = feed("good"), bad = feed("bad"), unchanged = feed("unchanged")
        let disabled = feed("disabled", enabled: false)
        let pending = Task { await service.refresh([good, bad, good, unchanged, disabled]) }
        await waitFor { await transport.count == 3 }
        await transport.finish("good", with: .success(.modified(data: xml, finalURL: good.url,
                                                                etag: "\"v2\"", lastModified: nil)))
        await transport.finish("bad", with: .failure(FeedFetchError.transport))
        await transport.finish("unchanged", with: .success(.notModified))
        let results = await pending.value
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.feedID), [good.id, bad.id, unchanged.id])
        XCTAssertEqual(results.map(\.configurationRevision),
                       [good.configurationRevision, bad.configurationRevision, unchanged.configurationRevision])
        XCTAssertEqual(results.map(\.attemptedAt), [now, now, now])
        guard case .modified(let items, let etag, let modified) = results[0].result else {
            return XCTFail("Expected parsed entries")
        }
        XCTAssertEqual(items.map(\.title), ["Story"])
        XCTAssertEqual(etag, "\"v2\"")
        XCTAssertNil(modified)
        XCTAssertEqual(results[1].result, .failed(.offline, retryNotBefore: nil))
        XCTAssertEqual(results[2].result, .notModified)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3) // No automatic retries, not one request per topic.
        XCTAssertEqual(requests.first?.etag, "\"v1\"")
        XCTAssertEqual(requests.first?.lastModified, "Wed, 01 Jan 2025 00:00:00 GMT")
    }

    func testRetryAfterSecondsDatesAndDeferredRequests() async {
        let transport = ServiceTransport()
        let service = FeedService(fetcher: transport, clock: { self.now })
        let deferred = feed("deferred", retry: now.addingTimeInterval(120))
        let due = feed("due", retry: now.addingTimeInterval(-1))
        let limited = feed("limited")
        let unavailable = feed("unavailable")
        let pending = Task { await service.refresh([deferred, due, limited, unavailable]) }
        await waitFor { await transport.count == 3 }
        await transport.finish("due", with: .success(.notModified))
        await transport.finish("limited", with: .failure(FeedFetchError.http(429, retryAfter: "60")))
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let httpDate = date.string(from: now.addingTimeInterval(180))
        await transport.finish("unavailable", with: .failure(FeedFetchError.http(503, retryAfter: httpDate)))
        let results = await pending.value
        XCTAssertEqual(results[0].result, .deferred(retryNotBefore: now.addingTimeInterval(120)))
        XCTAssertNil(results[0].attemptedAt)
        XCTAssertEqual(results[1].result, .notModified)
        XCTAssertEqual(results[2].result, .failed(.rateLimited, retryNotBefore: now.addingTimeInterval(60)))
        XCTAssertEqual(results[3].result, .failed(.http, retryNotBefore: now.addingTimeInterval(180)))
        let requestCount = await transport.count
        XCTAssertEqual(requestCount, 3)
        for value in ["-1", "1.5", "garbage", "9999999999999999999999999999999999999999999999999999999999999999",
                      "1\nX: secret"] {
            XCTAssertNil(FeedService.retryDeadline(value, at: now), value)
        }
        XCTAssertEqual(FeedService.retryDeadline("0", at: now), now)
        XCTAssertEqual(FeedService.retryDeadline(date.string(from: now.addingTimeInterval(-60)), at: now), now)
        let rfc850 = "Sunday, 06-Nov-94 08:49:37 GMT"
        XCTAssertNotNil(FeedService.retryDeadline(rfc850, at: Date(timeIntervalSince1970: 0)))
        XCTAssertNotNil(FeedService.retryDeadline("Sun Nov 6 08:49:37 1994", at: Date(timeIntervalSince1970: 0)))
    }

    func testValidationSharesFourPermitsWithRefreshAndAcceptsEmptyXML() async throws {
        let transport = ServiceTransport()
        let service = FeedService(fetcher: transport, clock: { self.now })
        let feeds = (0..<4).map { feed("refresh\($0)") }
        let refresh = Task { await service.refresh(feeds) }
        await waitFor { await transport.count == 4 }
        let revision = UUID()
        let validation = Task { try await service.validate(draft("validate", revision: revision)) }
        // Wait for the queued validation to be scheduled; it must not start with 4 active.
        try await Task.sleep(nanoseconds: 20_000_000)
        let heldCount = await transport.count
        let initialPeak = await transport.peak
        XCTAssertEqual(heldCount, 4)
        XCTAssertEqual(initialPeak, 4)
        await transport.finish("refresh0", with: .success(.notModified))
        await waitFor { await transport.has("validate") }
        let request = await transport.requests.last
        XCTAssertEqual(request?.url.lastPathComponent, "validate")
        XCTAssertEqual(request?.requiresBody, true)
        XCTAssertNil(request?.etag)
        await transport.finish("validate", with: .success(.modified(data: emptyXML,
                           finalURL: URL(string: "https://news.test/validate")!, etag: "tag", lastModified: nil)))
        let receipt = try await validation.value
        XCTAssertEqual(receipt.draftRevision, revision)
        XCTAssertEqual(receipt.url.absoluteString, "https://news.test/validate")
        XCTAssertEqual(receipt.validatedAt, now)
        XCTAssertEqual(receipt.etag, "tag")
        for index in 1..<4 { await transport.finish("refresh\(index)", with: .success(.notModified)) }
        let refreshed = await refresh.value
        let finalPeak = await transport.peak
        XCTAssertEqual(refreshed.count, 4)
        XCTAssertEqual(finalPeak, 4)
    }

    func testCancellationWhileQueuedAndActiveDoesNotLeakPermitOrReportFailure() async {
        let transport = ServiceTransport()
        let service = FeedService(fetcher: transport, clock: { self.now })
        let feeds = (0..<5).map { feed("c\($0)") }
        let work = Task { await service.refresh(feeds) }
        await waitFor { await transport.count == 4 }
        work.cancel()
        let results = await work.value
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0.result == .canceled })
        let validation = Task { try await service.validate(draft("after")) }
        await waitFor { await transport.has("after") }
        await transport.finish("after", with: .success(.modified(data: emptyXML,
                              finalURL: URL(string: "https://news.test/after")!, etag: nil, lastModified: nil)))
        let validated = try? await validation.value
        XCTAssertNotNil(validated)
        let peak = await transport.peak
        let remaining = await transport.inFlight
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(remaining, 0)
    }

    func testQueuedValidationCancellationDoesNotConsumeAPermit() async {
        let transport = ServiceTransport()
        let service = FeedService(fetcher: transport, clock: { self.now })
        let feeds = (0..<4).map { feed("hold\($0)") }
        let refresh = Task { await service.refresh(feeds) }
        await waitFor { await transport.count == 4 }
        let queued = Task { try await service.validate(draft("queued")) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? FeedServiceError, FeedServiceError(code: nil, retryNotBefore: nil)) }
        await transport.finish("hold0", with: .success(.notModified))
        let next = Task { try await service.validate(draft("next")) }
        await waitFor { await transport.has("next") }
        await transport.finish("next", with: .success(.modified(data: emptyXML,
                              finalURL: URL(string: "https://news.test/next")!, etag: nil, lastModified: nil)))
        let receipt = try? await next.value
        XCTAssertNotNil(receipt)
        for index in 1..<4 { await transport.finish("hold\(index)", with: .success(.notModified)) }
        let outcomes = await refresh.value
        let count = await transport.count
        XCTAssertEqual(outcomes.count, 4)
        XCTAssertEqual(count, 5) // queued cancellation never touched the fetcher.
    }

    func testMalformedFeedAndIndependentHTTPFailure() async {
        let transport = ServiceTransport()
        let service = FeedService(fetcher: transport, clock: { self.now })
        let malformed = feed("broken"), healthy = feed("healthy"), status = feed("status")
        let work = Task { await service.refresh([malformed, healthy, status]) }
        await waitFor { await transport.count == 3 }
        await transport.finish("broken", with: .success(.modified(data: Data("<rss>".utf8),
                              finalURL: malformed.url, etag: nil, lastModified: nil)))
        await transport.finish("healthy", with: .success(.modified(data: emptyXML,
                              finalURL: healthy.url, etag: nil, lastModified: nil)))
        await transport.finish("status", with: .failure(FeedFetchError.http(500, retryAfter: "300")))
        let outcomes = await work.value
        XCTAssertEqual(outcomes[0].result, .failed(.malformedFeed, retryNotBefore: nil))
        XCTAssertEqual(outcomes[1].result, .modified([], etag: nil, lastModified: nil))
        XCTAssertEqual(outcomes[2].result, .failed(.http, retryNotBefore: nil))
    }

    func testValidationFailuresAreSanitizedAndRequireBodyAndValidXML() async {
        let transport = ServiceTransport()
        let service = FeedService(fetcher: transport, clock: { self.now })
        let invalid = FeedDraft(id: nil, name: "  ", urlText: "http://user:pass@news.test/feed",
                                topicIDs: [], isEnabled: true, expectedRevision: nil, draftRevision: UUID())
        do { _ = try await service.validate(invalid); XCTFail("expected invalid draft") }
        catch { XCTAssertEqual(error as? FeedServiceError,
                               FeedServiceError(code: .invalidConfiguration, retryNotBefore: nil)) }
        let unsafe = FeedDraft(id: nil, name: "Valid", urlText: "http://user:pass@news.test/feed",
                               topicIDs: ["go"], isEnabled: true, expectedRevision: nil, draftRevision: UUID())
        do { _ = try await service.validate(unsafe); XCTFail("expected unsafe URL") }
        catch { XCTAssertEqual(error as? FeedServiceError, FeedServiceError(code: .unsafeURL, retryNotBefore: nil)) }
        let malformed = Task { try await service.validate(draft("malformed")) }
        await waitFor { await transport.has("malformed") }
        await transport.finish("malformed", with: .success(.modified(data: Data("<rss>".utf8),
                              finalURL: URL(string: "https://news.test/malformed")!, etag: nil, lastModified: nil)))
        do { _ = try await malformed.value; XCTFail("expected XML error") }
        catch { XCTAssertEqual(error as? FeedServiceError, FeedServiceError(code: .malformedFeed, retryNotBefore: nil)) }
        let noBody = Task { try await service.validate(draft("noBody")) }
        await waitFor { await transport.has("noBody") }
        await transport.finish("noBody", with: .success(.notModified))
        do { _ = try await noBody.value; XCTFail("304 cannot validate a new endpoint") }
        catch { XCTAssertEqual(error as? FeedServiceError, FeedServiceError(code: .malformedFeed, retryNotBefore: nil)) }
        let throttled = Task { try await service.validate(draft("throttled")) }
        await waitFor { await transport.has("throttled") }
        await transport.finish("throttled", with: .failure(FeedFetchError.http(429, retryAfter: "5")))
        do { _ = try await throttled.value; XCTFail("expected rate limit") }
        catch { XCTAssertEqual(error as? FeedServiceError,
                               FeedServiceError(code: .rateLimited, retryNotBefore: now.addingTimeInterval(5))) }
        let canceled = Task { try await service.validate(draft("canceled")) }
        await waitFor { await transport.has("canceled") }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("expected cancellation") }
        catch { XCTAssertEqual(error as? FeedServiceError, FeedServiceError(code: nil, retryNotBefore: nil)) }
        let count = await transport.count
        XCTAssertEqual(count, 4)
    }
}
