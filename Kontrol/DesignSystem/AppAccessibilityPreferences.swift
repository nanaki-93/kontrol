import AppKit
import SwiftUI

/// Production inputs are committed values only; nil means unreadable/loading
/// preferences and therefore safe system behavior. Preview overrides stay separate.
struct AppAccessibilityPreferences: Equatable {
    let textSize: DynamicTypeSize
    let reduceMotion: Bool
    var largeTextRequested = false

    static func resolve(_ preferences: AppPreferences?, systemTextSize: DynamicTypeSize,
                        systemReduceMotion: Bool) -> Self {
        Self(textSize: preferences?.textSize == .large ? max(systemTextSize, .xxLarge) : systemTextSize,
             reduceMotion: systemReduceMotion || preferences?.reduceMotion == .reduce,
             largeTextRequested: preferences?.textSize == .large)
    }
}

private struct AppAccessibilityPreferencesKey: EnvironmentKey {
    static let defaultValue: AppAccessibilityPreferences? = nil
}

private struct AppReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Unlike macOS's dynamicTypeSize, this value survives native sheet boundaries.
    var appAccessibilityPreferences: AppAccessibilityPreferences? {
        get { self[AppAccessibilityPreferencesKey.self] }
        set { self[AppAccessibilityPreferencesKey.self] = newValue }
    }

    /// Production reduction in addition to SwiftUI's read-only system input.
    /// Consumers OR this with accessibilityReduceMotion, never replace it.
    var appReduceMotion: Bool {
        get { self[AppReduceMotionKey.self] }
        set { self[AppReduceMotionKey.self] = newValue }
    }
}

private struct AppAccessibilityPreferencesModifier: ViewModifier {
    @ObservedObject var store: AppPreferencesStore
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var inheritedReduceMotion

    func body(content: Content) -> some View {
        let effective = AppAccessibilityPreferences.resolve(
            store.editableSnapshot?.preferences,
            systemTextSize: systemTextSize, systemReduceMotion: systemReduceMotion || inheritedReduceMotion)
        content
            // One effective size feeds shared absolute-point typography, native
            // fields and AppScaledMetric. Never also multiply a scaled metric.
            .environment(\.dynamicTypeSize, effective.textSize)
            .environment(\.appAccessibilityPreferences, effective)
            .font(AppTypography.nativeControlFont(for: effective.textSize))
            .buttonStyle(AccessibleNativeButtonStyle(size: effective.textSize))
            .environment(\.appReduceMotion, effective.reduceMotion)
            .transaction { transaction in
                if effective.reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

/// Automatic macOS buttons choose their own fixed font for a simple text label.
/// Hosting the label as content lets the native bezel/role/keyboard behavior stay
/// native while its glyphs use the same single resolved scale as text fields.
private struct AccessibleNativeButtonStyle: PrimitiveButtonStyle {
    let size: DynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        if size == .large {
            Button(configuration).buttonStyle(.automatic)
        } else {
            Button(role: configuration.role, action: configuration.trigger) {
                HStack(spacing: 0) { configuration.label }
                    .font(AppTypography.nativeControlFont(for: size))
            }.buttonStyle(.automatic)
        }
    }
}

/// macOS SwiftUI menu pickers discard the inherited font. Keep a real native
/// popup (including its menu, keyboard navigation and AX role), but explicitly
/// apply the same absolute-point font as other controls. Options are detached
/// values; rendering or rebuilding a menu never writes the selection binding.
struct AppMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var showsLabel = true
    @Environment(\.dynamicTypeSize) private var systemSize
    @Environment(\.appAccessibilityPreferences) private var effective

    init(_ title: String, selection: Binding<Value>, options: [(String, Value)], showsLabel: Bool = true) {
        self.title = title
        _selection = selection
        self.options = options
        self.showsLabel = showsLabel
    }

    var body: some View {
        HStack {
            if showsLabel { Text(title) }
            NativePopup(selection: $selection, options: options, title: title,
                        size: effective?.textSize ?? systemSize)
        }
    }

    private struct NativePopup: NSViewRepresentable {
        @Binding var selection: Value
        let options: [(String, Value)]
        let title: String
        let size: DynamicTypeSize
        @Environment(\.isEnabled) private var isEnabled

        func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, options: options) }

        func makeNSView(context: Context) -> NSPopUpButton {
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            button.target = context.coordinator
            button.action = #selector(Coordinator.select(_:))
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return button
        }

        func updateNSView(_ button: NSPopUpButton, context: Context) {
            let coordinator = context.coordinator
            coordinator.selection = $selection
            if !coordinator.options.elementsEqual(options, by: { $0.0 == $1.0 && $0.1 == $1.1 }) || button.numberOfItems != options.count {
                button.removeAllItems()
                // addItem(withTitle:) deduplicates titles; real choices may share
                // a name, so add distinct NSMenuItems to preserve value identity.
                for (name, _) in options {
                    button.menu?.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: ""))
                }
            }
            coordinator.options = options
            button.selectItem(at: options.firstIndex { $0.1 == selection } ?? -1)
            let font = AppTypography.nativeNSControlFont(for: size)
            button.font = font
            button.menu?.font = font
            button.isEnabled = isEnabled
            button.setAccessibilityLabel(title)
            button.invalidateIntrinsicContentSize()
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
            let intrinsic = nsView.intrinsicContentSize
            let font = nsView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            // AppKit's regular popup reports a fixed height even for a larger
            // font. Reserve glyph + bezel space so accessibility sizes cannot
            // clip or overlap the next field in SwiftUI's layout.
            let height = max(intrinsic.height, ceil(font.ascender - font.descender + AppMetrics.space2))
            return CGSize(width: min(proposal.width ?? intrinsic.width, intrinsic.width), height: height)
        }

        final class Coordinator: NSObject {
            var selection: Binding<Value>
            var options: [(String, Value)]
            init(selection: Binding<Value>, options: [(String, Value)]) {
                self.selection = selection
                self.options = options
            }
            @objc func select(_ sender: NSPopUpButton) {
                guard sender.isEnabled, options.indices.contains(sender.indexOfSelectedItem) else { return }
                selection.wrappedValue = options[sender.indexOfSelectedItem].1
            }
        }
    }
}

/// Preserve SwiftUI's system metric behavior unless production Large is requested.
/// macOS does not scale @ScaledMetric for app-supplied dynamicTypeSize (and sheets
/// reset it). Apply a minimum in absolute points, not a second multiplier.
@propertyWrapper
struct AppScaledMetric: DynamicProperty {
    @ScaledMetric private var systemValue: CGFloat
    @Environment(\.appAccessibilityPreferences) private var effective
    private let baseValue: CGFloat

    init(wrappedValue: CGFloat, relativeTo style: Font.TextStyle = .body) {
        baseValue = wrappedValue
        _systemValue = ScaledMetric(wrappedValue: wrappedValue, relativeTo: style)
    }

    var wrappedValue: CGFloat {
        guard let effective, effective.largeTextRequested else { return systemValue }
        return max(systemValue, baseValue * AppTypography.systemScale(for: effective.textSize))
    }
}

extension View {
    /// Install once at each ready scene root. Sheets inherit these inputs from
    /// their presenter; they must not resolve or scale a second time.
    func appAccessibilityPreferences(_ store: AppPreferencesStore) -> some View {
        modifier(AppAccessibilityPreferencesModifier(store: store))
    }
}
