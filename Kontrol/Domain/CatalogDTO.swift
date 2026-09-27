import Foundation

// Resource values only: parsing and validation have no SwiftData dependency.
struct CatalogDTO: Decodable {
    var catalogID: String
    var version: Int
    var topics: [TopicDTO]
    var subtopics: [SubtopicDTO]
    var concepts: [ConceptDTO]
    var lessons: [LessonDTO]
}

struct TopicDTO: Decodable {
    var id: String
    var name: String
}

struct SubtopicDTO: Decodable {
    var id: String
    var topicID: String
    var name: String
}

struct ConceptDTO: Decodable {
    var id: String
    var subtopicID: String
    var name: String
    var prerequisiteConceptIDs: [String]
}

struct LessonDTO: Decodable {
    var id: String
    var objectiveKey: String
    var title: String
    var topicID: String
    var subtopicID: String
    var conceptIDs: [String]
    var difficulty: String
    var format: String
    var estimatedMinutes: Int
    var prerequisiteConceptIDs: [String]
    var explanation: String
    var workedExample: String
    var exercise: String
    var referenceAnswer: String
    var selfCheckCriteria: [String]
    var contentVersion: Int
    var normalizedContentHash: String
    var source: String
    var provenance: String
}
