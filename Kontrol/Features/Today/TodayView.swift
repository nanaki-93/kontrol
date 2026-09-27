import SwiftUI

/// No personal records are seeded on first launch. Capture and persisted rows arrive in 4.2/4.3.
struct TodayView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FoundationStyle.heading("Today")
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(FoundationStyle.secondary)

            FoundationStyle.section("Next")
                .padding(.top, 14)
            Text("Nothing planned yet.")
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
        .accessibilityIdentifier("today-content")
    }
}
