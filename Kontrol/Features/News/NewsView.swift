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

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            PageHeader("News")
            if let snapshot = store.snapshot {
                topicFilters(snapshot)
            }
            HStack(spacing: AppMetrics.space2) {
                ActionButton("Refresh", symbol: "arrow.clockwise", isEnabled: !store.isRefreshing,
                             isBusy: store.isRefreshing) {
                    Task { await store.refresh(.manual) }
                }
                ActionButton("Topics & feeds", symbol: "slider.horizontal.3") {
                    showingTopics = true
                }
            }
            if let snapshot = store.snapshot {
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
        .sheet(isPresented: $showingTopics) {
            // Read-only entry until the shared editing surface is added in Step 4.5.
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.space4) {
                    PageHeader("Topics & feeds")
                    if let snapshot = store.snapshot {
                        Text("Selected topics: \(Self.selectedTopics(in: snapshot).map(\.name).joined(separator: ", "))")
                            .appTypography(.body)
                        Text("Feeds")
                            .appTypography(.section)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(snapshot.feeds) { feed in
                            Text("\(feed.name) · \(feed.isEnabled ? "Enabled" : "Disabled")")
                                .appTypography(.body)
                        }
                    }
                    ActionButton("Close") { showingTopics = false }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppMetrics.space8)
            }
            .frame(minWidth: 360, minHeight: 280)
        }
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
