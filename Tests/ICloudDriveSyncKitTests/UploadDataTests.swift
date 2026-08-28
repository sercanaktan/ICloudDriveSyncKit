import XCTest
import Foundation
@testable import ICloudDriveSyncKit

/// `ICloudDriveSyncWorker.uploadData` is the single place this package ever
/// writes to a person's iCloud Drive. These tests cover the three ways it
/// can go quietly wrong: losing/duplicating an item under the bounded
/// concurrency it now uses, letting one bad item silently abort (or
/// silently not abort) the rest of the export, and not actually stopping
/// when cancelled.
final class UploadDataTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var store: InMemoryCloudStore!
    private var worker: ICloudDriveSyncWorker!
    private var itemsURL: URL!
    private var manifestURL: URL!
    private var envelopeURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        store = InMemoryCloudStore()
        worker = ICloudDriveSyncWorker()
        itemsURL = tempDir.url.appendingPathComponent("Items", isDirectory: true)
        manifestURL = tempDir.url.appendingPathComponent("manifest.json")
        envelopeURL = tempDir.url.appendingPathComponent("backup.json")
    }

    override func tearDown() {
        tempDir = nil
        store = nil
        worker = nil
        super.tearDown()
    }

    private func upload(
        items: [String: Data],
        deletedItemIDs: Set<String> = [],
        hostSchemaMetadata: ICloudDriveHostSchemaMetadata? = nil,
        io: ICloudDriveSyncWorker.IOPrimitives? = nil
    ) async throws -> ICloudDriveSyncWorker.UploadDataResult {
        try await worker.uploadData(
            items: items,
            deletedItemIDs: deletedItemIDs,
            manifest: Data("manifest".utf8),
            allItemIDs: Set(items.keys),
            appName: "TestApp",
            exportedAt: Date(),
            deviceID: "device-1",
            itemModifiedAt: [:],
            hostSchemaMetadata: hostSchemaMetadata,
            itemsURL: itemsURL,
            manifestURL: manifestURL,
            envelopeURL: envelopeURL,
            io: io ?? store.ioPrimitives,
            onProgress: { _, _, _, _ in }
        )
    }

    func testEveryItemIsWrittenExactlyOnceIncludingNestedIDs() async throws {
        let items: [String: Data] = [
            "note-1": Data("hello".utf8),
            "note-2": Data("world".utf8),
            "diary/2024-01-01": Data("nested".utf8)
        ]

        let result = try await upload(items: items)

        XCTAssertEqual(result.exportedItemIDs, Set(items.keys))
        let finalFiles = await store.allFiles()
        for (id, data) in items {
            let url = ICloudDriveFileIO.itemURL(for: id, in: itemsURL)
            XCTAssertEqual(finalFiles[url], data, "item \"\(id)\" was not written to its resolved URL")
        }
        XCTAssertEqual(finalFiles[manifestURL], Data("manifest".utf8))
        XCTAssertNotNil(finalFiles[envelopeURL], "the envelope must always be written on a successful export")
    }

    func testEnvelopeListsExactlyAllItemIDsAndTheGivenDeviceID() async throws {
        let items = ["a": Data(), "b": Data()]
        _ = try await upload(items: items)

        let finalFiles = await store.allFiles()
        let envelopeData = try XCTUnwrap(finalFiles[envelopeURL])
        let envelope = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData)

        XCTAssertEqual(Set(envelope.itemIDs), Set(items.keys))
        XCTAssertEqual(envelope.deviceID, "device-1")
    }

    func testEnvelopeIncludesHostSchemaMetadataWhenProvided() async throws {
        let metadata = ICloudDriveHostSchemaMetadata(
            dataSchemaVersion: 2,
            minimumSupportedDataSchemaVersion: 1,
            appVersion: "1.1",
            appBuild: "42",
            additionalInfo: ["migration": "user-settings-to-preferences"]
        )
        _ = try await upload(items: ["a": Data()], hostSchemaMetadata: metadata)

        let finalFiles = await store.allFiles()
        let envelopeData = try XCTUnwrap(finalFiles[envelopeURL])
        let envelope = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData)

        XCTAssertEqual(envelope.hostSchemaMetadata, metadata)
    }

    func testRequestedDeletesActuallyRemoveTheItem() async throws {
        let staleURL = ICloudDriveFileIO.itemURL(for: "stale", in: itemsURL)
        await store.seed(staleURL, Data("old".utf8))

        _ = try await upload(items: ["fresh": Data("new".utf8)], deletedItemIDs: ["stale"])

        let finalFiles = await store.allFiles()
        XCTAssertNil(finalFiles[staleURL], "an item in `deletedItemIDs` must actually be gone afterward")
    }

    /// A single stuck delete (a file iCloud won't let go of right now, say)
    /// must never abort the rest of the export — deletes are explicitly
    /// best-effort, unlike writes below.
    func testAFailedDeleteIsSwallowedAndTheRestOfTheExportStillSucceeds() async throws {
        let stuckURL = ICloudDriveFileIO.itemURL(for: "stuck", in: itemsURL)
        await store.seed(stuckURL, Data())
        await store.setDeleteFailure(stuckURL)

        let result = try await upload(items: ["new-item": Data("x".utf8)], deletedItemIDs: ["stuck"])

        XCTAssertEqual(result.exportedItemIDs, ["new-item"])
        let finalFiles = await store.allFiles()
        XCTAssertNotNil(finalFiles[stuckURL], "a failed delete must leave the item exactly as it was, not silently drop it")
        XCTAssertNotNil(finalFiles[envelopeURL], "the export must still complete past a swallowed delete failure")
    }

    /// Unlike a delete failure, a single failed *write* must abort the
    /// whole export — nothing past it (including the manifest/envelope)
    /// should ever be written, since a partial export with a missing item
    /// but a manifest claiming otherwise would be worse than no export at
    /// all.
    func testAFailedWriteAbortsTheWholeExportBeforeManifestOrEnvelope() async throws {
        let failingURL = ICloudDriveFileIO.itemURL(for: "will-fail", in: itemsURL)
        await store.setWriteFailure(failingURL)

        do {
            _ = try await upload(items: ["will-fail": Data("x".utf8)])
            XCTFail("expected the write failure to propagate")
        } catch {
            // any error is acceptable here — the point is that it throws.
        }

        let finalFiles = await store.allFiles()
        XCTAssertNil(finalFiles[manifestURL], "manifest must never be written after an item write fails")
        XCTAssertNil(finalFiles[envelopeURL], "envelope must never be written after an item write fails")
    }

    func testCancellationStopsTheWritePassBeforeEveryItemIsWritten() async throws {
        var items: [String: Data] = [:]
        for i in 0..<20 { items["item-\(i)"] = Data("x".utf8) }

        let box = TaskCancelBox<ICloudDriveSyncWorker.UploadDataResult>()
        let store = self.store!
        let io = ICloudDriveSyncWorker.IOPrimitives(
            write: { data, url in
                try await store.write(data, to: url)
                if await store.writeCallCount() >= 3 {
                    box.cancelIfPresent()
                }
            },
            download: { url in try await store.download(url) },
            delete: { url in try await store.delete(url) },
            byteCount: { url in await store.byteCount(url) }
        )

        let task = Task<ICloudDriveSyncWorker.UploadDataResult, Error> {
            try await self.upload(items: items, io: io)
        }
        box.task = task

        do {
            _ = try await task.value
            XCTFail("expected cancellation to abort the export before every item was written")
        } catch is CancellationError {
            // expected
        }

        let writeCount = await store.writeCallCount()
        XCTAssertLessThan(writeCount, items.count, "cancellation should stop the write pass well before every item is touched")
    }
}
