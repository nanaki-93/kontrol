import AppKit
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
        case .learning: "Included starter content is available offline."
        case .projects: "Projects are available in the Projects tab."
        case .focus: "Focus"
        case .tasks: "No tasks captured yet."
        case .news: "News"
        case .settings: "No settings available yet."
        }
    }
}

struct AppShell: View {
    @ObservedObject var navigation: NavigationStore
    let dependencies: AppDependencies
    @FocusState private var focusedDestination: AppDestination?
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.appTextScaleOverride) private var previewTextScale

    /// Every destination now routes to its implemented feature surface.
    enum ContentKind: Equatable { case today, learning, projects, focus, tasks, news, settings }

    static func contentKind(for destination: AppDestination) -> ContentKind {
        switch destination {
        case .today: .today
        case .learning: .learning
        case .projects: .projects
        case .focus: .focus
        case .tasks: .tasks
        case .news: .news
        case .settings: .settings
        }
    }

    static func navigationTraits(for destination: AppDestination, selected: AppDestination) -> AccessibilityTraits {
        destination == selected ? .isSelected : []
    }

    static func showsStayHere(for navigation: NavigationStore) -> Bool {
        navigation.saveError != nil && navigation.pendingTransition != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            if navigation.saveError != nil {
                ErrorBanner(.saveFailed, recoveryTitle: "Retry save") {
                    if navigation.pendingTransition != nil {
                        navigation.retryTransition()
                    } else {
                        _ = navigation.flushForLifecycle()
                    }
                }
                .padding(.horizontal, AppMetrics.contentInset)
                if Self.showsStayHere(for: navigation) {
                    Button("Stay here") { navigation.cancelTransition() }
                        .padding(.horizontal, AppMetrics.contentInset)
                }
            }
            ScrollView {
                Group {
                    switch Self.contentKind(for: navigation.selectedDestination) {
                    case .today:
                        TodayView(store: dependencies.taskStore, scheduleStore: dependencies.scheduleStore,
                                  learningStore: dependencies.learningCatalogStore, navigation: navigation)
                    case .learning:
                        switch navigation.learningRoute {
                        case .choices:
                            LearningView(store: dependencies.learningCatalogStore, navigation: navigation,
                                         generation: dependencies.lessonGenerationStore,
                                         aiSettings: dependencies.aiSettingsStore,
                                         generationRepository: dependencies.catalogRepository)
                        case .detail(let id):
                            LessonExperienceView(lessonID: id, store: dependencies.learningCatalogStore,
                                                 drafts: dependencies.lessonDraftStore, navigation: navigation)
                        case .history:
                            LearningHistoryView(store: dependencies.learningCatalogStore, navigation: navigation)
                        case .historyReference(let id):
                            LearningHistoryView(store: dependencies.learningCatalogStore, navigation: navigation,
                                                initialSelectedID: id)
                                .id(id) // a second reference must not inherit the prior row's local selection
                        case .coverage(let subtopicID):
                            LearningCoverageView(store: dependencies.learningCatalogStore, navigation: navigation,
                                                 selectedSubtopicID: subtopicID)
                        }
                    case .projects:
                        ProjectsView(store: dependencies.projectStore)
                    case .focus:
                        FocusView(service: dependencies.focusService, taskStore: dependencies.taskStore,
                                  learningStore: dependencies.learningCatalogStore,
                                  preferencesStore: dependencies.appPreferencesStore)
                    case .tasks:
                        TasksView(store: dependencies.taskStore)
                    case .news:
                        NewsRouteView(store: dependencies.newsStore)
                    case .settings:
                        FoundationSettingsView(dependencies: dependencies)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
            }
        }
        .background(AppColors.background)
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .onAppear { navigation.attachDrafts(dependencies.lessonDraftStore) }
        .background(WindowCloseGuard(flush: { navigation.flushForLifecycle() },
                                     onBecomeKey: { dependencies.projectStore.refreshOnMainWindowActivation() }))
    }

    private var navigationBar: some View {
        // Explicit contiguous rows retain visual, AX, and native Tab order. Standard
        // text stays on one line; enlarged text never shrinks or drops a label.
        VStack(spacing: 0) {
            if AppTypography.scale(for: systemTextSize, override: previewTextScale) >= 2 {
                navigationRow(Array(AppDestination.allCases[0..<2]))
                navigationRow(Array(AppDestination.allCases[2..<4]))
                navigationRow(Array(AppDestination.allCases[4..<6]))
                navigationRow(Array(AppDestination.allCases[6..<7]))
            } else if AppTypography.scale(for: systemTextSize, override: previewTextScale) >= 1.6 {
                navigationRow(Array(AppDestination.allCases[0..<3]))
                navigationRow(Array(AppDestination.allCases[3..<5]))
                navigationRow(Array(AppDestination.allCases[5..<7]))
            } else if AppTypography.scale(for: systemTextSize, override: previewTextScale) >= 1.3 {
                navigationRow(Array(AppDestination.allCases.prefix(4)))
                navigationRow(Array(AppDestination.allCases.dropFirst(4)))
            } else {
                navigationRow(AppDestination.allCases)
            }
        }
        .padding(.horizontal, AppMetrics.contentInset)
        .background(AppColors.background)
        .overlay(alignment: .bottom) { AppColors.border.frame(height: 1) }
    }

    private func navigationRow(_ destinations: [AppDestination]) -> some View {
        HStack(spacing: 0) {
            ForEach(destinations, id: \.self) { destination in
                let selected = destination == navigation.selectedDestination
                Button {
                    navigation.select(destination)
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: AppMetrics.space2) {
                            Image(systemName: destination.symbol)
                                .accessibilityHidden(true)
                            Text(destination.title)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .appTypography(.navigation)
                        .frame(maxWidth: .infinity, minHeight: AppMetrics.preferredTarget)
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
                        Rectangle()
                            .fill(selected ? AppColors.accent : .clear)
                            .frame(height: 2)
                    }
                    .frame(minWidth: AppMetrics.minimumTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedDestination, equals: destination)
                .overlay {
                    if focusedDestination == destination {
                        RoundedRectangle(cornerRadius: AppMetrics.smallRadius)
                            .strokeBorder(AppColors.focusRing, lineWidth: 2)
                            .padding(-3)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(destination.title)
                .accessibilityAddTraits(Self.navigationTraits(for: destination, selected: navigation.selectedDestination))
                .accessibilityIdentifier("navigation-\(destination.rawValue)")
            }
        }
        .focusSection()
    }
}

/// Routing bridge owns per-window visibility while the shared store owns cached news.
/// The shared owner publishes local cache before its foreground refresh starts.
private struct NewsRouteView: View {
    @ObservedObject var store: NewsStore
    @State private var windowID = UUID()

    var body: some View {
        NewsView(store: store)
        .onAppear {
            store.setAppActive(NSApp.isActive)
            store.setVisible(true, windowID: windowID)
        }
        .onDisappear { store.setVisible(false, windowID: windowID) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.setAppActive(false)
        }
    }
}
