import SwiftUI

struct TodayView: View {
    @ObservedObject var store: TaskStore
    @State private var showingCapture = false
    @State private var presentation: EditorPresentation?
    @State private var editorOpenError = false
    @State private var actionError: TaskMutationError?
    @State private var lastEditorTriggerID: UUID?
    @FocusState private var addTaskFocused: Bool
    @FocusState private var editFocusedID: UUID?

    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let draft: TaskEditorDraft
    }

    private func edit(_ row: TaskSnapshot) {
        do {
            presentation = EditorPresentation(draft: try TaskEditorDraft(editing: row, in: store))
            editorOpenError = false
        } catch {
            editorOpenError = true
            store.refresh()
        }
    }

    private func setCompleted(_ row: TaskSnapshot, completed: Bool) {
        do {
            try store.setCompleted(id: row.id, completed: completed)
            actionError = nil
        } catch {
            actionError = store.mutationError ?? .writeFailed
        }
    }

    private var localDateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.calendar = store.temporalContext.calendar
        style.timeZone = store.temporalContext.timeZone
        return style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Today", metadata: store.temporalContext.now.formatted(localDateStyle)) {
                ActionButton("Add task", symbol: "plus", variant: .primary) {
                    showingCapture = true
                }
                .accessibilityIdentifier("today-add-task")
                .focused($addTaskFocused)
            }

            SectionHeader("Next")
                .padding(.top, AppMetrics.space2)
            if editorOpenError {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: {
                    editorOpenError = false
                    store.retryRead()
                })
                Text("Could not open this task. Refresh the list and try again.")
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if let actionError {
                switch actionError {
                case .writeFailed:
                    ErrorBanner(.saveFailed)
                        .accessibilityIdentifier("today-action-error")
                    Text("\(actionError.message) Use the task action again to retry.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                case .notFound:
                    Text("This task is no longer available. Refresh the list or choose another task.")
                        .appTypography(.metadata)
                        .foregroundStyle(AppColors.error)
                        .accessibilityIdentifier("today-action-error")
                    ActionButton("Refresh tasks") {
                        store.retryRead()
                        self.actionError = nil
                    }
                    .accessibilityIdentifier("today-action-refresh")
                }
            }
            if let message = store.readState.message {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: store.retryRead)
                Text(message)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            let today = store.select(.today)
            if store.readState == .loaded && today.isEmpty {
                EmptyState("No tasks planned or due today.", guidance: "Use Add task to capture one.")
            } else if !today.isEmpty {
                ScrollView {
                    TaskRows(rows: today, temporalContext: store.temporalContext, onEdit: { row in
                        lastEditorTriggerID = row.id
                        edit(row)
                    }, onSetCompleted: setCompleted, editFocus: $editFocusedID)
                }
            }
            Divider().overlay(AppColors.border)
            SectionHeader("Schedule")
            EmptyState("Scheduling isn't available yet.")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear { store.refresh() }
        .sheet(isPresented: $showingCapture, onDismiss: {
            // Wait for the native sheet to finish closing before returning keyboard focus.
            addTaskFocused = true
        }) {
            QuickCaptureView(store: store, onCancel: {
                showingCapture = false
            }, onSaved: {
                showingCapture = false
            })
        }
        .sheet(item: $presentation, onDismiss: {
            if let id = lastEditorTriggerID, store.select(.today).contains(where: { $0.id == id }) {
                editFocusedID = id
            } else {
                addTaskFocused = true
            }
            lastEditorTriggerID = nil
        }) { item in
            TaskEditorView(draft: item.draft, onCancel: {
                presentation = nil
            }, onSaved: {
                presentation = nil
            }, onMissingTask: {
                presentation = nil
            })
        }
    }
}
