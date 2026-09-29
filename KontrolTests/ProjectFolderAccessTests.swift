import Foundation
import XCTest
@testable import Kontrol

final class ProjectFolderAccessTests: XCTestCase {
    private final class FakeOperations: ProjectBookmarkOperations {
        var resolvedFolder: URL?
        var stale = false
        var resolveError: Error?
        var createError: Error?
        var allowed = true
        var starts = 0
        var stops = 0
        var creations = 0
        var resolutions = 0
        var onStart: (() -> Void)?
        let bookmark = Data([0x01, 0x02, 0x03])

        func resolve(_ data: Data) throws -> (folder: URL, isStale: Bool) {
            resolutions += 1
            if let resolveError { throw resolveError }
            guard let resolvedFolder else { throw ProjectFolderAccessError.unresolved }
            return (resolvedFolder, stale)
        }

        func createBookmark(for selectedFolder: URL) throws -> Data {
            creations += 1
            if let createError { throw createError }
            return bookmark
        }

        func startAccessing(_ folder: URL) -> Bool {
            starts += 1
            onStart?()
            return allowed
        }

        func stopAccessing(_ folder: URL) { stops += 1 }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSelectionAndBookmarkReleaseOnSuccessAndThrow() async throws {
        let url = try folder()
        let fake = FakeOperations()
        fake.resolvedFolder = url
        let access = ProjectFolderAccess(operations: fake)
        let result = try await access.withSelectedFolder(url) { scoped in
            XCTAssertEqual(scoped, url)
            return 42
        }
        XCTAssertEqual(result, 42)
        let data = try await access.makeBookmark(selectedFolder: url)
        XCTAssertEqual(data, fake.bookmark)
        XCTAssertEqual(fake.creations, 1)
        do {
            _ = try await access.withBookmark(data) { scoped -> Int in
                XCTAssertEqual(scoped, url)
                throw ProjectFolderAccessError.invalidFolder
            }
            XCTFail("Expected operation failure")
        } catch let error as ProjectFolderAccessError {
            XCTAssertEqual(error, .invalidFolder)
        }
        XCTAssertEqual(fake.starts, 3)
        XCTAssertEqual(fake.stops, 3)
    }

    func testStaleUnresolvedRevokedAndDeniedDoNotRunWorkOrFallBack() async throws {
        let url = try folder()
        let fake = FakeOperations()
        fake.resolvedFolder = url
        let access = ProjectFolderAccess(operations: fake)
        var invoked = false
        func attempt(_ operation: () async throws -> Void, equals expected: ProjectFolderAccessError,
                     file: StaticString = #filePath, line: UInt = #line) async {
            do {
                try await operation()
                XCTFail("Expected classified failure", file: file, line: line)
            } catch let error as ProjectFolderAccessError {
                XCTAssertEqual(error, expected, file: file, line: line)
            } catch {
                XCTFail("Unexpected error type", file: file, line: line)
            }
        }
        fake.stale = true
        await attempt({ try await access.withBookmark(fake.bookmark) { _ in invoked = true } }, equals: .stale)
        XCTAssertEqual(fake.starts, 0)
        fake.stale = false
        fake.resolveError = CocoaError(.fileNoSuchFile)
        await attempt({ try await access.withBookmark(fake.bookmark) { _ in invoked = true } }, equals: .unresolved)
        fake.resolveError = CocoaError(.fileReadNoPermission)
        await attempt({ try await access.withBookmark(fake.bookmark) { _ in invoked = true } }, equals: .revoked)
        fake.resolveError = nil
        fake.allowed = false
        await attempt({ try await access.withBookmark(fake.bookmark) { _ in invoked = true } }, equals: .revoked)
        await attempt({ try await access.withSelectedFolder(url) { _ in invoked = true } }, equals: .denied)
        await attempt({ _ = try await access.makeBookmark(selectedFolder: url) }, equals: .denied)
        XCTAssertFalse(invoked)
        XCTAssertEqual(fake.creations, 0)
        XCTAssertEqual(fake.stops, 0)
        await attempt({ try await access.withBookmark(Data()) { _ in invoked = true } }, equals: .unresolved)
    }

    func testInvalidFolderAndBookmarkFailureReleaseScope() async throws {
        let url = try folder()
        let file = url.appendingPathComponent("file")
        try Data().write(to: file)
        let fake = FakeOperations()
        let access = ProjectFolderAccess(operations: fake)
        do {
            _ = try await access.withSelectedFolder(file) { _ in XCTFail("Not a directory") }
            XCTFail("Expected invalid folder")
        } catch let error as ProjectFolderAccessError {
            XCTAssertEqual(error, .invalidFolder)
        }
        fake.createError = CocoaError(.fileReadNoPermission)
        do {
            _ = try await access.makeBookmark(selectedFolder: url)
            XCTFail("Expected bookmark failure")
        } catch let error as ProjectFolderAccessError {
            XCTAssertEqual(error, .bookmarkCreationFailed)
        }
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.stops, 2)
    }

    func testMutationCancellationBeforeScopeAndBeforeBodyPreventsWork() async throws {
        let url = try folder()
        let fake = FakeOperations()
        fake.resolvedFolder = url
        let access = ProjectFolderAccess(operations: fake)
        var writes = 0

        let alreadyCanceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await access.withMutationBookmark(fake.bookmark) { _ in
                writes += 1
                return 1
            }
        }
        do {
            _ = try await alreadyCanceled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(fake.resolutions, 0)
        XCTAssertEqual(fake.starts, 0)

        // Cancellation after scope acquisition still prevents entry into the mutation body.
        fake.onStart = { withUnsafeCurrentTask { $0?.cancel() } }
        let canceledInScope = Task {
            try await access.withMutationBookmark(fake.bookmark) { _ in
                writes += 1
                return 2
            }
        }
        do {
            _ = try await canceledInScope.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.stops, 1)
    }

    func testMutationReturnsCommittedReceiptWhenCanceledAtBodyReturnButReadStillCancels() async throws {
        let url = try folder()
        let fake = FakeOperations()
        fake.resolvedFolder = url
        let access = ProjectFolderAccess(operations: fake)
        let receipt = "verified revision"
        let mutation = Task {
            try await access.withMutationBookmark(fake.bookmark) { scoped in
                XCTAssertEqual(scoped, url)
                // Stand-in for a committed write and its verified receipt.
                withUnsafeCurrentTask { $0?.cancel() }
                return receipt
            }
        }
        let returnedReceipt = try await mutation.value
        XCTAssertEqual(returnedReceipt, receipt)

        let read = Task {
            try await access.withBookmark(fake.bookmark) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return receipt
            }
        }
        do {
            _ = try await read.value
            XCTFail("Read must still reject a canceled result")
        } catch is CancellationError { }
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.stops, 2)
    }

    func testMutationBookmarkFailuresAndBodyThrowReleaseWithoutFallback() async throws {
        let url = try folder()
        let fake = FakeOperations()
        fake.resolvedFolder = url
        let access = ProjectFolderAccess(operations: fake)
        var invoked = false
        func expect(_ failure: ProjectFolderAccessError) async {
            do {
                _ = try await access.withMutationBookmark(fake.bookmark) { _ -> Int in
                    invoked = true
                    return 0
                }
                XCTFail("Expected \(failure)")
            } catch let error as ProjectFolderAccessError {
                XCTAssertEqual(error, failure)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        fake.stale = true
        await expect(.stale)
        fake.stale = false
        fake.resolveError = CocoaError(.fileNoSuchFile)
        await expect(.unresolved)
        fake.resolveError = CocoaError(.fileReadNoPermission)
        await expect(.revoked)
        fake.resolveError = nil
        fake.allowed = false
        await expect(.revoked)
        XCTAssertFalse(invoked)
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.stops, 0)
        fake.allowed = true
        do {
            _ = try await access.withMutationBookmark(fake.bookmark) { _ -> Int in
                throw ProjectFolderAccessError.invalidFolder
            }
            XCTFail("Expected body error")
        } catch let error as ProjectFolderAccessError {
            XCTAssertEqual(error, .invalidFolder)
        }
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.stops, 1)
    }

    func testCancellationDuringOperationReleasesScope() async throws {
        let url = try folder()
        let fake = FakeOperations()
        let access = ProjectFolderAccess(operations: fake)
        let entered = expectation(description: "entered scope")
        let task = Task {
            try await access.withSelectedFolder(url) { _ in
                entered.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must not leave the grant active.
        }
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.stops, 1)
    }
}
