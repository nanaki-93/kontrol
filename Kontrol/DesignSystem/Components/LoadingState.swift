import SwiftUI

/// A passive indication of caller-owned work. Reduced motion uses a static determinate
/// track instead of an indeterminate spinner; the visible loading label remains unchanged.
struct LoadingState: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.loadingReduceMotionOverride) private var previewReduceMotion

    private var reduceMotion: Bool { previewReduceMotion ?? systemReduceMotion }

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        HStack(spacing: AppMetrics.space3) {
            Group {
                if reduceMotion {
                    ProgressView(value: 0, total: 1)
                } else {
                    ProgressView()
                }
            }
            .controlSize(.small)
            .frame(width: AppMetrics.preferredTarget)
            .accessibilityHidden(true)
            Text(label)
                .appTypography(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Loading: \(label)")
        }
        .foregroundStyle(AppColors.textPrimary)
    }
}

/// Test/preview-only input. The system setting remains the default in production.
private struct LoadingReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var loadingReduceMotionOverride: Bool? {
        get { self[LoadingReduceMotionOverrideKey.self] }
        set { self[LoadingReduceMotionOverrideKey.self] = newValue }
    }
}
