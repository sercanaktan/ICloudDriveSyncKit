import XCTest
import Foundation
@testable import ICloudDriveSyncKit

/// A false positive here (flagging a conflict that isn't one) means a
/// person gets an unnecessary "keep local or cloud?" prompt; a false
/// negative (missing a real conflict) means one device's edit silently
/// overwrites another device's edit with no warning at all — the second
/// failure mode is the dangerous one, so these tests lean toward covering
/// every way a conflict could be missed.
final class ConflictDetectionTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var store: InMemoryCloudStore!
    private var worker: ICloudDriveSyncWorker!
    private var envelopeURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        store = InMemoryCloudStore()
        worker = ICloudDriveSyncWorker()
        envelopeURL = tempDir.url.appendingPathComponent("backup.json")
    }

    override func tearDown() {
        tempDir = nil
        store = nil
        worker = nil
        super.tearDown()
    }

    /// `detectConflicts` checks `FileManager.fileExists` against real disk
    /// before ever calling `io.download` (same pattern as `readBackup` —
    /// see `RestoreWorkerTests`'s doc comment) — a real placeholder file
    /// has to exist at `envelopeURL` for it to even attempt the download.
    private func placeAndSeedEnvelope(_ envelope: BackupEnvelope) async throws {
        try Data().write(to: envelopeURL)
        await store.seed(envelopeURL, try JSONEncoder.icloudDriveSync.encode(envelope))
    }

    func testNoConflictWhenNoCloudEnvelopeExistsYet() async {
        let result = await worker.detectConflicts(
            candidateItemIDs: ["a"],
            localModifiedAt: ["a": Date()],
            ourDeviceID: "device-1",
            envelopeURL: envelopeURL,
            io: store.ioPrimitives
        )
        XCTAssertTrue(result.conflictedItemIDs.isEmpty)
        XCTAssertNil(result.cloudEnvelope)
    }

    func testNoConflictWhenTheCloudEnvelopeWasWrittenByThisSameDevice() async throws {
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["a"], deviceID: "device-1", itemModifiedAt: ["a": Date()]
        ))

        let result = await worker.detectConflicts(
            candidateItemIDs: ["a"],
            localModifiedAt: ["a": Date.distantPast],
            ourDeviceID: "device-1", // the same device that wrote the cloud envelope
            envelopeURL: envelopeURL,
            io: store.ioPrimitives
        )

        XCTAssertTrue(result.conflictedItemIDs.isEmpty, "a device must never conflict with its own prior sync")
    }

    func testConflictWhenAnotherDevicesCloudEditIsNewerThanTheLocalEdit() async throws {
        let cloudTime = Date()
        let localTime = cloudTime.addingTimeInterval(-3600)
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["a"], deviceID: "other-device", itemModifiedAt: ["a": cloudTime]
        ))

        let result = await worker.detectConflicts(
            candidateItemIDs: ["a"],
            localModifiedAt: ["a": localTime],
            ourDeviceID: "device-1",
            envelopeURL: envelopeURL,
            io: store.ioPrimitives
        )

        XCTAssertEqual(result.conflictedItemIDs, ["a"])
        XCTAssertEqual(result.cloudEnvelope?.deviceID, "other-device")
    }

    func testNoConflictWhenTheLocalEditIsNewerThanTheCloudEdit() async throws {
        let cloudTime = Date().addingTimeInterval(-3600)
        let localTime = Date()
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["a"], deviceID: "other-device", itemModifiedAt: ["a": cloudTime]
        ))

        let result = await worker.detectConflicts(
            candidateItemIDs: ["a"],
            localModifiedAt: ["a": localTime],
            ourDeviceID: "device-1",
            envelopeURL: envelopeURL,
            io: store.ioPrimitives
        )

        XCTAssertTrue(result.conflictedItemIDs.isEmpty, "the local edit is strictly newer, so this must not be flagged")
    }

    func testEqualTimestampsAreNotFlaggedAsAConflict() async throws {
        // The comparison is strictly `>` — a cloud timestamp exactly equal
        // to the local one (e.g. this device's own edit already synced,
        // read back) must not be treated as "cloud is newer."
        let sameTime = Date()
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["a"], deviceID: "other-device", itemModifiedAt: ["a": sameTime]
        ))

        let result = await worker.detectConflicts(
            candidateItemIDs: ["a"],
            localModifiedAt: ["a": sameTime],
            ourDeviceID: "device-1",
            envelopeURL: envelopeURL,
            io: store.ioPrimitives
        )

        XCTAssertTrue(result.conflictedItemIDs.isEmpty)
    }

    func testIDsMissingModifiedTimeOnEitherSideAreSkippedNotFlagged() async throws {
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["a", "b"], deviceID: "other-device",
            itemModifiedAt: ["a": Date()] // "b" has no cloud-side modified time at all
        ))

        let result = await worker.detectConflicts(
            candidateItemIDs: ["a", "b"],
            localModifiedAt: [:], // neither "a" nor "b" has a local modified time either
            ourDeviceID: "device-1",
            envelopeURL: envelopeURL,
            io: store.ioPrimitives
        )

        XCTAssertTrue(result.conflictedItemIDs.isEmpty, "an id missing modified-time data on either side must never become a false-positive conflict")
    }

    func testOnlyCandidateItemIDsAreConsideredEvenIfOthersWouldConflict() async throws {
        let cloudTime = Date()
        let localTime = cloudTime.addingTimeInterval(-3600)
        try await placeAndSeedEnvelope(BackupEnvelope(
            appName: "TestApp", schemaVersion: 1, exportedAt: Date(),
            itemIDs: ["a", "b"], deviceID: "other-device",
            itemModifiedAt: ["a": cloudTime, "b": cloudTime]
        ))

        let result = await worker.detectConflicts(
            candidateItemIDs: ["a"], // "b" would also conflict, but wasn't asked about
            localModifiedAt: ["a": localTime, "b": localTime],
            ourDeviceID: "device-1",
            envelopeURL: envelopeURL,
            io: store.ioPrimitives
        )

        XCTAssertEqual(result.conflictedItemIDs, ["a"])
    }
}
