import SwiftUI

/// The same committed owner is observed from News and Settings. Selection is saved
/// immediately; feed action destinations are view-local, never a second settings copy.
struct NewsManagementView: View {
    @ObservedObject var store: NewsStore
    @State private var actionError: String?
    @State private var pendingFeedIDs = Set<UUID>()
    @State private var feedAction: FeedAction?
    @FocusState private var focusedTopic: String?

    enum FeedAction: Equatable, Identifiable {
        case add
        case edit(FeedSourceSnapshot)
        case remove(FeedSourceSnapshot)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let feed): return "edit-\(feed.id)"
            case .remove(let feed): return "remove-\(feed.id)"
            }
        }
        var title: String {
            switch self {
            case .add: return "Add feed"
            case .edit: return "Edit feed"
            case .remove: return "Remove feed"
            }
        }
    }

    static func selectedCountText(_ snapshot: NewsSnapshot) -> String {
        let count = snapshot.topics.filter { snapshot.preferences.selectedTopicIDs.contains($0.id) }.count
        return "\(count) \(count == 1 ? "topic" : "topics") selected"
    }

    static func topicNames(for feed: FeedSourceSnapshot, in snapshot: NewsSnapshot) -> String {
        snapshot.topics.filter { feed.topicIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    static func enabledDraft(for feed: FeedSourceSnapshot, enabled: Bool) -> FeedDraft {
        FeedDraft(id: feed.id, name: feed.name, urlText: feed.url.absoluteString,
                  topicIDs: feed.topicIDs, isEnabled: enabled,
                  expectedRevision: feed.configurationRevision, draftRevision: UUID())
    }

    static func errorMessage(_ error: Error) -> String {
        switch error as? NewsRepositoryError {
        case .staleRevision: return "News settings changed elsewhere. Reload and review before trying again."
        case .validationRequired: return "This feed must be validated before enabling. Try again when online."
        case .invalidFeed, .duplicateEndpoint, .feedLimitReached:
            return "The feed configuration could not be saved. Review its settings."
        default: return "Could not save this change. Saved topics and feeds have not changed. Try again."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text("Topics & feeds")
                .appTypography(.section)
                .accessibilityAddTraits(.isHeader)
            if let actionError {
                Text(actionError)
                    .appTypography(.body)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
                ActionButton("Reload News settings") {
                    store.reload()
                    if store.localFailure == nil { self.actionError = nil }
                }
            }
            if store.localFailure == .read || store.localFailure == .catalog {
                ErrorBanner(.readFailed, recoveryTitle: "Retry loading News settings") { store.reload() }
                if store.snapshot != nil { StatusPill("Previously loaded settings · may be out of date", kind: .warning) }
            }
            if let snapshot = store.snapshot {
                management(snapshot)
                    .disabled(store.localFailure == .read || store.localFailure == .catalog)
            } else if store.isLoading {
                ProgressView("Loading saved News settings")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AppColors.textPrimary)
        .onAppear { store.loadIfNeeded() } // Local load only, never foreground refresh.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("news-management")
        .sheet(item: $feedAction) { action in
            // Step 4.5 establishes the entry points only. Step 4.6 replaces this
            // non-mutating destination with the editor and removal confirmation.
            VStack(alignment: .leading, spacing: AppMetrics.space4) {
                PageHeader(action.title)
                if case .edit(let feed) = action { Text(feed.name).appTypography(.body) }
                if case .remove(let feed) = action { Text(feed.name).appTypography(.body) }
                Text("\(action.title) is not available yet. No feed has been changed.")
                    .appTypography(.body)
                    .fixedSize(horizontal: false, vertical: true)
                ActionButton("Cancel") { feedAction = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppMetrics.space6)
            .frame(width: 360)
            .background(AppColors.background)
        }
    }

    private func management(_ snapshot: NewsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text(Self.selectedCountText(snapshot))
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityIdentifier("news-selected-topic-count")
            Text("Topics")
                .appTypography(.section)
                .accessibilityAddTraits(.isHeader)
            Text("Changes save immediately. Selecting no topics hides headlines without deleting saved articles.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                      alignment: .leading, spacing: AppMetrics.space2) {
                ForEach(snapshot.topics) { topic in
                    Toggle(topic.name, isOn: Binding(
                        get: { store.snapshot?.preferences.selectedTopicIDs.contains(topic.id) ?? false },
                        set: { selected in
                            guard var ids = store.snapshot?.preferences.selectedTopicIDs else { return }
                            if selected { ids.insert(topic.id) } else { ids.remove(topic.id) }
                            do { try store.saveSelectedTopics(ids); actionError = nil }
                            catch { actionError = Self.errorMessage(error) }
                        }))
                    .toggleStyle(.checkbox)
                    .appTypography(.body)
                    .frame(minHeight: AppMetrics.minimumTarget, alignment: .leading)
                    .focused($focusedTopic, equals: topic.id)
                    .overlay {
                        if focusedTopic == topic.id {
                            RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                                .strokeBorder(AppColors.focusRing, lineWidth: 2)
                                .padding(-3)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Select \(topic.name) topic for News")
                    .accessibilityIdentifier("news-topic-\(topic.id)")
                }
            }
            if snapshot.preferences.selectedTopicIDs.isEmpty {
                Text("No topics selected. Choose any topic above to show its headlines.")
                    .appTypography(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Feeds")
                .appTypography(.section)
                .accessibilityAddTraits(.isHeader)
            Text("\(snapshot.feeds.filter(\.isEnabled).count) enabled · \(snapshot.feeds.count) of 32 feeds")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            ActionButton("Add feed", symbol: "plus", isEnabled: snapshot.feeds.count < 32) { feedAction = .add }
                .accessibilityIdentifier("news-add-feed")
            if snapshot.feeds.count >= 32 {
                Text("Feed limit reached. Remove a feed before adding another.").appTypography(.body)
            }
            if snapshot.feeds.isEmpty {
                Text("No feeds saved. Add a feed to start receiving headlines.").appTypography(.body)
            } else if !snapshot.feeds.contains(where: \.isEnabled) {
                Text("No enabled feeds. Enable a saved feed or add another; cached articles remain saved.")
                    .appTypography(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(snapshot.feeds) { feed in feedRow(feed, snapshot: snapshot) }
        }
    }

    private func feedRow(_ feed: FeedSourceSnapshot, snapshot: NewsSnapshot) -> some View {
        let pending = pendingFeedIDs.contains(feed.id)
        return VStack(alignment: .leading, spacing: AppMetrics.space2) {
            Text(feed.name).appTypography(.body)
            Text(feed.url.absoluteString)
                .textSelection(.enabled)
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Topics: \(Self.topicNames(for: feed, in: snapshot))")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(pending ? "Validating / saving change" : (feed.isEnabled ? "Enabled" : "Disabled"))
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space2) { feedControls(feed, pending: pending) }
                VStack(alignment: .leading, spacing: AppMetrics.space2) { feedControls(feed, pending: pending) }
            }
            AppColors.border.frame(height: 1).padding(.top, AppMetrics.space2)
        }
        .padding(.vertical, AppMetrics.space2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("news-feed-\(feed.id)")
    }

    @ViewBuilder
    private func feedControls(_ feed: FeedSourceSnapshot, pending: Bool) -> some View {
        ActionButton(feed.isEnabled ? "Disable" : "Enable", isEnabled: !pending, isBusy: pending) {
            pendingFeedIDs.insert(feed.id)
            let draft = Self.enabledDraft(for: feed, enabled: !feed.isEnabled)
            Task {
                defer { pendingFeedIDs.remove(feed.id) }
                do { try await store.saveFeed(draft); actionError = nil }
                catch is CancellationError { }
                catch { actionError = Self.errorMessage(error) }
            }
        }
        .accessibilityLabel("\(feed.isEnabled ? "Disable" : "Enable") \(feed.name) feed")
        ActionButton("Edit", isEnabled: !pending) { feedAction = .edit(feed) }
            .accessibilityLabel("Edit \(feed.name) feed")
        ActionButton("Remove", variant: .destructive, isEnabled: !pending) { feedAction = .remove(feed) }
            .accessibilityLabel("Remove \(feed.name) feed")
    }
}

/// Owns scrolling only for the modal. Inline Settings inherits its scene's ScrollView.
struct NewsManagementSheet: View {
    @ObservedObject var store: NewsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            ScrollView {
                NewsManagementView(store: store)
                    .padding(AppMetrics.space6)
            }
            ActionButton("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, AppMetrics.space6)
                .padding(.bottom, AppMetrics.space4)
        }
        .frame(minWidth: 360, idealWidth: 620, maxWidth: 720, minHeight: 280, idealHeight: 600)
        .background(AppColors.background)
        .preferredColorScheme(.dark)
    }
}
