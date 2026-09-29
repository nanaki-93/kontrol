import SwiftUI

/// Read-only coverage inspection. The shell owns scrolling and the navigation store
/// owns the window-local subtopic selection; neither browsing action opens a lesson.
struct LearningCoverageView: View {
    @ObservedObject var store: LearningCatalogStore
    @ObservedObject var navigation: NavigationStore
    let selectedSubtopicID: String?
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    struct TopicGroup: Identifiable, Equatable {
        let id: String
        let name: String
        let subtopics: [SubtopicCoverageSnapshot]
    }

    static func groups(_ subtopics: [SubtopicCoverageSnapshot]) -> [TopicGroup] {
        Dictionary(grouping: subtopics, by: \.topicID).map { id, rows in
            TopicGroup(id: id, name: rows.first?.topicName ?? id,
                       subtopics: rows.sorted { $0.id < $1.id })
        }.sorted { $0.id < $1.id }
    }

    static func countLabel(_ row: SubtopicCoverageSnapshot, evidence: CoverageEvidenceState) -> String {
        let count = "\(row.practicedConceptCount) of \(row.currentConceptCount) concepts practiced"
        if case .incomplete = evidence { return "\(count) (known evidence only)" }
        return count
    }

    private func recentLabel(_ date: Date?, evidence: CoverageEvidenceState) -> String {
        guard let date else {
            if case .incomplete = evidence { return "No known recorded practice" }
            return "No recorded practice"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Most recent practice · \(formatter.string(from: date))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Button(selectedSubtopicID == nil ? "Back to choices" : "Back to Coverage") {
                if selectedSubtopicID == nil { navigation.backToChoices() }
                else { navigation.selectCoverageSubtopic(nil) }
            }
            .focusable()
            .accessibilityIdentifier("learning-coverage-back")
            PageHeader("Coverage")
            switch store.coverageState {
            case .notLoaded:
                LoadingState("Loading Coverage")
            case .failed(let stale):
                ErrorBanner(.readFailed, recoveryTitle: "Retry Coverage read") {
                    _ = try? store.retryCoverage()
                }
                .accessibilityIdentifier("learning-coverage-read-error")
                Text(stale == nil ? "Coverage unavailable. Retry to load current concepts." :
                     "Coverage unavailable. Previously loaded counts may be out of date; retry before inspecting concepts.")
                    .appTypography(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("learning-coverage-unavailable")
            case .current(.membershipUnavailable):
                EmptyState("Current catalog membership unavailable",
                           guidance: "Coverage cannot be calculated without a validated current catalog. No zero counts are inferred.")
                    .accessibilityIdentifier("learning-coverage-membership-unavailable")
            case .current(.available(_, _, let subtopics, let evidence)):
                if case .incomplete(let ids) = evidence {
                    Text("Some older completions lack trustworthy concept evidence (\(ids.count)). Counts below reflect known practice only, not all practice.")
                        .appTypography(.body)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("learning-coverage-incomplete")
                }
                if let selectedSubtopicID {
                    if let row = subtopics.first(where: { $0.id == selectedSubtopicID }) {
                        SectionHeader("\(row.topicName) · \(row.name)")
                        subtopicCard(row, evidence: evidence, selected: true)
                    } else {
                        EmptyState("Subtopic no longer in the current catalog",
                                   guidance: "Return to Coverage to see current subtopics.")
                            .accessibilityIdentifier("learning-coverage-missing-subtopic")
                    }
                } else if subtopics.isEmpty {
                    EmptyState("No current subtopics", guidance: "Coverage will appear when the installed catalog includes subtopics.")
                        .accessibilityIdentifier("learning-coverage-empty")
                } else {
                    ForEach(Self.groups(subtopics)) { group in
                        SectionHeader(group.name)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: AppMetrics.space4)],
                                  alignment: .leading, spacing: AppMetrics.space4) {
                            ForEach(group.subtopics) { row in
                                subtopicCard(row, evidence: evidence, selected: false)
                            }
                        }
                        .accessibilityIdentifier("learning-coverage-topic-\(group.id)")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.horizontalInset)
        .onAppear {
            // No catalog reconciliation, slot assignment, attempt, or progress write.
            if case .notLoaded = store.coverageState { _ = try? store.loadCoverage() }
        }
    }

    private func subtopicCard(_ row: SubtopicCoverageSnapshot, evidence: CoverageEvidenceState,
                              selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader(row.name)
            Text(Self.countLabel(row, evidence: evidence))
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("learning-coverage-count-\(row.id)")
            if row.currentConceptCount == 0 {
                Text("No current concepts in this subtopic.")
                    .appTypography(.metadata)
                    .accessibilityIdentifier("learning-coverage-zero-\(row.id)")
            }
            Text(recentLabel(row.latestCompletion, evidence: evidence))
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("learning-coverage-recent-\(row.id)")
            if !selected {
                Button("View concepts in \(row.name)") { navigation.selectCoverageSubtopic(row.id) }
                    .focusable()
                    .accessibilityIdentifier("learning-coverage-view-concepts-\(row.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.space4)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
        .accessibilityIdentifier("learning-coverage-subtopic-\(row.id)")
    }
}
