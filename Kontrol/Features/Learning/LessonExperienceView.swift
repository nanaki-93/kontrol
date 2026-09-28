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
    @State private var showingSolution = false
    @State private var gateError: LessonExperienceError?
    @State private var completion: LessonMutationResult?
    @State private var dismissal: LearningView.DismissalConfirmation?
    @State private var showingDismissal = false
    @FocusState private var dismissalFocused: Bool
    @FocusState private var backFocused: Bool

    /// A gate is offered only against the current committed detail and its exact saved buffer.
    /// The repository rechecks the revision and all gates during the transaction.
    static func canComplete(_ detail: LessonDetailSnapshot, buffer: LessonDraftStore.Buffer,
                            lessonID: String) -> Bool {
        guard detail.id == lessonID, detail.progress?.status == .started,
              let attempt = detail.attempt, attempt.lessonID == lessonID,
              attempt.id == buffer.attemptID, attempt.completedAt == nil,
              case .pinned(let definition) = detail.content, definition.id == lessonID else { return false }
        return !buffer.isDirty && buffer.status == .saved &&
            buffer.expectedRevision == attempt.revision && buffer.text == attempt.answerDraft &&
            attempt.solutionRevealedAt != nil && attempt.selfCheckAcknowledgedAt != nil
    }
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
                .focused($backFocused)
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
        .confirmationDialog("Show another instead of \(dismissal?.title ?? "this lesson")?",
                            isPresented: $showingDismissal, titleVisibility: .visible) {
            Button("Show another", role: .destructive) {
                if let dismissal { confirmDismissal(dismissal) }
            }
            Button("Keep lesson", role: .cancel) {}
        } message: {
            Text("Dismiss this assignment? Your unfinished response and studied version are retained in History. This does not complete the lesson.")
        }
        .onChange(of: showingDismissal) { _, visible in
            if !visible, let captured = dismissal {
                dismissal = nil
                DispatchQueue.main.async {
                    if store.state.snapshot?.slots.contains(where: { $0 == captured.slot }) == true {
                        dismissalFocused = true
                    } else {
                        backFocused = true
                    }
                }
            }
        }
        .onChange(of: lessonID) { _, _ in
            conflict = ConflictComparisonState()
            showingSolution = false
            gateError = nil
            completion = nil
            dismissal = nil
            showingDismissal = false
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
        if let receipt = completion, receipt.detail == detail,
           detail.progress?.status == .completed, detail.attempt?.completedAt != nil {
            PageHeader("Lesson completed")
            Text("\(receipt.history.first(where: { $0.lessonID == lessonID })?.title ?? lessonID) completed. Your saved response and studied version are retained in History. No grade is assigned.")
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lesson-completion-receipt")
            Button("Back to choices") { navigation.backToChoices() }
        } else if let definition = Self.studiedDefinition(detail, lessonID: lessonID) {
            PageHeader(definition.title)
            Text("\(definition.format.capitalized) · \(definition.difficulty.capitalized) · \(definition.estimatedMinutes) min · Studied version \(definition.contentVersion)")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            if let buffer = Self.response(detail, drafts: drafts, lessonID: lessonID) {
                Button("Show another instead of \(definition.title)") {
                    guard store.state.isAuthoritative, let snapshot = store.state.snapshot,
                          let captured = LearningView.dismissal(for: lessonID, in: snapshot,
                                                                 attemptID: buffer.attemptID) else {
                        gateError = .staleSlot
                        return
                    }
                    dismissal = captured
                    showingDismissal = true
                }
                .focusable()
                .focused($dismissalFocused)
                .accessibilityIdentifier("lesson-dismiss")
                if showingSolution && detail.attempt?.solutionRevealedAt != nil {
                    Button("Back to exercise") { showingSolution = false }
                        .accessibilityIdentifier("lesson-back-to-exercise")
                    SectionHeader(buffer.isDirty ? "Your response (not saved yet)" : "Your saved answer")
                    Text(buffer.text.isEmpty ? "(Blank response)" : buffer.text)
                        .appTypography(.body)
                        .textSelection(.enabled)
                    saveFeedback(buffer)
                    section("Reference solution", text: definition.referenceAnswer, code: definition.format == "code")
                    SectionHeader("Self-check · authored criteria")
                    ForEach(Array(definition.selfCheckCriteria.enumerated()), id: \.offset) { _, criterion in
                        Text("• \(criterion)")
                            .appTypography(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Compare for yourself. There is no automated grade.")
                        .appTypography(.body)
                    if detail.attempt?.selfCheckAcknowledgedAt == nil {
                        Button("Acknowledge self-check") {
                            performGate { try drafts.setSelfCheckAcknowledged(attemptID: buffer.attemptID, acknowledged: true) }
                        }
                        .accessibilityIdentifier("lesson-acknowledge")
                    } else {
                        Text("Self-check acknowledged")
                            .appTypography(.body)
                            .accessibilityIdentifier("lesson-acknowledged")
                    }
                    Button("Complete") {
                        performGate {
                            let receipt = try drafts.complete(attemptID: buffer.attemptID)
                            completion = receipt
                            return receipt
                        }
                    }
                    .disabled(!Self.canComplete(detail, buffer: buffer, lessonID: lessonID))
                    .accessibilityIdentifier("lesson-complete")
                } else {
                    section("Explanation", text: definition.explanation, code: definition.format == "code")
                    section("Worked example", text: definition.workedExample, code: definition.format == "code")
                    section("Exercise", text: definition.exercise, code: definition.format == "code")
                    responseEditor(buffer, exercise: definition.exercise)
                    Button(detail.attempt?.solutionRevealedAt == nil ? "Show solution" : "View solution") {
                        if detail.attempt?.solutionRevealedAt != nil {
                            showingSolution = true
                        } else {
                            performGate {
                                let receipt = try drafts.revealSolution(attemptID: buffer.attemptID)
                                showingSolution = true
                                return receipt
                            }
                        }
                    }
                    .accessibilityIdentifier("lesson-show-solution")
                }
                if let gateError {
                    Text("Lesson action not saved (\(String(describing: gateError))). Your response and route are retained. Retry after resolving any unsaved answer or read error.")
                        .appTypography(.body)
                        .foregroundStyle(AppColors.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("lesson-gate-error")
                }
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

    private func confirmDismissal(_ captured: LearningView.DismissalConfirmation) {
        do {
            // Flush before the atomic, exact-assignment dismissal. A failed flush leaves
            // the route and confirmation's assignment unchanged for a fresh retry.
            guard navigation.flushForLifecycle() else { throw navigation.saveError ?? .persistenceFailure }
            let receipt = try drafts.dismiss(lessonID: captured.lessonID,
                                             expectedSlot: captured.slot, attemptID: captured.attemptID)
            guard receipt.detail.id == captured.lessonID else { throw LessonExperienceError.invalidStoredData }
            gateError = nil
            navigation.backToChoices()
        } catch {
            gateError = (error as? LessonExperienceError) ?? .persistenceFailure
        }
    }

    private func performGate(_ action: () throws -> LessonMutationResult) {
        do {
            _ = try action()
            gateError = nil
        } catch {
            gateError = (error as? LessonExperienceError) ?? .persistenceFailure
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
            saveFeedback(buffer)
        }
        .appTypography(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The same app-owned buffer can change from another window while this window shows
    /// the solution. Keep its durable status and stale-revision recovery visible there too.
    private func saveFeedback(_ buffer: LessonDraftStore.Buffer) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space2) {
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
