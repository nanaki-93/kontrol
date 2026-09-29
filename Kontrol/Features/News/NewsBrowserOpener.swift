import AppKit
import Foundation

/// Injected boundary for the system's default browser. Callers must pass a stored article
/// destination, not a GUID, canonical identity, or an untrusted URL supplied by a view.
@MainActor
protocol NewsBrowserOpening {
    func open(_ url: URL) -> Bool
}

struct NewsBrowserOpener: NewsBrowserOpening {
    func open(_ url: URL) -> Bool {
        // Defense in depth: never hand an unsafe URL to NSWorkspace, even if a caller
        // bypasses the store's persisted-row check.
        guard let safeURL = try? NewsURLPolicy.articleURL(url) else { return false }
        return NSWorkspace.shared.open(safeURL)
    }
}
