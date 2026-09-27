import SwiftData
import SwiftUI

/// Read-only definition snapshots; opening Learning does not create personal progress.
struct LearningTopicSummary: Identifiable, Equatable {
    struct StarterLesson: Identifiable, Equatable {
        let id: String
        let title: String
        let format: String
        let estimatedMinutes: Int
    }

    let id: String
    let name: String
    let lessons: [StarterLesson]

    @MainActor
    static func load(from container: ModelContainer) throws -> [LearningTopicSummary] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let topics = try context.fetch(FetchDescriptor<Topic>())
        let lessons = try context.fetch(FetchDescriptor<LessonDefinition>())
        // Match the agreed starter topic order; still show imported future topics.
        let order = ["go", "java", "design", "perf", "security"]
        return topics.map { topic in
            LearningTopicSummary(
                id: topic.id, name: topic.name,
                lessons: lessons.filter { $0.topicID == topic.id }
                    .sorted { $0.id < $1.id }
                    .map { StarterLesson(id: $0.id, title: $0.title,
                                         format: $0.format, estimatedMinutes: $0.estimatedMinutes) }
            )
        }.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.id) ?? order.count
            let right = order.firstIndex(of: rhs.id) ?? order.count
            return left == right ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : left < right
        }
    }
}

/// M43: unframed, read-only starter rows in the M00 shell; M15's active choices belong to F05.
struct LearningView: View {
    let container: ModelContainer
    /// A caller-supplied reader permits isolated empty/failure presentation tests.
    /// Production still reads the current offline SwiftData definitions.
    private let load: @MainActor (ModelContainer) throws -> [LearningTopicSummary]
    @State private var topics: [LearningTopicSummary] = []
    @State private var loadFailed = false

    init(container: ModelContainer,
         load: @escaping @MainActor (ModelContainer) throws -> [LearningTopicSummary] = LearningTopicSummary.load) {
        self.container = container
        self.load = load
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Learning")
            if loadFailed {
                ErrorBanner(.readFailed)
                Text("Return to Learning to try again.")
                    .appTypography(.body)
                    .foregroundStyle(AppColors.textSecondary)
            } else if topics.isEmpty {
                EmptyState("No starter topics are installed.", guidance: "Starter content is not available yet.")
            } else {
                // Definitions are not active slots, progress or interactive lessons.
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        SectionHeader(topic.name)
                            .accessibilityIdentifier("learning-topic-\(topic.id)")
                        if topic.lessons.isEmpty {
                            EmptyState("No starter lesson in this topic yet.")
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(topic.lessons) { lesson in
                                    AppListRow(lesson.title,
                                               metadata: "\(lesson.format.capitalized) · \(lesson.estimatedMinutes) min")
                                        .accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("learning-lesson-\(lesson.id)")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        do {
            topics = try load(container)
            loadFailed = false
        } catch {
            topics = []
            loadFailed = true
        }
    }
}
