import SwiftUI

/// Sheet-local draft and cancellation key. The shared store owns only committed values.
@MainActor
final class NewsFeedEditorState: ObservableObject {
    @Published var draft: FeedDraft
    @Published private(set) var isSubmitting = false
    @Published private(set) var fieldErrors: [String: String] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsReload = false
    @Published private(set) var pendingText = "Saving feed"
    let editorID = UUID()
    private var saveTask: Task<Void, Never>?
    private var isClosed = false

    init(feed: FeedSourceSnapshot? = nil) {
        draft = Self.makeDraft(feed)
    }

    static func makeDraft(_ feed: FeedSourceSnapshot?) -> FeedDraft {
        FeedDraft(id: feed?.id, name: feed?.name ?? "", urlText: feed?.url.absoluteString ?? "",
                  topicIDs: feed?.topicIDs ?? [], isEnabled: feed?.isEnabled ?? true,
                  expectedRevision: feed?.configurationRevision, draftRevision: UUID())
    }

    static func localErrors(_ draft: FeedDraft, snapshot: NewsSnapshot?) -> [String: String] {
        var errors: [String: String] = [:]
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.utf8.count > 256 { errors["name"] = "Enter a name of at most 256 UTF-8 bytes." }
        let endpoint = try? NewsURLPolicy.normalizedFeedURL(draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        if endpoint == nil { errors["url"] = "Enter a valid HTTPS feed URL without credentials." }
        if let snapshot {
            if let endpoint, snapshot.feeds.contains(where: {
                $0.id != draft.id && (try? NewsURLPolicy.normalizedFeedURL($0.url.absoluteString)) == endpoint
            }) { errors["url"] = "This endpoint is already saved. Edit the existing feed instead." }
            if draft.topicIDs.isEmpty || !draft.topicIDs.isSubset(of: Set(snapshot.topics.map(\.id))) {
                errors["topics"] = "Select at least one available topic."
            }
            if draft.id == nil && snapshot.feeds.count >= 32 { errors["limit"] = "Remove a feed before adding another; the limit is 32." }
        } else { errors["settings"] = "Reload News settings before saving." }
        return errors
    }

    static func requiresValidation(_ draft: FeedDraft, snapshot: NewsSnapshot?) -> Bool {
        guard draft.isEnabled else { return false }
        guard let old = snapshot?.feeds.first(where: { $0.id == draft.id }) else { return true }
        return (try? NewsURLPolicy.normalizedFeedURL(old.url.absoluteString)) !=
            (try? NewsURLPolicy.normalizedFeedURL(draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines))) ||
            (!old.isEnabled && old.lastSuccessAt == nil)
    }

    static func message(for error: Error) -> String {
        if let failure = error as? FeedServiceError {
            switch failure.code {
            case .malformedFeed: return "The feed did not return supported RSS or Atom XML. Review the URL and try again. Your draft is retained."
            case .rateLimited: return "The server is rate-limiting requests. Wait before trying Save again. Your draft is retained."
            case .unsafeURL: return "The feed or its redirect is not a safe HTTPS endpoint. Review the URL."
            case .oversizedResponse: return "The feed exceeds the response limit. Choose a smaller feed."
            default: return "Could not check this feed. Review the URL or try again when online. Your draft is retained."
            }
        }
        switch error as? NewsRepositoryError {
        case .staleRevision: return "This feed changed elsewhere. Reload the latest feed and review before saving. Your draft has not been saved."
        case .duplicateEndpoint: return "This endpoint is already saved. Edit the existing feed instead."
        case .feedLimitReached: return "Remove a feed before adding another; the limit is 32."
        case .invalidFeed: return "Review the name, HTTPS URL, and topics before saving."
        case .validationRequired: return "This endpoint needs a successful feed check. Try Save again when online."
        default: return "Could not save this feed on this Mac. Nothing new was committed. Your draft is retained; try Save again."
        }
    }

    func submit(store: NewsStore, onSaved: @escaping () -> Void) {
        guard !isClosed, !isSubmitting, !needsReload else { return }
        fieldErrors = Self.localErrors(draft, snapshot: store.snapshot)
        guard fieldErrors.isEmpty else { return }
        // Each submission gets fresh validation evidence while preserving the session key.
        let attempt = FeedDraft(id: draft.id, name: draft.name, urlText: draft.urlText,
            topicIDs: draft.topicIDs, isEnabled: draft.isEnabled,
            expectedRevision: draft.expectedRevision, draftRevision: UUID())
        errorMessage = nil
        pendingText = Self.requiresValidation(attempt, snapshot: store.snapshot) ? "Checking this feed…" : "Saving feed…"
        isSubmitting = true
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isSubmitting = false; self.saveTask = nil }
            // Cancel may run before this queued task starts. Do not create a new store
            // attempt after the cancellation key has already been invalidated.
            guard !self.isClosed, !Task.isCancelled else { return }
            do {
                try await store.saveFeed(attempt, editorID: self.editorID)
                guard !self.isClosed else { return }
                onSaved()
            } catch {
                guard !self.isClosed else { return }
                if error is CancellationError {
                    self.errorMessage = "The feed check was canceled. Your draft is retained; try Save again."
                } else {
                    self.errorMessage = Self.message(for: error)
                    self.needsReload = (error as? NewsRepositoryError) == .staleRevision
                }
            }
        }
    }

    /// Explicitly replaces the unsaved fields; never silently adopts a newer revision.
    func reloadLatest(store: NewsStore) {
        guard !isSubmitting, !isClosed else { return }
        store.reload()
        guard store.localFailure == nil else {
            errorMessage = "Could not reload News settings. Your draft is retained. Try again."
            return
        }
        guard let id = draft.id, let current = store.snapshot?.feeds.first(where: { $0.id == id }) else {
            errorMessage = "This feed was removed elsewhere. Cancel to return to the feed list. Your draft was not saved."
            needsReload = true
            return
        }
        draft = Self.makeDraft(current)
        fieldErrors = [:]
        errorMessage = "Latest saved feed loaded. Review its fields before saving."
        needsReload = false
    }

    func cancel(store: NewsStore) {
        isClosed = true
        store.cancelFeedEdit(id: editorID)
        saveTask?.cancel()
    }
}

struct NewsFeedEditorView: View {
    @ObservedObject var store: NewsStore
    @StateObject private var editor: NewsFeedEditorState
    let onDismiss: () -> Void
    @FocusState private var nameFocused: Bool

    init(store: NewsStore, feed: FeedSourceSnapshot? = nil, onDismiss: @escaping () -> Void) {
        self.store = store
        _editor = StateObject(wrappedValue: NewsFeedEditorState(feed: feed))
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader(editor.draft.id == nil ? "Add feed" : "Edit feed")
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.space4) {
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Name")
                        TextField("Name", text: $editor.draft.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .accessibilityIdentifier("news-editor-name")
                        fieldError("name")
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Feed URL")
                        TextField("https://", text: $editor.draft.urlText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Feed URL, HTTPS required")
                            .accessibilityIdentifier("news-editor-url")
                        fieldError("url")
                    }
                    Text("Topics · choose at least one").accessibilityAddTraits(.isHeader)
                    ForEach(store.snapshot?.topics ?? []) { topic in
                        Toggle(topic.name, isOn: Binding(
                            get: { editor.draft.topicIDs.contains(topic.id) },
                            set: { if $0 { editor.draft.topicIDs.insert(topic.id) } else { editor.draft.topicIDs.remove(topic.id) } }))
                            .toggleStyle(.checkbox)
                            .frame(minHeight: AppMetrics.minimumTarget, alignment: .leading)
                            .accessibilityLabel("Map feed to \(topic.name) topic")
                    }
                    fieldError("topics")
                    Toggle("Enabled", isOn: $editor.draft.isEnabled)
                        .toggleStyle(.checkbox)
                        .frame(minHeight: AppMetrics.minimumTarget, alignment: .leading)
                    Text("Enabled new or changed endpoints must pass a feed check. Save disabled to keep a locally valid draft while offline.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                    fieldError("limit")
                    fieldError("settings")
                }
                .disabled(editor.isSubmitting)
                .appTypography(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if editor.isSubmitting { ProgressView(editor.pendingText).accessibilityIdentifier("news-editor-pending") }
            if let message = editor.errorMessage {
                Text(message).appTypography(.body).foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("news-editor-error")
            }
            if editor.needsReload {
                Text("Reload replaces your unsaved fields with the latest saved feed.")
                    .appTypography(.metadata)
                ActionButton("Reload latest feed & review", isEnabled: !editor.isSubmitting) {
                    editor.reloadLatest(store: store)
                    nameFocused = true
                }
            }
            HStack(spacing: AppMetrics.space3) {
                ActionButton("Cancel") { editor.cancel(store: store); onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("news-editor-cancel")
                ActionButton("Save", variant: .primary, isEnabled: !editor.needsReload,
                             isBusy: editor.isSubmitting) { editor.submit(store: store, onSaved: onDismiss) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("news-editor-save")
            }
        }
        .padding(AppMetrics.space6)
        .frame(minWidth: 360, idealWidth: 560, maxWidth: 680, minHeight: 400, idealHeight: 620)
        .background(AppColors.background)
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .onAppear { nameFocused = true }
        .onDisappear { editor.cancel(store: store) }
        .interactiveDismissDisabled(editor.isSubmitting)
    }

    @ViewBuilder private func fieldError(_ key: String) -> some View {
        if let message = editor.fieldErrors[key] {
            Text(message).foregroundStyle(AppColors.error).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("news-editor-\(key)-error")
        }
    }
}

/// An explicit destructive confirmation. Failure keeps the confirmation and saved feed.
struct NewsFeedRemovalView: View {
    @ObservedObject var store: NewsStore
    let feed: FeedSourceSnapshot
    let onDismiss: () -> Void
    @State private var errorMessage: String?
    @State private var needsReview = false
    @FocusState private var cancelFocused: Bool

    static func confirm(feed: FeedSourceSnapshot, store: NewsStore) throws {
        guard store.snapshot?.feeds.first(where: { $0.id == feed.id })?.configurationRevision == feed.configurationRevision else {
            throw NewsRepositoryError.staleRevision
        }
        try store.removeFeed(id: feed.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Remove \(feed.name)?")
            ScrollView {
                Text("This deletes the subscription and its sole-source cached headlines. Articles also saved from another feed remain. This cannot be undone here. To pause requests and keep its bounded cache, Cancel and disable the feed instead.")
                    .appTypography(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Text(errorMessage).appTypography(.body).foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space3) { actions }
                VStack(alignment: .leading, spacing: AppMetrics.space3) { actions }
            }
        }
        .padding(AppMetrics.space6)
        .frame(minWidth: 360, idealWidth: 520, maxWidth: 680, minHeight: 260, idealHeight: 360)
        .background(AppColors.background)
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .onAppear { cancelFocused = true }
    }

    @ViewBuilder private var actions: some View {
        ActionButton("Cancel · keep feed", action: onDismiss)
            .keyboardShortcut(.cancelAction)
            .focused($cancelFocused)
            .accessibilityIdentifier("news-removal-cancel")
        ActionButton("Remove feed", variant: .destructive, isEnabled: !needsReview) {
            do { try Self.confirm(feed: feed, store: store); onDismiss() }
            catch {
                needsReview = (error as? NewsRepositoryError) == .staleRevision
                errorMessage = needsReview
                    ? "This feed changed or was removed elsewhere. Cancel and review the latest feed before confirming removal."
                    : "Could not save removal. The saved feed and cache are unchanged. Try again or Cancel."
            }
        }
        .accessibilityLabel("Confirm removal of \(feed.name) feed")
        .accessibilityIdentifier("news-removal-confirm")
    }
}
