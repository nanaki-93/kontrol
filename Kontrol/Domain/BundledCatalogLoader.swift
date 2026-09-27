import CryptoKit
import Foundation

// Only reads app resources. Store mutation belongs to the catalog repository.
enum BundledCatalogError: Error, Equatable {
    case missingResource
    case invalidFingerprint
}

enum BundledCatalogLoader {
    static func load(from bundle: Bundle = .main) throws -> ValidatedCatalog {
        guard let url = bundle.url(forResource: "starter-catalog", withExtension: "json") else {
            throw BundledCatalogError.missingResource
        }
        let data = try Data(contentsOf: url)
        let catalog = try CatalogValidator.decodeAndValidate(data)
        try verifyFingerprints(in: catalog)
        return catalog
    }

    // SHA-256 over NFC-normalized, whitespace-trimmed teaching sections in fixed
    // order, separated by U+001F. Metadata and cosmetic titles are not content.
    static func fingerprint(for lesson: LessonDTO) -> String {
        let sections = [lesson.explanation, lesson.workedExample, lesson.exercise,
                        lesson.referenceAnswer] + lesson.selfCheckCriteria
        let normalized = sections.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        }.joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verifyFingerprints(in catalog: ValidatedCatalog) throws {
        guard catalog.value.lessons.allSatisfy({ $0.normalizedContentHash == fingerprint(for: $0) }) else {
            throw BundledCatalogError.invalidFingerprint
        }
    }
}
