import SwiftUI

struct TodayView: View {
    let taskRepository: any TaskRepository
    var now: () -> Date = Date.init
    var calendar: () -> Calendar = { .current }
    var timeZone: () -> TimeZone = { .current }
    @State private var showingCapture = false
    @State private var rows: [TaskRow] = []
    @State private var loadFailed = false
    @State private var displayedDate = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            PageHeader("Today", metadata: displayedDate.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                ActionButton("Add task", symbol: "plus", variant: .primary) {
                    showingCapture = true
                }
                .accessibilityIdentifier("today-add-task")
            }

            SectionHeader("Next")
                .padding(.top, AppMetrics.space2)
            if loadFailed {
                ErrorBanner(.readFailed)
            } else {
                let today = TaskRow.forToday(rows, at: displayedDate, calendar: calendar(), timeZone: timeZone())
                if today.isEmpty {
                    EmptyState("No tasks planned or due today.", guidance: "Use Add task to capture one.")
                } else {
                    TaskRows(rows: today)
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
        .onAppear(perform: refresh)
        .sheet(isPresented: $showingCapture) {
            QuickCaptureView(repository: taskRepository, onCancel: {
                showingCapture = false
            }, onSaved: {
                showingCapture = false
                refresh()
            })
        }
    }

    private func refresh() {
        displayedDate = now()
        do {
            rows = try taskRepository.fetchAll().map(TaskRow.init)
            loadFailed = false
        } catch {
            rows = []
            loadFailed = true
        }
    }
}
