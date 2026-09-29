import Foundation

/// Evidence for one editor revision and endpoint, not permission to save a later draft.
struct ValidatedFeed: Equatable {
    let draftRevision: UUID
    let url: URL
    let validatedAt: Date
    let etag: String?
    let lastModified: String?
}

struct FeedServiceError: Error, Equatable {
    /// Nil denotes cancellation, never a user-facing transport failure.
    let code: NewsErrorCode?
    let retryNotBefore: Date?
}

/// Refresh and editor validation use the same permit pool. A permit covers the entire
/// transfer AND parse, so a slow parse cannot start an unbounded next transfer.
actor FeedService {
    private let fetcher: FeedFetching
    private let parser: FeedParser
    private let clock: () -> Date
    private let permits = FeedRequestPermits(count: 4)

    init(fetcher: FeedFetching = FeedFetcher(), parser: FeedParser = FeedParser(),
         clock: @escaping () -> Date = Date.init) {
        self.fetcher = fetcher
        self.parser = parser
        self.clock = clock
    }

    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome] {
        // A feed shared by several topics must be fetched only once. Preserve input
        // order for callers, irrespective of network completion order.
        var seen = Set<UUID>()
        let unique = feeds.filter { $0.isEnabled && seen.insert($0.id).inserted }
        return await withTaskGroup(of: (Int, FeedRefreshOutcome).self) { group in
            for (index, feed) in unique.enumerated() {
                group.addTask { [self] in (index, await self.refreshOne(feed)) }
            }
            var results = [(Int, FeedRefreshOutcome)]()
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.topicIDs.isEmpty else {
            throw FeedServiceError(code: .invalidConfiguration, retryNotBefore: nil)
        }
        let url: URL
        do { url = try NewsURLPolicy.feedURL(draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { throw FeedServiceError(code: .unsafeURL, retryNotBefore: nil) }
        do {
            let response = try await request(FeedFetchRequest(url: url, requiresBody: true))
            guard case .modified(_, let etag, let lastModified) = response.response else {
                throw FeedServiceError(code: .malformedFeed, retryNotBefore: nil)
            }
            return ValidatedFeed(draftRevision: draft.draftRevision, url: url,
                                 validatedAt: response.attemptedAt, etag: etag, lastModified: lastModified)
        } catch {
            throw Self.classify(error, at: clock())
        }
    }

    private func refreshOne(_ feed: FeedSourceSnapshot) async -> FeedRefreshOutcome {
        func outcome(_ attempt: Date?, _ result: FeedRefreshResult) -> FeedRefreshOutcome {
            FeedRefreshOutcome(feedID: feed.id, configurationRevision: feed.configurationRevision,
                               attemptedAt: attempt, result: result)
        }
        if Task.isCancelled { return outcome(nil, .canceled) }
        if let deadline = feed.retryNotBefore, deadline > clock() {
            return outcome(nil, .deferred(retryNotBefore: deadline))
        }
        var attemptedAt: Date?
        do {
            let result = try await request(FeedFetchRequest(url: feed.url, etag: feed.etag,
                                                            lastModified: feed.lastModified))
            attemptedAt = result.attemptedAt
            switch result.response {
            case .modified(let parsed, let etag, let lastModified):
                // The request helper has already parsed the body and checked cancellation.
                return outcome(attemptedAt, .modified(parsed, etag: etag, lastModified: lastModified))
            case .notModified:
                return outcome(attemptedAt, .notModified)
            }
        } catch let error as FeedRequestFailure {
            attemptedAt = error.attemptedAt
            let classified = Self.classify(error.cause, at: clock())
            guard let code = classified.code else { return outcome(attemptedAt, .canceled) }
            return outcome(attemptedAt, .failed(code, retryNotBefore: classified.retryNotBefore))
        } catch {
            let classified = Self.classify(error, at: clock())
            guard let code = classified.code else { return outcome(attemptedAt, .canceled) }
            return outcome(attemptedAt, .failed(code, retryNotBefore: classified.retryNotBefore))
        }
    }

    private struct ParsedResponse {
        enum Body {
            case modified([NewsFeedEntry], String?, String?)
            case notModified
        }
        let attemptedAt: Date
        let response: Body
    }

    private struct FeedRequestFailure: Error {
        let attemptedAt: Date?
        let cause: Error
    }

    private func request(_ input: FeedFetchRequest) async throws -> ParsedResponse {
        try await permits.acquire()
        let started = clock()
        do {
            try Task.checkCancellation()
            let fetched = try await fetcher.fetch(input)
            let response: ParsedResponse.Body
            switch fetched {
            case .notModified: response = .notModified
            case .modified(let data, let finalURL, let etag, let lastModified):
                let parsed = try parser.parse(data, baseURL: finalURL)
                response = .modified(parsed.entries, etag, lastModified)
            }
            try Task.checkCancellation()
            await permits.release()
            return ParsedResponse(attemptedAt: started, response: response)
        } catch {
            await permits.release()
            throw FeedRequestFailure(attemptedAt: started, cause: error)
        }
    }

    private static func classify(_ error: Error, at now: Date) -> FeedServiceError {
        if let wrapped = error as? FeedRequestFailure { return classify(wrapped.cause, at: now) }
        if error is CancellationError { return FeedServiceError(code: nil, retryNotBefore: nil) }
        if let error = error as? FeedServiceError { return error }
        if let error = error as? FeedFetchError {
            switch error {
            case .canceled: return FeedServiceError(code: nil, retryNotBefore: nil)
            case .timeout: return FeedServiceError(code: .timeout, retryNotBefore: nil)
            case .unsafeURL, .tooManyRedirects: return FeedServiceError(code: .unsafeURL, retryNotBefore: nil)
            case .oversizedResponse: return FeedServiceError(code: .oversizedResponse, retryNotBefore: nil)
            case .http(let status, let header):
                let deadline = (status == 429 || status == 503) ? retryDeadline(header, at: now) : nil
                return FeedServiceError(code: status == 429 ? .rateLimited : .http, retryNotBefore: deadline)
            case .transport: return FeedServiceError(code: .offline, retryNotBefore: nil)
            case .htmlResponse, .emptyBody, .invalidResponse:
                return FeedServiceError(code: .malformedFeed, retryNotBefore: nil)
            }
        }
        if error is FeedParserError { return FeedServiceError(code: .malformedFeed, retryNotBefore: nil) }
        return FeedServiceError(code: .offline, retryNotBefore: nil)
    }

    /// RFC 9110 delay-seconds or one of the three HTTP-date forms. Invalid/overflowing
    /// values are ignored, not converted to arbitrary long-lived server lockouts.
    static func retryDeadline(_ raw: String?, at now: Date) -> Date? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 1024 else { return nil }
        if raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            guard let seconds = TimeInterval(raw), seconds.isFinite,
                  seconds <= Date.distantFuture.timeIntervalSince(now) else { return nil }
            return now.addingTimeInterval(seconds)
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
                       "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: raw), formatter.string(from: date) == raw {
                return max(date, now)
            }
        }
        return nil
    }
}

/// FIFO, cancellation-aware actor semaphore. Canceling a queued waiter removes it
/// without consuming a permit; canceling a holder releases exactly once via request().
private actor FeedRequestPermits {
    private let maximum: Int
    private var available: Int
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(count: Int) { maximum = count; available = count }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // If cancellation raced with a permit handoff, the caller still owns it.
        if Task.isCancelled { release(); throw CancellationError() }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            let waiter = waiters.remove(at: index)
            waiter.1.resume(throwing: CancellationError())
        }
    }

    func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.1.resume()
        } else {
            assert(available < maximum)
            available += 1
        }
    }
}
