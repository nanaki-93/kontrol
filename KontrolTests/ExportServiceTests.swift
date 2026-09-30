import Foundation
import XCTest
@testable import Kontrol

final class ExportServiceTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kontrol-export-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func snapshot() throws -> LocalDataExport {
        let time = try ExportTimestamp(value: "2026-09-30T12:00:00.123Z")
        var snapshot = LocalDataExport(exportedAt: time, appVersion: "1.0")
        snapshot.tasks = [.init(id: UUID(), title: " \tAPI_KEY=keep me 🔐 e\u{301}\r\n ",
                               notes: " exact notes\n", dueAt: nil, plannedDay: nil,
                               createdAt: time, completedAt: nil)]
        return snapshot
    }

    private func assertEmpty(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], file: file, line: line)
    }

    func testPreparationRoundTripsPrivatePermissionsAndConsumesExactlyOnceWithoutDestinationAccess() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("unrelated.json")
        let existing = Data("existing destination bytes".utf8)
        try existing.write(to: destination)
        let snapshot = try snapshot()
        let writer: any ExportFilePreparing = ExportFileWriter(temporaryRoot: root)
        let artifact = try await writer.prepare(snapshot)
        let bytes = try artifact.consume { url in
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(fileAttributes[.type] as? FileAttributeType, .typeRegular)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(try LocalDataExport.decode(bytes), snapshot.canonicalized())
            XCTAssertEqual(bytes, try snapshot.encoded())
            return bytes
        }
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertThrowsError(try artifact.consume { _ in XCTFail("Consumed artifact reused") }) {
            XCTAssertEqual($0 as? ExportFileWriterError, .artifactUnavailable)
        }
        try artifact.discard()
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated.json"])
    }

    func testInvalidSnapshotAndEncoderFailuresAreSafeAndCleanOwnedArtifacts() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var invalid = try snapshot()
        invalid.schemaVersion = 2
        do {
            _ = try await ExportFileWriter(temporaryRoot: root).prepare(invalid)
            XCTFail("Invalid snapshot prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
        try assertEmpty(root)
        let hooks = ExportFileWriter.PreparationHooks(encode: { _ in
            throw NSError(domain: "sensitive path/content must not escape", code: 1)
        })
        do {
            _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
            XCTFail("Encoder failure prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
        try assertEmpty(root)
    }

    func testMalformedUnsupportedAndValidButWrongPreparedJSONCannotProceed() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        var wrong = snapshot
        wrong.appVersion = "different valid snapshot"
        var unsupported = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        unsupported["schemaVersion"] = 2
        let badBytes = [Data("not JSON".utf8), try JSONSerialization.data(withJSONObject: unsupported), try wrong.encoded()]
        for bytes in badBytes {
            let hooks = ExportFileWriter.PreparationHooks(encode: { _ in bytes })
            do {
                _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot)
                XCTFail("Invalid prepared bytes accepted")
            } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
            try assertEmpty(root)
        }
    }

    func testValidationReadsBackActualFileAndRejectsChangedStoredBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, directory in
            if stage == .fileWritten {
                try Data("corrupt storage".utf8).write(to: directory.appendingPathComponent("export.json"))
            }
        })
        do {
            _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
            XCTFail("Corrupt file prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .invalidPreparation) }
        try assertEmpty(root)
    }

    func testInjectedFailuresAtEveryPreparationStageCleanOnlyOwnedDirectory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: sentinel)
        for failingStage in ExportFileWriter.PreparationStage.allCases {
            let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, _ in
                if stage == failingStage { throw NSError(domain: "private raw IO failure", code: 1) }
            })
            do {
                _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
                XCTFail("Injected failure prepared")
            } catch { XCTAssertEqual(error as? ExportFileWriterError, .preparationFailed) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated"])
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        }
    }

    func testPrivateFileCreationFailurePreservesUnrelatedBytesAndCleansStaging() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated")
        let original = Data("untouched unrelated bytes".utf8)
        try original.write(to: unrelated)
        let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, directory in
            if stage == .encoded {
                // Force a real exclusive-create failure; never follow an existing link.
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("export.json"),
                                                          withDestinationURL: unrelated)
            }
        })
        do {
            _ = try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot())
            XCTFail("Existing private file overwritten")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .preparationFailed) }
        XCTAssertEqual(try Data(contentsOf: unrelated), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated"])
    }

    func testUnavailableTemporaryRootFailsWithoutCreatingAnything() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await ExportFileWriter(temporaryRoot: root.appendingPathComponent("absent")).prepare(snapshot())
            XCTFail("Unavailable storage prepared")
        } catch { XCTAssertEqual(error as? ExportFileWriterError, .preparationFailed) }
        try assertEmpty(root)
    }

    func testCancellationBeforePreparationCreatesNoArtifact() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExportFileWriter(temporaryRoot: root).prepare(snapshot)
        }
        do { _ = try await task.value; XCTFail("Canceled preparation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertEmpty(root)
    }

    @MainActor
    func testCancellationAtEveryStageWaitsForWorkerAndCleansBeforeReturning() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        for cancellationStage in ExportFileWriter.PreparationStage.allCases {
            let reached = expectation(description: "Worker reached stage")
            let release = DispatchSemaphore(value: 0)
            let hooks = ExportFileWriter.PreparationHooks(checkpoint: { stage, _ in
                if stage == cancellationStage {
                    XCTAssertFalse(Thread.isMainThread)
                    reached.fulfill()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw ExportFileWriterError.preparationFailed
                    }
                }
            })
            let task = Task { try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot) }
            await fulfillment(of: [reached], timeout: 5)
            task.cancel()
            // The noncooperative checkpoint still owns its directory at this point.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
            release.signal()
            do { _ = try await task.value; XCTFail("Canceled worker returned artifact") }
            catch { XCTAssertTrue(error is CancellationError) }
            try assertEmpty(root)
        }
    }

    @MainActor
    func testEncodingAndIOLeaveUnrelatedMainActorWorkResponsive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = try snapshot()
        snapshot.tasks[0].notes = String(repeating: "long exact saved answer\n", count: 100_000)
        let enteredEncoder = expectation(description: "Off-main encoder entered")
        let responsive = expectation(description: "Unrelated main-actor work ran")
        let release = DispatchSemaphore(value: 0)
        let hooks = ExportFileWriter.PreparationHooks(encode: { snapshot in
            XCTAssertFalse(Thread.isMainThread)
            enteredEncoder.fulfill()
            guard release.wait(timeout: .now() + 10) == .success else {
                throw ExportFileWriterError.preparationFailed
            }
            return try snapshot.encoded()
        }, checkpoint: { _, _ in XCTAssertFalse(Thread.isMainThread) })
        let task = Task { try await ExportFileWriter(temporaryRoot: root, hooks: hooks).prepare(snapshot) }
        await fulfillment(of: [enteredEncoder], timeout: 5)
        Task { @MainActor in
            XCTAssertTrue(Thread.isMainThread)
            responsive.fulfill()
            release.signal()
        }
        await fulfillment(of: [responsive], timeout: 5)
        let artifact = try await task.value
        try artifact.consume { url in XCTAssertEqual(try LocalDataExport.decode(Data(contentsOf: url)), snapshot) }
        try assertEmpty(root)
    }

    func testConcurrentArtifactAliasesAdmitExactlyOneConsumerAndCleanOnce() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot()
        let artifact = try await ExportFileWriter(temporaryRoot: root).prepare(snapshot)
        let consumed = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        try artifact.consume { url in
                            XCTAssertEqual(try LocalDataExport.decode(Data(contentsOf: url)), snapshot)
                        }
                        return true
                    } catch {
                        XCTAssertEqual(error as? ExportFileWriterError, .artifactUnavailable)
                        return false
                    }
                }
            }
            var successes = 0
            for await success in group { if success { successes += 1 } }
            return successes
        }
        XCTAssertEqual(consumed, 1)
        try artifact.discard()
        try assertEmpty(root)
    }

    func testExplicitDiscardAbandonmentAndThrowingConsumptionCleanArtifacts() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ExportFileWriter(temporaryRoot: root)
        let discarded = try await writer.prepare(snapshot())
        try discarded.discard()
        try discarded.discard()
        try assertEmpty(root)
        var abandoned: PreparedExportArtifact? = try await writer.prepare(snapshot())
        weak let weakArtifact = abandoned
        XCTAssertNotNil(abandoned)
        abandoned = nil
        XCTAssertNil(weakArtifact)
        try assertEmpty(root)
        let consumed = try await writer.prepare(snapshot())
        XCTAssertThrowsError(try consumed.consume { _ -> Void in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
        try assertEmpty(root)
        XCTAssertThrowsError(try consumed.consume { _ in XCTFail("Consumed twice") }) {
            XCTAssertEqual($0 as? ExportFileWriterError, .artifactUnavailable)
        }
    }
}
