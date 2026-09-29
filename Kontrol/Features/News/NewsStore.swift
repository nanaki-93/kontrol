import Foundation
import Combine

/// The transport stays behind an actor; a store never owns a URLSession or parses XML.
protocol NewsRefreshing {
    func refresh(_ feeds: [FeedSourceSnapshot]) async -> [FeedRefreshOutcome]
    func validate(_ draft: FeedDraft) async throws -> ValidatedFeed
}

extension FeedService: NewsRefreshing {}

enum NewsRefreshTrigger {
    case foreground
    case manual
}

enum NewsLocalFailure: Equatable {
    case read
    case save
    case catalog
}

enum NewsEditorError: Error, Equatable {
    case sessionRequired
}

/// Only stable classifications leave the opening boundary; never publish the URL or a
/// system error description (which may include untrusted URL contents).
struct NewsBrowserFailure: Equatable {
    let articleID: UUID
    let code: NewsErrorCode

    var message: String {
        switch code {
        case .unsafeURL: return "This article link is unsafe. Check the source and try again."
        default: return "Could not open this article in your browser. Try again."
        }
    }
}

/// One app-owned instance can be observed by any number of windows. Visibility is counted
/// by window identity; app foreground activity is independent of key-window status.
@MainActor
final class NewsStore: ObservableObject {
    @Published private(set) var snapshot: NewsSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var localFailure: NewsLocalFailure?
    @Published private(set) var refreshFailures: [UUID: NewsErrorCode] = [:]
    @Published private(set) var retryDeadlines: [UUID: Date] = [:]
    @Published private(set) var isPartialRefresh = false
    @Published private(set) var browserOpenFailure: NewsBrowserFailure?

    private let repository: NewsRepository
    private let service: NewsRefreshing
    private let browserOpener: NewsBrowserOpening
    private let catalog: DefaultFeedCatalog?
    private let clock: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var visibleWindows = Set<UUID>()
    private var appIsActive = false
    private var scheduled: Task<Void, Never>?
    private var scheduleGeneration = 0
    private var inFlight: Task<Void, Never>?
    private var feedTasks: [UUID: Task<[FeedRefreshOutcome], Never>] = [:]
    // Use the caller's stable editor ID for new feeds, or the feed ID for existing ones.
    // Never store the draft here: the editor retains it through validation/save failures.
    private var editorAttempts: [UUID: UUID] = [:]

    init(repository: NewsRepository, service: NewsRefreshing, catalog: DefaultFeedCatalog?,
         browserOpener: NewsBrowserOpening? = nil,
         clock: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { interval in
             try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
         }) {
        self.repository = repository
        self.service = service
        self.browserOpener = browserOpener ?? NewsBrowserOpener()
        self.catalog = catalog
        self.clock = clock
        self.sleep = sleep
        // Neither persistence nor networking is touched during dependency construction.
    }

    var isVisibleAndActive: Bool { appIsActive && !visibleWindows.isEmpty }

    /// Resolve the current cached row by identity on every attempt, including Retry. An
    /// altered persisted link cannot be replaced by a view-supplied destination. Opening
    /// is not a read-history mutation and cannot evict or rewrite the cached article.
    func openArticle(id: UUID) {
        guard let article = snapshot?.articles.first(where: { $0.id == id }) else { return }
        guard let safeURL = try? NewsURLPolicy.articleURL(article.url) else {
            browserOpenFailure = NewsBrowserFailure(articleID: id, code: .unsafeURL)
            return
        }
        if browserOpener.open(safeURL) {
            browserOpenFailure = nil
        } else {
            browserOpenFailure = NewsBrowserFailure(articleID: id, code: .openFailed)
        }
    }

    func dismissBrowserOpenFailure() {
        browserOpenFailure = nil
    }

    /// Synchronous cache-first publication: callers may inspect cached rows before starting IO.
    func loadIfNeeded() {
        guard snapshot == nil, !isLoading else { return }
        guard let catalog else {
            localFailure = .catalog
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try repository.loadOrInitialize(catalog)
            localFailure = nil
            scheduleNextCheck()
        } catch {
            localFailure = .read // Retain any previously published cache; never invent an empty feed.
        }
    }

    /// Reload after a Settings edit made through the shared repository. Obsolete requests
    /// cannot publish into the old configuration even when the transport ignores cancellation.
    func reload() {
        guard let catalog else {
            localFailure = .catalog
            return
        }
        do {
            let current = try repository.loadOrInitialize(catalog)
            publishConfiguration(current)
            localFailure = nil
        } catch { localFailure = .read }
    }

    func setVisible(_ visible: Bool, windowID: UUID) {
        if visible { visibleWindows.insert(windowID) } else { visibleWindows.remove(windowID) }
        activityChanged()
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        activityChanged()
    }

    private func activityChanged() {
        guard isVisibleAndActive else { cancelSchedule(); return }
        loadIfNeeded()
        scheduleNextCheck()
        // Visibility does not await a feed. Concurrent entries coalesce in refresh().
        Task { await refresh(.foreground) }
    }

    private func cancelSchedule() {
        scheduleGeneration += 1
        scheduled?.cancel()
        scheduled = nil
    }

    private func eligibleFeeds(_ trigger: NewsRefreshTrigger, at now: Date) -> [FeedSourceSnapshot] {
        guard let snapshot else { return [] }
        return snapshot.feeds.filter { feed in
            feed.isEnabled && !feed.topicIDs.isDisjoint(with: snapshot.preferences.selectedTopicIDs) &&
            (feed.retryNotBefore == nil || feed.retryNotBefore! <= now) &&
            (trigger == .manual || max(feed.lastAttemptAt ?? .distantPast,
                                        feed.lastSuccessAt ?? .distantPast).addingTimeInterval(30 * 60) <= now)
        }
    }

    private func scheduleNextCheck() {
        cancelSchedule()
        guard isVisibleAndActive, let snapshot, inFlight == nil else { return }
        let now = clock()
        let relevant = snapshot.feeds.filter {
            $0.isEnabled && !$0.topicIDs.isDisjoint(with: snapshot.preferences.selectedTopicIDs)
        }
        guard !relevant.isEmpty else { return }
        let next = relevant.map { feed -> Date in
            max(max(feed.lastAttemptAt ?? .distantPast,
                    feed.lastSuccessAt ?? .distantPast).addingTimeInterval(30 * 60),
                feed.retryNotBefore ?? .distantPast)
        }.min()!
        let generation = scheduleGeneration
        // Immediate eligibility is handled by activityChanged()/refresh completion. Avoid
        // a tight retry loop if the clock or a test scheduler has not advanced.
        let interval = next > now ? next.timeIntervalSince(now) : 60
        scheduled = Task { [weak self, sleep] in
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled, let self, self.scheduleGeneration == generation,
                  self.isVisibleAndActive else { return }
            await self.refresh(.foreground)
        }
    }

    func refresh(_ trigger: NewsRefreshTrigger) async {
        loadIfNeeded()
        guard snapshot != nil, localFailure != .read else { return }
        if let inFlight { await inFlight.value; return }
        guard trigger == .manual || isVisibleAndActive else { return }
        let feeds = eligibleFeeds(trigger, at: clock())
        guard !feeds.isEmpty else { scheduleNextCheck(); return }
        cancelSchedule()
        isRefreshing = true
        refreshFailures = [:]
        retryDeadlines = [:]
        isPartialRefresh = false
        // Give each feed its own cancellable request. Canceling the batch would also
        // cancel unchanged feeds and lose successes already returned by the service.
        let requests = feeds.map { feed in
            (feed.id, Task { [service] in await service.refresh([feed]) })
        }
        feedTasks = Dictionary(uniqueKeysWithValues: requests)
        let task = Task { [weak self] in
            var outcomes: [FeedRefreshOutcome] = []
            for (_, request) in requests { outcomes += await request.value }
            self?.finishRefresh(outcomes)
        }
        inFlight = task
        await task.value
    }

    private func finishRefresh(_ outcomes: [FeedRefreshOutcome]) {
        // Even after a configuration edit, completed successes from other, unchanged feeds
        // may be committed. The repository independently checks each authoritative revision.
        do {
            let committed = try repository.applyRefresh(outcomes, at: clock())
            snapshot = committed
            localFailure = nil
            let accepted = outcomes.filter { outcome in
                committed.feeds.contains { $0.id == outcome.feedID && $0.isEnabled &&
                    $0.configurationRevision == outcome.configurationRevision }
            }
            refreshFailures = Dictionary(uniqueKeysWithValues: accepted.compactMap { outcome in
                if case .failed(let code, _) = outcome.result { return (outcome.feedID, code) }
                return nil
            })
            retryDeadlines = Dictionary(uniqueKeysWithValues: accepted.compactMap { outcome in
                switch outcome.result {
                case .failed(_, let date): return date.map { (outcome.feedID, $0) }
                case .deferred(let date): return (outcome.feedID, date)
                default: return nil
                }
            })
            let succeeded = accepted.contains { outcome in
                switch outcome.result { case .modified, .notModified: return true; default: return false }
            }
            isPartialRefresh = succeeded && !refreshFailures.isEmpty
        } catch {
            // An unsuccessful commit never publishes fetched rows or a success timestamp.
            localFailure = .save
        }
        feedTasks = [:]
        inFlight = nil
        isRefreshing = false
        scheduleNextCheck()
    }

    private func publishConfiguration(_ updated: NewsSnapshot) {
        if let previous = snapshot {
            let old = Dictionary(uniqueKeysWithValues: previous.feeds.map { ($0.id, $0) })
            for feed in old.values {
                guard feed.isEnabled else { continue }
                let replacement = updated.feeds.first { $0.id == feed.id }
                if replacement == nil || replacement?.isEnabled == false ||
                    replacement?.url != feed.url ||
                    replacement?.configurationRevision != feed.configurationRevision {
                    feedTasks[feed.id]?.cancel()
                }
            }
        }
        snapshot = updated
        scheduleNextCheck()
    }

    func saveSelectedTopics(_ ids: Set<String>) throws {
        loadIfNeeded()
        guard let snapshot else { throw NewsRepositoryError.invalidStoredData }
        do {
            publishConfiguration(try repository.savePreferences(
                NewsPreferencesEdit(selectedTopicIDs: ids), expectedRevision: snapshot.preferences.revision))
            localFailure = nil
        } catch { localFailure = .save; throw error }
    }

    /// Pass the same editor ID to each new-feed save attempt and to Cancel. Existing
    /// feeds can use their feed ID when no separate editor ID is supplied.
    func cancelFeedEdit(id: UUID) {
        editorAttempts.removeValue(forKey: id)
    }

    func saveFeed(_ draft: FeedDraft, editorID: UUID? = nil) async throws {
        loadIfNeeded()
        guard let snapshot, localFailure != .read else { throw NewsRepositoryError.invalidStoredData }
        // A draft revision identifies one validation, not the editor session. Never
        // allow the default path to save a new feed without a stable cancellation key.
        guard let key = editorID ?? draft.id else { throw NewsEditorError.sessionRequired }
        let attempt = UUID()
        editorAttempts[key] = attempt
        defer {
            if editorAttempts[key] == attempt { editorAttempts.removeValue(forKey: key) }
        }

        // Reject malformed or stale drafts before doing IO. The repository repeats these
        // checks against authoritative state at commit time (including uniqueness/limits).
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointText = draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              !draft.topicIDs.isEmpty,
              draft.topicIDs.isSubset(of: Set(snapshot.topics.map(\.id))),
              let endpoint = try? NewsURLPolicy.feedURL(endpointText),
              let normalized = try? NewsURLPolicy.normalizedFeedURL(endpoint.absoluteString) else {
            throw NewsRepositoryError.invalidFeed
        }
        let original: FeedSourceSnapshot?
        if let id = draft.id {
            guard let feed = snapshot.feeds.first(where: { $0.id == id }),
                  feed.configurationRevision == draft.expectedRevision else {
                throw NewsRepositoryError.staleRevision
            }
            original = feed
        } else {
            guard draft.expectedRevision == nil else { throw NewsRepositoryError.staleRevision }
            guard snapshot.feeds.count < 32 else { throw NewsRepositoryError.feedLimitReached }
            original = nil
        }
        guard !snapshot.feeds.contains(where: {
            $0.id != original?.id &&
                (try? NewsURLPolicy.normalizedFeedURL($0.url.absoluteString)) == normalized
        }) else { throw NewsRepositoryError.duplicateEndpoint }

        let oldEndpoint = original.flatMap { try? NewsURLPolicy.normalizedFeedURL($0.url.absoluteString) }
        let needsValidation = draft.isEnabled && (original == nil || oldEndpoint != normalized ||
            (original?.isEnabled == false && original?.lastSuccessAt == nil))
        let receipt: ValidatedFeed?
        if needsValidation {
            do { receipt = try await service.validate(draft) }
            catch {
                // A canceled editor must not surface a late transport failure as its own.
                guard editorAttempts[key] == attempt else { throw CancellationError() }
                throw error
            }
            // A service seam may ignore cancellation or return a receipt for another draft.
            guard editorAttempts[key] == attempt else { throw CancellationError() }
            guard receipt?.draftRevision == draft.draftRevision, receipt?.url == endpoint else {
                throw NewsRepositoryError.validationRequired
            }
        } else { receipt = nil }
        guard editorAttempts[key] == attempt else { throw CancellationError() }
        do {
            let updated = try repository.saveFeed(draft, validation: receipt)
            publishConfiguration(updated)
            localFailure = nil
        } catch {
            if let failure = error as? NewsRepositoryError {
                switch failure {
                case .staleRevision, .invalidFeed, .duplicateEndpoint,
                     .feedLimitReached, .validationRequired:
                    break // Recover in the editor, without replacing its draft.
                default: localFailure = .save
                }
            } else { localFailure = .save }
            throw error
        }
    }

    func removeFeed(id: UUID) throws {
        loadIfNeeded()
        guard let feed = snapshot?.feeds.first(where: { $0.id == id }) else {
            throw NewsRepositoryError.staleRevision
        }
        do {
            publishConfiguration(try repository.removeFeed(id: id, expectedRevision: feed.configurationRevision))
            localFailure = nil
        } catch { localFailure = .save; throw error }
    }
}
