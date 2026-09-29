import Foundation

/// Identity and explanation only; feature content remains in the authoritative inspection.
struct FeatureCandidate: Equatable {
    let id: String
    let reason: FeatureSelectionReason
}

enum FeatureSelectionReason: Equatable {
    case currentFocus
    case dependenciesComplete
    case ready
}

enum FeatureSelectionState: Equatable {
    case unavailable
    case candidatesAvailable
    case validationExclusions
    case noFeatures
    case allComplete
    case noReadyFeatures
}

/// Counts only validated records; excluded files have unknown status.
struct FeatureStatusCounts: Equatable {
    let planned: Int
    let ready: Int
    let active: Int
    let blocked: Int
    let completed: Int

    init(features: [ProjectFeature]) {
        planned = features.filter { $0.status == .planned }.count
        ready = features.filter { $0.status == .ready }.count
        active = features.filter { $0.status == .active }.count
        blocked = features.filter { $0.status == .blocked }.count
        completed = features.filter { $0.status == .completed }.count
    }
}

/// A validated ready record and the prerequisite IDs not currently completed.
struct UnresolvedFeatureDependencies: Equatable {
    let featureID: String
    let dependencyIDs: [String]
}

struct FeatureSelection: Equatable {
    let candidates: [FeatureCandidate]
    let state: FeatureSelectionState
    let progress: ProjectFeatureCount
    /// Nil when the manifest or enumeration is unavailable; never implies zero work.
    let statusCounts: FeatureStatusCounts?
    let unresolvedDependencies: [UnresolvedFeatureDependencies]
}

/// Selects from already validated V1 records; never reads or changes project files.
struct FeatureSelector {
    func select(from inspection: ProjectInspection) -> FeatureSelection {
        let progress = inspection.featureCount
        guard inspection.manifest?.schemaVersion == 1,
              inspection.featureEnumeration == .complete,
              let focus = inspection.manifest?.currentFocus else {
            return FeatureSelection(candidates: [], state: .unavailable, progress: progress,
                                    statusCounts: nil, unresolvedDependencies: [])
        }

        let byID = Dictionary(uniqueKeysWithValues: inspection.features.map { ($0.id, $0) })
        let focusAreas = Set(focus)
        func matchesFocus(_ feature: ProjectFeature) -> Bool {
            feature.areas.contains { focusAreas.contains($0) }
        }
        func priority(_ value: ProjectFeaturePriority) -> Int {
            switch value { case .high: return 0; case .medium: return 1; case .low: return 2 }
        }
        func effort(_ value: ProjectFeatureEffort) -> Int {
            switch value { case .small: return 0; case .medium: return 1; case .large: return 2 }
        }

        let eligible = inspection.features.filter { feature in
            feature.status == .ready && feature.dependsOn.allSatisfy { byID[$0]?.status == .completed }
        }
        let ranked = eligible.sorted { lhs, rhs in
            if matchesFocus(lhs) != matchesFocus(rhs) { return matchesFocus(lhs) }
            if lhs.priority != rhs.priority { return priority(lhs.priority) < priority(rhs.priority) }
            if lhs.effort != rhs.effort { return effort(lhs.effort) < effort(rhs.effort) }
            return lhs.id < rhs.id
        }
        let candidates = ranked.prefix(3).map { feature in
            let reason: FeatureSelectionReason = matchesFocus(feature) ? .currentFocus :
                (feature.dependsOn.isEmpty ? .ready : .dependenciesComplete)
            return FeatureCandidate(id: feature.id, reason: reason)
        }
        let counts = FeatureStatusCounts(features: inspection.features)
        let unresolved = inspection.features.filter { $0.status == .ready }.compactMap { feature -> UnresolvedFeatureDependencies? in
            let ids = Set(feature.dependsOn.filter { byID[$0]?.status != .completed }).sorted()
            return ids.isEmpty ? nil : UnresolvedFeatureDependencies(featureID: feature.id, dependencyIDs: ids)
        }.sorted { $0.featureID < $1.featureID }
        let state: FeatureSelectionState
        if !candidates.isEmpty {
            state = .candidatesAvailable
        } else if !inspection.excludedFeaturePaths.isEmpty {
            state = .validationExclusions
        } else if inspection.features.isEmpty {
            state = .noFeatures
        } else if counts.completed == inspection.features.count {
            state = .allComplete
        } else {
            state = .noReadyFeatures
        }
        return FeatureSelection(candidates: candidates, state: state, progress: progress,
                                statusCounts: counts, unresolvedDependencies: unresolved)
    }
}
