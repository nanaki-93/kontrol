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

/// The no-candidate case will be refined into distinct empty states by the next policy step.
enum FeatureSelectionState: Equatable {
    case unavailable
    case candidatesAvailable
    case noCandidates
}

struct FeatureSelection: Equatable {
    let candidates: [FeatureCandidate]
    let state: FeatureSelectionState
}

/// Selects from already validated V1 records; never reads or changes project files.
struct FeatureSelector {
    func select(from inspection: ProjectInspection) -> FeatureSelection {
        guard inspection.manifest?.schemaVersion == 1,
              inspection.featureEnumeration == .complete,
              let focus = inspection.manifest?.currentFocus else {
            return FeatureSelection(candidates: [], state: .unavailable)
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
        return FeatureSelection(candidates: candidates,
                                state: candidates.isEmpty ? .noCandidates : .candidatesAvailable)
    }
}
