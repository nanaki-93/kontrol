import Foundation
import XCTest
@testable import Kontrol

private final class FeedStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((FeedStubProtocol) -> Void)?
    static var requests: [URLRequest] = []
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        handler?(self)
    }
    override func stopLoading() { stopped = true }
    func send(status: Int = 200, headers: [String: String] = [:], chunks: [Data] = [Data("<rss/>".utf8)]) {
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks where !stopped { client?.urlProtocol(self, didLoad: chunk) }
        if !stopped { client?.urlProtocolDidFinishLoading(self) }
    }
    func redirect(to url: URL) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": url.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func configure(_ handler: @escaping (FeedStubProtocol) -> Void) {
        lock.lock(); requests = []; self.handler = handler; lock.unlock()
    }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

final class FeedFetcherTests: XCTestCase {
    private let url = URL(string: "https://news.test/rss")!
    private func fetcher(timeout: TimeInterval = 15) -> FeedFetcher {
        FeedFetcher(protocolClasses: [FeedStubProtocol.self], timeout: timeout)
    }
    private func failure(_ request: FeedFetchRequest, fetcher: FeedFetcher? = nil) async -> FeedFetchError? {
        do { _ = try await (fetcher ?? self.fetcher()).fetch(request); return nil }
        catch { return error as? FeedFetchError }
    }
    private func assertFailure(_ expected: FeedFetchError, _ request: FeedFetchRequest,
                               fetcher: FeedFetcher? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await failure(request, fetcher: fetcher)
        XCTAssertEqual(result, expected, file: file, line: line)
    }

    func testConditionalHeadersBodyAndInitial304() async throws {
        FeedStubProtocol.configure { $0.send(status: 304, chunks: []) }
        let request = FeedFetchRequest(url: url, etag: "\"v1\"", lastModified: "Wed, 01 Jan 2025 00:00:00 GMT")
        let response = try await fetcher().fetch(request)
        guard case .notModified = response else { return XCTFail("304 must be distinct") }
        let sent = try XCTUnwrap(FeedStubProtocol.captured().first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 01 Jan 2025 00:00:00 GMT")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
        await assertFailure(.emptyBody, FeedFetchRequest(url: url, requiresBody: true))
        FeedStubProtocol.configure { $0.send(chunks: []) }
        await assertFailure(.emptyBody, FeedFetchRequest(url: url))
        FeedStubProtocol.configure { $0.send(headers: ["Content-Type": "application/xml"], chunks: [Data("<rss/>".utf8)]) }
        guard case .modified(let data, let finalURL, _, _) = try await fetcher().fetch(FeedFetchRequest(url: url, requiresBody: true)) else {
            return XCTFail("expected body")
        }
        XCTAssertEqual(data, Data("<rss/>".utf8))
        XCTAssertEqual(finalURL, url)
    }

    func testCrossOriginRedirectDoesNotSendValidatorsOrCredentials() async throws {
        FeedStubProtocol.configure { stub in
            if stub.request.url!.host == "news.test" {
                stub.redirect(to: URL(string: "https://other.test/feed")!)
            } else {
                stub.send(chunks: [Data("<feed/>".utf8)])
            }
        }
        _ = try await fetcher().fetch(FeedFetchRequest(url: url, etag: "\"private\"", lastModified: "private"))
        let requests = FeedStubProtocol.captured()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "If-None-Match"), "\"private\"")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-Modified-Since"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
    }

    func testInvalidEndpointsHTMLStatusesAndErrorBodyCap() async {
        FeedStubProtocol.configure { $0.send() }
        for value in ["http://news.test/rss", "https://user:pass@news.test/rss", "file:///etc/passwd"] {
            await assertFailure(.unsafeURL, FeedFetchRequest(url: URL(string: value)!))
        }
        XCTAssertTrue(FeedStubProtocol.captured().isEmpty)
        FeedStubProtocol.configure { $0.send(headers: ["Content-Type": "text/html"], chunks: [Data("<html/>".utf8)]) }
        await assertFailure(.htmlResponse, FeedFetchRequest(url: url))
        FeedStubProtocol.configure { $0.send(status: 429, headers: ["Retry-After": "60"], chunks: [Data("secret".utf8)]) }
        await assertFailure(.http(429, retryAfter: "60"), FeedFetchRequest(url: url))
        FeedStubProtocol.configure { $0.send(status: 503, chunks: [Data(repeating: 0, count: FeedFetcher.maximumBytes + 1)]) }
        await assertFailure(.oversizedResponse, FeedFetchRequest(url: url))
    }

    func testDecodedStreamingBoundIncludingExpandedTransferAndExactLimit() async throws {
        // URLSession delivers decoded chunks for gzip on the wire. The protocol seam
        // injects expanded chunks directly at that same delegate boundary.
        FeedStubProtocol.configure {
            $0.send(headers: ["Content-Encoding": "gzip"],
                    chunks: [Data(repeating: 65, count: FeedFetcher.maximumBytes), Data([66])])
        }
        await assertFailure(.oversizedResponse, FeedFetchRequest(url: url))
        FeedStubProtocol.configure { $0.send(chunks: [Data(repeating: 65, count: FeedFetcher.maximumBytes)]) }
        guard case .modified(let data, _, _, _) = try await fetcher().fetch(FeedFetchRequest(url: url)) else {
            return XCTFail("exact limit should pass")
        }
        XCTAssertEqual(data.count, FeedFetcher.maximumBytes)
    }

    func testDeadlineAndCancellationTerminatePendingTransfer() async {
        FeedStubProtocol.configure { stub in
            let response = HTTPURLResponse(url: stub.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Deliberately hold the transfer open after headers.
        }
        await assertFailure(.timeout, FeedFetchRequest(url: url), fetcher: fetcher(timeout: 0.05))
        let task = Task { await failure(FeedFetchRequest(url: url)) }
        for _ in 0..<100 where FeedStubProtocol.captured().count < 2 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        let canceledResult = await task.value
        XCTAssertEqual(canceledResult, .canceled)
        let canceled = Task { () -> FeedFetchError? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await failure(FeedFetchRequest(url: url))
        }
        let preCanceledResult = await canceled.value
        XCTAssertEqual(preCanceledResult, .canceled)
    }

    func testDeadlineCoversRedirectAndSubsequentBody() async {
        FeedStubProtocol.configure { stub in
            if stub.request.url!.lastPathComponent == "rss" {
                stub.redirect(to: URL(string: "https://news.test/slow")!)
            } else {
                let response = HTTPURLResponse(url: stub.request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
                stub.client?.urlProtocol(stub, didLoad: Data("partial".utf8))
            }
        }
        await assertFailure(.timeout, FeedFetchRequest(url: url), fetcher: fetcher(timeout: 0.05))
        XCTAssertEqual(FeedStubProtocol.captured().count, 2)
    }

    func testHTTPSRedirectAndHopPolicy() async {
        FeedStubProtocol.configure { stub in
            stub.redirect(to: URL(string: "http://news.test/downgrade")!)
        }
        await assertFailure(.unsafeURL, FeedFetchRequest(url: url))
        FeedStubProtocol.configure { stub in
            stub.redirect(to: URL(string: "file:///etc/passwd")!)
        }
        await assertFailure(.unsafeURL, FeedFetchRequest(url: url))
        FeedStubProtocol.configure { stub in
            let n = Int(stub.request.url!.lastPathComponent) ?? 0
            if n < 6 { stub.redirect(to: URL(string: "https://news.test/\(n + 1)")!) }
            else { stub.send() }
        }
        await assertFailure(.tooManyRedirects, FeedFetchRequest(url: URL(string: "https://news.test/0")!))
        FeedStubProtocol.configure { stub in
            let n = Int(stub.request.url!.lastPathComponent) ?? 0
            if n < 5 { stub.redirect(to: URL(string: "https://news.test/\(n + 1)")!) }
            else { stub.send() }
        }
        do {
            guard case .modified(_, let finalURL, _, _) = try await fetcher().fetch(FeedFetchRequest(url: URL(string: "https://news.test/0")!)) else {
                return XCTFail("expected modified")
            }
            XCTAssertEqual(finalURL.absoluteString, "https://news.test/5")
        } catch { XCTFail("five redirects should pass: \(error)") }
    }
}
