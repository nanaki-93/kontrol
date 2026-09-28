import SwiftUI

/// Practice is a read of one stable lesson ID. Only an explicit Open/Resume starts an attempt;
/// a route refresh never substitutes a newer catalog definition for studied content.
struct LessonExperienceView: View {
    let lessonID: String
    @ObservedObject var store: LearningCatalogStore
    @ObservedObject var drafts: LessonDraftStore
    @ObservedObject var navigation: NavigationStore

    /// The comparison survives a failed reconciliation; only a successful explicit reload
    /// clears the recovery error and makes it eligible for another attempt.
    @MainActor struct ConflictComparisonState {
        var detail: LessonDetailSnapshot?
        var error: String?

        mutating func reload(drafts: LessonDraftStore, attemptID: UUID) {
            do {
                detail = try drafts.reload(attemptID: attemptID)
                error = nil
            } catch {
                self.error = "Could not reload the saved answer. Keep your local response open and retry Reload saved answer for comparison."
            }
        }

        mutating func reconcile(drafts: LessonDraftStore, attemptID: UUID) {
            guard let detail, error == nil else { return }
            do {
                try drafts.reconcileForRetry(attemptID: attemptID, with: detail)
                self.detail = nil
                error = nil
            } catch {
                // The committed answer may have changed again. Do not discard either
                // side of the comparison or claim that the draft was saved.
                self.error = "Could not reconcile with the saved answer. Reload it, compare again, then retry save. Your local response is still here."
            }
        }
    }

    @State private var conflict = ConflictComparisonState()
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.appTextScaleOverride) private var previewScale

    static func matchedDetail(_ state: LessonDetailReadState, lessonID: String) -> LessonDetailSnapshot? {
        guard case .current(let detail) = state, detail.id == lessonID else { return nil }
        return detail
    }

    static func studiedDefinition(_ detail: LessonDetailSnapshot, lessonID: String) -> LessonDefinitionSnapshot? {
        guard detail.id == lessonID, let attempt = detail.attempt,
              attempt.lessonID == lessonID, detail.progress?.status == .started,
              attempt.completedAt == nil,
              case .pinned(let definition) = detail.content,
              definition.id == lessonID else { return nil }
        return definition
    }

    static func response(_ detail: LessonDetailSnapshot, drafts: LessonDraftStore,
                         lessonID: String) -> LessonDraftStore.Buffer? {
        guard detail.id == lessonID, let attempt = detail.attempt,
              attempt.lessonID == lessonID, let buffer = drafts.buffers[attempt.id],
              buffer.lessonID == lessonID, buffer.attemptID == attempt.id else { return nil }
        return buffer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Button("Back to choices") { navigation.backToChoices() }
                .accessibilityIdentifier("lesson-back")
            switch store.detailState {
            case .failed(let id, _) where id == lessonID:
                if store.error == .invalidStoredData || store.error == .contentUnavailable {
                    Text("Studied content unavailable. The original exercise could not be read; current catalog text is not substituted.")
                        .appTypography(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ErrorBanner(.readFailed, recoveryTitle: "Retry lesson") {
                    _ = try? store.retryDetail(lessonID: lessonID)
                }
            case .current(let detail) where detail.id == lessonID:
                detailContent(detail)
            default:
                LoadingState("Opening lesson")
                Button("Reload lesson") { _ = try? store.loadDetail(lessonID: lessonID) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.horizontalInset)
        .onAppear { loadRequestedDetail() }
        .onChange(of: lessonID) { _, _ in
            conflict = ConflictComparisonState()
            loadRequestedDetail()
        }
        .onChange(of: store.detailState) { _, state in
            if let detail = Self.matchedDetail(state, lessonID: lessonID) { drafts.observe(detail) }
        }
    }

    private func loadRequestedDetail() {
        if let detail = try? store.loadDetail(lessonID: lessonID) { drafts.observe(detail) }
    }

    @ViewBuilder private func detailContent(_ detail: LessonDetailSnapshot) -> some View {
        if let definition = Self.studiedDefinition(detail, lessonID: lessonID) {
            PageHeader(definition.title)
            Text("\(definition.format.capitalized) · \(definition.difficulty.capitalized) · \(definition.estimatedMinutes) min · Studied version \(definition.contentVersion)")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            section("Explanation", text: definition.explanation, code: definition.format == "code")
            section("Worked example", text: definition.workedExample, code: definition.format == "code")
            section("Exercise", text: definition.exercise, code: definition.format == "code")
            if let buffer = Self.response(detail, drafts: drafts, lessonID: lessonID) {
                responseEditor(buffer, exercise: definition.exercise)
            } else {
                LoadingState("Opening response")
            }
        } else {
            // A missing/corrupt pin is never repaired with `.current` catalog text.
            SectionHeader("Studied content unavailable")
            Text("The original exercise cannot be recovered. Current catalog content is not substituted.")
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let attempt = detail.attempt, attempt.lessonID == lessonID {
                let buffer = Self.response(detail, drafts: drafts, lessonID: lessonID)
                SectionHeader(buffer?.isDirty == true ? "Your unsaved response (retained locally)" : "Your saved answer")
                let answer = buffer?.text ?? attempt.answerDraft
                Text(answer.isEmpty ? "(Blank response)" : answer)
                    .appTypography(.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("lesson-retained-answer")
            }
        }
    }

    private func section(_ title: String, text: String, code: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader(title)
            Text(text)
                .font(AppTypography.font(.body, for: textSize, override: previewScale))
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lesson-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.space4)
        .background(code ? AppColors.raisedSurface : AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
    }

    private func responseEditor(_ buffer: LessonDraftStore.Buffer, exercise: String) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
            SectionHeader("Your response")
            TextEditor(text: Binding(
                get: { Self.responseForEditor(store.detailState, drafts: drafts, lessonID: lessonID)?.text ?? "" },
                set: { value in
                    guard let detail = Self.matchedDetail(store.detailState, lessonID: lessonID),
                          let current = Self.response(detail, drafts: drafts, lessonID: lessonID),
                          current.attemptID == buffer.attemptID else { return }
                    drafts.edit(value, attemptID: current.attemptID)
                }
            ))
            .font(AppTypography.font(.body, for: textSize, override: previewScale))
            .frame(minHeight: 170)
            .scrollContentBackground(.hidden)
            .background(AppColors.raisedSurface)
            .accessibilityLabel("Response to \(exercise)")
            .accessibilityIdentifier("lesson-response-\(lessonID)")
            switch buffer.status {
            case .saving:
                Text("Saving")
                    .foregroundStyle(AppColors.warning)
                    .accessibilityIdentifier("lesson-save-status")
            case .saved:
                Text("Saved")
                    .foregroundStyle(AppColors.success)
                    .accessibilityIdentifier("lesson-save-status")
            case .notSaved(let error):
                Text("Not saved — Retry")
                    .foregroundStyle(AppColors.error)
                    .accessibilityIdentifier("lesson-save-status")
                if error == .staleRevision {
                    Text("Another answer was saved. Your local response is retained; reload and reconcile before retrying.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reload saved answer for comparison") {
                        conflict.reload(drafts: drafts, attemptID: buffer.attemptID)
                    }
                    if let comparison = conflict.detail, comparison.id == lessonID,
                       comparison.attempt?.id == buffer.attemptID {
                        Text("\(conflict.error == nil ? "Saved response" : "Previously loaded saved response — reload before using"): \(comparison.attempt?.answerDraft ?? "")")
                            .textSelection(.enabled)
                        Button("Use my local response instead") {
                            conflict.reconcile(drafts: drafts, attemptID: buffer.attemptID)
                        }
                        .disabled(conflict.error != nil)
                    }
                    if let error = conflict.error {
                        Text(error)
                            .foregroundStyle(AppColors.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("lesson-conflict-error")
                    }
                }
                Button("Retry save") { _ = try? drafts.retry(attemptID: buffer.attemptID) }
                    .accessibilityIdentifier("lesson-retry-save")
            }
        }
        .appTypography(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func responseForEditor(_ state: LessonDetailReadState, drafts: LessonDraftStore,
                                          lessonID: String) -> LessonDraftStore.Buffer? {
        guard let detail = matchedDetail(state, lessonID: lessonID) else { return nil }
        return response(detail, drafts: drafts, lessonID: lessonID)
    }
}
