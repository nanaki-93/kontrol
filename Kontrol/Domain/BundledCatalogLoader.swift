import Foundation

// Only reads app resources. Store mutation belongs to the catalog repository.
enum BundledCatalogError: Error, Equatable {
    case missingResource
}

enum BundledCatalogLoader {
    static func load(from bundle: Bundle = .main) throws -> ValidatedCatalog {
        guard let url = bundle.url(forResource: "starter-catalog", withExtension: "json") else {
            throw BundledCatalogError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try CatalogValidator.decodeAndValidate(data)
    }

    // Expose the same calculation to callers that author catalog updates. A
    // ValidatedCatalog has already checked every fingerprint during construction.
    static func fingerprint(for lesson: LessonDTO) -> String {
        CatalogValidator.fingerprint(for: lesson)
    }
}
