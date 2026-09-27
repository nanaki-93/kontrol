import AppKit
import SwiftUI

/// A blocking startup surface: the decorative navigation is intentionally not
/// interactive until the catalog and store have both opened successfully.
struct RecoveryView: View {
    let failure: LaunchFailure
    @ObservedObject var launch: LaunchCoordinator
    var onQuit: () -> Void = { NSApp.terminate(nil) }
    var onRetry: (() -> Void)? = nil
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable { case quit, retry }

    private func cardOffset(for height: CGFloat) -> CGFloat {
        // Leave room for the dimmed context at the smaller reference size.
        if height >= 800 { return -110 }
        if height >= 600 { return -75 }
        return 0
    }

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
            // The native Settings scene is 520×340. Keep the M01 chrome at
            // reference sizes, but give its actions priority in small windows.
            let compact = geometry.size.height < 500
            VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("KONTROL_")
                    .foregroundStyle(FoundationStyle.primary)
                Spacer()
            }
            .font(.system(size: 16, design: .monospaced))
            .padding(.horizontal, FoundationStyle.horizontalInset)
            .frame(height: compact ? 42 : 66)
            .overlay(alignment: .bottom) { FoundationStyle.border.frame(height: 1) }
            .accessibilityHidden(true)

            if !compact {
            // This is M01's frozen shell context, not the usable AppShell: no
            // destinations are reachable before the store and catalog open.
            HStack(spacing: 0) {
                ForEach(AppDestination.allCases, id: \.self) { destination in
                    VStack(spacing: 0) {
                        Label(destination.title, systemImage: destination.symbol)
                            .frame(maxWidth: .infinity, minHeight: 65)
                            .foregroundStyle(destination == .today
                                ? FoundationStyle.accent : FoundationStyle.secondary)
                        Rectangle()
                            .fill(destination == .today ? FoundationStyle.accent : .clear)
                            .frame(height: 2)
                    }
                }
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(.horizontal, 20)
            .frame(height: 67)
            .overlay(alignment: .bottom) { FoundationStyle.border.frame(height: 1) }
            .accessibilityHidden(true)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                Text("Kontrol")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                Text(contextMessage)
                    .font(.system(size: 14, design: .monospaced))
            }
            .foregroundStyle(FoundationStyle.secondary.opacity(0.14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FoundationStyle.horizontalInset)
            .padding(.top, 32)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            }

            Spacer(minLength: compact ? 8 : 16)
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 25, weight: .medium, design: .monospaced))
                    .foregroundStyle(FoundationStyle.primary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("recovery-title")
                Text(guidance)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(FoundationStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recovery-guidance")
                Spacer(minLength: compact ? 8 : 24)
                HStack(spacing: 10) {
                    Button("Quit", action: onQuit)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(FoundationStyle.background)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(FoundationStyle.border))
                        .focusable()
                        .focused($focusedAction, equals: .quit)
                        .overlay {
                            if focusedAction == .quit {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(FoundationStyle.primary, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier("recovery-quit")
                    Button("Try again") {
                        if let onRetry { onRetry() }
                        else { Task { await launch.retry() } }
                    }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .foregroundStyle(FoundationStyle.background)
                        .background(FoundationStyle.accent, in: RoundedRectangle(cornerRadius: 4))
                        .focusable()
                        .focused($focusedAction, equals: .retry)
                        .overlay {
                            if focusedAction == .retry {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(FoundationStyle.primary, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .disabled(launch.state == .opening)
                        .accessibilityIdentifier("recovery-retry")
                }
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(FoundationStyle.primary)
            }
            .padding(compact ? 18 : 28)
            .frame(maxWidth: 680, minHeight: compact ? 0 : 190,
                   maxHeight: compact ? nil : 265, alignment: .topLeading)
            .background(FoundationStyle.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(FoundationStyle.border))
            .padding(.horizontal, 24)
            .offset(y: compact ? 0 : cardOffset(for: geometry.size.height))
            Spacer(minLength: compact ? 8 : 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FoundationStyle.background)
        .preferredColorScheme(.dark)
        .onAppear { focusedAction = .retry }
        }
    }
}
