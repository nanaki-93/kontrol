import SwiftUI

/// A canceled transport can finish after a new submission begins. Only the
/// active submission may publish a result or clear the progress indicator.
struct GenerationSheetSubmission {
    private(set) var activeID: UUID?
    var isRunning: Bool { activeID != nil }

    mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return id
    }

    mutating func retire() { activeID = nil }

    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}

/// Window-local, read-only scope preview. Only the explicit Generate/Retry action calls the provider.
struct LessonGenerationSheet: View {
    let topicID: String
    let repository: any CatalogRepository
    @ObservedObject var learning: LearningCatalogStore
    @ObservedObject var settings: AISettingsStore
    @ObservedObject var generation: LessonGenerationStore
    var navigation: NavigationStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var owner = UUID()
    @State private var context: LessonGenerationContext?
    @State private var registry: GenerationObjectives?
    @State private var scopeError: String?
    @State private var objectiveKey: String?
    @State private var format = ""
    @State private var difficulty = ""
    @State private var failure: LessonGenerationError?
    @State private var retryNotBefore: Date?
    @State private var result: GeneratedLessonInsertionResult?
    @State private var openError: String?
    @State private var submission = GenerationSheetSubmission()

    private var running: Bool { submission.isRunning }

    static func successMessage(for receipt: GeneratedLessonInsertionResult) -> String {
        receipt.assignedSlot == nil ? "Saved; current choices unchanged" : "Added to choices"
    }

    /// Accept only the committed ID, including when it has no slot. A stale
    /// projection or a failed draft flush must never start an attempt or route.
    static func openAcceptedLesson(_ receipt: GeneratedLessonInsertionResult,
                                   learning: LearningCatalogStore, navigation: NavigationStore) throws {
        guard let accepted = receipt.catalog.definitions.first(where: { $0.id == receipt.lessonID }),
              accepted.source == "generated" else { throw LessonExperienceError.staleSlot }
        try navigation.openLesson(id: receipt.lessonID) {
            guard learning.state.isAuthoritative,
                  let current = learning.state.snapshot,
                  current.definitions.first(where: { $0.id == receipt.lessonID }) == accepted,
                  !current.progress.contains(where: { $0.lessonID == receipt.lessonID &&
                      ($0.status == .completed || $0.status == .dismissed) }) else {
                throw LessonExperienceError.staleSlot
            }
            return try learning.openLesson(lessonID: receipt.lessonID)
        }
    }

    static func available(_ context: LessonGenerationContext, registry: GenerationObjectives,
                          topicID: String) -> [GenerationObjective] {
        let excluded = Set(context.terminal.filter { $0.status == .completed || $0.status == .dismissed }
            .compactMap { $0.metadata.objectiveKey.map(LessonDeduplication.normalizedObjective) })
        return registry.objectives.filter {
            $0.topicID == topicID && !excluded.contains(LessonDeduplication.normalizedObjective($0.key))
        }.sorted { $0.key < $1.key }
    }

    static func retryAllowed(at now: Date, notBefore: Date?) -> Bool {
        notBefore.map { now >= $0 } ?? true
    }

    static func failureMessage(_ error: LessonGenerationError) -> String {
        switch error {
        case .disabled, .unconfigured: "AI lessons are off. Configure and enable them in Settings."
        case .missingCredential: "The saved key is missing. Replace it in Settings."
        case .inaccessibleCredential: "Keychain is unavailable. Unlock it and try again."
        case .unsupportedModel: "The model is unsupported. Choose another in Settings."
        case .unavailableObjectives: "Generation objectives are unavailable. Try again after reinstalling the app."
        case .corruptObjectives: "Generation objectives are invalid. Try again after reinstalling the app."
        case .exhaustedObjectives: "No unseen generation objectives available"
        case .invalidScope, .unmetPrerequisites: "This scope is not eligible. Choose another objective or complete its prerequisites."
        case .staleContext: "Learning changed while generating. Review the scope and try again."
        case .offline: "Offline. Check your connection and retry when ready."
        case .timeout: "The request timed out. Retry when ready."
        case .rateLimited: "OpenAI rate limited this request. Retry when permitted."
        case .authentication, .authorization: "OpenAI denied access. Check the key and model in Settings."
        case .persistenceFailure: "Lesson not saved. Check local storage and retry."
        case .duplicateIdentity, .duplicateContent, .duplicateObjective: "This lesson is already covered. Choose another objective."
        case .cancelled: "Generation cancelled. No lesson was added."
        default: "The response could not be used. No lesson was added. Retry or change scope."
        }
    }

    private var objectives: [GenerationObjective] {
        guard let context, let registry else { return [] }
        return Self.available(context, registry: registry, topicID: topicID)
    }
    private var selected: GenerationObjective? { objectives.first { $0.key == objectiveKey } }
    private var scopeFailure: LessonGenerationError? {
        guard let context, let registry, let selected else { return nil }
        do {
            _ = try LessonGenerationRequestBuilder.make(selection: .init(topicID: topicID,
                objectiveKey: selected.key, format: format, difficulty: difficulty),
                operationID: owner, context: context, registry: registry)
            return nil
        } catch { return error as? LessonGenerationError ?? .invalidScope }
    }
    private var disabledReason: String? {
        if let scopeError { return scopeError }
        if objectives.isEmpty { return "No unseen generation objectives available" }
        if !settings.presentation.enabled { return "AI lessons are off. Enable them in Settings." }
        if settings.credentialStatus != .available { return "A readable saved key is required. Open Settings to configure it." }
        if settings.presentation.modelID == nil { return "Choose a model in Settings." }
        if let scopeFailure { return Self.failureMessage(scopeFailure) }
        if settings.operationGate.isBusy && !running { return "Another AI operation is running. Try again when it finishes." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.space4) {
                Text("Generate a lesson").appTypography(.section).accessibilityAddTraits(.isHeader)
                Text("Your current choices and unfinished work remain available while this runs.")
                    .appTypography(.body)
                if let context {
                    let catalog = context.catalog.value
                    Text("Topic: \(catalog.topics.first { $0.id == topicID }?.name ?? topicID)")
                    if let selected {
                        Text("Subtopic: \(catalog.subtopics.first { $0.id == selected.subtopicID }?.name ?? selected.subtopicID)")
                        Text("Concepts: \(selected.conceptIDs.map { id in catalog.concepts.first { $0.id == id }?.name ?? id }.joined(separator: ", "))")
                        Text("Objective: \(selected.text)")
                            .fixedSize(horizontal: false, vertical: true)
                        AppMenuPicker("Format", selection: $format,
                                      options: selected.formats.map { ($0.capitalized, $0) })
                        .disabled(running)
                        AppMenuPicker("Difficulty", selection: $difficulty,
                                      options: selected.difficulties.map { ($0.capitalized, $0) })
                        .disabled(running)
                    }
                    if objectives.count > 1 {
                        AppMenuPicker("Objective", selection: $objectiveKey,
                                      options: objectives.map { ($0.text, Optional($0.key)) })
                        .disabled(running)
                    }
                }
                Text("OpenAI receives the selected topic, subtopic, concepts, objective, difficulty, format, relevant completed concepts and completed/dismissed objective metadata. Answers, tasks and activity history are not sent. Generation may incur provider charges.")
                    .appTypography(.metadata).foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if running {
                    ProgressView("Generating one lesson…")
                        .accessibilityIdentifier("generation-progress")
                    Button("Cancel generation") { cancelSubmission() }
                        .accessibilityIdentifier("generation-cancel")
                } else if let result {
                    Text(Self.successMessage(for: result))
                        .accessibilityIdentifier("generation-result")
                    Text("Saved locally. Opening starts your work; generation itself does not mark practice or certify accuracy.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let navigation {
                        Button("Open lesson") {
                            do {
                                try Self.openAcceptedLesson(result, learning: learning, navigation: navigation)
                                dismiss()
                            } catch {
                                openError = "Lesson could not be opened. Your unfinished work is retained. Retry after saving your draft or return to choices."
                            }
                        }
                        .accessibilityIdentifier("generation-open")
                    }
                    if let openError {
                        Text(openError).foregroundStyle(AppColors.error)
                            .accessibilityIdentifier("generation-open-error")
                    }
                } else {
                    if let failure {
                        Text("Lesson not added").appTypography(.section).accessibilityAddTraits(.isHeader)
                        Text(Self.failureMessage(failure)).accessibilityIdentifier("generation-error")
                    }
                    if let disabledReason {
                        Text(disabledReason).accessibilityIdentifier("generation-disabled-reason")
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let wait = !Self.retryAllowed(at: timeline.date, notBefore: retryDate)
                        if wait, let retryDate {
                            Text("Retry available after \(retryDate.formatted(date: .abbreviated, time: .standard)). No automatic retry.")
                                .accessibilityIdentifier("generation-retry-after")
                        }
                        Button(failure == nil ? "Generate lesson" : "Retry generation") { submit() }
                            .disabled(disabledReason != nil || wait)
                            .accessibilityIdentifier("generation-submit")
                    }
                    if !settings.presentation.enabled || settings.credentialStatus != .available ||
                        settings.presentation.modelID == nil {
                        if let navigation {
                            Button("Configure in Settings") {
                                navigation.select(.settings) // NavigationStore owns the draft-flush guard.
                                if navigation.selectedDestination == .settings { dismiss() }
                            }.accessibilityIdentifier("generation-settings")
                        } else {
                            Text("Open Settings to configure AI lessons.")
                        }
                    }
                }
                Button("Close") { dismiss() }.accessibilityIdentifier("generation-close")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppMetrics.space6)
        }
        .frame(minWidth: 360, idealWidth: 560, minHeight: 300, idealHeight: 520)
        .onAppear { reloadScope() }
        .onDisappear { cancelSubmission() }
        .onChange(of: objectiveKey) { _, key in
            if let selected = objectives.first(where: { $0.key == key }) {
                format = selected.formats[0]
                difficulty = selected.difficulties[0]
            }
            failure = nil
        }
        .onChange(of: settings.presentation.revision) { _, _ in
            if running { cancelSubmission() }
        }
    }

    private var retryDate: Date? {
        retryNotBefore
    }

    private func reloadScope() {
        do {
            let fresh = try repository.generationContext(topicID: topicID)
            let loaded = try GenerationObjectivesLoader.load(catalog: fresh.catalog, membership: fresh.membership)
            context = fresh
            registry = loaded
            scopeError = nil
            let available = Self.available(fresh, registry: loaded, topicID: topicID)
            objectiveKey = available.first?.key
            if let first = available.first { format = first.formats[0]; difficulty = first.difficulties[0] }
        } catch let error as GenerationObjectivesError {
            scopeError = error.message
        } catch {
            scopeError = "Generation scope could not be loaded. Close and try again."
        }
    }

    private func cancelSubmission() {
        // Retire before invalidating the lease: a late response must not update
        // this presentation even if another request has already acquired it.
        submission.retire()
        generation.cancel(owner: owner)
    }

    private func submit() {
        guard disabledReason == nil, Self.retryAllowed(at: Date(), notBefore: retryDate),
              let selected, let submissionID = submission.begin() else { return }
        let selection = LessonGenerationSelection(topicID: topicID, objectiveKey: selected.key,
                                                  format: format, difficulty: difficulty)
        failure = nil
        Task {
            // Cancel/dismiss can occur before this task first runs.
            guard submission.activeID == submissionID else { return }
            let outcome: Result<GeneratedLessonInsertionResult, Error>
            do { outcome = .success(try await generation.generate(selection: selection, owner: owner)) }
            catch { outcome = .failure(error) }
            guard submission.finish(submissionID) else { return }
            switch outcome {
            case .success(let receipt):
                openError = nil
                result = receipt
            case .failure(let error as LessonGenerationError) where error == .cancelled:
                break // Dismissal is not a failure.
            case .failure(let error):
                failure = error as? LessonGenerationError ?? .persistenceFailure
                if case .rateLimited(let date) = failure { retryNotBefore = date }
            }
        }
    }
}
