import SwiftUI

/// History reads never open an attempt. Selection is a window-local stable ID, and
/// detail is rendered only after an independent, matching read of that ID.
struct LearningHistoryView: View {
    @ObservedObject var store: LearningCatalogStore
    @ObservedObject var navigation: NavigationStore
    @State private var selectedID: String?
    @State private var actionError: LessonExperienceError?
    @State private var filters = LearningHistoryFilters()
    @State private var customStart = HistoryLocalDate(Date(), calendar: .current, timeZone: .current)
    @State private var customEnd = HistoryLocalDate(Date(), calendar: .current, timeZone: .current)
    @State private var hasChosenCustom = false
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    init(store: LearningCatalogStore, navigation: NavigationStore,
         initialFilters: LearningHistoryFilters = .init()) {
        self.store = store
        self.navigation = navigation
        _filters = State(initialValue: initialFilters)
        if case .custom(let start, let end) = initialFilters.date {
            _customStart = State(initialValue: start)
            _customEnd = State(initialValue: end)
            _hasChosenCustom = State(initialValue: true)
        }
    }

    // Selection is derived from the authoritative History read, not from a stale
    // detail or installed definition. The same projection drives rows and detail.
    static func visibleEntry(_ id: String?, in state: LessonHistoryReadState,
                             groups: [LearningHistoryDayGroup]) -> LessonHistorySnapshot? {
        guard let entry = entry(id, in: state),
              groups.contains(where: { $0.rows.contains(where: { $0.lessonID == entry.lessonID && $0.status == entry.status }) })
        else { return nil }
        return entry
    }

    static func entry(_ id: String?, in state: LessonHistoryReadState) -> LessonHistorySnapshot? {
        guard let id, case .current(let rows) = state else { return nil }
        return rows.first { $0.lessonID == id }
    }

    static func matchedDetail(_ entry: LessonHistorySnapshot?, state: LessonDetailReadState) -> LessonDetailSnapshot? {
        guard let entry, case .current(let detail) = state,
              detail.id == entry.lessonID, detail.progress?.status == entry.status,
              detail.attempt == entry.attempt else { return nil }
        if entry.attempt == nil, entry.status == .dismissed {
            // Detail may preview a newer installed definition. Only the archive
            // is shown as dismissal-time reference; never compare it to preview.
            guard entry.content == .unavailable ||
                  (entry.provenance == .dismissalReference || entry.provenance == .legacyRecoveredReference) &&
                  entry.content == entry.metadata?.dismissalTimeDefinition.map(LessonStudiedContent.current)
            else { return nil }
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
                filterControls(rows)
                switch selection(for: rows) {
                case .failure(let error):
                    Text(error == .reversedCustomRange
                         ? "End date must be on or after start date. Adjust the range to see saved lessons."
                         : "Choose valid local dates to see saved lessons.")
                        .appTypography(.body)
                        .foregroundStyle(AppColors.error)
                        .accessibilityIdentifier("learning-history-range-error")
                    Button("Clear filters") { clearFilters() }
                        .accessibilityIdentifier("learning-history-clear-invalid-range")
                case .success(let groups):
                    if rows.isEmpty {
                        EmptyState("No history yet", guidance: "Completed and dismissed lessons will appear here.")
                            .accessibilityIdentifier("learning-history-empty")
                    } else if groups.isEmpty {
                        VStack(alignment: .leading, spacing: AppMetrics.space4) {
                            EmptyState("No matching lessons", guidance: "Try a wider date or clear filters to see saved lessons.")
                                .accessibilityIdentifier("learning-history-no-match")
                            Button("Clear filters") { clearFilters() }
                                .accessibilityIdentifier("learning-history-clear-filters")
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: AppMetrics.space6) {
                                rowsPanel(groups).frame(maxWidth: .infinity, alignment: .leading)
                                detailPanel(groups: groups).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minWidth: 720)
                            VStack(alignment: .leading, spacing: AppMetrics.space4) {
                                rowsPanel(groups)
                                detailPanel(groups: groups)
                            }
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
            reconcileSelection()
        }
        .onChange(of: store.historyState) { _, _ in reconcileSelection() }
        .onChange(of: filters) { _, _ in reconcileSelection() }
        .onChange(of: timeZone) { _, _ in reconcileSelection() }
        .onChange(of: calendar) { _, _ in reconcileSelection() }
    }

    private func selection(for rows: [LessonHistorySnapshot]) -> Result<[LearningHistoryDayGroup], LearningHistorySelectionError> {
        LearningHistorySelection.select(rows, filters: filters, now: Date(), calendar: calendar,
                                        timeZone: timeZone, locale: locale)
    }

    private func reconcileSelection() {
        guard let selectedID, case .current(let rows) = store.historyState else { return }
        guard case .success(let groups) = selection(for: rows),
              Self.visibleEntry(selectedID, in: store.historyState, groups: groups) != nil else {
            self.selectedID = nil
            actionError = nil
            return
        }
    }

    private func clearFilters() {
        filters = LearningHistoryFilters()
    }

    private func pickerDate(_ day: HistoryLocalDate) -> Date {
        var local = calendar
        local.timeZone = timeZone
        return local.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
    }

    private var startDate: Binding<Date> {
        Binding(get: { pickerDate(customStart) }, set: {
            customStart = HistoryLocalDate($0, calendar: calendar, timeZone: timeZone)
            filters.date = .custom(start: customStart, end: customEnd)
        })
    }

    private var endDate: Binding<Date> {
        Binding(get: { pickerDate(customEnd) }, set: {
            customEnd = HistoryLocalDate($0, calendar: calendar, timeZone: timeZone)
            filters.date = .custom(start: customStart, end: customEnd)
        })
    }

    private func filterControls(_ rows: [LessonHistorySnapshot]) -> some View {
        let names = Dictionary(uniqueKeysWithValues: (store.state.snapshot?.topics ?? []).map { ($0.id, $0.name) })
        var available = Set(rows.compactMap(\.topicID).filter { !$0.isEmpty })
        available.formUnion(names.keys) // current topics with no saved work remain filterable
        if case .topic(let id) = filters.topic { available.insert(id) } // retain a selected topic after a refresh
        let topicIDs = available.sorted()
        let hasUnknown = rows.contains { $0.topicID == nil || $0.topicID == "" } || filters.topic == .unknown
        return VStack(alignment: .leading, spacing: AppMetrics.space2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space4) { pickers(topicIDs: topicIDs, names: names, hasUnknown: hasUnknown) }
                VStack(alignment: .leading, spacing: AppMetrics.space2) {
                    pickers(topicIDs: topicIDs, names: names, hasUnknown: hasUnknown)
                }
            }
            if case .custom = filters.date {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppMetrics.space4) { customDates }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) { customDates }
                }
            }
            if filters != LearningHistoryFilters(),
               case .success(let groups) = selection(for: rows), !groups.isEmpty {
                Button("Clear filters") { clearFilters() }
                    .accessibilityIdentifier("learning-history-clear-filters-active")
            }
        }
        .accessibilityIdentifier("learning-history-filters")
    }

    @ViewBuilder private func pickers(topicIDs: [String], names: [String: String], hasUnknown: Bool) -> some View {
        Picker("Topic", selection: Binding(get: {
            switch filters.topic {
            case .all: return 0
            case .unknown: return 1
            case .topic(let id): return topicIDs.firstIndex(of: id).map { $0 + 2 } ?? 0
            }
        }, set: { index in
            if index == 0 { filters.topic = .all }
            else if index == 1 { filters.topic = .unknown }
            else if topicIDs.indices.contains(index - 2) { filters.topic = .topic(topicIDs[index - 2]) }
        })) {
            Text("All topics").tag(0)
            if hasUnknown { Text("Unknown topic").tag(1) }
            ForEach(topicIDs.indices, id: \.self) { index in
                Text(names[topicIDs[index]] ?? topicIDs[index]).tag(index + 2)
            }
        }
        .accessibilityIdentifier("learning-history-topic-filter")
        Picker("Status", selection: Binding(get: {
            switch filters.status { case .all: return 0; case .completed: return 1; case .dismissed: return 2 }
        }, set: { filters.status = $0 == 1 ? .completed : $0 == 2 ? .dismissed : .all })) {
            Text("All statuses").tag(0)
            Text("Completed").tag(1)
            Text("Dismissed").tag(2)
        }
        .accessibilityIdentifier("learning-history-status-filter")
        Picker("Date", selection: Binding(get: {
            switch filters.date {
            case .allTime: return 0
            case .today: return 1
            case .lastSevenDays: return 2
            case .custom: return 3
            }
        }, set: { choice in
            switch choice {
            case 1: filters.date = .today
            case 2: filters.date = .lastSevenDays
            case 3:
                if !hasChosenCustom {
                    let today = HistoryLocalDate(Date(), calendar: calendar, timeZone: timeZone)
                    customStart = today
                    customEnd = today
                    hasChosenCustom = true
                }
                filters.date = .custom(start: customStart, end: customEnd)
            default: filters.date = .allTime
            }
        })) {
            Text("All time").tag(0)
            Text("Today").tag(1)
            Text("Last 7 days").tag(2)
            Text("Custom range").tag(3)
        }
        .accessibilityIdentifier("learning-history-date-filter")
    }

    @ViewBuilder private var customDates: some View {
        DatePicker("Start date", selection: startDate, displayedComponents: .date)
            .accessibilityIdentifier("learning-history-start-date")
        DatePicker("End date", selection: endDate, displayedComponents: .date)
            .accessibilityIdentifier("learning-history-end-date")
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func rowsPanel(_ groups: [LearningHistoryDayGroup]) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader("Saved lessons")
            ForEach(groups, id: \.day.start) { group in
                SectionHeader(group.label)
                    .accessibilityIdentifier("learning-history-day-\(Int(group.day.start.timeIntervalSince1970))")
                ForEach(group.rows) { entry in
                    Button {
                        selectedID = entry.lessonID
                        actionError = nil
                        _ = try? store.loadDetail(lessonID: entry.lessonID)
                    } label: {
                        AppListRow(entry.title, metadata: "\(entry.status == .completed ? "Completed" : "Dismissed") · \(entry.topicID.flatMap { $0.isEmpty ? nil : $0 } ?? "Topic unavailable") · \(formattedDate(entry.date))")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("learning-history-row-\(entry.lessonID)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func detailPanel(groups: [LearningHistoryDayGroup]) -> some View {
        if let selectedID, let visible = Self.visibleEntry(selectedID, in: store.historyState, groups: groups) {
            if case .failed(let id, _) = store.detailState, id == selectedID {
                ErrorBanner(.readFailed, recoveryTitle: "Retry lesson read") {
                    _ = try? store.retryDetail(lessonID: id)
                }
                .accessibilityIdentifier("learning-history-detail-error")
                Text("Saved lesson detail unavailable. Retry; no current lesson is substituted.")
                    .appTypography(.body)
            } else if let detail = Self.matchedDetail(visible, state: store.detailState) {
                archivedDetail(visible, detail: detail)
            } else {
                Text("Saved lesson detail unavailable. Select the lesson again to retry its read.")
                    .appTypography(.body)
                    .accessibilityIdentifier("learning-history-detail-unavailable")
                Button("Retry lesson read") { _ = try? store.loadDetail(lessonID: selectedID) }
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
            Text("\(entry.status == .completed ? "Completed" : "Dismissed") · \(formattedDate(entry.date))")
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
