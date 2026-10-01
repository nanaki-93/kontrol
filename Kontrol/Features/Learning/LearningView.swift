import SwiftUI

/// Window-local topic selection over the app-owned, committed catalog projection.
/// Reading or switching topics never reconciles slots or creates personal records.
struct LearningView: View {
    @ObservedObject var store: LearningCatalogStore
    /// Supplied by the shell for guarded entry. Standalone previews browse only.
    var navigation: NavigationStore? = nil
    var generation: LessonGenerationStore? = nil
    var aiSettings: AISettingsStore? = nil
    var generationRepository: (any CatalogRepository)? = nil
    @State private var selectedTopicID: String?
    @State private var previewSelection = LearningPreviewSelection()
    @State private var entryError: LessonExperienceError?
    @State private var dismissal: DismissalConfirmation?
    @State private var showingDismissal = false
    @State private var generationTopicID: String?
    @State private var moreLessonsExpanded = false
    @State private var optionsLessonID: String?
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.appTextScaleOverride) private var textScaleOverride
    @Environment(\.appAccessibilityPreferences) private var accessibilityPreferences
    @FocusState private var focusedTopicID: String?
    @FocusState private var focusedLessonID: String?
    @FocusState private var focusedDismissLessonID: String?

    private static let topicOrder = ["go", "java", "design", "perf", "security"]

    /// The accepted topic and committed slots, not a row index, supply preview identity.
    struct LearningPreviewSelection: Equatable {
        var topicID: String? = nil
        var lessonID: String? = nil

        func resolved(for topicID: String, choices: [LessonDefinitionSnapshot]) -> Self {
            let retained = self.topicID == topicID && choices.contains { $0.id == lessonID }
            return Self(topicID: topicID, lessonID: retained ? lessonID : choices.first?.id)
        }

        func selecting(_ id: String, from projection: PreviewProjection) -> Self {
            guard projection.choices.contains(where: { $0.id == id }),
                  projection.selection.topicID == topicID else { return self }
            return Self(topicID: topicID, lessonID: id)
        }
    }

    struct PreviewProjection {
        let selection: LearningPreviewSelection
        let choices: [LessonDefinitionSnapshot]
        let lesson: LessonDefinitionSnapshot?

        var actionLessonID: String? { lesson?.id }
    }

    static func preview(for acceptedTopicID: String?, selection: LearningPreviewSelection,
                        state: LearningCatalogReadState) -> PreviewProjection? {
        guard state.isAuthoritative, let snapshot = state.snapshot,
              let topic = topicProjection(for: acceptedTopicID, in: snapshot)?.selected else { return nil }
        let choices = choices(for: topic.id, in: snapshot)
        let resolved = selection.resolved(for: topic.id, choices: choices)
        return PreviewProjection(selection: resolved, choices: choices,
                                 lesson: choices.first { $0.id == resolved.lessonID })
    }

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

    static func orderedTopics(in snapshot: LearningCatalogSnapshot) -> [LearningTopicSnapshot] {
        snapshot.topics.sorted { lhs, rhs in
            let left = topicOrder.firstIndex(of: lhs.id) ?? topicOrder.count
            let right = topicOrder.firstIndex(of: rhs.id) ?? topicOrder.count
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    /// A read-only projection of ordered topics and the current (or fallback) topic.
    /// An empty catalog has no selection; resolving never persists a fallback ID.
    static func topicProjection(for selectedID: String?, in snapshot: LearningCatalogSnapshot)
        -> (topics: [LearningTopicSnapshot], selected: LearningTopicSnapshot)? {
        let topics = orderedTopics(in: snapshot)
        guard let selected = topics.first(where: { $0.id == selectedID }) ?? topics.first else { return nil }
        return (topics, selected)
    }

    static func choices(for topicID: String, in snapshot: LearningCatalogSnapshot) -> [LessonDefinitionSnapshot] {
        let definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) })
        return snapshot.slots.filter { $0.topicID == topicID }
            .sorted { $0.slotIndex < $1.slotIndex }
            .compactMap { definitions[$0.lessonID] }
    }

    static func restoredUnslotted(for topicID: String, in snapshot: LearningCatalogSnapshot) -> [LessonProgressSnapshot] {
        snapshot.progress.filter { progress in
            progress.status == .started &&
            !snapshot.slots.contains(where: { $0.lessonID == progress.lessonID }) &&
            snapshot.definitions.contains(where: { $0.id == progress.lessonID && $0.topicID == topicID &&
                (progress.dismissedAt != nil || $0.source == "generated") })
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
                    catalogContent(snapshot)
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
                    let selectedID = navigation?.selectedTopicID ?? selectedTopicID
                    let current = Self.preview(for: selectedID, selection: previewSelection, state: store.state)
                    if current?.actionLessonID == captured.lessonID && optionsLessonID == captured.lessonID {
                        focusedDismissLessonID = captured.lessonID
                    } else if let currentID = current?.selection.lessonID {
                        focusedLessonID = currentID
                    } else {
                        focusedTopicID = current?.selection.topicID ?? captured.slot.topicID
                    }
                }
            }
        }
        .sheet(item: Binding(get: { generationTopicID.map(GenerationTopic.init) },
                             set: { generationTopicID = $0?.id })) { topic in
            if let generation, let aiSettings, let generationRepository {
                LessonGenerationSheet(topicID: topic.id, repository: generationRepository,
                                      learning: store, settings: aiSettings, generation: generation,
                                      navigation: navigation)
            } else {
                Text("Generation is not configured in this preview.")
                    .padding(AppMetrics.space6)
            }
        }
    }

    @ViewBuilder private func catalogContent(_ snapshot: LearningCatalogSnapshot) -> some View {
        if let navigation {
            // Observe the accepted topic outside the adaptive list/preview so
            // both layout candidates share the same preview identity.
            RoutedLearningCatalog(navigation: navigation) { selectedID in
                responsiveCatalog(snapshot, selectedID: selectedID)
            }
        } else {
            responsiveCatalog(snapshot, selectedID: selectedTopicID)
        }
    }

    private func responsiveCatalog(_ snapshot: LearningCatalogSnapshot, selectedID: String?) -> some View {
        catalog(snapshot, selectedID: selectedID)
        // Recreate the selected layout when the topic changes rather than reusing
        // a measured candidate with the prior topic's lesson rows.
        .id(selectedID)
        .onAppear {
            if let resolved = Self.preview(for: selectedID, selection: previewSelection,
                                           state: store.state)?.selection {
                previewSelection = resolved
                if let focused = focusedLessonID ?? focusedDismissLessonID,
                   focused != resolved.lessonID {
                    DispatchQueue.main.async {
                        let acceptedID = navigation?.selectedTopicID ?? selectedTopicID
                        if let current = Self.preview(for: acceptedID, selection: previewSelection,
                                                      state: store.state), let id = current.selection.lessonID {
                            focusedLessonID = id
                        } else {
                            focusedTopicID = acceptedID ?? resolved.topicID
                        }
                    }
                }
            }
        }
        // Observe outside the topic-keyed layout: a reconstructed candidate cannot
        // deliver its first onChange. Retain the last identity through failed reads.
        .onChange(of: Self.preview(for: selectedID, selection: previewSelection,
                                   state: store.state)?.selection) { previous, resolved in
            guard let resolved else { return }
            previewSelection = resolved
            if optionsLessonID != resolved.lessonID { optionsLessonID = nil }
            if !showingDismissal && previous?.lessonID != resolved.lessonID &&
                (focusedLessonID == previous?.lessonID || focusedDismissLessonID == previous?.lessonID) {
                // The removed row/option no longer accepts focus. Return to a
                // surviving choice, or to the topic when its choices are empty.
                DispatchQueue.main.async {
                    let acceptedID = navigation?.selectedTopicID ?? selectedTopicID
                    if let current = Self.preview(for: acceptedID, selection: previewSelection, state: store.state),
                       let id = current.selection.lessonID {
                        focusedLessonID = id
                    } else {
                        focusedTopicID = acceptedID ?? resolved.topicID
                    }
                }
            }
        }
    }

    @ViewBuilder private func catalog(_ snapshot: LearningCatalogSnapshot, selectedID: String?) -> some View {
        if let projection = Self.topicProjection(for: selectedID, in: snapshot),
           let preview = Self.preview(for: selectedID, selection: previewSelection, state: store.state) {
            catalog(projection.topics, selected: projection.selected, snapshot: snapshot,
                    preview: preview)
        }
    }

    @ViewBuilder private func catalog(_ topics: [LearningTopicSnapshot], selected: LearningTopicSnapshot,
                                      snapshot: LearningCatalogSnapshot, preview: PreviewProjection) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            // Topics remain distinct without consuming a permanent third column.
            topicList(topics, selected: selected)
            lessonList(selected, snapshot: snapshot, preview: preview)
        }
    }

    private func topicList(_ topics: [LearningTopicSnapshot], selected: LearningTopicSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader("Topics")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppMetrics.space2)],
                      alignment: .leading, spacing: AppMetrics.space2) {
                ForEach(topics) { topic in
                    let isSelected = selected.id == topic.id
                    Button {
                        if let navigation {
                            navigation.selectTopic(topic.id)
                            guard navigation.selectedTopicID == topic.id,
                                  navigation.learningRoute == .choices,
                                  navigation.pendingTransition == nil,
                                  navigation.saveError == nil else { return }
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

    private func lessonList(_ selected: LearningTopicSnapshot, snapshot: LearningCatalogSnapshot,
                            preview: PreviewProjection) -> some View {
        let choices = preview.choices
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppMetrics.space6) {
                        choiceRows(choices, snapshot: snapshot, selectedID: preview.selection.lessonID)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let lesson = preview.lesson {
                            lessonPreview(lesson, topicID: selected.id, snapshot: snapshot)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // Require room for two readable panes at the effective text size.
                    .frame(minWidth: 820 * AppTypography.scale(
                        for: accessibilityPreferences?.textSize ?? systemTextSize,
                        override: textScaleOverride))
                    VStack(alignment: .leading, spacing: AppMetrics.space4) {
                        choiceRows(choices, snapshot: snapshot, selectedID: preview.selection.lessonID)
                        if let lesson = preview.lesson {
                            lessonPreview(lesson, topicID: selected.id, snapshot: snapshot)
                        }
                    }
                }
            }
            // Unslotted work belongs to its own section, never to choices or their count.
            let unslotted = Self.restoredUnslotted(for: selected.id, in: snapshot)
            if !unslotted.isEmpty, let navigation {
                SectionHeader("Saved work")
                ForEach(unslotted) { progress in
                    let title = snapshot.definitions.first { $0.id == progress.lessonID }?.title ?? progress.lessonID
                    Button("Resume \(title)") { open(progress.lessonID, using: navigation) }
                        .accessibilityIdentifier("learning-restored-resume-\(progress.lessonID)")
                }
            }
            DisclosureGroup("More lessons", isExpanded: $moreLessonsExpanded) {
                Button("Generate lesson") { generationTopicID = selected.id }
                    .accessibilityIdentifier("learning-generate")
            }
            .accessibilityIdentifier("learning-more-lessons")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceRows(_ choices: [LessonDefinitionSnapshot], snapshot: LearningCatalogSnapshot,
                            selectedID: String?) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space3) {
            SectionHeader("Lessons")
            ForEach(choices) { lesson in
                        let isSelected = selectedID == lesson.id
                        let started = snapshot.progress.contains { $0.lessonID == lesson.id && $0.status == .started }
                        let provenance = LessonExperienceView.generationLabel(for: lesson)
                        Button {
                            // Browse only. No attempt, draft flush, or navigation on selection.
                            if let current = Self.preview(for: navigation?.selectedTopicID ?? selectedTopicID,
                                                          selection: previewSelection, state: store.state) {
                                previewSelection = current.selection.selecting(lesson.id, from: current)
                                optionsLessonID = nil
                                entryError = nil
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: AppMetrics.space1) {
                                Text(lesson.title)
                                    .appTypography(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(lesson.estimatedMinutes) min\(started ? " · In progress" : "")")
                                    .appTypography(.metadata)
                                    .foregroundStyle(AppColors.textSecondary)
                                if let provenance {
                                    Text(provenance).appTypography(.metadata)
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                            }
                            .foregroundStyle(isSelected ? AppColors.accent : AppColors.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: AppMetrics.preferredTarget, alignment: .leading)
                            .padding(AppMetrics.space3)
                            .background(isSelected ? AppColors.raisedSurface : AppColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedLessonID, equals: lesson.id)
                        .overlay {
                            if focusedLessonID == lesson.id {
                                RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                                    .strokeBorder(AppColors.focusRing, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel(lesson.title)
                        .accessibilityValue("\(isSelected ? "Selected" : "Not selected") · \(lesson.estimatedMinutes) min\(started ? " · In progress" : "")\(provenance.map { " · \($0)" } ?? "")")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("learning-lesson-\(lesson.id)")
                    }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lessonPreview(_ lesson: LessonDefinitionSnapshot, topicID: String,
                               snapshot: LearningCatalogSnapshot) -> some View {
        let started = snapshot.progress.contains { $0.lessonID == lesson.id && $0.status == .started }
        return VStack(alignment: .leading, spacing: AppMetrics.space3) {
            SectionHeader("Preview")
            Text(lesson.title)
                .appTypography(.section)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(lesson.displayObjective)
                .appTypography(.body)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(lesson.difficulty.capitalized) · \(lesson.format.capitalized) · \(lesson.estimatedMinutes) min\(started ? " · In progress" : "")")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let concepts = conceptLabels(for: lesson, in: snapshot)
            if !concepts.isEmpty {
                Text(concepts).appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let label = LessonExperienceView.generationLabel(for: lesson) {
                Text(label).appTypography(.metadata).foregroundStyle(AppColors.textSecondary)
            }
            if let navigation {
                ActionButton(started ? "Resume" : "Open", variant: .primary) {
                    do {
                        // The closure captures the displayed identity, never a later fallback.
                        try Self.openPreview(lesson.id, topicID: topicID, selection: previewSelection,
                                             state: store.state, in: store, using: navigation)
                        entryError = nil
                    } catch {
                        entryError = (error as? LessonExperienceError) ?? .persistenceFailure
                    }
                }
                .accessibilityLabel("\(started ? "Resume" : "Open") \(lesson.title)")
                .accessibilityIdentifier("learning-open-\(lesson.id)")
                DisclosureGroup("More options", isExpanded: Binding(
                    get: { optionsLessonID == lesson.id },
                    set: { expanded in
                        optionsLessonID = expanded ? lesson.id : nil
                        if !expanded && focusedDismissLessonID == lesson.id {
                            focusedLessonID = lesson.id
                        }
                    }
                )) {
                    Button("Show another") {
                        guard store.state.isAuthoritative,
                              let current = store.state.snapshot,
                              Self.preview(for: navigation.selectedTopicID, selection: previewSelection,
                                           state: store.state)?.actionLessonID == lesson.id,
                              let captured = Self.dismissal(for: lesson.id, in: current) else {
                            entryError = .staleSlot
                            return
                        }
                        dismissal = captured
                        showingDismissal = true
                    }
                    .accessibilityLabel("Show another instead of \(lesson.title)")
                    .focusable()
                    .focused($focusedDismissLessonID, equals: lesson.id)
                    .accessibilityIdentifier("learning-dismiss-\(lesson.id)")
                }
                .accessibilityIdentifier("learning-more-options-\(lesson.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.space4)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
        .accessibilityIdentifier("learning-preview-\(lesson.id)")
    }

    private func dismiss(_ captured: DismissalConfirmation) {
        do {
            guard let navigation else { throw LessonExperienceError.invalidTransition }
            _ = try Self.dismiss(captured, in: store, using: navigation)
            entryError = nil
        } catch {
            entryError = (error as? LessonExperienceError) ?? .persistenceFailure
        }
    }

    static func dismiss(_ captured: DismissalConfirmation, in store: LearningCatalogStore,
                        using navigation: NavigationStore) throws -> LessonMutationResult {
        // No new slot lookup here: the repository rejects a replaced occupant or timestamp.
        // Flush all app-owned buffers before this transition, including a second window's edits.
        guard navigation.flushForLifecycle() else { throw navigation.saveError ?? .persistenceFailure }
        return try store.dismiss(lessonID: captured.lessonID, expectedSlot: captured.slot)
    }

    private struct GenerationTopic: Identifiable {
        let id: String
    }

    /// Shared by choice Open and Saved work Resume. The same committed-state
    /// check runs after the draft barrier, before starting or routing work.
    static func open(_ id: String, in store: LearningCatalogStore,
                     using navigation: NavigationStore) throws {
        try navigation.openLesson(id: id) {
            guard let snapshot = store.state.snapshot, store.state.isAuthoritative,
                  let definition = snapshot.definitions.first(where: { $0.id == id }),
                  (snapshot.slots.contains(where: { $0.lessonID == id }) ||
                   snapshot.progress.contains(where: { $0.lessonID == id && $0.status == .started &&
                       ($0.dismissedAt != nil || definition.source == "generated") })) else {
                throw LessonExperienceError.staleSlot
            }
            return try store.openLesson(lessonID: id)
        }
    }

    /// Revalidate the captured preview before the guarded draft/attempt command. A
    /// removed or newly selected lesson cannot turn an old button into a fallback action.
    static func openPreview(_ id: String, topicID: String, selection: LearningPreviewSelection,
                            state: LearningCatalogReadState, in store: LearningCatalogStore,
                            using navigation: NavigationStore) throws {
        guard state.isAuthoritative, let snapshot = state.snapshot,
              navigation.learningRoute == .choices,
              topicProjection(for: navigation.selectedTopicID, in: snapshot)?.selected.id == topicID,
              let current = preview(for: topicID, selection: selection, state: state),
              current.selection.lessonID == id,
              current.actionLessonID == id else { throw LessonExperienceError.staleSlot }
        try open(id, in: store, using: navigation)
    }

    private func open(_ id: String, using navigation: NavigationStore) {
        do {
            try Self.open(id, in: store, using: navigation)
            entryError = nil
        } catch {
            entryError = (error as? LessonExperienceError) ?? .persistenceFailure
        }
    }
}

/// @Published emits in willSet: reading selectedTopicID while SwiftUI processes that
/// publication can return the *previous* topic. Render the emitted value instead of
/// re-reading the store, including when the parent does not observe NavigationStore.
private struct RoutedLearningCatalog<Content: View>: View {
    @ObservedObject var navigation: NavigationStore
    @State private var renderedTopicID: String?
    let content: (String?) -> Content

    init(navigation: NavigationStore, content: @escaping (String?) -> Content) {
        self.navigation = navigation
        self.content = content
        _renderedTopicID = State(initialValue: navigation.selectedTopicID)
    }

    var body: some View {
        content(renderedTopicID)
            .onReceive(navigation.$selectedTopicID) { renderedTopicID = $0 }
    }
}
