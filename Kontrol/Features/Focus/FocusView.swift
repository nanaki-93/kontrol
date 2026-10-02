import SwiftUI

/// Unsaved, window-local configuration. Disappearing links stay selected until explicitly
/// changed; neither selecting a lesson nor validating the draft opens an attempt.
struct FocusReadyDraft {
    enum DurationSource: Equatable { case followingDefault, userOverride, submitted }
    enum ActivityType: Equatable { case none, task, lesson }

    private(set) var activityType: ActivityType = .none
    private(set) var duration: FocusDuration = .default
    private(set) var durationSource: DurationSource = .followingDefault
    private(set) var usesFallback = false
    private(set) var linkedTaskID: UUID?
    private(set) var linkedLessonID: String?

    init(preferences: AppPreferencesSnapshot? = .defaults) {
        followPreferences(preferences)
    }

    /// A failed read is not a loaded default, even if the store retains an older receipt.
    mutating func followPreferences(_ snapshot: AppPreferencesSnapshot?) {
        guard durationSource == .followingDefault else { return }
        duration = snapshot?.preferences.focusDuration ?? .default
        usesFallback = snapshot == nil
    }

    mutating func selectDuration(_ value: FocusDuration) {
        duration = value
        durationSource = .userOverride
        usesFallback = false
    }

    /// Freeze before attempting Start, including validation/persistence failures in the service.
    mutating func markSubmitted() { durationSource = .submitted }

    var fallbackMessage: String? {
        usesFallback ? "Using a 25-minute fallback because preferences could not be read. Retry preferences in Settings." : nil
    }

    /// Only the user's choice changes the link. Inventory updates must not erase a stale ID:
    /// configuration validation will require an explicit correction before Start.
    mutating func selectActivityType(_ type: ActivityType) {
        activityType = type
        switch type {
        case .none:
            linkedTaskID = nil
            linkedLessonID = nil
        case .task:
            linkedLessonID = nil
        case .lesson:
            linkedTaskID = nil
        }
    }

    mutating func selectTask(_ id: UUID?) {
        linkedTaskID = id
        if id != nil {
            activityType = .task
            linkedLessonID = nil
        }
    }

    mutating func selectLesson(_ id: String?) {
        linkedLessonID = id
        if id != nil {
            activityType = .lesson
            linkedTaskID = nil
        }
    }

    /// Use the authoritative catalog inventory, not the four Learning choice slots.
    /// Selecting a lesson does not create a progress row or open an attempt.
    static func lessons(from state: LearningCatalogReadState) -> [LessonDefinitionSnapshot]? {
        guard state.isAuthoritative, let snapshot = state.snapshot else { return nil }
        let active = Dictionary(uniqueKeysWithValues: snapshot.progress.map { ($0.lessonID, $0.status) })
        return snapshot.definitions.filter { lesson in
            let status = active[lesson.id] ?? .available
            return status == .available || status == .started
        }.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
    }

    func configuration(openTasks: [TaskSnapshot], tasksReadable: Bool,
                       lessons: [LessonDefinitionSnapshot]? = nil) throws -> FocusConfiguration {
        _ = try duration.seconds()
        if let linkedTaskID {
            guard tasksReadable, openTasks.contains(where: { $0.id == linkedTaskID && !$0.isCompleted }) else {
                throw FocusError.unavailableTask
            }
        }
        if let linkedLessonID {
            guard lessons?.contains(where: { $0.id == linkedLessonID }) == true else {
                throw FocusError.unavailableLesson
            }
        }
        return FocusConfiguration(duration: duration, linkedTaskID: linkedTaskID,
                                  linkedLessonID: linkedLessonID)
    }
}

/// Display values come from the committed row; only the running countdown comes
/// from the service's monotonic clock. No view-local timer or optimistic state.
struct FocusTimerPresentation {
    let session: FocusSessionSnapshot
    let countdownSeconds: Int

    var stateText: String { session.state == .running ? "Running" : "Paused" }
    var title: String { session.linkedTitleSnapshot ?? "Focus session" }
    var countdown: String {
        let seconds = max(0, countdownSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var actualDuration: String {
        let seconds = Int(min(session.actualSeconds.rounded(.down), Double(Int.max).nextDown))
        return "\(seconds / 60) min \(seconds % 60) sec focused"
    }
}

/// Recovery values are frozen in the committed row, not sampled from a new clock.
struct FocusRecoveryPresentation {
    let session: FocusSessionSnapshot

    var title: String { session.linkedTitleSnapshot ?? "Focus session" }
    private var wholeRecordedSeconds: Int {
        Int(min(session.actualSeconds.rounded(.down), Double(Int.max).nextDown))
    }
    var recorded: String { Self.duration(wholeRecordedSeconds) }
    var remaining: String { Self.duration(session.plannedSeconds - wholeRecordedSeconds) }

    private static func duration(_ seconds: Int) -> String {
        "\(seconds / 60) min \(seconds % 60) sec"
    }
}

struct FocusView: View {
    @ObservedObject var service: FocusService
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var learningStore: LearningCatalogStore
    @ObservedObject var preferencesStore: AppPreferencesStore
    @State private var draft: FocusReadyDraft

    init(service: FocusService, taskStore: TaskStore, learningStore: LearningCatalogStore,
         preferencesStore: AppPreferencesStore) {
        self.service = service
        self.taskStore = taskStore
        self.learningStore = learningStore
        self.preferencesStore = preferencesStore
        _draft = State(initialValue: FocusReadyDraft(preferences: preferencesStore.editableSnapshot))
    }

    private var customMinutes: String {
        if case .custom(let text) = draft.duration { return text }
        return ""
    }
    @State private var showingSessions = false
    @State private var historyFilter: FocusHistoryFilter = .recent
    @AccessibilityFocusState private var focusHistoryNavigation: Bool
    @AccessibilityFocusState private var focusTimerNavigation: Bool
    @FocusState private var focusSessionsButton: Bool
    @FocusState private var focusBackButton: Bool
    @AppScaledMetric(relativeTo: .largeTitle) private var countdownFontSize: CGFloat = 64
    @State private var startError: FocusError?
    @State private var actionError: (sessionID: UUID, state: FocusSessionState, message: String)?

    private var openTasks: [TaskSnapshot] {
        taskStore.snapshots.filter { !$0.isCompleted }
            .sorted { $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title }
    }

    private var lessons: [LessonDefinitionSnapshot]? { FocusReadyDraft.lessons(from: learningStore.state) }

    private var configuration: FocusConfiguration? {
        try? draft.configuration(openTasks: openTasks, tasksReadable: taskStore.readState == .loaded,
                                 lessons: lessons)
    }

    private var validationMessage: String? {
        do {
            _ = try draft.configuration(openTasks: openTasks, tasksReadable: taskStore.readState == .loaded,
                                        lessons: lessons)
            return nil
        } catch FocusError.unavailableTask {
            return "The selected task is no longer available. Choose another open task or select No task."
        } catch FocusError.unavailableLesson {
            return "The selected lesson is unavailable. Retry learning choices or choose another lesson or No link."
        } catch {
            return "Enter a positive whole number of minutes that fits the timer."
        }
    }

    private var durationLabel: String {
        guard let seconds = try? draft.duration.seconds() else { return "Set a valid duration" }
        return "\(seconds / 60) minutes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            if showingSessions {
                PageHeader("Sessions") {
                    ActionButton("Back to timer", symbol: "arrow.left") {
                        showingSessions = false
                        focusSessionsButton = true
                        focusTimerNavigation = true
                    }
                    .focused($focusBackButton)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityFocused($focusHistoryNavigation)
                    .accessibilityIdentifier("focus-back-to-timer")
                }
                // Navigation is local to this window; the service clock remains owned by the graph.
                FocusHistoryView(service: service, filter: $historyFilter)
            } else {
                PageHeader("Focus", metadata: service.completionPendingError != nil ? "Completion pending" :
                           service.activeSession?.recoveryRequired == true ? "Interrupted" :
                           service.activeSession == nil ? "Ready" : "Session active") {
                    ActionButton("Sessions", symbol: "clock.arrow.circlepath") {
                        showingSessions = true
                        focusBackButton = true
                        focusHistoryNavigation = true
                    }
                    .focused($focusSessionsButton)
                    .accessibilityFocused($focusTimerNavigation)
                    .accessibilityIdentifier("focus-sessions")
                }
                if case .failed = service.readState {
                    ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: { service.retryRead() })
                        .accessibilityIdentifier("focus-read-error")
                    Text("Active session status is unknown. Starting is unavailable until Focus can load.")
                        .appTypography(.body)
                } else if service.readState == .notLoaded {
                    LoadingState("Loading Focus")
                } else if let active = service.activeSession {
                    // The committed session takes precedence over stale local drafts in every window.
                    if service.completionPendingError != nil {
                        completionPendingContent(active)
                    } else if active.recoveryRequired {
                        recoveryContent(active)
                    } else {
                        timerContent(active)
                    }
                } else {
                    readyContent
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .padding(.bottom, AppMetrics.space8)
        .fixedSize(horizontal: false, vertical: true) // AppShell scrolls overflow at enlarged text sizes.
        .onAppear {
            if taskStore.readState == .notLoaded { taskStore.refresh() }
            learningStore.loadIfNeeded()
            refreshDefault()
        }
        .onChange(of: preferencesStore.committed) { _, _ in refreshDefault() }
        .onChange(of: preferencesStore.state) { _, _ in refreshDefault() }
        .onChange(of: service.activeSession?.id) { old, new in
            if old != nil && new == nil { resetDraft() }
        }
    }

    private func refreshDefault() {
        guard service.activeSession == nil else { return }
        draft.followPreferences(preferencesStore.editableSnapshot)
    }

    private func resetDraft() {
        draft = FocusReadyDraft(preferences: preferencesStore.editableSnapshot)
        startError = nil
    }

    private func recoveryContent(_ session: FocusSessionSnapshot) -> some View {
        let recovery = FocusRecoveryPresentation(session: session)
        let failedChoice: FocusRecoveryChoice? = {
            if case .recover(let choice) = service.mutationFailure?.action { return choice }
            return nil
        }()
        return VStack(alignment: .leading, spacing: AppMetrics.space6) {
            StatusPill("Interrupted", kind: .warning)
                .accessibilityIdentifier("focus-recovery-state")
            Text("Resume session?").appTypography(.section)
            Text(recovery.title).appTypography(.body)
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                Text("\(recovery.recorded) recorded")
                    .accessibilityIdentifier("focus-recovery-recorded")
                Text("\(recovery.remaining) remaining · Paused while you decide")
                    .accessibilityIdentifier("focus-recovery-remaining")
            }
            .appTypography(.body)
            Text("Resuming or ending this session does not complete a linked task.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            if let failedChoice {
                ErrorBanner(.saveFailed, recoveryTitle: "Retry \(failedChoice == .resume ? "Resume" : "End session")",
                            recovery: { retryAction() })
                    .accessibilityIdentifier("focus-recovery-error")
                Text("The decision was not saved. This session is still interrupted; retry before starting another.")
                    .appTypography(.metadata)
            } else if let actionError, actionError.sessionID == session.id, actionError.state == session.state {
                Text(actionError.message).appTypography(.metadata).foregroundStyle(AppColors.error)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space3) { recoveryActions(enabled: failedChoice == nil) }
                VStack(alignment: .leading, spacing: AppMetrics.space3) { recoveryActions(enabled: failedChoice == nil) }
            }
            ActionButton("Start new session (decision pending)", isEnabled: false) {}
                .accessibilityIdentifier("focus-recovery-start-disabled")
        }
    }

    @ViewBuilder
    private func recoveryActions(enabled: Bool) -> some View {
        ActionButton("End session", symbol: "stop.fill", isEnabled: enabled) {
            resolveRecovery(.end)
        }
        .accessibilityIdentifier("focus-recovery-end")
        ActionButton("Resume", symbol: "play.fill", variant: .primary, isEnabled: enabled) {
            resolveRecovery(.resume)
        }
        .accessibilityIdentifier("focus-recovery-resume")
    }

    private func resolveRecovery(_ choice: FocusRecoveryChoice) {
        do {
            try service.resolveRecovery(choice)
            actionError = nil
        } catch {
            if let session = service.activeSession {
                actionError = (session.id, session.state,
                    "The decision could not be saved. The session is still interrupted; try again.")
            }
        }
    }

    private func completionPendingContent(_ session: FocusSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            StatusPill("Completion pending", kind: .error)
                .accessibilityIdentifier("focus-completion-pending-state")
            Text("00:00")
                .font(.system(size: countdownFontSize, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppColors.accent)
                .accessibilityLabel("Time remaining: zero; completion not saved")
                .accessibilityIdentifier("focus-completion-pending-countdown")
            Text(session.linkedTitleSnapshot ?? "Focus session").appTypography(.section)
            Text("Planned time reached. This session is not yet recorded as Completed. Today's committed total and Sessions remain unchanged until saving succeeds.")
                .appTypography(.body)
            Text("Focus never marks a linked task complete.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            ErrorBanner(.saveFailed, recoveryTitle: "Retry saving completion", recovery: {
                do {
                    try service.retryCompletion()
                    actionError = nil
                } catch {
                    actionError = (session.id, session.state, "Completion still could not be saved. Retry saving to resolve it.")
                }
            })
            .accessibilityIdentifier("focus-completion-pending-error")
            if let actionError, actionError.sessionID == session.id, actionError.state == session.state {
                Text(actionError.message).appTypography(.metadata).foregroundStyle(AppColors.error)
            }
            Text("No extra focused time is being added.")
                .appTypography(.metadata)
                .foregroundStyle(AppColors.textSecondary)
            ActionButton("Start new session (save pending)", isEnabled: false) {}
                .accessibilityIdentifier("focus-completion-start-disabled")
        }
    }

    private func timerContent(_ session: FocusSessionSnapshot) -> some View {
        let timer = FocusTimerPresentation(session: session,
            countdownSeconds: service.countdownSeconds ?? session.plannedSeconds)
        return VStack(alignment: .leading, spacing: AppMetrics.space6) {
            StatusPill(timer.stateText, kind: session.state == .running ? .success : .warning)
                .accessibilityIdentifier("focus-timer-state")
            Text(timer.countdown)
                .font(.system(size: countdownFontSize, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppColors.accent)
                .accessibilityLabel("\(timer.stateText), \(timer.countdown) remaining")
                .accessibilityIdentifier("focus-timer-countdown")
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                Text(timer.title).appTypography(.section)
                Text("Started \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                Text(session.state == .running ? "Saved \(timer.actualDuration)" : timer.actualDuration)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                if session.state == .paused, let pausedAt = session.pausedAt {
                    Text("Paused at \(pausedAt.formatted(date: .omitted, time: .shortened)) · Paused time is excluded")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppMetrics.space3) { timerActions(session) }
                VStack(alignment: .leading, spacing: AppMetrics.space3) { timerActions(session) }
            }
            if let failure = service.mutationFailure,
               failure.action == (session.state == .running ? .pause : .resume) || failure.action == .end {
                ErrorBanner(.saveFailed, recoveryTitle: "Retry action", recovery: { retryAction() })
                    .accessibilityIdentifier("focus-action-error")
                Text("\(timer.stateText) is still the saved state. Retry the action to save it.")
                    .appTypography(.metadata)
            } else if let actionError, actionError.sessionID == session.id, actionError.state == session.state {
                Text(actionError.message).appTypography(.metadata).foregroundStyle(AppColors.error)
            }
            if service.checkpointError != nil {
                ErrorBanner(.saveFailed, recoveryTitle: "Retry checkpoint", recovery: { service.retryCheckpoint() })
                    .accessibilityIdentifier("focus-checkpoint-error")
                Text("Time is still being counted; the latest checkpoint has not saved.")
                    .appTypography(.metadata)
            }
            let today = service.history(.today)
            VStack(alignment: .leading, spacing: AppMetrics.space2) {
                SectionHeader("Today")
                Text("\(today.groups.flatMap(\.sessions).count) sessions · \(today.todayWholeMinutes) min focused")
                    .appTypography(.body)
                    .accessibilityIdentifier("focus-today-total")
                Text("Completed and ended sessions only; this session is not included.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func timerActions(_ session: FocusSessionSnapshot) -> some View {
        ActionButton(session.state == .running ? "Pause" : "Resume",
                     symbol: session.state == .running ? "pause.fill" : "play.fill", variant: .primary) {
            performAction(session.state == .running ? .pause : .resume)
        }
        .accessibilityIdentifier("focus-timer-primary-action")
        ActionButton("End session", symbol: "stop.fill") {
            performAction(.end)
        }
        .accessibilityIdentifier("focus-timer-end")
    }

    private func performAction(_ action: FocusMutationAction) {
        do {
            switch action {
            case .pause: try service.pause()
            case .resume: try service.resume()
            case .end: try service.end()
            default: return
            }
            actionError = nil
        } catch {
            if let session = service.activeSession {
                actionError = (session.id, session.state,
                    "Action could not be saved. The session is still in its last saved state.")
            }
        }
    }

    private func retryAction() {
        do {
            try service.retryMutation()
            actionError = nil
        } catch {
            if let session = service.activeSession {
                actionError = (session.id, session.state,
                    "Retry did not save. The session remains in its last saved state.")
            }
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            Text((try? draft.duration.seconds()).map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "--:--")
                .font(.system(size: countdownFontSize, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppColors.accent)
                .accessibilityLabel("Ready, \(durationLabel)")
                .accessibilityIdentifier("focus-ready-countdown")

            VStack(alignment: .leading, spacing: AppMetrics.space3) {
                SectionHeader("Duration")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppMetrics.space2) { durationChoices }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) { durationChoices }
                }
                if case .custom = draft.duration {
                    TextField("Minutes", text: Binding(
                        get: { customMinutes },
                        set: { draft.selectDuration(.custom($0)); startError = nil }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Custom duration in whole minutes")
                        .accessibilityIdentifier("focus-custom-minutes")
                }
                Text(durationLabel)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                if let message = draft.fallbackMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .appTypography(.metadata)
                        .accessibilityIdentifier("focus-preferences-fallback")
                }
            }

            VStack(alignment: .leading, spacing: AppMetrics.space3) {
                SectionHeader("Optional task")
                if taskStore.readState != .loaded {
                    ErrorBanner(.readFailed, recoveryTitle: "Retry tasks", recovery: { taskStore.retryRead() })
                    Text("Task choices are unavailable. You can still start without a task.")
                        .appTypography(.metadata)
                }
                AppMenuPicker("Link to task", selection: Binding(
                    get: { draft.linkedTaskID },
                    set: { draft.selectTask($0); startError = nil }
                ), options: [("No task", nil as UUID?)] + openTasks.map { ($0.title, Optional($0.id)) } +
                    (draft.linkedTaskID.map { id in
                        openTasks.contains(where: { $0.id == id }) ? [] : [("Unavailable task — choose again", Optional(id))]
                    } ?? []))
                .frame(maxWidth: 380)
                .accessibilityIdentifier("focus-task-picker")
                if openTasks.isEmpty && taskStore.readState == .loaded {
                    Text("No open tasks. Start without a task, or add one in Tasks.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: AppMetrics.space3) {
                SectionHeader("Optional lesson")
                if lessons == nil {
                    ErrorBanner(.readFailed, recoveryTitle: "Retry learning choices", recovery: {
                        if case .failed = learningStore.state { learningStore.retry() }
                        else { learningStore.loadIfNeeded() }
                    })
                    Text("Lesson choices are unavailable. You can still start without a lesson.")
                        .appTypography(.metadata)
                }
                AppMenuPicker("Link to lesson", selection: Binding(
                    get: { draft.linkedLessonID },
                    set: { draft.selectLesson($0); startError = nil }
                ), options: [("No lesson", nil as String?)] + (lessons ?? []).map { ($0.title, Optional($0.id)) } +
                    (draft.linkedLessonID.map { id in
                        lessons?.contains(where: { $0.id == id }) == true ? [] : [("Unavailable lesson — choose again", Optional(id))]
                    } ?? []))
                .frame(maxWidth: 380)
                .accessibilityIdentifier("focus-lesson-picker")
                if lessons?.isEmpty == true {
                    Text("No available lessons. Start without a lesson or visit Learning.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            if let validationMessage {
                Text(validationMessage)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.error)
                    .accessibilityIdentifier("focus-validation")
            }
            if let startError {
                if startError == .persistenceFailure {
                    ErrorBanner(.saveFailed)
                        .accessibilityIdentifier("focus-start-error")
                }
                Text(startError == .unavailableTask
                     ? "That task changed before Start. Choose another task or No task, then try again."
                     : startError == .unavailableLesson
                     ? "That lesson changed before Start. Retry learning choices or choose another lesson or No link, then try again."
                     : startError == .activeSessionConflict
                     ? "Another window has started a session. Focus can only run one session at a time."
                     : "Start did not save. Your choices are still here; try Start again.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            ActionButton("Start", symbol: "play.fill", variant: .primary,
                         isEnabled: configuration != nil && service.readState.canStart && service.activeSession == nil) {
                start()
            }
            .accessibilityIdentifier("focus-start")
            ActionButton("Cancel configuration") {
                resetDraft()
            }
            .accessibilityIdentifier("focus-cancel-configuration")
        }
    }

    @ViewBuilder private var durationChoices: some View {
        durationButton("15", .fifteen)
        durationButton("25", .twentyFive)
        durationButton("50", .fifty)
        durationButton("Custom", .custom(customMinutes))
    }

    private func durationButton(_ label: String, _ value: FocusDuration) -> some View {
        let selected: Bool
        switch (draft.duration, value) {
        case (.fifteen, .fifteen), (.twentyFive, .twentyFive), (.fifty, .fifty), (.custom, .custom):
            selected = true
        default: selected = false
        }
        return ActionButton(label, variant: selected ? .primary : .secondary) {
            draft.selectDuration(value)
            startError = nil
        }
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func start() {
        guard service.readState.canStart, service.activeSession == nil, let configuration else { return }
        draft.markSubmitted()
        do {
            try service.start(configuration: configuration)
            startError = nil
        } catch {
            startError = error as? FocusError ?? .persistenceFailure
            if startError == .unavailableTask { taskStore.refresh() }
            // Keep the selected ID even if the next read removes it; the user must correct it.
            if startError == .unavailableLesson { learningStore.refresh() }
        }
    }
}
