import SwiftUI

/// A decorative symbol and visible label exposed as one accessibility name.
struct IconLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: AppMetrics.space2) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
