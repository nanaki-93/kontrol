import SwiftUI

/// Window-local topic selection over the app-owned, committed catalog projection.
/// Reading or switching topics never reconciles slots or creates personal records.
struct LearningView: View {
    @ObservedObject var store: LearningCatalogStore
    @State private var selectedTopicID: String?
    @State private var inspectedLessonID: String?
    @FocusState private var focusedTopicID: String?
    @FocusState private var focusedLessonID: String?

    private static let topicOrder = ["go", "java", "design", "perf", "security"]

    static func orderedTopics(in snapshot: LearningCatalogSnapshot) -> [LearningTopicSnapshot] {
        snapshot.topics.sorted { lhs, rhs in
            let left = topicOrder.firstIndex(of: lhs.id) ?? topicOrder.count
            let right = topicOrder.firstIndex(of: rhs.id) ?? topicOrder.count
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    static func choices(for topicID: String, in snapshot: LearningCatalogSnapshot) -> [LessonDefinitionSnapshot] {
        let definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) })
        return snapshot.slots.filter { $0.topicID == topicID }
            .sorted { $0.slotIndex < $1.slotIndex }
            .compactMap { definitions[$0.lessonID] }
    }

    /// Resolve inspection only through a committed slot in the currently selected topic.
    /// A stale selection cannot expose an unslotted or replaced definition.
    static func inspectedLesson(_ id: String?, for topicID: String,
                                in snapshot: LearningCatalogSnapshot) -> LessonDefinitionSnapshot? {
        choices(for: topicID, in: snapshot).first { $0.id == id }
    }

    private func conceptLabels(for lesson: LessonDefinitionSnapshot, in snapshot: LearningCatalogSnapshot) -> String {
        let concepts = Dictionary(uniqueKeysWithValues: snapshot.concepts.map { ($0.id, $0.name) })
        return lesson.conceptIDs.map { concepts[$0] ?? $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Learning")
            switch store.state {
            case .notLoaded, .loading:
                LoadingState("Loading learning choices")
            case .failed(let stale):
                ErrorBanner(.readFailed, recoveryTitle: "Retry learning choices", recovery: store.retry)
                Text(stale == nil ? "Learning choices could not be loaded." :
                     "Previously loaded choices are unavailable until the read succeeds.")
                    .appTypography(.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .empty(let snapshot), .current(let snapshot):
                if Self.orderedTopics(in: snapshot).isEmpty {
                    EmptyState("No learning topics are installed.",
                               guidance: "There are no choices to inspect.")
                } else {
                    // The shell owns vertical scrolling. ViewThatFits sees its finite width
                    // without requesting an unbounded-height GeometryReader inside it.
                    ViewThatFits(in: .horizontal) {
                        catalog(snapshot, compact: false)
                            .frame(minWidth: 720)
                        catalog(snapshot, compact: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear { store.loadIfNeeded() }
    }

    @ViewBuilder private func catalog(_ snapshot: LearningCatalogSnapshot, compact: Bool) -> some View {
        let topics = Self.orderedTopics(in: snapshot)
        let selected = topics.first { $0.id == selectedTopicID } ?? topics[0]
        if compact {
            VStack(alignment: .leading, spacing: AppMetrics.space4) {
                topicList(topics, selected: selected, compact: true)
                lessonList(selected, snapshot: snapshot)
            }
        } else {
            HStack(alignment: .top, spacing: AppMetrics.space6) {
                topicList(topics, selected: selected, compact: false)
                    .frame(width: 190, alignment: .leading)
                lessonList(selected, snapshot: snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func topicList(_ topics: [LearningTopicSnapshot], selected: LearningTopicSnapshot,
                           compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader("Topics")
            LazyVGrid(columns: compact ? [GridItem(.adaptive(minimum: 150), spacing: AppMetrics.space2)] :
                        [GridItem(.flexible())], alignment: .leading, spacing: AppMetrics.space2) {
                ForEach(topics) { topic in
                    let isSelected = selected.id == topic.id
                    Button {
                        selectedTopicID = topic.id
                        inspectedLessonID = nil
                    } label: {
                        Text(topic.name)
                            .appTypography(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: AppMetrics.preferredTarget, alignment: .leading)
                            .foregroundStyle(isSelected ? AppColors.accent : AppColors.textPrimary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedTopicID, equals: topic.id)
                    .overlay {
                        if focusedTopicID == topic.id {
                            RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                                .strokeBorder(AppColors.focusRing, lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(topic.name)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("learning-topic-\(topic.id)")
                }
            }
        }
    }

    private func lessonList(_ selected: LearningTopicSnapshot, snapshot: LearningCatalogSnapshot) -> some View {
        let choices = Self.choices(for: selected.id, in: snapshot)
        return VStack(alignment: .leading, spacing: AppMetrics.space4) {
                SectionHeader(selected.name, metadata: "\(choices.count) available")
                if choices.isEmpty {
                    EmptyState("No choices available in \(selected.name).",
                               guidance: "There are no eligible choices to inspect right now. Try another topic.")
                } else {
                    ForEach(choices) { lesson in
                        VStack(alignment: .leading, spacing: AppMetrics.space2) {
                            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                                AppListRow(lesson.title,
                                           metadata: "\(lesson.format.capitalized) · \(lesson.difficulty.capitalized) · \(lesson.estimatedMinutes) min")
                                Text(lesson.displayObjective)
                                    .appTypography(.body)
                                    .foregroundStyle(AppColors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(conceptLabels(for: lesson, in: snapshot))
                                    .appTypography(.metadata)
                                    .foregroundStyle(AppColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("learning-lesson-\(lesson.id)")
                            DisclosureGroup(isExpanded: Binding(
                                get: { Self.inspectedLesson(inspectedLessonID, for: selected.id, in: snapshot)?.id == lesson.id },
                                set: { inspectedLessonID = $0 ? lesson.id : nil }
                            )) {
                                inspection(lesson)
                            } label: {
                                Text("Inspect \(lesson.title) · Read-only reference")
                                    .appTypography(.body)
                                    .frame(maxWidth: .infinity, minHeight: AppMetrics.preferredTarget, alignment: .leading)
                            }
                            .focusable()
                            .focused($focusedLessonID, equals: lesson.id)
                            .overlay {
                                if focusedLessonID == lesson.id {
                                    RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                                        .strokeBorder(AppColors.focusRing, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Inspect \(lesson.title), read-only reference")
                            .accessibilityIdentifier("learning-inspect-\(lesson.id)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppMetrics.space4)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspection(_ lesson: LessonDefinitionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text("Read-only reference · No responses are saved here.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            section("Explanation", text: lesson.explanation)
            section("Worked example", text: lesson.workedExample)
            section("Exercise prompt (for reading)", text: lesson.exercise)
            section("Reference material · Example response", text: lesson.referenceAnswer)
            section("Reference material · Self-check criteria",
                    text: lesson.selfCheckCriteria.map { "• \($0)" }.joined(separator: "\n"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            Text(heading)
                .appTypography(.body)
                .foregroundStyle(AppColors.textPrimary)
            // Verbatim text: authored content is data, never HTML, Markdown, or executable code.
            Text(verbatim: text)
                .appTypography(.body)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
