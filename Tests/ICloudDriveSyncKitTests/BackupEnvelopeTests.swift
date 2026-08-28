import XCTest
import Foundation
@testable import ICloudDriveSyncKit

/// `BackupEnvelope`'s lenient decoding is the one deliberate "legacy
/// support" exception in this whole package (see the type's own doc
/// comment) — an envelope written before conflict detection existed has no
/// `deviceID`/`itemModifiedAt` keys at all, and decoding one of those must
/// still succeed with safe defaults. A regression here doesn't just break a
/// feature — it makes an existing person's cloud backup permanently
/// unreadable by every future version of the app.
final class BackupEnvelopeTests: XCTestCase {
    func testRoundTripEncodeDecodePreservesEveryField() throws {
        let original = BackupEnvelope(
            appName: "TestApp",
            schemaVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            itemIDs: ["a", "b", "diary/c"],
            deviceID: "device-1",
            itemModifiedAt: ["a": Date(timeIntervalSince1970: 1_700_000_100)],
            backupID: "snapshot-1",
            label: "Before migration",
            hostSchemaMetadata: ICloudDriveHostSchemaMetadata(
                dataSchemaVersion: 2,
                minimumSupportedDataSchemaVersion: 1,
                appVersion: "1.1",
                appBuild: "42",
                additionalInfo: ["flavor": "pro"]
            )
        )

        let data = try JSONEncoder.icloudDriveSync.encode(original)
        let decoded = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: data)

        XCTAssertEqual(decoded.appName, original.appName)
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)
        XCTAssertEqual(decoded.itemIDs, original.itemIDs)
        XCTAssertEqual(decoded.deviceID, original.deviceID)
        XCTAssertEqual(decoded.itemModifiedAt, original.itemModifiedAt)
        XCTAssertEqual(decoded.backupID, original.backupID)
        XCTAssertEqual(decoded.label, original.label)
        XCTAssertEqual(decoded.hostSchemaMetadata, original.hostSchemaMetadata)
    }

    func testDecodesLegacyEnvelopeMissingConflictFields() throws {
        let legacyJSON = """
        {
            "appName": "TestApp",
            "schemaVersion": 1,
            "exportedAt": "2023-01-01T00:00:00Z",
            "itemIDs": ["a", "b"]
        }
        """
        let decoded = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.itemIDs, ["a", "b"])
        // An empty deviceID can never equal a real device's id, so an old
        // envelope is always (and safely) treated as "written by some other
        // device" everywhere this is compared.
        XCTAssertEqual(decoded.deviceID, "")
        XCTAssertEqual(decoded.itemModifiedAt, [:])
        XCTAssertNil(decoded.backupID)
        XCTAssertNil(decoded.label)
        XCTAssertNil(decoded.hostSchemaMetadata)
    }

    func testDecodesEnvelopeWithNullConflictFieldsTheSameAsMissingOnes() throws {
        // Not just an absent key — an explicit JSON `null` for these same
        // two fields (which a hand-edited or third-party-written envelope
        // could plausibly contain) must degrade exactly the same way.
        let jsonWithNulls = """
        {
            "appName": "TestApp",
            "schemaVersion": 1,
            "exportedAt": "2023-01-01T00:00:00Z",
            "itemIDs": ["a"],
            "deviceID": null,
            "itemModifiedAt": null
        }
        """
        let decoded = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: Data(jsonWithNulls.utf8))

        XCTAssertEqual(decoded.deviceID, "")
        XCTAssertEqual(decoded.itemModifiedAt, [:])
    }

    func testMissingRequiredFieldStillThrowsRatherThanInventingData() {
        // `itemIDs` (unlike `deviceID`/`itemModifiedAt`) was never made
        // optional — a genuinely malformed envelope should still fail to
        // decode instead of silently returning an empty/fake item list,
        // which downstream would look exactly like "empty backup" and could
        // make a real backup appear to not exist.
        let malformedJSON = """
        {
            "appName": "TestApp",
            "schemaVersion": 1,
            "exportedAt": "2023-01-01T00:00:00Z"
        }
        """
        XCTAssertThrowsError(try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: Data(malformedJSON.utf8)))
    }
}
