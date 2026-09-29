import SwiftUI

/// Read-only coverage inspection. The shell owns scrolling and the navigation store
/// owns the window-local subtopic selection; neither browsing action opens a lesson.
struct LearningCoverageView: View {
    @ObservedObject var store: LearningCatalogStore
    @ObservedObject var navigation: NavigationStore
    let selectedSubtopicID: String?
    @State private var expandedConceptID: String?
    @State private var entryError: LessonExperienceError?
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
                        conceptList(row, evidence: evidence)
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
            // These are independent read-only projections. Never infer empty
            // references from a failed History read.
            if case .notLoaded = store.coverageState { _ = try? store.loadCoverage() }
            if case .notLoaded = store.historyState { _ = try? store.loadHistory() }
        }
        .onChange(of: selectedSubtopicID) { _, _ in
            expandedConceptID = nil
            entryError = nil
        }
    }

    @ViewBuilder private func conceptList(_ row: SubtopicCoverageSnapshot,
                                          evidence: CoverageEvidenceState) -> some View {
        if row.concepts.isEmpty {
            EmptyState("No current concepts", guidance: "There are no concepts to inspect in this subtopic.")
                .accessibilityIdentifier("learning-coverage-no-concepts")
        } else {
            SectionHeader("Concepts")
            if let entryError {
                Text("Lesson could not be opened (\(String(describing: entryError))). Your choices and unfinished work are retained. Retry from the current list.")
                    .appTypography(.body)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("learning-coverage-entry-error")
            }
            ForEach(row.concepts) { concept in
                VStack(alignment: .leading, spacing: AppMetrics.space2) {
                    SectionHeader(concept.name)
                    Text(concept.latestCompletion == nil ?
                         (evidence == .complete ? "Not yet practiced" : "No known recorded practice") : "Practiced")
                        .appTypography(.body)
                        .accessibilityIdentifier("learning-coverage-practice-\(concept.id)")
                    if concept.latestCompletion != nil {
                        Text(recentLabel(concept.latestCompletion, evidence: .complete))
                            .appTypography(.metadata)
                            .accessibilityIdentifier("learning-coverage-concept-recent-\(concept.id)")
                    }
                    Button("View lessons for \(concept.name)") {
                        expandedConceptID = expandedConceptID == concept.id ? nil : concept.id
                        entryError = nil
                    }
                    .focusable()
                    .accessibilityIdentifier("learning-coverage-view-lessons-\(concept.id)")
                    if expandedConceptID == concept.id {
                        conceptLessons(concept, in: row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppMetrics.space4)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
                .accessibilityIdentifier("learning-coverage-concept-\(concept.id)")
            }
        }
    }

    @ViewBuilder private func conceptLessons(_ concept: ConceptCoverageSnapshot,
                                              in row: SubtopicCoverageSnapshot) -> some View {
        if case .failed = store.historyState {
            ErrorBanner(.readFailed, recoveryTitle: "Retry History read") {
                _ = try? store.retryHistory()
            }
            Text("Saved lesson references and eligibility are unavailable until History can be read.")
                .appTypography(.body)
        } else if case .current(let history) = store.historyState,
                  let snapshot = store.state.isAuthoritative ? store.state.snapshot : nil,
                  case .current(.available(_, _, let subtopics, _)) = store.coverageState,
                  subtopics.contains(where: { $0.id == row.id && $0.concepts.contains(concept) }) {
            let choices = LearningCoverage.lessons(for: concept.id, in: snapshot, history: history)
            SectionHeader("Available lessons")
            if choices.isEmpty {
                EmptyState("No eligible lessons for this concept",
                           guidance: "No current choice or restored work is available. Browsing will not restore dismissed lessons or repeat completed content.")
                    .accessibilityIdentifier("learning-coverage-no-eligible-\(concept.id)")
            } else {
                ForEach(choices) { choice in
                    Button("\(choice.started ? "Resume" : "Open") \(choice.title)") {
                        open(choice, conceptID: concept.id, subtopicID: row.id)
                    }
                    .focusable()
                    .accessibilityIdentifier("learning-coverage-open-\(choice.lessonID)")
                }
            }
            let references = LearningCoverage.completedReferences(for: concept.id, in: history)
            if !references.isEmpty {
                SectionHeader("Completed references")
                ForEach(references) { entry in
                    Button("Read completed \(entry.title) in History") {
                        // Match the archived ID again; History validates the row and
                        // detail before displaying saved content or an answer.
                        guard case .current(let current) = store.historyState,
                              LearningCoverage.completedReferences(for: concept.id, in: current).contains(entry)
                        else { return }
                        navigation.showCompletedReference(id: entry.lessonID)
                    }
                    .focusable()
                    .accessibilityIdentifier("learning-coverage-reference-\(entry.lessonID)")
                }
            }
        } else {
            Text("Current choices or coverage unavailable. Retry the failed read before viewing lessons.")
                .appTypography(.body)
                .accessibilityIdentifier("learning-coverage-lessons-unavailable")
        }
    }

    private func open(_ captured: ConceptLessonChoice, conceptID: String, subtopicID: String) {
        func currentChoice() -> Bool {
            guard store.state.isAuthoritative, case .current(let history) = store.historyState,
                  case .current(.available(_, _, let rows, _)) = store.coverageState,
                  rows.contains(where: { $0.id == subtopicID && $0.concepts.contains(where: { $0.id == conceptID }) }),
                  let snapshot = store.state.snapshot else { return false }
            return LearningCoverage.lessons(for: conceptID, in: snapshot, history: history).contains(captured)
        }
        guard currentChoice() else { entryError = .staleSlot; return }
        guard navigation.flushForLifecycle() else { entryError = navigation.saveError; return }
        guard currentChoice() else { entryError = .staleSlot; return }
        do {
            let receipt = try store.openConceptLesson(lessonID: captured.lessonID, expectedSlot: captured.slot,
                                                      expectedConceptID: conceptID)
            guard receipt.detail.id == captured.lessonID,
                  receipt.detail.progress?.status == .started,
                  receipt.detail.attempt?.lessonID == captured.lessonID else {
                throw LessonExperienceError.invalidStoredData
            }
            entryError = nil
            navigation.enterLesson(id: captured.lessonID)
        } catch {
            entryError = (error as? LessonExperienceError) ?? .persistenceFailure
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
