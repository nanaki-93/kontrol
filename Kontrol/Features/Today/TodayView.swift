import SwiftUI

struct TodayView: View {
    @ObservedObject var store: TaskStore
    @State private var showingCapture = false
    @FocusState private var addTaskFocused: Bool

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
                TaskRows(rows: today, temporalContext: store.temporalContext)
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
    }
}
