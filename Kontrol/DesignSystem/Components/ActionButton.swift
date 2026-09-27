import SwiftUI

/// A presentation-only native action. Callers keep ownership of shortcuts, AX identifiers,
/// enabled/busy state, and the callback (including any asynchronous work).
struct ActionButton: View {
    enum Variant {
        case primary, secondary, destructive
    }

    let title: String
    let symbol: String?
    let variant: Variant
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    init(_ title: String, symbol: String? = nil, variant: Variant = .secondary,
         isEnabled: Bool = true, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.variant = variant
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button {
            // Guard even if a stale AX press or shortcut reaches the disabled native control.
            guard isEnabled && !isBusy else { return }
            action()
        } label: {
            HStack(spacing: AppMetrics.space2) {
                if let symbol, !symbol.isEmpty {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if isBusy {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
            }
            .appTypography(.action)
            .frame(minWidth: AppMetrics.minimumTarget, minHeight: AppMetrics.minimumTarget)
            .padding(.horizontal, AppMetrics.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionButtonStyle(variant: variant, isHovered: isHovered,
                                       isFocused: isFocused, isAvailable: isEnabled && !isBusy))
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(title)
        .accessibilityValue(isBusy ? "In progress" : "")
    }
}

private struct ActionButtonStyle: ButtonStyle {
    let variant: ActionButton.Variant
    let isHovered: Bool
    let isFocused: Bool
    let isAvailable: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isAvailable
        return configuration.label
            .foregroundStyle(foreground(pressed: pressed))
            .background(background(pressed: pressed), in: RoundedRectangle(cornerRadius: AppMetrics.smallRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                    .strokeBorder(boundary(pressed: pressed), lineWidth: 1)
            }
            // Offset the focus ring onto the surrounding dark surface. On an accent fill,
            // an inset light ring would miss the 3:1 focus-boundary contrast threshold.
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                        .strokeBorder(AppColors.focusRing, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isAvailable ? 1 : 0.55)
    }

    private func foreground(pressed: Bool) -> Color {
        switch variant {
        case .primary: pressed ? AppColors.textPrimary : AppColors.textOnAccent
        case .secondary: AppColors.textPrimary
        case .destructive: AppColors.error
        }
    }

    private func background(pressed: Bool) -> Color {
        if pressed { return variant == .primary ? AppColors.surface : AppColors.background }
        if isHovered && isAvailable && variant != .primary { return AppColors.raisedSurface }
        return variant == .primary ? AppColors.accent : AppColors.surface
    }

    private func boundary(pressed: Bool) -> Color {
        if pressed || (isHovered && isAvailable) { return AppColors.focusRing }
        switch variant {
        case .primary: return AppColors.accent
        case .secondary: return AppColors.controlBoundary
        case .destructive: return AppColors.error
        }
    }
}
