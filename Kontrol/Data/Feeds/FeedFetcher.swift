import Foundation

struct FeedFetchRequest {
    let url: URL
    let etag: String?
    let lastModified: String?
    /// Validation must receive an XML body, never a 304.
    let requiresBody: Bool

    init(url: URL, etag: String? = nil, lastModified: String? = nil, requiresBody: Bool = false) {
        self.url = url
        self.etag = etag
        self.lastModified = lastModified
        self.requiresBody = requiresBody
    }
}

enum FeedFetchResponse {
    case modified(data: Data, finalURL: URL, etag: String?, lastModified: String?)
    case notModified
}

enum FeedFetchError: Error, Equatable {
    case unsafeURL, tooManyRedirects, oversizedResponse, timeout, canceled
    case htmlResponse, http(Int, retryAfter: String?), emptyBody, invalidResponse, transport
}

protocol FeedFetching {
    func fetch(_ request: FeedFetchRequest) async throws -> FeedFetchResponse
}

/// One isolated ephemeral session per call: delegate state cannot leak between concurrent feeds.
/// URLSessionDataDelegate receives decoded transfer bytes incrementally, including HTTP error bodies.
final class FeedFetcher: FeedFetching {
    static let maximumBytes = 2_097_152
    static let deadline: TimeInterval = 15
    private let protocolClasses: [AnyClass]
    private let timeout: TimeInterval

    init(protocolClasses: [AnyClass] = [], timeout: TimeInterval = FeedFetcher.deadline) {
        self.protocolClasses = protocolClasses
        self.timeout = min(max(timeout, 0.001), Self.deadline)
    }

    func fetch(_ request: FeedFetchRequest) async throws -> FeedFetchResponse {
        if Task.isCancelled { throw FeedFetchError.canceled }
        guard let url = try? NewsURLPolicy.feedURL(request.url.absoluteString) else {
            throw FeedFetchError.unsafeURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: timeout)
        // Never let untrusted or persisted header values inject additional fields.
        if let etag = Self.safeValidator(request.etag) { urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = Self.safeValidator(request.lastModified) {
            urlRequest.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        let operation = FeedTransfer(requiresBody: request.requiresBody, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request: urlRequest, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            operation.cancel(as: .canceled)
        }
    }

    static func safeValidator(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 1024,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return value
    }
}

private final class FeedTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private let requiresBody: Bool
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<FeedFetchResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var redirects = 0
    private var response: HTTPURLResponse?
    private var body = Data()
    private var timer: DispatchSourceTimer?

    init(requiresBody: Bool, timeout: TimeInterval) {
        self.requiresBody = requiresBody
        self.timeout = timeout
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<FeedFetchResponse, Error>) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(throwing: FeedFetchError.canceled)
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        let timer = DispatchSource.makeTimerSource(queue: .global())
        self.timer = timer
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.cancel(as: .timeout) }
        timer.resume()
        lock.unlock()
        task.resume()
    }

    func cancel(as error: FeedFetchError) { finish(.failure(error)) }

    private func finish(_ result: Result<FeedFetchResponse, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        let session = self.session
        let timer = self.timer
        self.timer = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        timer?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let count = redirects
        let done = completed
        lock.unlock()
        let error: FeedFetchError?
        if done { error = .canceled }
        else if count > 5 { error = .tooManyRedirects }
        else if request.url.flatMap({ try? NewsURLPolicy.feedURL($0.absoluteString) }) == nil {
            error = .unsafeURL
        } else { error = nil }
        if let error {
            completionHandler(nil)
            finish(.failure(error))
        } else {
            // Redirects never forward credentials; validators belong only to their origin.
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            if response.url?.host?.lowercased() != next.url?.host?.lowercased() ||
                response.url?.port != next.url?.port {
                next.setValue(nil, forHTTPHeaderField: "If-None-Match")
                next.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
            }
            completionHandler(next)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              let url = http.url, (try? NewsURLPolicy.feedURL(url.absoluteString)) != nil else {
            completionHandler(.cancel)
            finish(.failure(FeedFetchError.unsafeURL))
            return
        }
        if http.statusCode == 200,
           let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           type.contains("text/html") || type.contains("application/xhtml+xml") {
            completionHandler(.cancel)
            finish(.failure(FeedFetchError.htmlResponse))
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let tooLarge = data.count > FeedFetcher.maximumBytes - body.count
        if !completed && !tooLarge { body.append(data) }
        let done = completed
        lock.unlock()
        if !done && tooLarge { finish(.failure(FeedFetchError.oversizedResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let response = self.response
        let data = body
        lock.unlock()
        if let error {
            if let urlError = error as? URLError, urlError.code == .timedOut { finish(.failure(FeedFetchError.timeout)) }
            else if let urlError = error as? URLError, urlError.code == .cancelled { finish(.failure(FeedFetchError.canceled)) }
            else { finish(.failure(FeedFetchError.transport)) }
            return
        }
        guard let response, let url = response.url else { finish(.failure(FeedFetchError.invalidResponse)); return }
        switch response.statusCode {
        case 200:
            guard !data.isEmpty else { finish(.failure(FeedFetchError.emptyBody)); return }
            finish(.success(.modified(data: data, finalURL: url,
                                      etag: FeedFetcher.safeValidator(response.value(forHTTPHeaderField: "ETag")),
                                      lastModified: FeedFetcher.safeValidator(response.value(forHTTPHeaderField: "Last-Modified")))))
        case 304 where !requiresBody: finish(.success(.notModified))
        case 304: finish(.failure(FeedFetchError.emptyBody))
        default:
            finish(.failure(FeedFetchError.http(response.statusCode,
                                  retryAfter: FeedFetcher.safeValidator(response.value(forHTTPHeaderField: "Retry-After")))))
        }
    }
}
