import AppKit
import SwiftUI

/// Blocking recovery: the frozen shell is context only, never a second navigation surface.
struct RecoveryView: View {
    let failure: LaunchFailure
    @ObservedObject var launch: LaunchCoordinator
    var onQuit: () -> Void = { NSApp.terminate(nil) }
    var onRetry: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTextScaleOverride) private var textScaleOverride

    private var title: String {
        switch failure {
        case .store: "Cannot open local data"
        case .catalog: "Cannot load starter lessons"
        }
    }

    private var contextMessage: String {
        switch failure {
        case .store: "Local data unavailable"
        case .catalog: "Starter lessons unavailable"
        }
    }

    private var guidance: String {
        switch failure {
        case .store: "Your data has not been reset. Retry opening it, or quit and try again later."
        case .catalog: "Starter lessons could not be loaded. Your local data has not been reset. Try again, or quit and try again later."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 500
            let scale = AppTypography.scale(for: dynamicTypeSize, override: textScaleOverride)
            let headerHeight: CGFloat = compact ? 42 : 66
            let cardHeight = min(max(0, geometry.size.height - headerHeight - 2 * AppMetrics.space2),
                                 compact ? 300 : (scale >= 1.3 ? 330 : 265))
            VStack(spacing: 0) {
                Text("KONTROL_")
                    .appTypography(.navigation)
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppMetrics.horizontalInset)
                    .frame(height: headerHeight)
                    .overlay(alignment: .bottom) { AppColors.border.frame(height: 1) }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                if !compact {
                    // M01's dimmed, frozen navigation: labels are not controls or AX destinations.
                    HStack(spacing: 0) {
                        ForEach(AppDestination.allCases, id: \.self) { destination in
                            VStack(spacing: 0) {
                                Label(destination.title, systemImage: destination.symbol)
                                    .frame(maxWidth: .infinity, minHeight: 65)
                                    .foregroundStyle(destination == .today ? AppColors.accent : AppColors.textSecondary)
                                Rectangle()
                                    .fill(destination == .today ? AppColors.accent : .clear)
                                    .frame(height: 2)
                            }
                        }
                    }
                    .appTypography(.action)
                    .padding(.horizontal, AppMetrics.space6)
                    .frame(height: 67)
                    .overlay(alignment: .bottom) { AppColors.border.frame(height: 1) }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Kontrol").appTypography(.page)
                        Text(contextMessage).appTypography(.action)
                    }
                    .foregroundStyle(AppColors.textSecondary.opacity(0.14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppMetrics.horizontalInset)
                    .padding(.top, AppMetrics.space8)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }

                Spacer(minLength: AppMetrics.space2)
                VStack(alignment: .leading, spacing: AppMetrics.space3) {
                    // Only the copy scrolls. Quit and Retry stay pinned even when the
                    // title wraps or system text size grows inside the compact scene.
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppMetrics.space3) {
                            Text(title)
                                .appTypography(.dialog)
                                .foregroundStyle(AppColors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("recovery-title")
                            Text(guidance)
                                .appTypography(.body)
                                .foregroundStyle(AppColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("recovery-guidance")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: AppMetrics.space2) {
                        ActionButton("Quit", action: onQuit)
                            .accessibilityIdentifier("recovery-quit")
                        ActionButton("Try again", variant: .primary,
                                     isEnabled: launch.state != .opening,
                                     isBusy: launch.state == .opening) {
                            // The coordinator also gates retry synchronously before suspension.
                            guard launch.state != .opening else { return }
                            if let onRetry { onRetry() }
                            else { Task { await launch.retry() } }
                        }
                        .accessibilityIdentifier("recovery-retry")
                    }
                }
                .padding(compact ? AppMetrics.space4 : AppMetrics.space6)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(height: cardHeight)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppMetrics.mediumRadius))
                .overlay(RoundedRectangle(cornerRadius: AppMetrics.mediumRadius).strokeBorder(AppColors.border))
                .padding(.horizontal, AppMetrics.space6)
                Spacer(minLength: AppMetrics.space2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background)
            .preferredColorScheme(.dark)
        }
    }
}
