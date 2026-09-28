import SwiftUI

struct TodayView: View {
    @ObservedObject var store: TaskStore
    var now: () -> Date = Date.init
    var calendar: () -> Calendar = { .current }
    var timeZone: () -> TimeZone = { .current }
    @State private var showingCapture = false
    @FocusState private var addTaskFocused: Bool
    @State private var displayedDate = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Today", metadata: displayedDate.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                ActionButton("Add task", symbol: "plus", variant: .primary) {
                    showingCapture = true
                }
                .accessibilityIdentifier("today-add-task")
                .focused($addTaskFocused)
            }

            SectionHeader("Next")
                .padding(.top, AppMetrics.space2)
            if let message = store.readState.message {
                ErrorBanner(.readFailed, recoveryTitle: "Retry", recovery: store.retryRead)
                Text(message)
                    .appTypography(.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
            let today = TaskSelection.select(store.snapshots, filter: .today,
                                             selectedDate: displayedDate, now: displayedDate,
                                             calendar: calendar(), timeZone: timeZone())
            if store.readState == .loaded && today.isEmpty {
                EmptyState("No tasks planned or due today.", guidance: "Use Add task to capture one.")
            } else if !today.isEmpty {
                TaskRows(rows: today.map(TaskRow.init))
            }
            Divider().overlay(AppColors.border)
            SectionHeader("Schedule")
            EmptyState("Scheduling isn't available yet.")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.horizontalInset)
        .padding(.top, AppMetrics.space8)
        .onAppear {
            displayedDate = now()
            store.refresh()
        }
        .sheet(isPresented: $showingCapture, onDismiss: {
            // Wait for the native sheet to finish closing before returning keyboard focus.
            addTaskFocused = true
        }) {
            QuickCaptureView(repository: store.repository, onCancel: {
                showingCapture = false
            }, onSaved: {
                showingCapture = false
                store.refresh()
            })
        }
    }
}
