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
    @State private var topics: [LearningTopicSummary] = []
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FoundationStyle.heading("Learning")
            Text("Included starter content · available offline")
                .foregroundStyle(FoundationStyle.secondary)
            if loadFailed {
                Text("Could not load starter content. Return to Learning to try again.")
                    .foregroundStyle(FoundationStyle.secondary)
            } else if topics.isEmpty {
                Text("No starter topics are installed.")
                    .foregroundStyle(FoundationStyle.secondary)
            } else {
                // Definitions are not active slots, progress or interactive lessons.
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        FoundationStyle.section(topic.name)
                            .accessibilityIdentifier("learning-topic-\(topic.id)")
                        if topic.lessons.isEmpty {
                            Text("No starter lesson in this topic yet.")
                                .foregroundStyle(FoundationStyle.secondary)
                        } else {
                            ForEach(topic.lessons) { lesson in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(lesson.title)
                                        .foregroundStyle(FoundationStyle.primary)
                                    Spacer(minLength: 0)
                                    Text("\(lesson.format.capitalized) · \(lesson.estimatedMinutes) min")
                                        .foregroundStyle(FoundationStyle.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("learning-lesson-\(lesson.id)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().overlay(FoundationStyle.border)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 15, design: .monospaced))
        .padding(.horizontal, FoundationStyle.horizontalInset)
        .padding(.top, 32)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        do {
            topics = try LearningTopicSummary.load(from: container)
            loadFailed = false
        } catch {
            topics = []
            loadFailed = true
        }
    }
}
