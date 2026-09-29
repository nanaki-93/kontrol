import Foundation
import XCTest
@testable import Kontrol

final class FeatureSelectorTests: XCTestCase {
    private func feature(_ id: String, _ status: ProjectFeatureStatus = .ready,
                         priority: ProjectFeaturePriority = .medium,
                         effort: ProjectFeatureEffort = .medium,
                         areas: [String] = [], dependencies: [String] = []) -> ProjectFeature {
        ProjectFeature(id: id, title: id, status: status, priority: priority, effort: effort,
                       dependsOn: dependencies, areas: areas, completedAt: nil,
                       body: "Body for \(id)", sourcePath: ".kontrol/features/\(id).md")
    }

    private func inspection(_ features: [ProjectFeature], focus: [String] = [],
                            version: Int? = 1,
                            enumeration: ProjectFeatureEnumeration = .complete,
                            excluded: [String] = []) -> ProjectInspection {
        let manifest = version.map {
            ProjectManifest(schemaVersion: $0, id: "project", name: "Project", description: "",
                            stack: [], goals: [], currentFocus: focus)
        }
        return ProjectInspection(manifest: manifest, roadmap: .absent, features: features,
                                 excludedFeaturePaths: excluded, featureEnumeration: enumeration,
                                 context: .absent, rules: .absent, history: .absent,
                                 diagnostics: [], sources: [], readAt: Date(timeIntervalSince1970: 42))
    }

    private func ids(_ selection: FeatureSelection) -> [String] {
        selection.candidates.map(\.id)
    }

    func testOnlyReadyWithAllValidatedCompletedPrerequisitesIsEligible() {
        let records = [feature("planned", .planned, priority: .high),
                       feature("active", .active, priority: .high),
                       feature("blocked", .blocked, priority: .high),
                       feature("done", .completed),
                       feature("ready"),
                       feature("two", dependencies: ["done", "otherDone"]),
                       feature("otherDone", .completed),
                       feature("unfinished", dependencies: ["done", "active"]),
                       feature("missing", dependencies: ["notValidated"]),
                       feature("blockedTarget", dependencies: ["blocked"])]
        let result = FeatureSelector().select(from: inspection(records, excluded: [".kontrol/features/bad.md"]))
        XCTAssertEqual(ids(result), ["ready", "two"])
        XCTAssertEqual(result.candidates.map(\.reason), [.ready, .dependenciesComplete])
        XCTAssertEqual(result.state, .candidatesAvailable)
        XCTAssertEqual(ids(FeatureSelector().select(from: inspection(records.filter { $0.id != "ready" && $0.id != "two" }))), [])
    }

    func testUnavailableManifestAndFailedEnumerationSuppressEvenOtherwiseReadyRecords() {
        let ready = [feature("candidate")]
        for version: Int? in [nil, 2] {
            let selection = FeatureSelector().select(from: inspection(ready, version: version))
            XCTAssertEqual(selection.state, .unavailable)
            XCTAssertEqual(selection.progress, .unavailable)
            XCTAssertNil(selection.statusCounts)
            XCTAssertTrue(selection.unresolvedDependencies.isEmpty)
        }
        let failed = FeatureSelector().select(from: inspection(ready, enumeration: .failed))
        XCTAssertEqual(failed.state, .unavailable)
        XCTAssertEqual(failed.progress, .unavailable)
        XCTAssertNil(failed.statusCounts)
        XCTAssertEqual(FeatureSelector().select(from: inspection([])).state, .noFeatures)
    }

    func testEmptyAndAllCompleteAreDistinctAndProgressCountsValidatedFeatures() {
        let empty = FeatureSelector().select(from: inspection([]))
        XCTAssertEqual(empty.state, .noFeatures)
        XCTAssertEqual(empty.progress, .complete(completed: 0, total: 0))
        XCTAssertEqual(empty.statusCounts, FeatureStatusCounts(features: []))

        let complete = FeatureSelector().select(from: inspection([feature("done", .completed),
                                                                 feature("other", .completed)]))
        XCTAssertEqual(complete.state, .allComplete)
        XCTAssertEqual(complete.progress, .complete(completed: 2, total: 2))
        XCTAssertEqual(complete.statusCounts?.completed, 2)
        XCTAssertTrue(complete.candidates.isEmpty)
    }

    func testNoReadyCountsDistinguishPlannedActiveBlockedAndUnfinishedPrerequisites() {
        let cases: [(ProjectFeatureStatus, FeatureStatusCounts)] = [
            (.planned, FeatureStatusCounts(features: [feature("one", .planned)])),
            (.active, FeatureStatusCounts(features: [feature("one", .active)])),
            (.blocked, FeatureStatusCounts(features: [feature("one", .blocked)]))
        ]
        for (status, expected) in cases {
            let result = FeatureSelector().select(from: inspection([feature("one", status)]))
            XCTAssertEqual(result.state, .noReadyFeatures)
            XCTAssertEqual(result.statusCounts, expected)
            XCTAssertEqual(result.progress, .complete(completed: 0, total: 1))
            XCTAssertTrue(result.unresolvedDependencies.isEmpty)
        }

        let mixed = [feature("z", dependencies: ["planned", "active", "planned"]),
                     feature("a", dependencies: ["blocked", "done"]),
                     feature("planned", .planned), feature("active", .active),
                     feature("blocked", .blocked), feature("done", .completed)]
        let result = FeatureSelector().select(from: inspection(mixed))
        XCTAssertEqual(result.state, .noReadyFeatures)
        XCTAssertEqual(result.progress, .complete(completed: 1, total: 6))
        XCTAssertEqual(result.statusCounts, FeatureStatusCounts(features: mixed))
        XCTAssertEqual(result.unresolvedDependencies, [
            UnresolvedFeatureDependencies(featureID: "a", dependencyIDs: ["blocked"]),
            UnresolvedFeatureDependencies(featureID: "z", dependencyIDs: ["active", "planned"])
        ])
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testExclusionsTakePrecedenceOverEmptyCompleteAndNoReadyButNotValidCandidates() {
        let excluded = [".kontrol/features/invalid.md"]
        for records in [[], [feature("done", .completed)], [feature("planned", .planned)]] {
            let result = FeatureSelector().select(from: inspection(records, excluded: excluded))
            XCTAssertEqual(result.state, .validationExclusions)
            XCTAssertEqual(result.progress, .partial(completed: records.filter { $0.status == .completed }.count,
                                                     total: records.count, excludedFiles: 1))
            XCTAssertEqual(result.statusCounts, FeatureStatusCounts(features: records))
            XCTAssertTrue(result.candidates.isEmpty)
        }
        let peers = [feature("done", .completed), feature("valid")]
        let result = FeatureSelector().select(from: inspection(peers, excluded: excluded))
        XCTAssertEqual(result.state, .candidatesAvailable)
        XCTAssertEqual(ids(result), ["valid"])
        XCTAssertEqual(result.progress, .partial(completed: 1, total: 2, excludedFiles: 1))
        XCTAssertEqual(result.statusCounts?.completed, 1)
    }

    func testUnavailableOverridesExclusionsAndEvenCompletedRecords() {
        let records = [feature("done", .completed), feature("ready")]
        let unavailableCases: [(Int?, ProjectFeatureEnumeration)] = [
            (nil, .complete), (2, .complete), (1, .failed)
        ]
        for (version, enumeration) in unavailableCases {
            let result = FeatureSelector().select(from: inspection(records, version: version,
                                                                     enumeration: enumeration,
                                                                     excluded: ["bad.md"]))
            XCTAssertEqual(result.state, .unavailable)
            XCTAssertEqual(result.progress, .unavailable)
            XCTAssertNil(result.statusCounts)
            XCTAssertTrue(result.candidates.isEmpty)
        }
    }

    func testFocusIsMembershipNotFocusOrderOrNumberOfMatchesAndWinsOverPriority() {
        let records = [feature("z", priority: .low, areas: ["last"]),
                       feature("a", priority: .high, areas: ["first", "last"]),
                       feature("b", priority: .high, areas: ["first"]),
                       feature("nonfocus", priority: .high, effort: .small, areas: ["other"])]
        let selector = FeatureSelector()
        let expected = ["a", "b", "z"]
        XCTAssertEqual(ids(selector.select(from: inspection(records, focus: ["first", "last"]))), expected)
        XCTAssertEqual(ids(selector.select(from: inspection(records, focus: ["last", "first"]))), expected)
        XCTAssertEqual(selector.select(from: inspection(records, focus: ["first", "last"]))
            .candidates.map(\.reason), [.currentFocus, .currentFocus, .currentFocus])
        XCTAssertEqual(ids(selector.select(from: inspection([feature("plain", areas: ["First"])], focus: ["first"]))), ["plain"])
        XCTAssertEqual(selector.select(from: inspection([feature("plain", areas: ["First"])], focus: ["first"]))
            .candidates.first?.reason, .ready)
    }

    func testPriorityThenEffortThenCaseSensitiveStableIDAndInputOrderIndependence() {
        let records = [feature("lowSmall", priority: .low, effort: .small),
                       feature("mediumSmall", priority: .medium, effort: .small),
                       feature("highLarge", priority: .high, effort: .large),
                       feature("highMedium", priority: .high, effort: .medium),
                       feature("z", priority: .high, effort: .small),
                       feature("a", priority: .high, effort: .small),
                       feature("A", priority: .high, effort: .small)]
        let selector = FeatureSelector()
        let expected = ["A", "a", "z"]
        for ordering in [records, Array(records.reversed()), [records[2], records[6], records[0], records[4],
                                                       records[1], records[5], records[3]]] {
            XCTAssertEqual(ids(selector.select(from: inspection(Array(ordering)))), expected)
        }
        XCTAssertEqual(ids(selector.select(from: inspection(records.filter { !["A", "a", "z"].contains($0.id) }))),
                       ["highMedium", "highLarge", "mediumSmall"])
        XCTAssertEqual(ids(selector.select(from: inspection([feature("x"), feature("y")]))), ["x", "y"])
    }

    func testReasonPrecedenceAndNoVacancyFilling() {
        let records = [feature("focus", priority: .high, areas: ["core"], dependencies: ["done"]),
                       feature("dependent", priority: .medium, dependencies: ["done"]),
                       feature("plain", priority: .low), feature("done", .completed),
                       feature("planned", .planned, priority: .high, areas: ["core"]),
                       feature("blocked", .blocked, priority: .high, areas: ["core"])]
        let selection = FeatureSelector().select(from: inspection(records, focus: ["core"]))
        XCTAssertEqual(ids(selection), ["focus", "dependent", "plain"])
        XCTAssertEqual(selection.candidates.map(\.reason), [.currentFocus, .dependenciesComplete, .ready])
        XCTAssertEqual(ids(FeatureSelector().select(from: inspection(records.filter { $0.id != "plain" }))),
                       ["focus", "dependent"])
    }
}
