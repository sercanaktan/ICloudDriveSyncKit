import XCTest
import Foundation
@testable import ICloudDriveSyncKit

private struct ProgressEvent: Equatable, Sendable {
    let phase: ICloudDriveSyncProgressPhase
    let completed: Int
    let total: Int?
    let itemID: String?
}

final class ProgressTests: XCTestCase {
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
        try? FileManager.default.createDirectory(at: itemsURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        tempDir = nil
        store = nil
        worker = nil
        super.tearDown()
    }

    func testUploadReportsItemManifestAndEnvelopeProgress() async throws {
        let staleURL = ICloudDriveFileIO.itemURL(for: "stale", in: itemsURL)
        await store.seed(staleURL, Data("old".utf8))
        let items: [String: Data] = [
            "a": Data("A".utf8),
            "b": Data("B".utf8),
            "diary/c": Data("C".utf8)
        ]
        let recorder = ProgressRecorder()

        _ = try await worker.uploadData(
            items: items,
            deletedItemIDs: ["stale"],
            manifest: Data("manifest".utf8),
            allItemIDs: Set(items.keys),
            appName: "TestApp",
            exportedAt: Date(),
            deviceID: "device-1",
            itemModifiedAt: [:],
            itemsURL: itemsURL,
            manifestURL: manifestURL,
            envelopeURL: envelopeURL,
            io: store.ioPrimitives,
            onProgress: { phase, completed, total, itemID in
                await recorder.append(ProgressEvent(phase: phase, completed: completed, total: total, itemID: itemID))
            }
        )

        let events = await recorder.snapshot()
        XCTAssertEqual(events.map { $0.completed }, [1, 2, 3, 4, 4, 5, 5, 6])
        XCTAssertEqual(events.map { $0.total }, Array(repeating: 6, count: events.count))
        XCTAssertEqual(events.map { $0.phase }, [
            .uploadingItems,
            .uploadingItems,
            .uploadingItems,
            .uploadingItems,
            .uploadingManifest,
            .uploadingManifest,
            .uploadingEnvelope,
            .uploadingEnvelope
        ])
        XCTAssertEqual(Set(events.compactMap { $0.itemID }), Set(items.keys).union(["stale"]))
    }

    func testReadBackupReportsEnvelopeManifestAndItemProgress() async throws {
        let itemIDs = ["a", "b", "diary/c"]
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp",
            schemaVersion: 1,
            exportedAt: Date(),
            itemIDs: itemIDs,
            deviceID: "device-1",
            itemModifiedAt: [:]
        ))
        await store.seed(manifestURL, Data("manifest".utf8))
        for id in itemIDs {
            try await placeAndSeedItem(id, data: Data(id.utf8))
        }
        let recorder = ProgressRecorder()

        _ = try await worker.readBackup(
            backupURL: envelopeURL,
            manifestURL: manifestURL,
            itemsURL: itemsURL,
            io: store.ioPrimitives,
            onProgress: { phase, completed, total, itemID in
                await recorder.append(ProgressEvent(phase: phase, completed: completed, total: total, itemID: itemID))
            }
        )

        let events = await recorder.snapshot()
        XCTAssertEqual(events.first, ProgressEvent(phase: .downloadingEnvelope, completed: 0, total: nil, itemID: nil))
        XCTAssertEqual(events.dropFirst(1).map { $0.completed }, [1, 2, 3, 4, 5])
        XCTAssertEqual(events.dropFirst(1).map { $0.total }, Array(repeating: 5, count: 5))
        XCTAssertEqual(events.dropFirst(1).map { $0.phase }, [
            .downloadingManifest,
            .downloadingManifest,
            .downloadingItems,
            .downloadingItems,
            .downloadingItems
        ])
        XCTAssertEqual(Set(events.compactMap { $0.itemID }), Set(itemIDs))
    }

    func testReadBackupItemsReportsMissingAndFailedItemsAsCompletedProgress() async throws {
        try await placeAndSeedItem("ok", data: Data("ok".utf8))
        let failingURL = ICloudDriveFileIO.itemURL(for: "failing", in: itemsURL)
        try Data().write(to: failingURL)
        await store.setDownloadFailure(failingURL, error: ICloudDriveSyncError.downloadFailed("simulated"))
        let recorder = ProgressRecorder()

        let result = try await worker.readBackupItems(
            requestedItemIDs: ["ok", "missing", "failing", "ghost"],
            envelopeItemIDs: ["ok", "missing", "failing"],
            itemsURL: itemsURL,
            io: store.ioPrimitives,
            onProgress: { phase, completed, total, itemID in
                await recorder.append(ProgressEvent(phase: phase, completed: completed, total: total, itemID: itemID))
            }
        )

        let events = await recorder.snapshot()
        XCTAssertEqual(events.map { $0.phase }, Array(repeating: ICloudDriveSyncProgressPhase.downloadingItems, count: 4))
        XCTAssertEqual(events.map { $0.completed }, [1, 2, 3, 4])
        XCTAssertEqual(events.map { $0.total }, Array(repeating: 4, count: 4))
        XCTAssertEqual(Set(events.compactMap { $0.itemID }), ["ok", "missing", "failing", "ghost"])
        XCTAssertEqual(result.report.restoredItemCount, 1)
        XCTAssertEqual(result.report.missingItems.count, 2)
        XCTAssertEqual(result.report.failedItems.count, 1)
    }

    func testProgressPercentIsClampedToValidRange() {
        XCTAssertEqual(ICloudDriveSyncProgress(phase: .downloadingItems, completedUnitCount: -1, totalUnitCount: 4).percentCompleted, 0)
        XCTAssertEqual(ICloudDriveSyncProgress(phase: .downloadingItems, completedUnitCount: 2, totalUnitCount: 4).percentCompleted, 50)
        XCTAssertEqual(ICloudDriveSyncProgress(phase: .downloadingItems, completedUnitCount: 8, totalUnitCount: 4).percentCompleted, 100)
        XCTAssertNil(ICloudDriveSyncProgress(phase: .waitingForNetwork).percentCompleted)
        XCTAssertNil(ICloudDriveSyncProgress(phase: .downloadingItems, completedUnitCount: 1, totalUnitCount: 0).percentCompleted)
    }

    private func placeAndSeedItem(_ id: String, data: Data) async throws {
        let url = ICloudDriveFileIO.itemURL(for: id, in: itemsURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        await store.seed(url, data)
    }

    private func placeAndSeedEnvelope(_ envelope: BackupEnvelope) async throws {
        try Data().write(to: envelopeURL)
        await store.seed(envelopeURL, try JSONEncoder.icloudDriveSync.encode(envelope))
    }
}

private actor ProgressRecorder {
    private var events: [ProgressEvent] = []

    func append(_ event: ProgressEvent) {
        events.append(event)
    }

    func snapshot() -> [ProgressEvent] {
        events
    }
}
