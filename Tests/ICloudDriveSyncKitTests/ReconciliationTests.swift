import XCTest
import Foundation
@testable import ICloudDriveSyncKit

/// `reconcileOrphanedItems` is the most dangerous method in this whole
/// package: it deletes real files from a person's iCloud backup based on a
/// computed diff, with no confirmation step. A bug here doesn't corrupt or
/// lose local data (it only ever touches the cloud copy, and only ever
/// files *not* in the host's current roster), but it could delete a cloud
/// item that should have survived — these tests exist to make that as hard
/// to do by accident as possible. Every test here operates on a real
/// temp-directory `Items/` folder, since `coordinatedListFiles(under:)`
/// walks real disk.
final class ReconciliationTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var itemsURL: URL!
    private var worker: ICloudDriveSyncWorker!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        itemsURL = tempDir.url.appendingPathComponent("Items", isDirectory: true)
        try? FileManager.default.createDirectory(at: itemsURL, withIntermediateDirectories: true)
        worker = ICloudDriveSyncWorker()
    }

    override func tearDown() {
        tempDir = nil
        itemsURL = nil
        worker = nil
        super.tearDown()
    }

    /// Writes a real, empty placeholder file at an id's resolved URL — these
    /// tests only care about which files exist afterward, never their
    /// contents.
    @discardableResult
    private func writeItem(_ id: String) throws -> URL {
        let url = ICloudDriveFileIO.itemURL(for: id, in: itemsURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: url)
        return url
    }

    private func deletingIO() -> ICloudDriveSyncWorker.IOPrimitives {
        ICloudDriveSyncWorker.IOPrimitives(
            write: { _, _ in },
            download: { _ in Data() },
            delete: { url in try FileManager.default.removeItem(at: url) },
            byteCount: { _ in nil }
        )
    }

    func testRemovesOnlyFilesNotInTheExpectedIDs() async throws {
        let keptURL = try writeItem("keep-me")
        let orphanURL = try writeItem("orphan-me")

        let result = try await worker.reconcileOrphanedItems(
            expectedItemIDs: ["keep-me"],
            itemsURL: itemsURL,
            io: deletingIO()
        )

        XCTAssertEqual(result.removedItemCount, 1)
        XCTAssertEqual(result.removedRelativePaths, ["orphan-me.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path), "an item still in the expected roster must survive a reconciliation sweep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path), "an orphaned item should have been removed")
    }

    func testKeepsNestedFolderIDsWhenTheyAreExpected() async throws {
        let keptURL = try writeItem("diary/2024-01-01-abc")
        let orphanURL = try writeItem("diary/2024-01-02-orphan")

        let result = try await worker.reconcileOrphanedItems(
            expectedItemIDs: ["diary/2024-01-01-abc"],
            itemsURL: itemsURL,
            io: deletingIO()
        )

        XCTAssertEqual(result.removedItemCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path), "a nested (subfoldered) id that's still expected must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    /// The single most important guarantee this type has: when every file
    /// on disk is in the expected set, `delete` must never be called even
    /// once. A bug that deletes-then-recreates, or that computes the diff
    /// backward, would still often "look right" on the count alone.
    func testNoOrphansMeansDeleteIsNeverCalledAtAll() async throws {
        try writeItem("a")
        try writeItem("b")
        var deleteCallCount = 0
        let io = ICloudDriveSyncWorker.IOPrimitives(
            write: { _, _ in },
            download: { _ in Data() },
            delete: { _ in deleteCallCount += 1 },
            byteCount: { _ in nil }
        )

        let result = try await worker.reconcileOrphanedItems(
            expectedItemIDs: ["a", "b"],
            itemsURL: itemsURL,
            io: io
        )

        XCTAssertEqual(result.removedItemCount, 0)
        XCTAssertEqual(result.removedRelativePaths, [])
        XCTAssertEqual(deleteCallCount, 0, "must never call delete when nothing is orphaned")
    }

    func testEmptyOrMissingItemsDirectoryIsANoOpNotAnError() async throws {
        // A fresh install / pre-first-export state — nothing has ever been
        // exported yet, so the `Items/` folder doesn't exist on disk at all.
        let neverCreated = tempDir.url.appendingPathComponent("NeverCreated", isDirectory: true)

        let result = try await worker.reconcileOrphanedItems(
            expectedItemIDs: ["anything"],
            itemsURL: neverCreated,
            io: deletingIO()
        )

        XCTAssertEqual(result.removedItemCount, 0)
    }

    func testAFailedDeleteIsNotReportedAsRemovedAndTheFileSurvives() async throws {
        let orphanURL = try writeItem("stuck-orphan")

        let io = ICloudDriveSyncWorker.IOPrimitives(
            write: { _, _ in },
            download: { _ in Data() },
            delete: { _ in throw TestFailure.simulatedDeleteFailure },
            byteCount: { _ in nil }
        )

        let result = try await worker.reconcileOrphanedItems(
            expectedItemIDs: [],
            itemsURL: itemsURL,
            io: io
        )

        XCTAssertEqual(result.removedItemCount, 0, "a failed delete must not be counted as removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path), "the file must still be there since the real delete never actually happened")
    }

    func testOneStuckDeleteDoesNotStopTheRestOfTheSweep() async throws {
        let stuckURL = try writeItem("stuck")
        let removableURL = try writeItem("removable")

        let io = ICloudDriveSyncWorker.IOPrimitives(
            write: { _, _ in },
            download: { _ in Data() },
            delete: { url in
                if url == stuckURL {
                    throw TestFailure.simulatedDeleteFailure
                }
                try FileManager.default.removeItem(at: url)
            },
            byteCount: { _ in nil }
        )

        let result = try await worker.reconcileOrphanedItems(
            expectedItemIDs: [],
            itemsURL: itemsURL,
            io: io
        )

        XCTAssertEqual(result.removedItemCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuckURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removableURL.path))
    }

    func testCancellationAtEntryRemovesNothing() async throws {
        try writeItem("orphan-1")
        try writeItem("orphan-2")

        let task = Task<ICloudDriveSyncWorker.RawReconciliationResult, Error> {
            try Task.checkCancellation()
            return try await self.worker.reconcileOrphanedItems(
                expectedItemIDs: [],
                itemsURL: self.itemsURL,
                io: self.deletingIO()
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected a CancellationError")
        } catch is CancellationError {
            // expected
        }

        let remaining = try await ICloudDriveFileIO.coordinatedListFiles(under: itemsURL)
        XCTAssertEqual(remaining.count, 2, "cancelling before the sweep starts must leave every file untouched")
    }

    /// A stronger version of the cancellation guarantee: cancelling
    /// mid-sweep (not just before it starts) must still stop the sweep from
    /// processing every orphan — the cancellation trigger fires from
    /// *inside* one of the sweep's own delete calls, which sidesteps the
    /// race a `task.cancel()` called from outside the task would have
    /// against the task's very first line running first.
    func testCancellationMidSweepStopsBeforeRemovingEveryOrphan() async throws {
        for i in 0..<10 {
            try writeItem("orphan-\(i)")
        }

        let box = TaskCancelBox<ICloudDriveSyncWorker.RawReconciliationResult>()
        let deleteCounter = LockedCounter()
        let io = ICloudDriveSyncWorker.IOPrimitives(
            write: { _, _ in },
            download: { _ in Data() },
            delete: { url in
                if deleteCounter.incrementAndCheck(target: 3) {
                    box.cancelIfPresent()
                }
                try FileManager.default.removeItem(at: url)
            },
            byteCount: { _ in nil }
        )

        let task = Task<ICloudDriveSyncWorker.RawReconciliationResult, Error> {
            try await self.worker.reconcileOrphanedItems(expectedItemIDs: [], itemsURL: self.itemsURL, io: io)
        }
        box.task = task

        do {
            _ = try await task.value
            XCTFail("expected cancellation to abort the sweep before every orphan was processed")
        } catch is CancellationError {
            // expected
        }

        let finalDeleteCount = deleteCounter.value
        XCTAssertLessThan(finalDeleteCount, 10, "cancellation should stop the sweep well before every orphan is touched")
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func incrementAndCheck(target: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedValue += 1
        return storedValue == target
    }
}
