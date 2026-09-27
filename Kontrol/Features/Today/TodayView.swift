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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                FoundationStyle.heading("Today")
                Spacer()
                Button {
                    showingCapture = true
                } label: {
                    Text("+ Task")
                }
                .accessibilityLabel("Add task")
                .accessibilityIdentifier("today-add-task")
            }
            Text(displayedDate, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(FoundationStyle.secondary)

            FoundationStyle.section("Next")
                .padding(.top, 14)
            if loadFailed {
                Text("Could not load today's tasks. Return to Today to try again.")
                    .foregroundStyle(FoundationStyle.secondary)
            } else {
                let today = TaskRow.forToday(rows, at: displayedDate, calendar: calendar(), timeZone: timeZone())
                if today.isEmpty {
                    Text("No tasks planned or due today. Use + Task to add one.")
                        .foregroundStyle(FoundationStyle.secondary)
                } else {
                    TaskRows(rows: today)
                }
            }
            Divider().overlay(FoundationStyle.border)
            FoundationStyle.section("Schedule")
            Text("No blocks scheduled for today.")
                .foregroundStyle(FoundationStyle.secondary)
            Divider().overlay(FoundationStyle.border)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 15, design: .monospaced))
        .padding(.horizontal, FoundationStyle.horizontalInset)
        .padding(.top, 32)
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
