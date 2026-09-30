import AppKit
import UniformTypeIdentifiers

/// URLs/replacement identities live only in the returned transient value.
enum ExportDestinationSelection {
    case canceled
    case approved(ApprovedExportDestination)
}

enum ExportSavePanelError: Error, Equatable {
    case selectionInProgress
    case missingDestination
}

@MainActor
protocol ExportDestinationSelecting {
    func selectDestination(suggestedAt date: Date) async throws -> ExportDestinationSelection
}

/// A value seam lets tests exercise the same configuration without opening AppKit.
struct ExportSavePanelConfiguration: Equatable {
    let allowedContentTypes: [UTType] = [.json]
    let allowsOtherFileTypes = false
    let isExtensionHidden = false
    let canCreateDirectories = true
    let suggestedFilename: String

    init(date: Date) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        suggestedFilename = "kontrol-export-\(formatter.string(from: date)).json"
    }
}

@MainActor
protocol ExportSavePanelPresenting: AnyObject {
    func configure(_ configuration: ExportSavePanelConfiguration)
    func begin(_ completion: @escaping @MainActor (Bool, URL?) -> Void)
    func cancel()
}

@MainActor
final class NativeExportSavePanel: ExportSavePanelPresenting {
    let panel = NSSavePanel()

    func configure(_ configuration: ExportSavePanelConfiguration) {
        panel.allowedContentTypes = configuration.allowedContentTypes
        panel.allowsOtherFileTypes = configuration.allowsOtherFileTypes
        panel.isExtensionHidden = configuration.isExtensionHidden
        panel.canCreateDirectories = configuration.canCreateDirectories
        panel.nameFieldStringValue = configuration.suggestedFilename
        // No delegate/validation override: AppKit retains replacement confirmation.
    }

    func begin(_ completion: @escaping @MainActor (Bool, URL?) -> Void) {
        panel.begin { [panel] response in
            completion(response == .OK, response == .OK ? panel.url : nil)
        }
    }

    func cancel() { panel.cancel(nil) }
}

/// Owns the panel until its callback actually finishes; cancellation has no timer
/// and does not admit another panel while native dismissal is still outstanding.
@MainActor
final class ExportSavePanel: ExportDestinationSelecting {
    @MainActor
    private final class Selection {
        let panel: any ExportSavePanelPresenting
        var canceled = false
        var finished = false
        init(panel: any ExportSavePanelPresenting) { self.panel = panel }
        func cancel() {
            guard !finished, !canceled else { return }
            canceled = true
            panel.cancel()
        }
    }

    private let makePanel: @MainActor () -> any ExportSavePanelPresenting
    private let approve: @MainActor (URL) throws -> ApprovedExportDestination
    private var active: Selection?

    init(makePanel: @escaping @MainActor () -> any ExportSavePanelPresenting = { NativeExportSavePanel() },
         approve: @escaping @MainActor (URL) throws -> ApprovedExportDestination = {
             try ExportFileWriter().approveDestination($0)
         }) {
        self.makePanel = makePanel
        self.approve = approve
    }

    func selectDestination(suggestedAt date: Date) async throws -> ExportDestinationSelection {
        guard active == nil else { throw ExportSavePanelError.selectionInProgress }
        guard !Task.isCancelled else { return .canceled }
        let selection = Selection(panel: makePanel())
        active = selection
        defer { active = nil }
        selection.panel.configure(ExportSavePanelConfiguration(date: date))
        let result: (Bool, URL?) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                selection.panel.begin { [weak selection] accepted, url in
                    guard let selection, !selection.finished else { return }
                    selection.finished = true
                    continuation.resume(returning: (accepted, url))
                }
            }
        } onCancel: {
            Task { @MainActor in selection.cancel() }
        }
        // Inspect the caller's task too: cancellation can race the dismissal callback.
        guard !Task.isCancelled, !selection.canceled, result.0 else { return .canceled }
        guard let url = result.1 else { throw ExportSavePanelError.missingDestination }
        // Identity capture is read-only and only occurs after native approval.
        // No preparation, bookmark creation, or destination write occurs here.
        return .approved(try approve(url))
    }
}
