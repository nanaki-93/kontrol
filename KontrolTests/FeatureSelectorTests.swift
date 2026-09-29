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
            XCTAssertEqual(selection, FeatureSelection(candidates: [], state: .unavailable))
        }
        XCTAssertEqual(FeatureSelector().select(from: inspection(ready, enumeration: .failed)).state, .unavailable)
        XCTAssertEqual(FeatureSelector().select(from: inspection([])).state, .noCandidates)
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
