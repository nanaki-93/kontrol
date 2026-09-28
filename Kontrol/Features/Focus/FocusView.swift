import SwiftUI

/// Unsaved, window-local configuration. A task that disappears stays selected until the
/// user explicitly changes it; the repository checks availability again at commit time.
struct FocusReadyDraft {
    var duration: FocusDuration = .default
    var linkedTaskID: UUID?

    func configuration(openTasks: [TaskSnapshot], tasksReadable: Bool) throws -> FocusConfiguration {
        _ = try duration.seconds()
        if let linkedTaskID {
            guard tasksReadable, openTasks.contains(where: { $0.id == linkedTaskID && !$0.isCompleted }) else {
                throw FocusError.unavailableTask
            }
        }
        return FocusConfiguration(duration: duration, linkedTaskID: linkedTaskID)
    }
}

struct FocusView: View {
    @ObservedObject var service: FocusService
    @ObservedObject var taskStore: TaskStore
    @State private var draft = FocusReadyDraft()
    @State private var customMinutes = ""
    @State private var showingSessions = false
    @State private var startError: FocusError?

    private var openTasks: [TaskSnapshot] {
        taskStore.snapshots.filter { !$0.isCompleted }
            .sorted { $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title }
    }

    private var configuration: FocusConfiguration? {
        try? draft.configuration(openTasks: openTasks, tasksReadable: taskStore.readState == .loaded)
    }

    private var validationMessage: String? {
        do {
            _ = try draft.configuration(openTasks: openTasks, tasksReadable: taskStore.readState == .loaded)
            return nil
        } catch FocusError.unavailableTask {
            return "The selected task is no longer available. Choose another open task or select No task."
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
            PageHeader("Focus", metadata: showingSessions ? "Sessions" : service.activeSession == nil ? "Ready" : "Session active") {
                ActionButton(showingSessions ? "Back to timer" : "Sessions", symbol: "clock.arrow.circlepath") {
                    showingSessions.toggle()
                }
                .accessibilityIdentifier("focus-sessions")
            }
            if showingSessions {
                // Navigation is local to this window; the service and its clock are never recreated.
                Text("Recent sessions")
                    .appTypography(.section)
                Text("Session history and filters will appear here.")
                    .appTypography(.body)
                    .foregroundStyle(AppColors.textSecondary)
            } else if case .failed = service.readState {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: { service.retryRead() })
                    .accessibilityIdentifier("focus-read-error")
                Text("Active session status is unknown. Starting is unavailable until Focus can load.")
                    .appTypography(.body)
            } else if service.readState == .notLoaded {
                LoadingState("Loading Focus")
            } else if let active = service.activeSession {
                // The committed session takes precedence over stale local drafts in every window.
                StatusPill(active.recoveryRequired ? "Interrupted" : active.state == .running ? "Running" : "Paused",
                           kind: active.recoveryRequired ? .warning : .success)
                Text("A focus session is active. Configure a new one after this session ends.")
                    .appTypography(.body)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                readyContent
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear { if taskStore.readState == .notLoaded { taskStore.refresh() } }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space6) {
            Text((try? draft.duration.seconds()).map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "--:--")
                .font(.system(size: 64, weight: .medium, design: .monospaced))
                .foregroundStyle(AppColors.accent)
                .accessibilityLabel("Ready, \(durationLabel)")
                .accessibilityIdentifier("focus-ready-countdown")

            VStack(alignment: .leading, spacing: AppMetrics.space3) {
                SectionHeader("Duration")
                HStack(spacing: AppMetrics.space2) {
                    durationButton("15", .fifteen)
                    durationButton("25", .twentyFive)
                    durationButton("50", .fifty)
                    durationButton("Custom", .custom(customMinutes))
                }
                if case .custom = draft.duration {
                    TextField("Minutes", text: $customMinutes)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Custom duration in whole minutes")
                        .accessibilityIdentifier("focus-custom-minutes")
                        .onChange(of: customMinutes) { _, value in draft.duration = .custom(value) }
                }
                Text(durationLabel)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }

            VStack(alignment: .leading, spacing: AppMetrics.space3) {
                SectionHeader("Optional task")
                if taskStore.readState != .loaded {
                    ErrorBanner(.readFailed, recoveryTitle: "Retry tasks", recovery: { taskStore.retryRead() })
                    Text("Task choices are unavailable. You can still start without a task.")
                        .appTypography(.metadata)
                }
                Picker("Link to task", selection: $draft.linkedTaskID) {
                    Text("No task").tag(nil as UUID?)
                    ForEach(openTasks) { task in Text(task.title).tag(task.id as UUID?) }
                    if let id = draft.linkedTaskID, !openTasks.contains(where: { $0.id == id }) {
                        Text("Unavailable task — choose again").tag(id as UUID?)
                    }
                }
                .frame(maxWidth: 380)
                .accessibilityIdentifier("focus-task-picker")
                if openTasks.isEmpty && taskStore.readState == .loaded {
                    Text("No open tasks. Start without a task, or add one in Tasks.")
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
                draft = FocusReadyDraft()
                customMinutes = ""
                startError = nil
            }
            .accessibilityIdentifier("focus-cancel-configuration")
        }
    }

    private func durationButton(_ label: String, _ value: FocusDuration) -> some View {
        let selected: Bool
        switch (draft.duration, value) {
        case (.fifteen, .fifteen), (.twentyFive, .twentyFive), (.fifty, .fifty), (.custom, .custom):
            selected = true
        default: selected = false
        }
        return ActionButton(label, variant: selected ? .primary : .secondary) {
            draft.duration = value
            startError = nil
        }
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func start() {
        guard service.readState.canStart, service.activeSession == nil, let configuration else { return }
        do {
            try service.start(configuration: configuration)
            startError = nil
        } catch {
            startError = error as? FocusError ?? .persistenceFailure
            if startError == .unavailableTask { taskStore.refresh() }
        }
    }
}
