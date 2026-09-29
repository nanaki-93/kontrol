import Foundation

/// Detached defaults. Persistence decides whether to initialize them; loading never edits a store
/// or starts a network request. The UUIDs in the resource are stable across catalog revisions.
struct DefaultFeedCatalog: Equatable {
    struct Feed: Equatable, Identifiable {
        let id: UUID
        let name: String
        let url: URL
        let topicIDs: Set<String>
    }

    let version: Int
    let topics: [NewsTopic]
    let initialSelectedTopicIDs: Set<String>
    let feeds: [Feed]
}

enum BundledFeedCatalogError: Error, Equatable {
    case missingResource
    case invalidCatalog
}

enum BundledFeedCatalog {
    private static let topicNames: [String: String] = [
        "go": "Go", "java": "Java", "software-engineering": "Software Engineering",
        "security": "Security", "system-design": "System Design", "ai": "AI",
        "japan": "Japan", "gaming": "Gaming", "anime": "Anime"
    ]
    private static let initiallySelected: Set<String> = [
        "go", "java", "software-engineering", "security", "system-design", "ai", "japan"
    ]

    private struct Document: Decodable {
        struct Topic: Decodable {
            let id: String
            let name: String
        }
        struct Feed: Decodable {
            let id: String
            let name: String
            let url: String
            let topicIDs: [String]
        }
        let version: Int
        let topics: [Topic]
        let initialSelectedTopicIDs: [String]
        let feeds: [Feed]
    }

    static func load(from bundle: Bundle = .main) throws -> DefaultFeedCatalog {
        guard let url = bundle.url(forResource: "default-feeds", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw BundledFeedCatalogError.missingResource
        }
        return try decodeAndValidate(data)
    }

    static func decodeAndValidate(_ data: Data) throws -> DefaultFeedCatalog {
        guard !data.isEmpty, data.count <= 64 * 1024,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version > 0, document.topics.count == topicNames.count,
              document.feeds.count > 0, document.feeds.count <= 32 else {
            throw BundledFeedCatalogError.invalidCatalog
        }
        let topics = document.topics.map { NewsTopic(id: $0.id, name: $0.name) }
        let topicIDs = topics.map(\.id)
        guard Set(topicIDs).count == topicIDs.count,
              topics.allSatisfy({ topicNames[$0.id] == $0.name }),
              document.initialSelectedTopicIDs.count == initiallySelected.count,
              Set(document.initialSelectedTopicIDs) == initiallySelected else {
            throw BundledFeedCatalogError.invalidCatalog
        }

        var ids = Set<UUID>()
        var endpoints = Set<String>()
        var feeds: [DefaultFeedCatalog.Feed] = []
        var coveredTopics = Set<String>()
        for item in document.feeds {
            let mappings = Set(item.topicIDs)
            guard let id = UUID(uuidString: item.id),
                  id.uuidString != "00000000-0000-0000-0000-000000000000",
                  ids.insert(id).inserted,
                  !item.name.isEmpty, item.name.count <= 120,
                  item.name == item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !mappings.isEmpty, mappings.count == item.topicIDs.count,
                  mappings.isSubset(of: Set(topicIDs)),
                  let endpoint = try? NewsURLPolicy.feedURL(item.url),
                  let normalized = try? NewsURLPolicy.normalizedFeedURL(item.url),
                  endpoints.insert(normalized).inserted,
                  let host = endpoint.host?.lowercased(),
                  host.contains("."),
                  !["example.com", "example.net", "example.org", "localhost"].contains(host),
                  !host.hasSuffix(".example.com"), !host.hasSuffix(".example.net"),
                  !host.hasSuffix(".example.org") else {
                throw BundledFeedCatalogError.invalidCatalog
            }
            coveredTopics.formUnion(mappings)
            feeds.append(.init(id: id, name: item.name, url: endpoint, topicIDs: mappings))
        }
        guard initiallySelected.isSubset(of: coveredTopics) else {
            throw BundledFeedCatalogError.invalidCatalog
        }
        return DefaultFeedCatalog(version: document.version, topics: topics,
                                  initialSelectedTopicIDs: initiallySelected, feeds: feeds)
    }
}
