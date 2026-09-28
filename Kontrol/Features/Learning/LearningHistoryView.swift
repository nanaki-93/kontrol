import SwiftUI

/// History reads never open an attempt. Selection is a window-local stable ID, and
/// detail is rendered only after an independent, matching read of that ID.
struct LearningHistoryView: View {
    @ObservedObject var store: LearningCatalogStore
    @ObservedObject var navigation: NavigationStore
    @State private var selectedID: String?
    @State private var actionError: LessonExperienceError?

    static func entry(_ id: String?, in state: LessonHistoryReadState) -> LessonHistorySnapshot? {
        guard let id, case .current(let rows) = state else { return nil }
        return rows.first { $0.lessonID == id }
    }

    static func matchedDetail(_ entry: LessonHistorySnapshot?, state: LessonDetailReadState) -> LessonDetailSnapshot? {
        guard let entry, case .current(let detail) = state,
              detail.id == entry.lessonID, detail.progress?.status == entry.status,
              detail.attempt == entry.attempt else { return nil }
        if entry.attempt == nil, entry.status == .dismissed {
            guard entry.content == .unavailable else { return nil }
        } else {
            guard detail.content == entry.content else { return nil }
        }
        return detail
    }

    static func canRestore(_ entry: LessonHistorySnapshot?, detail: LessonDetailSnapshot?) -> Bool {
        entry?.status == .dismissed && detail?.id == entry?.lessonID && detail?.progress?.status == .dismissed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Button("Back to choices") { navigation.backToChoices() }
                .accessibilityIdentifier("learning-history-back")
            PageHeader("History")
            if case .failed = store.state {
                ErrorBanner(.readFailed, recoveryTitle: "Retry learning choices", recovery: store.retry)
                Text("Learning choices unavailable. Restore is disabled until this read succeeds.")
                    .appTypography(.body)
            }
            if let actionError {
                Text("Restore was not saved (\(String(describing: actionError))). Your history and retained work are unchanged. Retry after resolving any read or save error.")
                    .appTypography(.body)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("learning-history-action-error")
            }
            if case .failed(let stale) = store.historyState {
                ErrorBanner(.readFailed, recoveryTitle: "Retry History read") {
                    _ = try? store.retryHistory()
                }
                .accessibilityIdentifier("learning-history-read-error")
                Text(stale == nil ? "History unavailable. Retry to load saved lessons." :
                     "History unavailable after a failed refresh. Earlier results may be out of date; retry before selecting or restoring.")
                    .appTypography(.body)
                    .accessibilityIdentifier("learning-history-unavailable")
            } else if case .current(let rows) = store.historyState {
                if rows.isEmpty {
                    EmptyState("No completed or dismissed lessons yet.",
                               guidance: "Completed and dismissed lessons will appear here.")
                        .accessibilityIdentifier("learning-history-empty")
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: AppMetrics.space6) {
                            rowsPanel(rows).frame(maxWidth: .infinity, alignment: .leading)
                            detailPanel.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minWidth: 720)
                        VStack(alignment: .leading, spacing: AppMetrics.space4) {
                            rowsPanel(rows)
                            detailPanel
                        }
                    }
                }
            } else {
                LoadingState("Loading History")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.horizontalInset)
        .onAppear {
            store.loadIfNeeded()
            if case .notLoaded = store.historyState { _ = try? store.loadHistory() }
        }
    }

    private func rowsPanel(_ rows: [LessonHistorySnapshot]) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader("Saved lessons")
            ForEach(rows) { entry in
                Button {
                    selectedID = entry.lessonID
                    actionError = nil
                    _ = try? store.loadDetail(lessonID: entry.lessonID)
                } label: {
                    AppListRow(entry.title, metadata: "\(entry.status == .completed ? "Completed" : "Dismissed") · \(entry.topicID ?? "Topic unavailable") · \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("learning-history-row-\(entry.lessonID)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var detailPanel: some View {
        if let selectedID {
            if case .failed(let id, _) = store.detailState, id == selectedID {
                ErrorBanner(.readFailed, recoveryTitle: "Retry lesson read") {
                    _ = try? store.retryDetail(lessonID: id)
                }
                .accessibilityIdentifier("learning-history-detail-error")
                Text("Saved lesson detail unavailable. Retry; no current lesson is substituted.")
                    .appTypography(.body)
            } else if let entry = Self.entry(selectedID, in: store.historyState),
                      let detail = Self.matchedDetail(entry, state: store.detailState) {
                archivedDetail(entry, detail: detail)
            } else {
                Text("Saved lesson detail unavailable. Select the lesson again to retry its read.")
                    .appTypography(.body)
                    .accessibilityIdentifier("learning-history-detail-unavailable")
                if Self.entry(selectedID, in: store.historyState) != nil {
                    Button("Retry lesson read") { _ = try? store.loadDetail(lessonID: selectedID) }
                }
            }
        } else {
            Text("Select a saved lesson to read its history.")
                .appTypography(.body)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private func archivedDetail(_ entry: LessonHistorySnapshot, detail: LessonDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            SectionHeader(entry.title)
            Text("\(entry.status == .completed ? "Completed" : "Dismissed") · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                .appTypography(.metadata)
            if entry.status == .dismissed && entry.attempt == nil {
                Text("Dismissed before study. No studied version was archived.")
                    .appTypography(.body)
                    .accessibilityIdentifier("learning-history-before-study")
            } else {
            switch entry.content {
            case .pinned(let studied):
                archivedSections(explanation: studied.explanation, example: studied.workedExample,
                                 exercise: studied.exercise, reference: studied.referenceAnswer,
                                 criteria: studied.selfCheckCriteria)
                Text("Studied version \(studied.contentVersion)").appTypography(.metadata)
            case .legacyCompleted(let studied):
                archivedSections(explanation: studied.explanation, example: studied.workedExample,
                                 exercise: studied.exercise, reference: studied.referenceAnswer,
                                 criteria: studied.selfCheckCriteria)
                Text("Saved completed snapshot").appTypography(.metadata)
            case .current:
                Text("Archived content unavailable. Current catalog content is not substituted.")
                    .appTypography(.body)
            case .unavailable:
                Text("Archived content unavailable. Current catalog content is not substituted.")
                    .appTypography(.body)
                    .accessibilityIdentifier("learning-history-content-unavailable")
            }
            }
            if let attempt = detail.attempt {
                SectionHeader("Saved answer")
                Text(attempt.answerDraft.isEmpty ? "(Blank response)" : attempt.answerDraft)
                    .appTypography(.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("learning-history-answer")
            }
            if Self.canRestore(entry, detail: detail) {
                Button("Restore \(entry.title)") { restore(entry) }
                    .disabled(!store.state.isAuthoritative)
                    .accessibilityIdentifier("learning-history-restore-\(entry.lessonID)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("learning-history-detail-\(entry.lessonID)")
    }

    private func archivedSections(explanation: String, example: String, exercise: String,
                                  reference: String, criteria: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            archivedSection("Explanation", explanation)
            archivedSection("Worked example", example)
            archivedSection("Exercise", exercise)
            archivedSection("Reference solution", reference)
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                SectionHeader("Self-check · authored criteria")
                ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                    Text("• \(criterion)")
                        .appTypography(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("learning-history-criterion")
                }
            }
        }
    }

    private func archivedSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader(title)
            Text(text).appTypography(.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("learning-history-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
    }

    private func restore(_ entry: LessonHistorySnapshot) {
        guard Self.canRestore(Self.entry(entry.lessonID, in: store.historyState),
                              detail: Self.matchedDetail(entry, state: store.detailState)) else {
            actionError = .invalidTransition
            return
        }
        guard navigation.flushForLifecycle() else {
            actionError = navigation.saveError ?? .persistenceFailure
            return
        }
        do {
            let receipt = try store.restoreDismissed(lessonID: entry.lessonID)
            guard receipt.detail.id == entry.lessonID else { throw LessonExperienceError.invalidStoredData }
            actionError = nil
            selectedID = nil // the restored lesson is no longer a terminal History row
        } catch {
            actionError = (error as? LessonExperienceError) ?? .persistenceFailure
        }
    }
}
