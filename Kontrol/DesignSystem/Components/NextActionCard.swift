import SwiftUI

/// A restrained next-action treatment, not an actionable surface itself. Only a
/// caller-supplied control can act; no scheduling or persistence lives here.
struct NextActionCard<Action: View>: View {
    let title: String
    let metadata: String?
    let status: StatusPill?
    private let action: Action
    private let hasAction: Bool

    init(_ title: String, metadata: String? = nil, status: StatusPill? = nil,
         @ViewBuilder action: () -> Action) {
        self.title = title
        self.metadata = metadata
        self.status = status
        self.action = action()
        self.hasAction = true
    }

    var body: some View {
        if hasAction {
            AppListRow(title, metadata: metadata, status: status, isNextAction: true) { action }
        } else {
            AppListRow(title, metadata: metadata, status: status, isNextAction: true)
        }
    }
}

extension NextActionCard where Action == EmptyView {
    init(_ title: String, metadata: String? = nil, status: StatusPill? = nil) {
        self.title = title
        self.metadata = metadata
        self.status = status
        self.action = EmptyView()
        self.hasAction = false
    }
}
