import SwiftUI

/// Shared honest placeholder for destinations whose features have not shipped yet.
struct FoundationView: View {
    let destination: AppDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FoundationStyle.heading(destination.title)
            Text(destination.foundationMessage)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(FoundationStyle.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FoundationStyle.horizontalInset)
        .padding(.top, 32)
        .accessibilityIdentifier("\(destination.rawValue)-content")
    }
}
