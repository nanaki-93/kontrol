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

struct QuickCaptureView: View {
    @StateObject private var draft: QuickCaptureDraft
    let onCancel: () -> Void
    let onSaved: () -> Void
    @FocusState private var titleFocused: Bool

    init(repository: any TaskRepository, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: QuickCaptureDraft(repository: repository))
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New task")
                .font(.system(size: 24, design: .monospaced))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .accessibilityIdentifier("quick-capture-title")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan for")
                Text("Today")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Plan for Today")
                    .accessibilityIdentifier("quick-capture-plan")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Due")
                Text("None")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Due None")
                    .accessibilityIdentifier("quick-capture-due")
            }
            if let error = draft.errorMessage {
                Text(error)
                    .foregroundStyle(FoundationStyle.accent)
                    .accessibilityIdentifier("quick-capture-error")
            }
            Spacer(minLength: 16)
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("quick-capture-cancel")
                Button("Add") { draft.add(onSuccess: onSaved) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canAdd)
                    .accessibilityIdentifier("quick-capture-add")
            }
        }
        .font(.system(size: 14, design: .monospaced))
        .padding(28)
        .frame(width: 520, height: 350)
        .background(FoundationStyle.surface)
        .foregroundStyle(FoundationStyle.primary)
        .onAppear { titleFocused = true }
    }
}
