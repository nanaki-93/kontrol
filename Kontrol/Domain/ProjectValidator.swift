import Foundation

/// Validation of parsed feature records. A reader supplies paths of files it could not
/// parse/read separately; those paths remain excluded without pretending to know their IDs.
struct ProjectFeatureValidation: Equatable {
    let features: [ProjectFeature]
    let excludedFeaturePaths: [String]
    let diagnostics: [ProjectDiagnostic]
}

struct ProjectValidator {
    func validate(_ records: [ProjectFeature], excludedPaths: [String] = [],
                  diagnostics existing: [ProjectDiagnostic] = []) -> ProjectFeatureValidation {
        let records = records.sorted { $0.sourcePath < $1.sourcePath }
        let groups = Dictionary(grouping: records.indices, by: { records[$0].id })
        var invalid = Set<Int>()
        var diagnostics = existing

        func report(_ code: ProjectDiagnosticCode, _ index: Int, _ ids: [String]) {
            diagnostics.append(ProjectDiagnostic(code: code, severity: .error,
                                                 relativePath: records[index].sourcePath,
                                                 affectedIDs: ids.sorted(), recovery: .editSource))
        }

        // Collect every identity before looking at *any* edge; a later file can make an
        // earlier target ambiguous. Filename and ID are deliberately independent.
        for id in groups.keys.sorted() where groups[id]!.count > 1 {
            for index in groups[id]! {
                invalid.insert(index)
                report(.duplicateID, index, [id])
            }
        }
        for index in records.indices where !invalid.contains(index) {
            for target in Set(records[index].dependsOn).sorted() {
                if target == records[index].id {
                    invalid.insert(index)
                    report(.selfDependency, index, [target])
                } else if groups[target] == nil {
                    invalid.insert(index)
                    report(.missingDependency, index, [records[index].id, target])
                }
            }
        }

        // Tarjan's SCCs identify precisely the cycle members, not the downstream
        // records which will be invalidated by propagation below.
        var next = 0
        var discovery = [Int: Int]()
        var low = [Int: Int]()
        var stack = [Int]()
        var onStack = Set<Int>()
        var component = [Int: Int]()
        var componentNumber = 0
        func visit(_ index: Int) {
            discovery[index] = next
            low[index] = next
            next += 1
            stack.append(index)
            onStack.insert(index)
            for target in Set(records[index].dependsOn).sorted() {
                guard let peers = groups[target], peers.count == 1, let peer = peers.first else { continue }
                if discovery[peer] == nil {
                    visit(peer)
                    low[index] = min(low[index]!, low[peer]!)
                } else if onStack.contains(peer) {
                    low[index] = min(low[index]!, discovery[peer]!)
                }
            }
            if low[index] == discovery[index] {
                var members = [Int]()
                while let member = stack.popLast() {
                    onStack.remove(member)
                    members.append(member)
                    component[member] = componentNumber
                    if member == index { break }
                }
                componentNumber += 1
                if members.count > 1 {
                    let ids = members.map { records[$0].id }.sorted()
                    for member in members {
                        invalid.insert(member)
                        report(.cyclicDependency, member, ids)
                    }
                }
            }
        }
        for index in records.indices where discovery[index] == nil && groups[records[index].id]?.count == 1 {
            visit(index)
        }

        // Fixed point: an invalid/ambiguous target makes its dependents invalid,
        // including transitive dependents irrespective of source enumeration order.
        var changed = true
        while changed {
            changed = false
            for index in records.indices where !invalid.contains(index) {
                if records[index].dependsOn.contains(where: { target in
                    guard let peers = groups[target] else { return false } // missing already reported
                    return peers.count > 1 || peers.contains(where: { invalid.contains($0) })
                }) {
                    invalid.insert(index)
                    changed = true
                }
            }
        }
        for index in records.indices {
            for target in Set(records[index].dependsOn).sorted() where target != records[index].id {
                guard let peers = groups[target],
                      peers.count > 1 || peers.contains(where: { invalid.contains($0) }) else { continue }
                // Cycle members already have a cycle diagnostic for internal edges.
                if peers.count == 1, component[index] != nil, component[index] == component[peers[0]] { continue }
                report(.invalidDependency, index, [records[index].id, target])
            }
        }
        let excluded = Set(excludedPaths).union(invalid.map { records[$0].sourcePath }).sorted()
        diagnostics.sort {
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            if ($0.line ?? 0) != ($1.line ?? 0) { return ($0.line ?? 0) < ($1.line ?? 0) }
            if ($0.column ?? 0) != ($1.column ?? 0) { return ($0.column ?? 0) < ($1.column ?? 0) }
            if $0.code.rawValue != $1.code.rawValue { return $0.code.rawValue < $1.code.rawValue }
            return $0.affectedIDs.lexicographicallyPrecedes($1.affectedIDs)
        }
        return ProjectFeatureValidation(features: records.indices.filter { !invalid.contains($0) }.map { records[$0] },
                                        excludedFeaturePaths: excluded, diagnostics: diagnostics)
    }
}
