import SwiftUI

/// History is a projection of the shared owner's committed rows. Filters and navigation
/// belong to the containing window; opening this view never loads or changes the timer.
struct FocusHistoryPresentation {
    let result: FocusHistoryResult
    let readState: FocusReadState

    var isStale: Bool { readState.isStale }
    var isUnreadable: Bool {
        if case .failed = readState { return true }
        return false
    }
    var isEmpty: Bool { !isUnreadable && result.groups.isEmpty }

    static func title(for session: FocusSessionSnapshot) -> String {
        session.linkedTitleSnapshot ?? "Focus session"
    }

    static func detail(for session: FocusSessionSnapshot) -> String {
        let seconds = Int(min(session.actualSeconds.rounded(.down), Double(Int.max).nextDown))
        let duration = "\(seconds / 60) min \(seconds % 60) sec"
        return "\(duration) focused · \(session.state == .completed ? "Completed" : "Ended early")"
    }
}

struct FocusHistoryView: View {
    @ObservedObject var service: FocusService
    @Binding var filter: FocusHistoryFilter

    var body: some View {
        let presentation = FocusHistoryPresentation(result: service.history(filter), readState: service.readState)
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            SectionHeader("Recent sessions")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space2) { filters }
                VStack(alignment: .leading, spacing: AppMetrics.space2) { filters }
            }
            .focusSection()
            if presentation.isUnreadable {
                ErrorBanner(.readFailed, recoveryTitle: "Retry sessions", recovery: { service.retryRead() })
                    .accessibilityIdentifier("focus-history-error")
                if presentation.isStale {
                    Text("Showing saved sessions from before the failed refresh. These results may be out of date.")
                        .appTypography(.body)
                        .foregroundStyle(AppColors.textSecondary)
                        .accessibilityIdentifier("focus-history-stale")
                    groups(presentation.result.groups)
                } else {
                    Text("Sessions could not be loaded. Retry to see your history.")
                        .appTypography(.body)
                        .accessibilityIdentifier("focus-history-unavailable")
                }
            } else if service.readState == .notLoaded {
                LoadingState("Loading sessions")
            } else if presentation.isEmpty {
                EmptyState("No sessions in this period", guidance: "Completed and ended sessions will appear here after they are saved.")
                    .accessibilityIdentifier("focus-history-empty")
            } else {
                groups(presentation.result.groups)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var filters: some View {
        filterButton("Recent", .recent, identifier: "focus-history-recent")
        filterButton("Today", .today, identifier: "focus-history-today")
        filterButton("This week", .thisWeek, identifier: "focus-history-week")
    }

    private func filterButton(_ title: String, _ choice: FocusHistoryFilter, identifier: String) -> some View {
        ActionButton(title, variant: filter == choice ? .primary : .secondary) { filter = choice }
            .accessibilityValue(filter == choice ? "Selected" : "Not selected")
            .accessibilityAddTraits(filter == choice ? .isSelected : [])
            .accessibilityIdentifier(identifier)
    }

    private func groupTitle(_ date: Date) -> String {
        var format = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        format.timeZone = service.temporalContext.timeZone
        return date.formatted(format)
    }

    private func groups(_ groups: [FocusHistoryGroup]) -> some View {
        // Rows remain read-only: there is no focusable empty cell or misleading action.
        ForEach(groups, id: \.day.start) { group in
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                Text(groupTitle(group.day.start))
                    .appTypography(.section)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.sessions, id: \.id) { session in
                    AppListRow(FocusHistoryPresentation.title(for: session),
                               metadata: FocusHistoryPresentation.detail(for: session))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("focus-history-session-\(session.id.uuidString)")
                }
            }
        }
    }
}
