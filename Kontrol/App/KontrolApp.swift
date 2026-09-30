import AppKit
import SwiftData
import SwiftUI

/// Close is vetoed before SwiftUI tears down the window. The delegate is retained
/// by the view coordinator and forwards other window delegate messages to SwiftUI.
struct WindowCloseGuard: NSViewRepresentable {
    let flush: () -> Bool
    let onBecomeKey: () -> Void

    init(flush: @escaping () -> Bool, onBecomeKey: @escaping () -> Void = {}) {
        self.flush = flush
        self.onBecomeKey = onBecomeKey
    }

    final class GuardView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.install(window)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var flush: () -> Bool
        var onBecomeKey: () -> Void
        weak var window: NSWindow?
        weak var previous: (any NSWindowDelegate)?

        init(flush: @escaping () -> Bool, onBecomeKey: @escaping () -> Void) {
            self.flush = flush
            self.onBecomeKey = onBecomeKey
        }

        func windowDidBecomeKey(_ notification: Notification) {
            onBecomeKey()
            previous?.windowDidBecomeKey?(notification)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard flush() else { return false }
            return previous?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            selector == #selector(NSWindowDelegate.windowShouldClose(_:)) ||
                selector == #selector(NSWindowDelegate.windowDidBecomeKey(_:)) ||
                super.responds(to: selector) || previous?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
        }

        func install(_ window: NSWindow?) {
            guard let window, self.window !== window else { return }
            uninstall()
            previous = window.delegate
            self.window = window
            window.delegate = self
            // Installation may follow the key notification during SwiftUI view setup.
            if window.isKeyWindow { onBecomeKey() }
        }

        func uninstall() {
            if window?.delegate === self { window?.delegate = previous }
            window = nil
            previous = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(flush: flush, onBecomeKey: onBecomeKey) }
    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: GuardView, context: Context) {
        context.coordinator.flush = flush
        context.coordinator.onBecomeKey = onBecomeKey
        context.coordinator.install(view.window)
    }
    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) { coordinator.uninstall() }
}

@MainActor
final class KontrolLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var navigation: NavigationStore?

    func applicationDidResignActive(_ notification: Notification) {
        _ = navigation?.flushForLifecycle()
    }

    func flushBeforeTermination() -> Bool {
        navigation?.flushForLifecycle() ?? true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !flushBeforeTermination() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Changes were not saved"
        alert.informativeText = "Retry saving before quitting, or cancel quit to keep your answer. Forced termination cannot save pending edits."
        alert.addButton(withTitle: "Retry Save")
        alert.addButton(withTitle: "Cancel Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return flushBeforeTermination() ? .terminateNow : .terminateCancel
    }
}


/// Opt-in Debug smoke path for signed-app recovery checks. It never opens the
/// production store: the first attempt fails before any IO and Retry opens a
/// unique store beneath the app's sandbox temporary directory.
@MainActor
func makeAppLaunchCoordinator(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
) -> LaunchCoordinator {
    #if DEBUG
    if environment["KONTROL_F00_RECOVERY_TEST"] == "1" {
        let directory = temporaryDirectory.appendingPathComponent(
            "KontrolF00Recovery-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Kontrol.store")
        var attempts = 0
        return LaunchCoordinator(open: {
            attempts += 1
            if attempts == 1 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try ModelContainerFactory().makeContainer(mode: .persistent(storeURL))
        })
    }
    #endif
    return LaunchCoordinator()
}

@main
struct KontrolApp: App {
    static let bootstrapTitle = "Kontrol"
    @StateObject private var launch = makeAppLaunchCoordinator()
    @StateObject private var navigation = NavigationStore()
    @NSApplicationDelegateAdaptor(KontrolLifecycleDelegate.self) private var lifecycle

    var body: some Scene {
        WindowGroup {
            MainWindowContent(launch: launch, navigation: navigation, lifecycle: lifecycle)
                .frame(minWidth: 1000, minHeight: 700)
        }
        Settings {
            SettingsSceneContent(launch: launch)
        }
        .defaultSize(width: 520, height: 340)
    }
}

/// Both scene entry points share the app-scoped coordinator. Reopening the main
/// window only asks an already-ready coordinator to start (a no-op).
struct MainWindowContent: View {
    @ObservedObject var launch: LaunchCoordinator
    @ObservedObject var navigation: NavigationStore
    var lifecycle: KontrolLifecycleDelegate? = nil
    @State private var recoveryFailure: LaunchFailure?

    var body: some View {
        Group {
            if let dependencies = launch.dependencies, launch.state == .ready {
                AppShell(navigation: navigation, dependencies: dependencies)
                    .appAccessibilityPreferences(dependencies.appPreferencesStore)
                    .modelContainer(dependencies.container)
                    .onAppear {
                        navigation.attachDrafts(dependencies.lessonDraftStore)
                        lifecycle?.navigation = navigation
                    }
            } else if case .failed(let failure) = launch.state {
                RecoveryView(failure: failure, launch: launch, onRetry: {
                    recoveryFailure = failure
                    Task { await launch.retry() }
                })
            } else if launch.state == .opening, let recoveryFailure {
                RecoveryView(failure: recoveryFailure, launch: launch)
            } else if launch.state == .opening {
                LoadingState("Opening Kontrol")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.background)
            } else {
                Text(KontrolApp.bootstrapTitle)
            }
        }
        .onChange(of: launch.state) { _, newState in
            if case .failed(let failure) = newState { recoveryFailure = failure }
            if newState == .ready { recoveryFailure = nil }
        }
        .preferredColorScheme(.dark)
        .task { await launch.start() }
    }
}

struct SettingsSceneContent: View {
    @ObservedObject var launch: LaunchCoordinator
    @State private var recoveryFailure: LaunchFailure?

    var body: some View {
        Group {
            if let dependencies = launch.dependencies, launch.state == .ready {
                ScrollView {
                    FoundationSettingsView(dependencies: dependencies)
                        .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
                }
                .background(AppColors.background)
                .appAccessibilityPreferences(dependencies.appPreferencesStore)
            } else if case .failed(let failure) = launch.state {
                RecoveryView(failure: failure, launch: launch, onRetry: {
                    recoveryFailure = failure
                    Task { await launch.retry() }
                })
            } else if launch.state == .opening, let recoveryFailure {
                RecoveryView(failure: recoveryFailure, launch: launch)
            } else {
                LoadingState("Opening Kontrol")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.background)
            }
        }
        // Retain the compact baseline without constraining enlarged content to
        // a fixed height. Ready Settings can scroll when the window is small.
        .frame(minWidth: 520, idealWidth: 520, minHeight: 340, idealHeight: 340)
        .preferredColorScheme(.dark)
        .onChange(of: launch.state) { _, newState in
            if case .failed(let failure) = newState { recoveryFailure = failure }
            if newState == .ready { recoveryFailure = nil }
        }
        .task { await launch.start() }
    }
}
