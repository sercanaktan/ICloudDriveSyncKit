import XCTest
import Foundation
@testable import ICloudDriveSyncKit

/// `readBackup`/`readBackupItems` are what runs on a fresh install with a
/// person's only copy of their data sitting in iCloud — getting the
/// missing-vs-failed classification wrong, or losing items to the bounded
/// concurrency this now uses, means data that should have come back
/// silently doesn't.
///
/// Important wrinkle these tests work around deliberately (see
/// `TestSupport.swift`'s doc comment on `InMemoryCloudStore`):
/// `readBackup` and `downloadOneItem` (inside `readBackupItems`) both check
/// `FileManager.default.fileExists(atPath:)` against real disk *before*
/// calling `io.download` — that's what actually distinguishes "not
/// downloaded from iCloud yet" (→ `.missing`) from a real download failure
/// (→ `.failed`). So every item a test wants to land in `.downloaded` needs
/// a real (content-irrelevant) placeholder file on disk *in addition* to
/// being seeded into the mock store, via `placeAndSeedItem` below.
final class RestoreWorkerTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var store: InMemoryCloudStore!
    private var worker: ICloudDriveSyncWorker!
    private var backupURL: URL!
    private var manifestURL: URL!
    private var itemsURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        store = InMemoryCloudStore()
        worker = ICloudDriveSyncWorker()
        backupURL = tempDir.url.appendingPathComponent("backup.json")
        manifestURL = tempDir.url.appendingPathComponent("manifest.json")
        itemsURL = tempDir.url.appendingPathComponent("Items", isDirectory: true)
        try? FileManager.default.createDirectory(at: itemsURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        tempDir = nil
        store = nil
        worker = nil
        super.tearDown()
    }

    private func placeAndSeedItem(_ id: String, data: Data) async throws {
        let url = ICloudDriveFileIO.itemURL(for: id, in: itemsURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        await store.seed(url, data)
    }

    private func placeAndSeedEnvelope(_ envelope: BackupEnvelope) async throws {
        try Data().write(to: backupURL)
        await store.seed(backupURL, try JSONEncoder.icloudDriveSync.encode(envelope))
    }

    func testReadBackupReturnsNilWhenNoBackupExistsYet() async throws {
        let result = try await worker.readBackup(
            backupURL: backupURL, manifestURL: manifestURL, itemsURL: itemsURL,
            io: store.ioPrimitives, onProgress: { _, _, _, _ in }
        )
        XCTAssertNil(result)
    }

    func testReadBackupDownloadsEnvelopeManifestAndEveryItem() async throws {
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["a", "b", "diary/c"], deviceID: "device-1", itemModifiedAt: [:]
        ))
        await store.seed(manifestURL, Data("manifest".utf8))
        try await placeAndSeedItem("a", data: Data("A".utf8))
        try await placeAndSeedItem("b", data: Data("B".utf8))
        try await placeAndSeedItem("diary/c", data: Data("C".utf8))

        let result = try await worker.readBackup(
            backupURL: backupURL, manifestURL: manifestURL, itemsURL: itemsURL,
            io: store.ioPrimitives, onProgress: { _, _, _, _ in }
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.manifest, Data("manifest".utf8))
        XCTAssertEqual(unwrapped.items["a"], Data("A".utf8))
        XCTAssertEqual(unwrapped.items["b"], Data("B".utf8))
        XCTAssertEqual(unwrapped.items["diary/c"], Data("C".utf8))
        XCTAssertEqual(unwrapped.report.expectedItemCount, 3)
        XCTAssertEqual(unwrapped.report.restoredItemCount, 3)
        XCTAssertTrue(unwrapped.report.missingItems.isEmpty)
        XCTAssertTrue(unwrapped.report.failedItems.isEmpty)
    }

    func testItemNeverDownloadedLocallyIsReportedAsMissingNotFailed() async throws {
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["present", "never-downloaded"], deviceID: "device-1", itemModifiedAt: [:]
        ))
        await store.seed(manifestURL, Data())
        try await placeAndSeedItem("present", data: Data("ok".utf8))
        // "never-downloaded" deliberately gets no placeholder file at all —
        // exactly what an item still sitting un-materialized in iCloud
        // looks like locally.

        let result = try await worker.readBackup(
            backupURL: backupURL, manifestURL: manifestURL, itemsURL: itemsURL,
            io: store.ioPrimitives, onProgress: { _, _, _, _ in }
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.items["present"], Data("ok".utf8))
        XCTAssertNil(unwrapped.items["never-downloaded"])
        XCTAssertEqual(unwrapped.report.missingItems.map(\.itemID), ["never-downloaded"])
        XCTAssertEqual(unwrapped.report.missingItems.first?.reason, .missingFile)
        XCTAssertTrue(unwrapped.report.failedItems.isEmpty)
    }

    func testDownloadFailureIsReportedAsFailedAndDoesNotAbortOtherItems() async throws {
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["good", "stuck"], deviceID: "device-1", itemModifiedAt: [:]
        ))
        await store.seed(manifestURL, Data())
        try await placeAndSeedItem("good", data: Data("ok".utf8))
        let stuckURL = ICloudDriveFileIO.itemURL(for: "stuck", in: itemsURL)
        try Data().write(to: stuckURL) // real placeholder, so this is attempted rather than reported "missing"
        await store.setDownloadFailure(stuckURL, error: ICloudDriveSyncError.downloadFailed("simulated"))

        let result = try await worker.readBackup(
            backupURL: backupURL, manifestURL: manifestURL, itemsURL: itemsURL,
            io: store.ioPrimitives, onProgress: { _, _, _, _ in }
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.items["good"], Data("ok".utf8), "one item's download failure must not affect another item")
        XCTAssertNil(unwrapped.items["stuck"])
        XCTAssertEqual(unwrapped.report.failedItems.map(\.itemID), ["stuck"])
        XCTAssertEqual(unwrapped.report.failedItems.first?.reason, .downloadFailed)
        XCTAssertTrue(unwrapped.report.missingItems.isEmpty)
    }

    func testRequestedItemNoLongerInTheCurrentEnvelopeIsMissing() async throws {
        // `readBackupItems` is also called directly for a targeted retry of
        // specific ids (`retryRestoreItems`) — an id the *current* envelope
        // no longer lists (e.g. deleted on another device since the retry
        // was queued) must resolve to "missing," never crash.
        let result = try await worker.readBackupItems(
            requestedItemIDs: ["ghost"],
            envelopeItemIDs: ["present"],
            itemsURL: itemsURL,
            io: store.ioPrimitives,
            onProgress: { _, _, _, _ in }
        )

        XCTAssertEqual(result.report.missingItems.map(\.itemID), ["ghost"])
        XCTAssertEqual(result.report.missingItems.first?.reason, .missingFile)
    }

    func testCancellationStopsDownloadingBeforeEveryItem() async throws {
        var itemIDs: [String] = []
        for i in 0..<20 {
            let id = "item-\(i)"
            itemIDs.append(id)
            try await placeAndSeedItem(id, data: Data("x".utf8))
        }

        let box = TaskCancelBox<ICloudDriveSyncWorker.RawRestoreItemsResult>()
        let store = self.store!
        let io = ICloudDriveSyncWorker.IOPrimitives(
            write: { data, url in try await store.write(data, to: url) },
            download: { url in
                let data = try await store.download(url)
                if await store.downloadCallCount() >= 3 {
                    box.cancelIfPresent()
                }
                return data
            },
            delete: { url in try await store.delete(url) },
            byteCount: { url in await store.byteCount(url) }
        )

        let task = Task<ICloudDriveSyncWorker.RawRestoreItemsResult, Error> {
            try await self.worker.readBackupItems(
                requestedItemIDs: Set(itemIDs),
                envelopeItemIDs: itemIDs,
                itemsURL: self.itemsURL,
                io: io,
                onProgress: { _, _, _, _ in }
            )
        }
        box.task = task

        do {
            _ = try await task.value
            XCTFail("expected cancellation to stop the restore before every item downloaded")
        } catch is CancellationError {
            // expected
        }

        let downloadCount = await store.downloadCallCount()
        XCTAssertLessThan(downloadCount, itemIDs.count, "cancellation should stop the download loop well before every item is touched")
    }
}
