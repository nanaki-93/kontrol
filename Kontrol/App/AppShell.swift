import SwiftUI

extension AppDestination {
    var title: String {
        switch self {
        case .today: "Today"
        case .learning: "Learning"
        case .projects: "Projects"
        case .focus: "Focus"
        case .tasks: "Tasks"
        case .news: "News"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: "house"
        case .learning: "book"
        case .projects: "folder"
        case .focus: "timer"
        case .tasks: "checkmark.square"
        case .news: "newspaper"
        case .settings: "gearshape"
        }
    }

    var foundationMessage: String {
        switch self {
        case .today: "Nothing planned yet."
        case .learning: "Starter lessons will appear here."
        case .projects: "No projects added yet."
        case .focus: "Focus sessions are not available yet."
        case .tasks: "No tasks captured yet."
        case .news: "News is not available yet."
        case .settings: "No settings available yet."
        }
    }
}

struct AppShell: View {
    @ObservedObject var navigation: NavigationStore
    let dependencies: AppDependencies
    @FocusState private var focusedDestination: AppDestination?

    /// Routing is deliberately limited to the foundation surfaces until their features ship.
    enum ContentKind: Equatable { case today, settings, foundation(AppDestination) }

    static func contentKind(for destination: AppDestination) -> ContentKind {
        switch destination {
        case .today: .today
        case .settings: .settings
        default: .foundation(destination)
        }
    }

    static func navigationTraits(for destination: AppDestination, selected: AppDestination) -> AccessibilityTraits {
        destination == selected ? .isSelected : []
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            ScrollView {
                Group {
                    switch Self.contentKind(for: navigation.selectedDestination) {
                    case .today:
                        TodayView(taskRepository: SwiftDataTaskRepository(container: dependencies.container))
                    case .settings:
                        FoundationSettingsView(dependencies: dependencies)
                    case .foundation(let destination):
                        FoundationView(destination: destination)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
            }
        }
        .background(FoundationStyle.background)
        .foregroundStyle(FoundationStyle.primary)
        .preferredColorScheme(.dark)
    }

    private var navigationBar: some View {
        HStack(spacing: 0) {
            ForEach(AppDestination.allCases, id: \.self) { destination in
                let selected = destination == navigation.selectedDestination
                Button {
                    navigation.select(destination)
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 9) {
                            Image(systemName: destination.symbol)
                                .accessibilityHidden(true)
                            Text(destination.title)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? FoundationStyle.accent : FoundationStyle.secondary)
                        Rectangle()
                            .fill(selected ? FoundationStyle.accent : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedDestination, equals: destination)
                .overlay {
                    if focusedDestination == destination {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(FoundationStyle.primary, lineWidth: 2)
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(destination.title)
                .accessibilityAddTraits(Self.navigationTraits(for: destination, selected: navigation.selectedDestination))
                .accessibilityIdentifier("navigation-\(destination.rawValue)")
            }
        }
        .padding(.horizontal, 20)
        .background(FoundationStyle.background)
        .overlay(alignment: .bottom) { FoundationStyle.border.frame(height: 1) }
    }
}
