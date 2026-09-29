import SwiftUI

/// Window-local topic selection over the app-owned, committed catalog projection.
/// Reading or switching topics never reconciles slots or creates personal records.
struct LearningView: View {
    @ObservedObject var store: LearningCatalogStore
    /// Supplied by the shell for guarded entry. Standalone previews browse only.
    var navigation: NavigationStore? = nil
    @State private var selectedTopicID: String?
    @State private var entryError: LessonExperienceError?
    @State private var dismissal: DismissalConfirmation?
    @State private var showingDismissal = false
    @State private var showingGenerationNotice = false
    @State private var generationChoiceCount = 0
    @FocusState private var focusedTopicID: String?
    @FocusState private var focusedLessonID: String?
    @FocusState private var focusedDismissLessonID: String?

    private static let topicOrder = ["go", "java", "design", "perf", "security"]

    /// Keep the entire assignment captured when confirmation opens, including assignedAt.
    struct DismissalConfirmation {
        let lessonID: String
        let title: String
        let slot: LessonSlotSnapshot
        let attemptID: UUID?
    }

    static func dismissal(for lessonID: String, in snapshot: LearningCatalogSnapshot,
                          attemptID: UUID? = nil) -> DismissalConfirmation? {
        guard let slot = snapshot.slots.first(where: { $0.lessonID == lessonID }),
              let lesson = snapshot.definitions.first(where: { $0.id == lessonID }) else { return nil }
        return DismissalConfirmation(lessonID: lessonID, title: lesson.title,
                                     slot: slot, attemptID: attemptID)
    }

    static func generationNotice(choiceCount: Int) -> String {
        let availability = choiceCount == 0 ? "No eligible lessons are installed" :
            "No additional eligible lessons are installed"
        return "\(availability) for this topic. Generate… is unavailable offline in this version. Try History or another topic."
    }

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

    static func restoredUnslotted(for topicID: String, in snapshot: LearningCatalogSnapshot) -> [LessonProgressSnapshot] {
        snapshot.progress.filter { progress in
            progress.status == .started && progress.dismissedAt != nil &&
            !snapshot.slots.contains(where: { $0.lessonID == progress.lessonID }) &&
            snapshot.definitions.contains(where: { $0.id == progress.lessonID && $0.topicID == topicID })
        }.sorted { $0.lessonID < $1.lessonID }
    }

    /// Resolve a slot identity from committed choices (never from a stale index).
    /// Retained for non-UI catalog projections; the choices UI does not disclose content.
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
            if let navigation {
                HStack(spacing: AppMetrics.space4) {
                    Button("History") { navigation.showHistory() }
                        .accessibilityIdentifier("learning-history")
                    Button("Coverage") { navigation.showCoverage() }
                        .accessibilityIdentifier("learning-coverage")
                }
            }
            if entryError != nil {
                ErrorBanner(.saveFailed)
                Text("Lesson action failed. Your choice and any unfinished work are retained; check the assignment and retry.")
                    .appTypography(.body)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if case .failed(let lessonID, _) = store.detailState {
                ErrorBanner(.readFailed, recoveryTitle: "Retry lesson read") {
                    _ = try? store.retryDetail(lessonID: lessonID)
                }
            }
            if case .failed = store.historyState {
                ErrorBanner(.readFailed, recoveryTitle: "Retry History read") {
                    _ = try? store.retryHistory()
                }
            }
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
                               guidance: "There are no lessons to open.")
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
        .onAppear {
            store.loadIfNeeded()
            // Practice returns here after a confirmed dismissal. Its action button no
            // longer exists, so restore keyboard focus to the topic in the choices view.
            if let snapshot = store.state.snapshot {
                let topics = Self.orderedTopics(in: snapshot)
                if let topic = topics.first(where: { $0.id == (navigation?.selectedTopicID ?? selectedTopicID) })
                    ?? topics.first {
                    DispatchQueue.main.async { focusedTopicID = topic.id }
                }
            }
        }
        .confirmationDialog("Show another instead of \(dismissal?.title ?? "this lesson")?",
                            isPresented: $showingDismissal, titleVisibility: .visible) {
            Button("Show another", role: .destructive) {
                if let dismissal { dismiss(dismissal) }
            }
            Button("Keep lesson", role: .cancel) {}
        } message: {
            Text("Dismiss this assignment from the choices? Unfinished work stays in History. This does not complete the lesson.")
        }
        .onChange(of: showingDismissal) { _, visible in
            if !visible, let captured = dismissal {
                dismissal = nil
                DispatchQueue.main.async {
                    if store.state.snapshot?.slots.contains(where: { $0 == captured.slot }) == true {
                        focusedDismissLessonID = captured.lessonID
                    } else {
                        focusedTopicID = captured.slot.topicID
                    }
                }
            }
        }
        .alert("Generation unavailable", isPresented: $showingGenerationNotice) {
            if let navigation {
                Button("History") { navigation.showHistory() }
            }
            Button("Another topic") { selectAnotherTopic() }
            Button("Stay here", role: .cancel) {}
        } message: {
            Text(Self.generationNotice(choiceCount: generationChoiceCount))
        }
    }

    @ViewBuilder private func catalog(_ snapshot: LearningCatalogSnapshot, compact: Bool) -> some View {
        let topics = Self.orderedTopics(in: snapshot)
        let selected = topics.first { $0.id == (navigation?.selectedTopicID ?? selectedTopicID) } ?? topics[0]
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
                        if let navigation {
                            guard navigation.flushForLifecycle() else { return }
                            navigation.selectTopic(topic.id)
                            guard navigation.selectedTopicID == topic.id else { return }
                        } else {
                            selectedTopicID = topic.id
                        }
                        entryError = nil
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
                if choices.count < 4 {
                    Text("\(4 - choices.count) vacant \(4 - choices.count == 1 ? "choice" : "choices") · no eligible lesson is repeated")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .accessibilityIdentifier("learning-vacancy")
                }
                if choices.isEmpty {
                    EmptyState("No choices available in \(selected.name).",
                               guidance: "There are no eligible lessons to open right now. Try another topic.")
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
                            if let navigation {
                                let started = snapshot.progress.contains { $0.lessonID == lesson.id && $0.status == .started }
                                Button("\(started ? "Resume" : "Open") \(lesson.title)") {
                                    open(lesson.id, using: navigation)
                                }
                                .frame(minHeight: AppMetrics.preferredTarget)
                                .focusable()
                                .focused($focusedLessonID, equals: lesson.id)
                                .accessibilityIdentifier("learning-open-\(lesson.id)")
                                Button("Show another instead of \(lesson.title)") {
                                    guard store.state.isAuthoritative,
                                          let current = store.state.snapshot,
                                          let captured = Self.dismissal(for: lesson.id, in: current) else {
                                        entryError = .staleSlot
                                        return
                                    }
                                    dismissal = captured
                                    showingDismissal = true
                                }
                                .focusable()
                                .focused($focusedDismissLessonID, equals: lesson.id)
                                .accessibilityIdentifier("learning-dismiss-\(lesson.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppMetrics.space4)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
                    }
                }
                // Restored work can be started but unslotted when all four assignments
                // remain valid. Keep it reachable without counting it as a fifth choice.
                let unslotted = Self.restoredUnslotted(for: selected.id, in: snapshot)
                if !unslotted.isEmpty, let navigation {
                    SectionHeader("Restored work")
                    ForEach(unslotted) { progress in
                        let title = snapshot.definitions.first { $0.id == progress.lessonID }?.title ?? progress.lessonID
                        Button("Resume \(title)") { open(progress.lessonID, using: navigation) }
                            .accessibilityIdentifier("learning-restored-resume-\(progress.lessonID)")
                    }
                }
                if choices.count < 4 {
                    Button("Generate…") {
                        generationChoiceCount = choices.count
                        showingGenerationNotice = true
                    }
                        .accessibilityIdentifier("learning-generate-unavailable")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dismiss(_ captured: DismissalConfirmation) {
        do {
            _ = try navigationDismiss(captured)
            entryError = nil
        } catch {
            entryError = (error as? LessonExperienceError) ?? .persistenceFailure
        }
    }

    private func navigationDismiss(_ captured: DismissalConfirmation) throws -> LessonMutationResult {
        // No new slot lookup here: the repository rejects a replaced occupant or timestamp.
        // Flush all app-owned buffers before this transition, including a second window's edits.
        guard let navigation else { throw LessonExperienceError.invalidTransition }
        guard navigation.flushForLifecycle() else { throw navigation.saveError ?? .persistenceFailure }
        return try store.dismiss(lessonID: captured.lessonID, expectedSlot: captured.slot)
    }

    private func selectAnotherTopic() {
        guard let snapshot = store.state.snapshot else { return }
        let topics = Self.orderedTopics(in: snapshot)
        guard topics.count > 1 else { return }
        let current = navigation?.selectedTopicID ?? selectedTopicID ?? topics[0].id
        let index = topics.firstIndex(where: { $0.id == current }) ?? 0
        let next = topics[(index + 1) % topics.count].id
        if let navigation { navigation.selectTopic(next) } else { selectedTopicID = next }
    }

    private func open(_ id: String, using navigation: NavigationStore) {
        // Recheck the current committed slot before mutating a choice rendered earlier.
        guard let snapshot = store.state.snapshot, store.state.isAuthoritative,
              (snapshot.slots.contains(where: { $0.lessonID == id }) ||
               snapshot.progress.contains(where: { $0.lessonID == id && $0.status == .started && $0.dismissedAt != nil })) else {
            entryError = .staleSlot
            return
        }
        // A failed draft barrier must not create an attempt or move the route.
        guard navigation.flushForLifecycle() else { return }
        do {
            let receipt = try store.openLesson(lessonID: id)
            guard receipt.detail.id == id else { throw LessonExperienceError.invalidStoredData }
            entryError = nil
            navigation.enterLesson(id: id)
        } catch {
            entryError = (error as? LessonExperienceError) ?? .persistenceFailure
        }
    }
}
