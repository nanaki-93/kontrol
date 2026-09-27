import Foundation
import OSLog

enum SafeLaunchLogger {
    // Only these fixed identifiers are permitted into the unified log. An
    // arbitrary NSError domain can itself contain sensitive input or a path.
    enum Stage: String {
        case storeOpen = "store_open"
        case catalogInitialization = "catalog_initialization"
    }

    struct Diagnostic: Equatable {
        let stage: Stage
        let domain: String
        let code: Int
    }

    private static let logger = Logger(subsystem: "com.kontrol.app", category: "launch")
    private static let allowedDomains: Set<String> = [
        NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
        "SwiftData.SwiftDataError"
    ]

    static func diagnostic(stage: Stage, error: Error) -> Diagnostic {
        let nsError = error as NSError
        return Diagnostic(stage: stage,
                          domain: allowedDomains.contains(nsError.domain) ? nsError.domain : "redacted",
                          code: nsError.code)
    }

    static func failure(stage: Stage, error: Error) {
        let safe = diagnostic(stage: stage, error: error)
        logger.error("stage=\(safe.stage.rawValue, privacy: .public) domain=\(safe.domain, privacy: .public) code=\(safe.code, privacy: .public)")
    }
}
