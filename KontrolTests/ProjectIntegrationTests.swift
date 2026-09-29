import Foundation
import SwiftData
import XCTest
@testable import Kontrol

/// Opaque in-process grants exercise the real scoped reader/parser/store and V8 repository.
/// They are intentionally not OS bookmarks: signed sandbox relaunch remains an F13 check.
private final class IntegrationGrants: ProjectBookmarkOperations {
    private let lock = NSLock()
    private var folders: [Data: URL] = [:]
    private var stale: Set<Data> = []
    private var starts = 0
    private var stops = 0

    func resolve(_ data: Data) throws -> (folder: URL, isStale: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let folder = folders[data] else { throw ProjectFolderAccessError.unresolved }
        return (folder, stale.contains(data))
    }

    func createBookmark(for selectedFolder: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let token = Data(UUID().uuidString.utf8)
        folders[token] = selectedFolder
        return token
    }

    func startAccessing(_ folder: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        starts += 1
        return true
    }

    func stopAccessing(_ folder: URL) {
        lock.lock(); defer { lock.unlock() }
        stops += 1
    }

    func invalidate(_ token: Data) {
        lock.lock(); defer { lock.unlock() }
        stale.insert(token)
    }

    var balanced: Bool {
        lock.lock(); defer { lock.unlock() }
        return starts == stops
    }
}

@MainActor
final class ProjectIntegrationTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func project(_ root: URL, folder: String, id: String) throws -> URL {
        let url = root.appendingPathComponent(folder, isDirectory: true)
        let base = url.appendingPathComponent(".kontrol", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("features"),
                                                withIntermediateDirectories: true)
        try Data("schema_version: 1\r\nid: \(id)\r\nname: \(folder)\r\ndescription: From disk\r\nstack: [Swift]\r\ngoals: [Inspect]\r\ncurrent_focus: [Local]\r\n".utf8)
            .write(to: base.appendingPathComponent("project.yaml"))
        try Data("schema_version: 1\nmilestones:\n  - id: phase\n    title: First\n    status: active\n".utf8)
            .write(to: base.appendingPathComponent("roadmap.yaml"))
        try Data("Notes from disk\r\n".utf8).write(to: base.appendingPathComponent("context.md"))
        try Data("---\nid: F1\ntitle: First\nstatus: planned\npriority: high\neffort: small\n---\nBody from disk\n".utf8)
            .write(to: base.appendingPathComponent("features/first.md"))
        return url
    }

    private func writeFeature(_ folder: URL, _ file: String, id: String, status: String = "ready",
                              priority: String = "medium", effort: String = "small",
                              dependencies: [String] = [], areas: [String] = []) throws {
        let yaml = "---\nid: \(id)\ntitle: \(id)\nstatus: \(status)\npriority: \(priority)\neffort: \(effort)\ndepends_on: [\(dependencies.joined(separator: ", "))]\nareas: [\(areas.joined(separator: ", "))]\n---\nFull body for \(id)\n"
        try Data(yaml.utf8).write(to: folder.appendingPathComponent(".kontrol/features/\(file).md"))
    }

    private func candidates(_ subject: ProjectStore, _ id: UUID) -> [String] {
        guard let inspection = subject.rows.first(where: { $0.reference.id == id })?.inspection else { return [] }
        return FeatureSelector().select(from: inspection).candidates.map(\.id)
    }

    /// Capture all .kontrol entries, including malformed peers, not just parsed sources.
    private func bytes(_ folders: [URL]) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for folder in folders {
            let base = folder.appendingPathComponent(".kontrol")
            let names = try FileManager.default.subpathsOfDirectory(atPath: base.path)
            for name in names {
                let file = base.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    result[folder.lastPathComponent + "/" + name] = try Data(contentsOf: file)
                }
            }
        }
        return result
    }

    private func unchanged<T>(_ folders: [URL], _ action: () async throws -> T) async throws -> T {
        let before = try bytes(folders)
        // Verify bytes even when the action fails; the caller asserts its error separately.
        do {
            let result = try await action()
            XCTAssertEqual(try bytes(folders), before, "An app operation changed project files")
            return result
        } catch {
            XCTAssertEqual(try bytes(folders), before, "A failed app operation changed project files")
            throw error
        }
    }

    /// Unlike `unchanged`, this snapshots the whole fixture (including Git sentinels and
    /// source files) so a mutation may change exactly one selected feature, and no temp
    /// artifact or previously absent entry can escape the comparison.
    private func tree(_ folder: URL) throws -> [String: Data] {
        let names = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
        var result: [String: Data] = [:]
        for name in names {
            let entry = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
                XCTFail("Fixture entry disappeared: \(name)")
                continue
            }
            result[name] = isDirectory.boolValue ? Data() : try Data(contentsOf: entry)
        }
        return result
    }

    private func assertOnlyFeatureChanged(_ before: [String: Data], _ after: [String: Data],
                                          file: StaticString = #filePath, line: UInt = #line) {
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        XCTAssertEqual(Set(changed), [".kontrol/features/first.md"], file: file, line: line)
    }

    private func text(_ content: ProjectOptionalDocument) -> String? {
        if case let .present(source) = content { return source.text }
        return nil
    }

    private func wait(_ condition: @escaping () -> Bool, file: StaticString = #filePath,
                      line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for project inspection", file: file, line: line)
    }

    private func store(_ container: ModelContainer, _ grants: IntegrationGrants,
                       beforeSave: @escaping () throws -> Void = {}) -> ProjectStore {
        let access = ProjectFolderAccess(operations: grants)
        return ProjectStore(inspector: ProjectInspector(access: access),
            repository: SwiftDataProjectReferenceRepository(container: container, beforeSave: beforeSave),
            identifier: ScopedProjectFolderIdentifier(access: access),
            writer: FeatureFileWriter(access: access))
    }

    private func mutationFixture(_ root: URL, name: String) throws -> URL {
        let folder = try project(root, folder: name, id: name)
        try writeFeature(folder, "downstream", id: "downstream", priority: "high",
                         dependencies: ["F1"])
        try writeFeature(folder, "peer", id: "peer")
        let git = folder.appendingPathComponent(".git")
        let source = folder.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        try Data([0, 1, 255, 42]).write(to: git.appendingPathComponent("index"))
        try Data("let version = 1\n".utf8).write(to: source.appendingPathComponent("App.swift"))
        try Data("schema_version: 1\nevents: []\n".utf8)
            .write(to: folder.appendingPathComponent(".kontrol/history.yaml"))
        return folder
    }

    func testRealCompletionUndoAndReopenDeriveProgressFromDisk() async throws {
        let root = try workspace()
        let folder = try mutationFixture(root, name: "journey")
        let grants = IntegrationGrants()
        let database = root.appendingPathComponent("journey.store")
        let original = try tree(folder)
        for sentinel in [".git/HEAD", ".git/index", "Sources/App.swift", ".kontrol/roadmap.yaml",
                         ".kontrol/history.yaml", ".kontrol/features/peer.md",
                         ".kontrol/features/downstream.md"] {
            XCTAssertNotNil(original[sentinel], "Missing fixture sentinel: \(sentinel)")
        }
        var id: UUID?
        var finalBytes: [String: Data] = [:]
        do {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(database))
            let subject = store(container, grants)
            _ = try await unchanged([folder]) { try await subject.previewFolder(folder) }
            guard case let .added(saved) = try await unchanged([folder], {
                try await subject.addPreviewedProject()
            }) else { return XCTFail("Expected saved reference") }
            id = saved
            XCTAssertEqual(try tree(folder), original)
            XCTAssertEqual(subject.rows[0].inspection?.featureCount, .complete(completed: 0, total: 3))
            XCTAssertEqual(candidates(subject, saved), ["peer"])
            subject.selectFeature("F1", in: saved)
            XCTAssertEqual(subject.selectedFeatureContent?.status, .planned)
            XCTAssertTrue(subject.canMarkComplete("F1", in: saved))

            await subject.markComplete("F1", in: saved)
            guard case .saved("F1") = subject.rows[0].completion else {
                return XCTFail("Expected verified save and refreshed inspection: \(String(describing: subject.rows[0].completion))")
            }
            let completed = try tree(folder)
            assertOnlyFeatureChanged(original, completed)
            XCTAssertEqual(subject.rows[0].inspection?.featureCount, .complete(completed: 1, total: 3))
            XCTAssertEqual(candidates(subject, saved), ["downstream", "peer"])
            XCTAssertEqual(subject.selectedFeatureContent?.status, .completed)
            XCTAssertNotNil(subject.selectedFeatureContent?.completedAt)
            XCTAssertTrue(subject.canUndoCompletion(in: saved))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".kontrol/features/first.md")),
                           completed[".kontrol/features/first.md"])

            await subject.undoCompletion(in: saved)
            guard case .undone("F1") = subject.rows[0].completion else {
                return XCTFail("Expected verified undo and refreshed inspection: \(String(describing: subject.rows[0].completion))")
            }
            XCTAssertEqual(try tree(folder), original, "Undo must restore exact bytes and leave no temp entries")
            XCTAssertEqual(subject.rows[0].inspection?.featureCount, .complete(completed: 0, total: 3))
            XCTAssertEqual(candidates(subject, saved), ["peer"])
            XCTAssertEqual(subject.selectedFeatureContent?.status, .planned)
            XCTAssertNil(subject.selectedFeatureContent?.completedAt)
            XCTAssertFalse(subject.canUndoCompletion(in: saved))

            // Complete once more so a fresh store can prove persisted completion is
            // reconstructed from .kontrol rather than an app-owned status or undo record.
            await subject.markComplete("F1", in: saved)
            XCTAssertEqual(subject.rows[0].completion, .saved("F1"))
            finalBytes = try tree(folder)
            assertOnlyFeatureChanged(original, finalBytes)
        }
        let reopenedContainer = try ModelContainerFactory().makeContainer(mode: .persistent(database))
        let reopened = store(reopenedContainer, grants)
        try await unchanged([folder]) {
            try reopened.enterProjects()
            await wait { reopened.rows.count == 1 && !reopened.rows[0].isRefreshing &&
                reopened.rows[0].inspection?.featureCount == .complete(completed: 1, total: 3) }
        }
        XCTAssertEqual(reopened.selectedID, id)
        if let id { XCTAssertEqual(candidates(reopened, id), ["downstream", "peer"])
            XCTAssertFalse(reopened.canUndoCompletion(in: id), "Undo is session-local") }
        XCTAssertEqual(reopened.rows[0].inspection?.features.first(where: { $0.id == "F1" })?.status,
                       .completed)
        XCTAssertEqual(try tree(folder), finalBytes)
        XCTAssertTrue(grants.balanced)
    }

    func testRealCompletionAndUndoRefuseExternalEditsWithoutChangingOtherFiles() async throws {
        let root = try workspace()
        let folder = try mutationFixture(root, name: "conflicts")
        let grants = IntegrationGrants()
        let container = try ModelContainerFactory().makeContainer(mode: .persistent(root.appendingPathComponent("conflicts.store")))
        let subject = store(container, grants)
        _ = try await unchanged([folder]) { try await subject.previewFolder(folder) }
        guard case let .added(id) = try await unchanged([folder], {
            try await subject.addPreviewedProject()
        }) else { return XCTFail("Expected saved reference") }
        let target = folder.appendingPathComponent(".kontrol/features/first.md")
        let original = try tree(folder)
        // Edit after inspection but before activation: the store passes its old digest to IO.
        try Data("---\nid: F1\ntitle: First\nstatus: planned\npriority: high\neffort: small\n---\nExternal edit\n".utf8)
            .write(to: target)
        let external = try tree(folder)
        assertOnlyFeatureChanged(original, external)
        await subject.markComplete("F1", in: id)
        XCTAssertEqual(subject.rows[0].completion, .failed("F1", .conflict))
        XCTAssertEqual(try tree(folder), external)
        XCTAssertFalse(subject.canUndoCompletion(in: id))
        try await unchanged([folder]) {
            subject.refresh(id)
            await wait { !subject.rows[0].isRefreshing && subject.rows[0].refreshFailure == nil &&
                subject.rows[0].inspection?.features.first(where: { $0.id == "F1" })?.body == "External edit\n" }
        }
        await subject.markComplete("F1", in: id)
        XCTAssertEqual(subject.rows[0].completion, .saved("F1"))
        let completed = try tree(folder)
        assertOnlyFeatureChanged(external, completed)
        XCTAssertTrue(subject.canUndoCompletion(in: id))

        var changed = try Data(contentsOf: target)
        changed.append(contentsOf: Data("\nAnother editor\n".utf8))
        try changed.write(to: target)
        let edited = try tree(folder)
        assertOnlyFeatureChanged(completed, edited)
        await subject.undoCompletion(in: id)
        XCTAssertEqual(subject.rows[0].completion, .undoFailed("F1", .undoConflict))
        XCTAssertEqual(try tree(folder), edited, "Undo must not erase an external edit")
        XCTAssertFalse(subject.canUndoCompletion(in: id))
        XCTAssertTrue(grants.balanced)
    }

    func testRealEligibilityExternalEditsReorderingReopenAndReadOnlyNavigation() async throws {
        let root = try workspace()
        let folder = try project(root, folder: "roadmap", id: "roadmap")
        let folders = [folder]
        let grants = IntegrationGrants()
        let database = root.appendingPathComponent("roadmap.store")
        // Only fixture setup and the explicitly external edits below may change project bytes.
        try writeFeature(folder, "downstream", id: "downstream", priority: "high",
                         effort: "medium", dependencies: ["F1"], areas: ["Local"])
        try writeFeature(folder, "beta", id: "beta", priority: "high")
        try writeFeature(folder, "gamma", id: "gamma", priority: "low", effort: "large", areas: ["Remote"])
        var id = UUID()
        do {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(database))
            let subject = store(container, grants)
            _ = try await unchanged(folders) { try await subject.previewFolder(folder) }
            guard case let .added(saved) = try await unchanged(folders, {
                try await subject.addPreviewedProject()
            }) else { return XCTFail("Expected saved reference") }
            id = saved
            XCTAssertEqual(candidates(subject, id), ["beta", "gamma"])
            XCTAssertEqual(subject.rows[0].inspection?.featureCount, .complete(completed: 0, total: 4))
            try await unchanged(folders) { subject.selectFeature("downstream", in: id) }
            XCTAssertEqual(subject.selectedFeature, ProjectFeatureIdentity(projectID: id, featureID: "downstream"))
            try await unchanged(folders) { subject.closeFeature() }
            try await unchanged(folders) { subject.selectFeature("F1", in: id) }
            XCTAssertEqual(subject.selectedFeatureContent?.status, .planned)

            // A user/editor, not the app, completes the prerequisite on disk.
            try writeFeature(folder, "first", id: "F1", status: "completed", priority: "high")
            let externalCompletion = try bytes(folders)
            try await unchanged(folders) {
                subject.refresh(id)
                await wait { !subject.rows[0].isRefreshing &&
                    subject.rows[0].inspection?.featureCount == .complete(completed: 1, total: 4) }
            }
            XCTAssertEqual(try bytes(folders), externalCompletion)
            XCTAssertEqual(candidates(subject, id), ["downstream", "beta", "gamma"])
            XCTAssertEqual(subject.selectedFeatureContent?.status, .completed)
            try await unchanged(folders) { subject.selectFeature("downstream", in: id) }
            XCTAssertEqual(subject.selectedFeatureContent?.dependsOn, ["F1"])

            // A second external edit changes both the focus match and priority ordering.
            try Data("schema_version: 1\nid: roadmap\nname: roadmap\ncurrent_focus: [Remote]\n".utf8)
                .write(to: folder.appendingPathComponent(".kontrol/project.yaml"))
            try writeFeature(folder, "beta", id: "beta", priority: "low")
            try writeFeature(folder, "gamma", id: "gamma", priority: "high", areas: ["Remote"])
            let reorderedBytes = try bytes(folders)
            try await unchanged(folders) {
                subject.refresh(id)
                await wait { !subject.rows[0].isRefreshing &&
                    subject.rows[0].inspection?.manifest?.currentFocus == ["Remote"] &&
                    subject.rows[0].inspection?.features.first(where: { $0.id == "beta" })?.priority == .low }
            }
            XCTAssertEqual(try bytes(folders), reorderedBytes)
            XCTAssertEqual(candidates(subject, id), ["gamma", "downstream", "beta"])
            XCTAssertEqual(subject.selectedFeatureContent?.id, "downstream")
            try await unchanged(folders) { subject.closeFeature() }
            XCTAssertNil(subject.selectedFeature)
        }
        // A fresh store must reconstruct the same order from the project files, not cached slots.
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(database))
        let subject = store(reopened, grants)
        try await unchanged(folders) {
            try subject.enterProjects()
            await wait { subject.rows.count == 1 && subject.rows[0].inspection != nil && !subject.rows[0].isRefreshing }
        }
        XCTAssertEqual(subject.selectedID, id)
        XCTAssertEqual(candidates(subject, id), ["gamma", "downstream", "beta"])
        XCTAssertEqual(subject.rows[0].inspection?.featureCount, .complete(completed: 1, total: 4))
        try await unchanged(folders) { subject.selectFeature("downstream", in: id) }
        let oldGrant = subject.rows[0].reference.bookmarkData
        grants.invalidate(oldGrant)
        try await unchanged(folders) {
            subject.refresh(id)
            await wait { !subject.rows[0].isRefreshing &&
                subject.rows[0].refreshFailure == .inspection(.access(.staleBookmark)) }
        }
        XCTAssertTrue(subject.rows[0].isRetainedInspection)
        XCTAssertEqual(subject.selectedFeatureContent?.id, "downstream")
        XCTAssertEqual(subject.rows[0].refreshFailure?.recovery, .reconnect)
        try await unchanged(folders) { subject.closeFeature() }
        XCTAssertNil(subject.selectedFeature)
        XCTAssertTrue(grants.balanced)
    }

    func testRealInvalidGraphExcludesPeersButPreservesValidSuggestionsAndBytes() async throws {
        let root = try workspace()
        let folder = try project(root, folder: "graph", id: "graph")
        let folders = [folder]
        let grants = IntegrationGrants()
        let container = try ModelContainerFactory().makeContainer(mode: .persistent(root.appendingPathComponent("graph.store")))
        let subject = store(container, grants)
        _ = try await unchanged(folders) { try await subject.previewFolder(folder) }
        guard case let .added(id) = try await unchanged(folders, {
            try await subject.addPreviewedProject()
        }) else { return XCTFail("Expected saved reference") }

        // This edit represents an external tool changing the saved folder after Add.
        try writeFeature(folder, "done", id: "done", status: "completed")
        try writeFeature(folder, "healthy", id: "healthy", priority: "high", areas: ["Local"])
        try writeFeature(folder, "eligible", id: "eligible", dependencies: ["done"])
        try writeFeature(folder, "awaiting", id: "awaiting", dependencies: ["F1"])
        try Data("not frontmatter\n".utf8).write(to: folder.appendingPathComponent(".kontrol/features/malformed.md"))
        try writeFeature(folder, "duplicate-a", id: "duplicate")
        try writeFeature(folder, "duplicate-b", id: "duplicate")
        try writeFeature(folder, "from-duplicate", id: "fromDuplicate", dependencies: ["duplicate"])
        try writeFeature(folder, "missing", id: "missing", dependencies: ["absent"])
        try writeFeature(folder, "self", id: "self", dependencies: ["self"])
        try writeFeature(folder, "cycle-a", id: "cycleA", dependencies: ["cycleB"])
        try writeFeature(folder, "cycle-b", id: "cycleB", dependencies: ["cycleA"])
        try writeFeature(folder, "chain-a", id: "chainA", dependencies: ["missing"])
        try writeFeature(folder, "chain-b", id: "chainB", dependencies: ["chainA"])
        let externallyEdited = try bytes(folders)
        try await unchanged(folders) {
            subject.refresh(id)
            await wait { !subject.rows[0].isRefreshing &&
                subject.rows[0].inspection?.featureCount == .partial(completed: 1, total: 5, excludedFiles: 10) }
        }
        XCTAssertEqual(try bytes(folders), externallyEdited)
        guard let inspection = subject.rows[0].inspection else { return XCTFail("Missing inspection") }
        XCTAssertEqual(inspection.features.map(\.id), ["awaiting", "done", "eligible", "F1", "healthy"])
        XCTAssertEqual(inspection.excludedFeaturePaths.count, 10)
        XCTAssertEqual(Set(inspection.diagnostics.map(\.code)),
                       Set([.invalidFrontmatter, .duplicateID, .invalidDependency, .missingDependency,
                            .selfDependency, .cyclicDependency]))
        let selection = FeatureSelector().select(from: inspection)
        XCTAssertEqual(selection.state, .candidatesAvailable)
        XCTAssertEqual(selection.progress, .partial(completed: 1, total: 5, excludedFiles: 10))
        XCTAssertEqual(selection.candidates.map(\.id), ["healthy", "eligible"])
        XCTAssertEqual(selection.unresolvedDependencies,
                       [UnresolvedFeatureDependencies(featureID: "awaiting", dependencyIDs: ["F1"])])
        try await unchanged(folders) { subject.selectFeature("chainB", in: id) }
        XCTAssertNil(subject.selectedFeature)
        try await unchanged(folders) { subject.selectFeature("awaiting", in: id) }
        XCTAssertEqual(subject.selectedFeatureContent?.id, "awaiting")
        try await unchanged(folders) { subject.selectFeature("healthy", in: id) }
        try await unchanged(folders) { subject.closeFeature() }
        // An unchanged reread must reproduce both validated peers and exclusions.
        try await unchanged(folders) {
            subject.refresh(id)
            await wait { !subject.rows[0].isRefreshing &&
                subject.rows[0].inspection?.featureCount == .partial(completed: 1, total: 5, excludedFiles: 10) }
        }
        XCTAssertEqual(candidates(subject, id), ["healthy", "eligible"])
        XCTAssertEqual(try bytes(folders), externallyEdited)
        XCTAssertTrue(grants.balanced)
    }

    func testTwoFolderAddReopenExternalEditsIndependentFailureAndReconnect() async throws {
        let root = try workspace()
        let first = try project(root, folder: "first", id: "one")
        let second = try project(root, folder: "second", id: "two")
        let folders = [first, second]
        let database = root.appendingPathComponent("isolated.store")
        let grants = IntegrationGrants()
        var firstID = UUID(), secondID = UUID()
        var oldGrant = Data()
        do {
            let container = try ModelContainerFactory().makeContainer(mode: .persistent(database))
            let subject = store(container, grants)
            for (folder, id) in [(first, "one"), (second, "two")] {
                let preview = try await unchanged(folders) { try await subject.previewFolder(folder) }
                XCTAssertTrue(preview.canAdd)
                XCTAssertEqual(preview.inspection.manifest?.id, id)
                guard case let .added(savedID) = try await unchanged(folders, {
                    try await subject.addPreviewedProject()
                }) else { return XCTFail("Add did not commit") }
                if id == "one" { firstID = savedID } else { secondID = savedID }
            }
            XCTAssertEqual(subject.rows.map(\.reference.id), [firstID, secondID])
            oldGrant = subject.rows[0].reference.bookmarkData
            let existing = try await unchanged(folders) { try await subject.previewFolder(first) }
            XCTAssertTrue(existing.canAdd)
            let duplicate = try await unchanged(folders) { try await subject.addPreviewedProject() }
            XCTAssertEqual(duplicate, .selectedExisting(firstID))
            XCTAssertEqual(subject.rows.count, 2)
            XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: container).fetchAll().count, 2)
        }
        // Reopen using a new container/store. The inspector must read disk, not saved metadata.
        let reopened = try ModelContainerFactory().makeContainer(mode: .persistent(database))
        let subject = store(reopened, grants)
        let reopenBaseline = try bytes(folders)
        try await unchanged(folders) { try subject.enterProjects() }
        await wait { subject.rows.allSatisfy { $0.inspection != nil && !$0.isRefreshing } }
        XCTAssertEqual(try bytes(folders), reopenBaseline)
        XCTAssertEqual(subject.rows.map(\.reference.id), [firstID, secondID])
        XCTAssertEqual(subject.rows.map { $0.inspection?.featureCount },
                       [.complete(completed: 0, total: 1), .complete(completed: 0, total: 1)])
        XCTAssertEqual(subject.rows[0].inspection.flatMap { text($0.context) }, "Notes from disk\r\n")
        let priorRead = subject.rows[0].reference.lastSuccessfulReadAt
        let feature = first.appendingPathComponent(".kontrol/features/first.md")
        try Data("---\nid: F1\ntitle: First\nstatus: completed\npriority: high\neffort: small\n---\nExternally edited\n".utf8).write(to: feature)
        try Data("Updated outside Kontrol\n".utf8)
            .write(to: first.appendingPathComponent(".kontrol/context.md"))
        let editedBaseline = try bytes(folders)
        try await unchanged(folders) { subject.refresh(firstID) }
        await wait { subject.rows[0].inspection?.featureCount == .complete(completed: 1, total: 1)
            && !subject.rows[0].isRefreshing }
        XCTAssertEqual(try bytes(folders), editedBaseline)
        XCTAssertEqual(subject.rows[0].inspection.flatMap { text($0.context) }, "Updated outside Kontrol\n")
        XCTAssertEqual(subject.rows[0].inspection?.features.first?.body, "Externally edited\n")
        XCTAssertNotEqual(subject.rows[0].reference.lastSuccessfulReadAt, priorRead)
        XCTAssertEqual(subject.rows[1].inspection?.featureCount, .complete(completed: 0, total: 1))

        // A damaged peer is a partial result, not a failure of the other folder.
        try Data("---\nid: broken\nstatus: nope\n---\n".utf8)
            .write(to: second.appendingPathComponent(".kontrol/features/broken.md"))
        let partialBaseline = try bytes(folders)
        try await unchanged(folders) { subject.refresh(secondID); subject.refresh(firstID) }
        await wait { subject.rows[1].inspection?.featureCount == .partial(completed: 0, total: 1, excludedFiles: 1)
            && !subject.rows[1].isRefreshing && !subject.rows[0].isRefreshing }
        XCTAssertEqual(try bytes(folders), partialBaseline)
        XCTAssertTrue(subject.rows[1].isStale)
        XCTAssertTrue(subject.rows[1].inspection?.diagnostics.contains(where: {
            $0.relativePath == ".kontrol/features/broken.md"
        }) == true)
        XCTAssertEqual(subject.rows[0].inspection?.featureCount, .complete(completed: 1, total: 1))

        grants.invalidate(oldGrant)
        let beforeFailure = try bytes(folders)
        try await unchanged(folders) { subject.refresh(firstID); subject.refresh(secondID) }
        await wait { subject.rows[0].refreshFailure == .inspection(.access(.staleBookmark))
            && !subject.rows[0].isRefreshing && !subject.rows[1].isRefreshing }
        XCTAssertEqual(try bytes(folders), beforeFailure)
        XCTAssertEqual(subject.rows[0].refreshFailure?.recovery, .reconnect)
        XCTAssertEqual(subject.rows[0].inspection?.featureCount, .complete(completed: 1, total: 1))
        XCTAssertEqual(subject.rows[1].inspection?.featureCount, .partial(completed: 0, total: 1, excludedFiles: 1))

        let replacement = try project(root, folder: "replacement", id: "one")
        let all = [first, second, replacement]
        let original = subject.rows[0].reference
        let reconnectBaseline = try bytes(all)
        let receipt = try await unchanged(all) { try await subject.reconnect(firstID, to: replacement) }
        XCTAssertEqual(receipt.id, firstID)
        XCTAssertEqual(receipt.displayOrder, original.displayOrder)
        XCTAssertNotEqual(receipt.revision, original.revision)
        XCTAssertNotEqual(receipt.bookmarkData, oldGrant)
        await wait { subject.rows[0].inspection?.manifest?.name == "replacement"
            && !subject.rows[0].isRefreshing }
        XCTAssertEqual(try bytes(all), reconnectBaseline)
        XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: reopened).fetchAll().map(\.id),
                       [firstID, secondID])
        XCTAssertEqual(subject.rows[1].inspection?.featureCount, .partial(completed: 0, total: 1, excludedFiles: 1))
        XCTAssertTrue(grants.balanced)
    }

    func testCancellationInvalidAddAndFailedSaveOrReconnectNeverWriteProjectFiles() async throws {
        let root = try workspace()
        let good = try project(root, folder: "good", id: "good")
        let wrong = try project(root, folder: "wrong", id: "wrong")
        let folders = [good, wrong]
        let grants = IntegrationGrants()
        enum Injected: Error { case save }
        var failSave = false
        let container = try ModelContainerFactory().makeContainer(mode: .persistent(root.appendingPathComponent("failure.store")))
        let subject = store(container, grants, beforeSave: { if failSave { throw Injected.save } })
        _ = try await unchanged(folders) { try await subject.previewFolder(good) }
        try await unchanged(folders) { subject.cancelAdd() }
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertTrue(try SwiftDataProjectReferenceRepository(container: container).fetchAll().isEmpty)
        // An externally damaged peer between preview and confirmation must block Add.
        let peer = good.appendingPathComponent(".kontrol/features/first.md")
        let originalPeer = try Data(contentsOf: peer)
        _ = try await unchanged(folders) { try await subject.previewFolder(good) }
        try Data("---\nid: F1\nstatus: invalid\n---\n".utf8).write(to: peer)
        do {
            _ = try await unchanged(folders) { try await subject.addPreviewedProject() }
            XCTFail("Invalid final inspection was accepted")
        } catch { XCTAssertEqual(error as? ProjectStoreError, .invalidPreview) }
        XCTAssertEqual(subject.preview?.canAdd, false)
        XCTAssertTrue(try SwiftDataProjectReferenceRepository(container: container).fetchAll().isEmpty)
        try originalPeer.write(to: peer) // External repair, never an app operation.
        _ = try await unchanged(folders) { try await subject.previewFolder(good) }
        failSave = true
        do {
            _ = try await unchanged(folders) { try await subject.addPreviewedProject() }
            XCTFail("Failed Add was accepted")
        } catch { XCTAssertEqual(subject.addMessage, "Project not added") }
        XCTAssertTrue(subject.rows.isEmpty)
        XCTAssertTrue(try SwiftDataProjectReferenceRepository(container: container).fetchAll().isEmpty)
        failSave = false
        guard case let .added(id) = try await unchanged(folders, { try await subject.addPreviewedProject() }) else {
            return XCTFail("Expected committed Add")
        }
        let old = subject.rows[0].reference
        try await unchanged(folders) { subject.cancelReconnect(id) }
        do {
            _ = try await unchanged(folders) { try await subject.reconnect(id, to: wrong) }
            XCTFail("Identity mismatch was accepted")
        } catch { XCTAssertEqual(error as? ProjectStoreError, .manifestMismatch) }
        failSave = true
        do {
            _ = try await unchanged(folders) { try await subject.reconnect(id, to: good) }
            XCTFail("Failed Reconnect was accepted")
        } catch { XCTAssertEqual(error as? ProjectStoreError, .projectNotReconnected) }
        XCTAssertEqual(subject.rows[0].reference, old)
        XCTAssertEqual(try SwiftDataProjectReferenceRepository(container: container).fetchAll(), [old])
        XCTAssertTrue(grants.balanced)
    }
}
