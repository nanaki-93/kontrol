import Foundation

// The URL is stable across launches. The sandbox redirects Application Support to
// the app's container; tests must supply their own temporary URLs instead.
enum StoreLocation {
    static func productionStoreURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return applicationSupport
            .appendingPathComponent("Kontrol", isDirectory: true)
            .appendingPathComponent("Kontrol.store", isDirectory: false)
    }
}
