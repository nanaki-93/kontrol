import Darwin
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

    private final class AccessLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0
        private var stops = 0
        func start() { lock.lock(); defer { lock.unlock() }; starts += 1 }
        func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
        var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [starts, stops] }
    }

    private func assertDeliveryClean(_ root: URL, destinationExists: Bool = true,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       destinationExists ? ["destination.json"] : [], file: file, line: line)
    }

    func testAtomicCreationAndReplacementRoundTripAndBalanceTransientAuthorization() async throws {
        for replacing in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            if replacing { try Data("previous bytes".utf8).write(to: target) }
            let ledger = AccessLedger()
            let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                       stopAccess: { _ in ledger.stop() }, checkpoint: { _, _ in
                XCTAssertFalse(Thread.isMainThread)
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let destination = try writer.approveDestination(target)
            let snapshot = try snapshot()
            let artifact = try await writer.prepare(snapshot)
            let outcome = try await writer.deliver(artifact, to: destination)
            XCTAssertEqual(outcome, .committed)
            XCTAssertEqual(try Data(contentsOf: target), try snapshot.encoded())
            XCTAssertEqual(try LocalDataExport.decode(Data(contentsOf: target)), snapshot)
            XCTAssertEqual(ledger.counts, [2, 2])
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try assertDeliveryClean(root)
            XCTAssertThrowsError(try artifact.consume { _ in XCTFail("Delivered artifact reused") }) {
                XCTAssertEqual($0 as? ExportFileWriterError, .artifactUnavailable)
            }
        }
    }

    func testOrdinaryNonscopedDestinationDoesNotStopUnacquiredAuthorization() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return false },
                                                   stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let destination = try writer.approveDestination(root.appendingPathComponent("destination.json"))
        let artifact = try await writer.prepare(snapshot())
        let outcome = try await writer.deliver(artifact, to: destination)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(ledger.counts, [2, 0])
        try assertDeliveryClean(root)
    }

    func testApprovalRejectsDirectoriesSymlinksAndDanglingSymlinksWithoutChangingBytes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("untouched".utf8)
        let target = root.appendingPathComponent("destination.json")
        try original.write(to: target)
        let link = root.appendingPathComponent("link")
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                   stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        for unsafe in [root, link, dangling, URL(string: "https://example.com/export.json")!] {
            XCTAssertThrowsError(try writer.approveDestination(unsafe)) {
                XCTAssertEqual($0 as? ExportFileWriterError, .unsafeDestination)
            }
        }
        XCTAssertEqual(ledger.counts, [3, 3])
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
    }

    func testChangedReplacementInodeAndInPlaceEditAreRejectedAndPreserveCurrentBytes() async throws {
        for replaceInode in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            try Data("original".utf8).write(to: target)
            let writer = ExportFileWriter(temporaryRoot: root)
            let approved = try writer.approveDestination(target)
            let current = Data("externally changed bytes".utf8)
            try current.write(to: target, options: replaceInode ? .atomic : [])
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Changed identity replaced") }
            catch { XCTAssertEqual(error as? ExportFileWriterError, .destinationChanged) }
            XCTAssertEqual(try Data(contentsOf: target), current)
            try assertDeliveryClean(root)
        }
    }

    func testIdentityIsRecheckedImmediatelyBeforeCommitAndCleansSibling() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        try Data("original".utf8).write(to: target)
        let current = Data("external replacement during staging".utf8)
        let hooks = ExportFileWriter.DeliveryHooks(checkpoint: { stage, _ in
            if stage == .beforeCommit { try current.write(to: target, options: .atomic) }
        })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Changed target replaced") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .destinationChanged) }
        XCTAssertEqual(try Data(contentsOf: target), current)
        try assertDeliveryClean(root)
    }

    func testAppearedAndRemovedDestinationsAndNewUnsafeTargetsFailSafely() async throws {
        for change in 0..<4 {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let existing = Data("current bytes".utf8)
            if change == 1 { try existing.write(to: target) }
            let writer = ExportFileWriter(temporaryRoot: root)
            let approved = try writer.approveDestination(target)
            switch change {
            case 0: try existing.write(to: target)
            case 1: try FileManager.default.removeItem(at: target)
            case 2: try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
            }
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Changed target accepted") }
            catch {
                XCTAssertEqual(error as? ExportFileWriterError, change < 2 ? .destinationChanged : .unsafeDestination)
            }
            if change == 0 { XCTAssertEqual(try Data(contentsOf: target), existing) }
            if change == 2 { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), []) }
            if change == 3 { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), root.appendingPathComponent("missing").path) }
            try assertDeliveryClean(root, destinationExists: change != 1)
        }
    }

    func testDeniedAuthorizationCleansArtifactWithoutStoppingUnacquiredScope() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let original = Data("preserve denied destination".utf8)
        try original.write(to: target)
        let approved = try ExportFileWriter().approveDestination(target)
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in
            ledger.start()
            throw NSError(domain: "private access denied", code: Int(EACCES))
        }, stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Denied access saved") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        XCTAssertEqual(ledger.counts, [1, 0])
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertDeliveryClean(root)
    }

    func testEveryPrecommitFailurePreservesDestinationAndBalancesAuthorization() async throws {
        for failingStage in ExportFileWriter.DeliveryStage.allCases where failingStage != .committed {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("preserve failure destination".utf8)
            try original.write(to: target)
            let ledger = AccessLedger()
            let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                       stopAccess: { _ in ledger.stop() }, checkpoint: { stage, _ in
                if stage == failingStage { throw NSError(domain: "private disk failure", code: Int(ENOSPC)) }
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let approved = try writer.approveDestination(target)
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Failed delivery saved") }
            catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
            XCTAssertEqual(ledger.counts, [2, 2])
            XCTAssertEqual(try Data(contentsOf: target), original)
            try assertDeliveryClean(root)
        }
    }

    func testDiskAndAtomicReplacementFailuresPreserveOriginalAndCleanAllStaging() async throws {
        for code in [ENOSPC, EACCES, EIO] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("original replacement bytes".utf8)
            try original.write(to: target)
            let hooks = ExportFileWriter.DeliveryHooks(commit: { _, _, replacing in
                XCTAssertTrue(replacing)
                throw NSError(domain: "sensitive filesystem path", code: Int(code))
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let approved = try writer.approveDestination(target)
            let artifact = try await writer.prepare(snapshot())
            do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Commit failure saved") }
            catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
            XCTAssertEqual(try Data(contentsOf: target), original)
            try assertDeliveryClean(root)
        }
    }

    func testPartialStagingWriteAndDiskFullFailureNeverChangeDestination() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let original = Data("original disk-full destination".utf8)
        try original.write(to: target)
        let hooks = ExportFileWriter.DeliveryHooks(writeStaging: { bytes, descriptor in
            // Model ENOSPC after a real partial write, not just before staging.
            let partial = bytes.prefix(32)
            try partial.withUnsafeBytes {
                guard Darwin.write(descriptor, $0.baseAddress!, $0.count) == $0.count else {
                    throw ExportFileWriterError.deliveryFailed
                }
            }
            throw NSError(domain: "private disk-full path", code: Int(ENOSPC))
        })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Partial write saved") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertDeliveryClean(root)
    }

    func testSiblingIsPrivateAndOnDestinationVolumeAndPrivateArtifactIsRemovedBeforeCommit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateRoot = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("destination.json")
        let snapshot = try snapshot()
        let bytes = try snapshot.encoded()
        let hooks = ExportFileWriter.DeliveryHooks(checkpoint: { stage, url in
            if stage == .staged {
                XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: privateRoot.path).count, 1)
            }
            if stage == .beforeCommit || stage == .committed {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: privateRoot.path), [])
            }
            if stage == .committed {
                throw NSError(domain: "late noncancellation failure cannot negate saved", code: 1)
            }
        })
        let writer = ExportFileWriter(temporaryRoot: privateRoot, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot)
        let outcome = try await writer.deliver(artifact, to: approved)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["destination.json", "private"])
        try assertEmpty(privateRoot)
    }

    func testRealMissingParentAndExclusiveCreationRaceDoNotOverwriteUnrelatedBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingTarget = root.appendingPathComponent("absent/destination.json")
        let writer = ExportFileWriter(temporaryRoot: root)
        let approved = try writer.approveDestination(missingTarget)
        let artifact = try await writer.prepare(snapshot())
        do { _ = try await writer.deliver(artifact, to: approved); XCTFail("Missing parent saved") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        try assertEmpty(root)
        let target = root.appendingPathComponent("destination.json")
        let current = Data("created just before rename".utf8)
        let hooks = ExportFileWriter.DeliveryHooks(commit: { sibling, destination, replacing in
            XCTAssertFalse(replacing)
            try current.write(to: destination)
            guard renamex_np(sibling.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ExportFileWriterError.deliveryFailed
            }
        })
        let raceWriter = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let newApproved = try raceWriter.approveDestination(target)
        let raceArtifact = try await raceWriter.prepare(snapshot())
        do { _ = try await raceWriter.deliver(raceArtifact, to: newApproved); XCTFail("Exclusive creation overwrote target") }
        catch { XCTAssertEqual(error as? ExportFileWriterError, .deliveryFailed) }
        XCTAssertEqual(try Data(contentsOf: target), current)
        try assertDeliveryClean(root)
    }

    func testCancellationBeforeDeliveryCleansArtifactWithoutAcquiringAuthorization() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("destination.json")
        let original = Data("preserve canceled destination".utf8)
        try original.write(to: target)
        let ledger = AccessLedger()
        let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                   stopAccess: { _ in ledger.stop() })
        let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
        let approved = try writer.approveDestination(target)
        let artifact = try await writer.prepare(snapshot())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await writer.deliver(artifact, to: approved)
        }
        do { _ = try await task.value; XCTFail("Canceled delivery saved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ledger.counts, [1, 1])
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertDeliveryClean(root)
    }

    @MainActor
    func testCancellationAtEveryDeliveryStagePreservesPrecommitBytesButReportsPostcommitSaved() async throws {
        for cancellationStage in ExportFileWriter.DeliveryStage.allCases {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("destination.json")
            let original = Data("original before cancellation".utf8)
            try original.write(to: target)
            let ledger = AccessLedger()
            let reached = expectation(description: "Delivery reached \(cancellationStage)")
            let release = DispatchSemaphore(value: 0)
            let hooks = ExportFileWriter.DeliveryHooks(startAccess: { _ in ledger.start(); return true },
                                                       stopAccess: { _ in ledger.stop() }, checkpoint: { stage, _ in
                XCTAssertFalse(Thread.isMainThread)
                if stage == cancellationStage {
                    reached.fulfill()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw ExportFileWriterError.deliveryFailed
                    }
                    if stage == .committed { throw CancellationError() }
                }
            })
            let writer = ExportFileWriter(temporaryRoot: root, deliveryHooks: hooks)
            let approved = try writer.approveDestination(target)
            let snapshot = try snapshot()
            let artifact = try await writer.prepare(snapshot)
            let task = Task { try await writer.deliver(artifact, to: approved) }
            await fulfillment(of: [reached], timeout: 5)
            task.cancel()
            // A blocked noncooperative worker still owns the operation/scope.
            XCTAssertEqual(ledger.counts, [2, 1])
            release.signal()
            if cancellationStage == .committed {
                let outcome = try await task.value
                XCTAssertEqual(outcome, .committed)
                XCTAssertEqual(try Data(contentsOf: target), try snapshot.encoded())
            } else {
                do { _ = try await task.value; XCTFail("Precommit cancellation saved") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertEqual(try Data(contentsOf: target), original)
            }
            XCTAssertEqual(ledger.counts, [2, 2])
            try assertDeliveryClean(root)
        }
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
