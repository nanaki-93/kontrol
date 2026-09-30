import SwiftUI

/// A window's topic filter and summary disclosure are transient; only the shared store
/// owns subscriptions and cached articles. NewsSelection projects source-aware rows once.
struct NewsView: View {
    @ObservedObject var store: NewsStore
    @State private var activeTopicID: String?
    @State private var expandedIDs = Set<UUID>()
    @State private var showingTopics = false
    @FocusState private var focusedFilter: String?

    static func selectedTopics(in snapshot: NewsSnapshot) -> [NewsTopic] {
        snapshot.topics.filter { snapshot.preferences.selectedTopicIDs.contains($0.id) }
    }

    static func effectiveFilter(_ filter: String?, in snapshot: NewsSnapshot) -> String? {
        guard let filter, snapshot.preferences.selectedTopicIDs.contains(filter),
              snapshot.topics.contains(where: { $0.id == filter }) else { return nil }
        return filter
    }

    static func sections(in snapshot: NewsSnapshot, filter: String?) -> [NewsSelection.Section] {
        NewsSelection.sections(snapshot, filter: effectiveFilter(filter, in: snapshot))
    }

    static func sourceName(for article: ArticleMetadata) -> String {
        article.sources.first?.feedName ?? "Unknown source"
    }

    static func readLabel(for article: ArticleMetadata) -> String {
        "Read \(article.title) from \(sourceName(for: article)) in browser"
    }

    /// A projection of committed data and transient IO, never a guess based on row count alone.
    enum ContentState: Equatable {
        case loading, readFailure, unavailable, noTopics, noFeeds, emptyCache, filteredEmpty, headlines
    }

    static func contentState(snapshot: NewsSnapshot?, isLoading: Bool, localFailure: NewsLocalFailure?,
                             filter: String?) -> ContentState {
        if localFailure == .read { return .readFailure }
        guard let snapshot else { return isLoading ? .loading : .unavailable }
        if snapshot.preferences.selectedTopicIDs.isEmpty { return .noTopics }
        if !snapshot.feeds.contains(where: {
            $0.isEnabled && !$0.topicIDs.isDisjoint(with: snapshot.preferences.selectedTopicIDs)
        }) { return .noFeeds }
        if !sections(in: snapshot, filter: filter).isEmpty { return .headlines }
        return effectiveFilter(filter, in: snapshot) == nil ? .emptyCache : .filteredEmpty
    }

    static func lastSuccessText(_ snapshot: NewsSnapshot?) -> String {
        guard let snapshot else { return "Refresh history unavailable" }
        guard let date = snapshot.preferences.lastRefreshAt else { return "Never refreshed" }
        return "Last successful refresh: \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func refreshingText(_ snapshot: NewsSnapshot?) -> String {
        guard let snapshot else { return "Refreshing selected feeds" }
        return sections(in: snapshot, filter: nil).isEmpty
            ? "Refreshing selected feeds · no saved headlines for selected topics yet"
            : "Refreshing · saved headlines remain available"
    }

    static func failureText(_ code: NewsErrorCode, in snapshot: NewsSnapshot) -> String {
        let cause: String
        switch code {
        case .offline: cause = "Offline or unable to reach a feed."
        case .timeout: cause = "A feed timed out."
        case .rateLimited: cause = "A feed is rate-limited."
        case .http: cause = "A feed returned an error."
        case .unsafeURL: cause = "A feed has an unsafe URL."
        case .oversizedResponse: cause = "A feed response was too large."
        case .malformedFeed: cause = "A feed could not be parsed."
        default: cause = "A feed could not be refreshed."
        }
        let cache = sections(in: snapshot, filter: nil).isEmpty
            ? "No saved headlines for selected topics yet."
            : "Saved headlines remain available."
        let recovery = code == .unsafeURL || code == .invalidConfiguration
            ? " Review it in Topics & feeds." : ""
        return "\(cause) \(cache)\(recovery)"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(at: timeline.date)
        }
        .sheet(isPresented: $showingTopics) {
            NewsManagementSheet(store: store)
        }
    }

    private func content(at now: Date) -> some View {
        let state = Self.contentState(snapshot: store.snapshot, isLoading: store.isLoading,
                                      localFailure: store.localFailure, filter: activeTopicID)
        let canRetry = store.canRetryRefresh(at: now)
        return VStack(alignment: .leading, spacing: AppMetrics.space6) {
            PageHeader("News")
            Text(Self.lastSuccessText(store.snapshot))
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            if let snapshot = store.snapshot { topicFilters(snapshot) }
            HStack(spacing: AppMetrics.space2) {
                ActionButton("Refresh", symbol: "arrow.clockwise", isEnabled: canRetry,
                             isBusy: store.isRefreshing) {
                    Task { await store.refresh(.manual) }
                }
                ActionButton("Topics & feeds", symbol: "slider.horizontal.3") {
                    showingTopics = true
                }
            }
            if store.isRefreshing {
                StatusPill(Self.refreshingText(store.snapshot), kind: .warning)
            }
            if store.localFailure == .read {
                ErrorBanner(.readFailed, recoveryTitle: "Retry loading local News") { store.reload() }
                if store.snapshot != nil {
                    StatusPill("Previously loaded · may be out of date", kind: .warning)
                }
            } else if store.localFailure == .save {
                ErrorBanner(.saveFailed)
                Text("Saved headlines have not changed. Retry when feeds are available.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            } else if store.localFailure == .catalog {
                ErrorBanner(.readFailed)
            }
            if let snapshot = store.snapshot {
                let failed = snapshot.feeds.filter {
                    $0.isEnabled && !$0.topicIDs.isDisjoint(with: snapshot.preferences.selectedTopicIDs) &&
                    $0.lastError != nil
                }
                if !failed.isEmpty {
                    StatusPill(store.isPartialRefresh ? "Partially refreshed · some feeds failed" :
                               "Some feeds could not be refreshed", kind: .warning)
                    ForEach(failed) { feed in
                        Text("\(feed.name): \(Self.failureText(feed.lastError!, in: snapshot))")
                            .appTypography(.body)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                let blocked = snapshot.feeds.filter {
                    $0.isEnabled && !$0.topicIDs.isDisjoint(with: snapshot.preferences.selectedTopicIDs) &&
                    ($0.retryNotBefore.map { $0 > now } ?? false)
                }
                if !blocked.isEmpty {
                    Text("Server retry available after \(blocked.compactMap(\.retryNotBefore).min()!.formatted(date: .abbreviated, time: .shortened)). Refresh will not request these feeds before then.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            if let failure = store.browserOpenFailure {
                VStack(alignment: .leading, spacing: AppMetrics.space2) {
                    StatusPill(failure.message, kind: .error)
                    HStack {
                        ActionButton("Retry opening article") {
                            store.openArticle(id: failure.articleID, sourceFeedID: failure.sourceFeedID)
                        }
                        ActionButton("Dismiss") { store.dismissBrowserOpenFailure() }
                    }
                }
            }
            switch state {
            case .loading: ProgressView("Loading saved News")
            case .readFailure: EmptyView() // Local read error is not an empty feed.
            case .unavailable: EmptyState("News is unavailable", guidance: "Try loading local News again.",
                                          actionTitle: "Retry loading local News") { store.reload() }
            case .noTopics: EmptyState("No topics selected", guidance: "Choose topics to see headlines.",
                                       actionTitle: "Topics & feeds") { showingTopics = true }
            case .noFeeds: EmptyState("No enabled feeds for selected topics",
                                      guidance: "Enable or add a feed in Topics & feeds.",
                                      actionTitle: "Topics & feeds") { showingTopics = true }
            case .emptyCache: EmptyState("No saved headlines yet",
                                         guidance: "Refresh to check your selected feeds. If a feed fails, try again later.")
            case .filteredEmpty: EmptyState("No headlines for this topic",
                                            guidance: "Try All selected topics or manage your feeds.",
                                            actionTitle: "All selected topics") { activeTopicID = nil }
            case .headlines: EmptyView()
            }
            if let snapshot = store.snapshot, state == .headlines || state == .readFailure {
                ForEach(Self.sections(in: snapshot, filter: activeTopicID), id: \.kind) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title)
                            .appTypography(.section)
                            .foregroundStyle(AppColors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, AppMetrics.space2)
                        ForEach(section.articles, id: \.article.id) { visible in
                            articleRow(visible, topics: snapshot.topics)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
    }

    private func topicFilters(_ snapshot: NewsSnapshot) -> some View {
        let topics = Self.selectedTopics(in: snapshot)
        let selected = Self.effectiveFilter(activeTopicID, in: snapshot)
        return ScrollView(.horizontal) {
            HStack(spacing: AppMetrics.space2) {
                filterButton("All", id: nil, selected: selected == nil)
                ForEach(topics) { topic in
                    filterButton(topic.name, id: topic.id, selected: selected == topic.id)
                }
            }
            .padding(.vertical, AppMetrics.space1)
        }
        .accessibilityLabel("Filter headlines by selected topic")
    }

    private func filterButton(_ title: String, id: String?, selected: Bool) -> some View {
        Button(title) { activeTopicID = id }
            .buttonStyle(.plain)
            .appTypography(.action)
            .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
            .padding(.horizontal, AppMetrics.space3)
            .frame(minHeight: AppMetrics.minimumTarget)
            .background(selected ? AppColors.surface : .clear,
                        in: RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
            .focusable()
            .focused($focusedFilter, equals: id ?? "all")
            .overlay {
                if focusedFilter == (id ?? "all") {
                    RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                        .strokeBorder(AppColors.focusRing, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("news-filter-\(id ?? "all")")
    }

    private func articleRow(_ visible: NewsSelection.VisibleArticle, topics: [NewsTopic]) -> some View {
        let article = visible.article
        let names = topics.filter { visible.topicIDs.contains($0.id) }.map(\.name)
        let isExpanded = expandedIDs.contains(article.id)
        return VStack(alignment: .leading, spacing: AppMetrics.space2) {
            Text(article.title)
                .appTypography(.body)
                .foregroundStyle(AppColors.textPrimary)
            Text([Self.sourceName(for: article),
                  article.publishedAt?.formatted(date: .abbreviated, time: .omitted) ?? NewsSelection.undatedLabel,
                  names.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · "))
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            if let summary = article.summary, !summary.isEmpty {
                Button(isExpanded ? "Hide summary" : "Show summary") {
                    if isExpanded { expandedIDs.remove(article.id) }
                    else { expandedIDs.insert(article.id) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.accent)
                .accessibilityLabel("\(isExpanded ? "Hide" : "Show") summary for \(article.title)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                if isExpanded {
                    Text(summary) // FeedParser already supplies inert plain text. Never render HTML.
                        .appTypography(.body)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            ActionButton("Read", symbol: "arrow.up.right") {
                store.openArticle(id: article.id, sourceFeedID: article.sources.first?.feedID)
            }
                .accessibilityLabel(Self.readLabel(for: article))
                .accessibilityIdentifier("news-read-\(article.id.uuidString)")
            AppColors.border.frame(height: 1).padding(.top, AppMetrics.space2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppMetrics.space3)
    }
}
