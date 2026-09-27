import SwiftUI

/// Attach to the caller's trigger view. The caller owns presentation and the operation;
/// dismissing with Cancel, Escape, or the window close control never invokes confirm.
struct ConfirmationAffordance: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String?
    let confirmTitle: String
    let cancelTitle: String
    let isDestructive: Bool
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button(cancelTitle, role: .cancel) {}
            Button(confirmTitle, role: isDestructive ? .destructive : nil, action: onConfirm)
        } message: {
            if let message, !message.isEmpty {
                Text(message).appTypography(.body)
            }
        }
    }
}

extension View {
    /// Uses the platform's native alert, including its keyboard and VoiceOver behavior.
    /// Pass reviewed user-facing copy; the component does not construct diagnostics.
    func confirmationAffordance(isPresented: Binding<Bool>, title: String,
                                message: String? = nil, confirmTitle: String,
                                cancelTitle: String, isDestructive: Bool = false,
                                onConfirm: @escaping () -> Void) -> some View {
        modifier(ConfirmationAffordance(isPresented: isPresented, title: title,
                                        message: message, confirmTitle: confirmTitle,
                                        cancelTitle: cancelTitle, isDestructive: isDestructive,
                                        onConfirm: onConfirm))
    }
}
