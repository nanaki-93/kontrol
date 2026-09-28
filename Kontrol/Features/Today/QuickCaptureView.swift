import SwiftUI

/// Sheet-local state: no SwiftData context or draft record exists until Add succeeds.
@MainActor
final class QuickCaptureDraft: ObservableObject {
    @Published var title = "" {
        didSet { errorMessage = nil }
    }
    @Published private(set) var errorMessage: String?
    private let repository: any TaskRepository

    init(repository: any TaskRepository) {
        self.repository = repository
    }

    var canAdd: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func add(onSuccess: () -> Void) {
        guard canAdd else { return }
        do {
            // nil means the repository captures the current local day and time zone.
            _ = try repository.create(title: title, plannedFor: nil)
            onSuccess()
        } catch {
            // Do not expose user text, store paths, or raw persistence errors.
            errorMessage = "Could not save the task. Your title is still here; try again."
        }
    }
}

private struct CaptureContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct QuickCaptureView: View {
    @StateObject private var draft: QuickCaptureDraft
    // An initial estimate avoids opening a one-point sheet before the first measurement.
    @State private var fieldsHeight: CGFloat = 200
    let onCancel: () -> Void
    let onSaved: () -> Void
    @FocusState private var titleFocused: Bool

    init(repository: any TaskRepository, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: QuickCaptureDraft(repository: repository))
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.space4) {
            Text("New task")
                .appTypography(.dialog)
                .accessibilityAddTraits(.isHeader)
            // Measure the fields at their natural height, but cap the scroll region so
            // the native sheet can always keep its actions outside the overflow area.
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.space4) {
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Title")
                        TextField("Title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                            .accessibilityIdentifier("quick-capture-title")
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Plan for")
                        Text("Today")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Plan for Today")
                            .accessibilityIdentifier("quick-capture-plan")
                    }
                    VStack(alignment: .leading, spacing: AppMetrics.space2) {
                        Text("Due")
                        Text("None")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Due None")
                            .accessibilityIdentifier("quick-capture-due")
                    }
                    if draft.errorMessage != nil {
                        ErrorBanner(.saveFailed)
                            .accessibilityIdentifier("quick-capture-error")
                        Text("Your title is still here; try again.")
                            .appTypography(.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CaptureContentHeightKey.self,
                                               value: geometry.size.height)
                    }
                }
            }
            // Only the fields scroll; the header and native actions stay visible.
            .frame(height: min(fieldsHeight, 400))
            .onPreferenceChange(CaptureContentHeightKey.self) { measured in
                // SwiftUI may emit a transient zero when the native sheet first mounts.
                // Never collapse the only editable field out of the visible scroll area.
                if measured > 0, measured.isFinite { fieldsHeight = measured }
            }
            HStack(spacing: AppMetrics.space3) {
                ActionButton("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("quick-capture-cancel")
                ActionButton("Add", variant: .primary, isEnabled: draft.canAdd) {
                    draft.add(onSuccess: onSaved)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("quick-capture-add")
            }
        }
        .appTypography(.body)
        .padding(AppMetrics.contentInset)
        .frame(width: 520)
        .background(AppColors.surface)
        .foregroundStyle(AppColors.textPrimary)
        .onAppear { titleFocused = true }
    }
}
