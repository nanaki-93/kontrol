import SwiftUI

/// Capture is available now; persisted rows arrive in the next foundation step.
struct TodayView: View {
    let taskRepository: any TaskRepository
    @State private var showingCapture = false
    @State private var didSave = false

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
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(FoundationStyle.secondary)

            FoundationStyle.section("Next")
                .padding(.top, 14)
            Text(didSave ? "Task saved. Task lists are coming soon." : "Captured tasks will appear here soon.")
                .foregroundStyle(FoundationStyle.secondary)
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
        .sheet(isPresented: $showingCapture) {
            QuickCaptureView(repository: taskRepository, onCancel: {
                showingCapture = false
            }, onSaved: {
                didSave = true
                showingCapture = false
            })
        }
    }
}
