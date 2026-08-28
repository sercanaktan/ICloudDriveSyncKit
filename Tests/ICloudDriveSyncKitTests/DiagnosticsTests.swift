import XCTest
import Foundation
@testable import ICloudDriveSyncKit

@MainActor
final class DiagnosticsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ICloudDriveSyncKitTests.Diagnostics.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEventLogKeepsOnlyTheMostRecentEntriesInsideCapacity() {
        var log = ICloudDriveSyncEventLog(capacity: 2)
        log.append(logEntry(name: "first", level: .info))
        log.append(logEntry(name: "second", level: .warning))
        log.append(logEntry(name: "third", level: .error))

        XCTAssertEqual(log.entries.map(\.name), ["second", "third"])
    }

    func testEventLogCapacityIsAtLeastOne() {
        var log = ICloudDriveSyncEventLog(capacity: 0)
        log.append(logEntry(name: "first", level: .info))
        log.append(logEntry(name: "second", level: .info))

        XCTAssertEqual(log.entries.map(\.name), ["second"])
    }

    func testDiagnosticsSnapshotReportsCurrentEngineStateWithoutItemIDs() {
        let engine = makeEngine(appName: "Diagnostics Host", eventLogCapacity: 4, isICloudAvailable: false)
        engine.notifyDataChanged(changedItemIDs: ["secret-note-id"], deletedItemIDs: ["deleted-note-id"])
        engine.notifyPreferencesChanged()
        engine.selectAutoSyncMode(.wifi)

        let snapshot = engine.makeDiagnosticsSnapshot()

        XCTAssertEqual(snapshot.appName, "Diagnostics Host")
        XCTAssertEqual(snapshot.deviceID, engine.deviceID)
        XCTAssertFalse(snapshot.isICloudAvailable)
        XCTAssertEqual(snapshot.autoSyncMode, .wifi)
        XCTAssertFalse(snapshot.isSyncing)
        XCTAssertFalse(snapshot.isNetworkConnected)
        XCTAssertTrue(snapshot.hasPendingChanges)
        XCTAssertEqual(snapshot.pendingItemCount, 1)
        XCTAssertEqual(snapshot.pendingDeletedItemCount, 1)
        XCTAssertTrue(snapshot.hasPendingPreferencesChange)
        XCTAssertEqual(snapshot.pendingConflictCount, 0)
        XCTAssertEqual(snapshot.syncOutcomeDescription, "warning(waitingForNetwork)")
        XCTAssertEqual(snapshot.syncMessage, ICloudDriveSyncConfig.Messages().waitingForNetwork)
        XCTAssertNil(snapshot.lastRestoreReport)
        XCTAssertEqual(snapshot.recentEvents.map(\.name), ["icloud_auto_sync_mode_changed"])
        XCTAssertFalse(snapshot.jsonString().contains("secret-note-id"))
        XCTAssertFalse(snapshot.jsonString().contains("deleted-note-id"))
    }

    func testDiagnosticsSnapshotReportsICloudAvailabilityFromBackupURLProvider() {
        let engine = makeEngine(isICloudAvailable: true)

        let snapshot = engine.makeDiagnosticsSnapshot()

        XCTAssertTrue(snapshot.isICloudAvailable)
    }

    func testRecentEventsAndLastErrorTrackLoggedFailures() async {
        let engine = makeEngine(isICloudAvailable: false)

        await engine.refreshBackupStatus()

        XCTAssertEqual(engine.syncOutcome, .failure(.iCloudUnavailable))
        XCTAssertEqual(engine.syncMessage, ICloudDriveSyncConfig.Messages().iCloudDriveUnavailable)
        XCTAssertTrue(engine.recentEvents.isEmpty)
        XCTAssertNil(engine.lastError)

        let snapshot = engine.makeDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.syncOutcomeDescription, "failure(iCloudUnavailable)")
        XCTAssertEqual(snapshot.syncMessage, ICloudDriveSyncConfig.Messages().iCloudDriveUnavailable)
    }

    func testLoggedEventsAreForwardedAndCappedInDiagnosticsSnapshot() {
        let engine = makeEngine(eventLogCapacity: 2)
        var forwardedEvents: [String] = []
        engine.onEvent = { name, _ in forwardedEvents.append(name) }

        engine.selectAutoSyncMode(.wifi)
        engine.selectAutoSyncMode(.always)
        engine.selectAutoSyncMode(.off)

        let snapshot = engine.makeDiagnosticsSnapshot()

        XCTAssertEqual(forwardedEvents, [
            "icloud_auto_sync_mode_changed",
            "icloud_auto_sync_mode_changed",
            "icloud_auto_sync_mode_changed"
        ])
        XCTAssertEqual(snapshot.recentEvents.map(\.name), [
            "icloud_auto_sync_mode_changed",
            "icloud_auto_sync_mode_changed"
        ])
        XCTAssertEqual(snapshot.recentEvents.map { $0.data["mode"] }, ["always", "off"])
    }

    func testDiagnosticsJSONCanBeParsedAndIncludesStableKeys() throws {
        let snapshot = ICloudDriveSyncDiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            appName: "Diagnostics Host",
            deviceID: "device-1",
            isICloudAvailable: true,
            autoSyncMode: .always,
            isSyncing: false,
            isNetworkConnected: true,
            isWiFiConnected: true,
            isCellularConnected: false,
            isLowDataModeEnabled: false,
            hasUnrestoredBackup: false,
            hasPendingChanges: true,
            pendingItemCount: 2,
            pendingDeletedItemCount: 1,
            pendingConflictCount: 0,
            hasPendingPreferencesChange: true,
            lastRestoredHostSchemaMetadata: ICloudDriveHostSchemaMetadata(dataSchemaVersion: 2, appVersion: "1.1"),
            lastSyncAt: Date(timeIntervalSince1970: 1_800_000_100),
            backupByteCount: 2048,
            syncOutcomeDescription: "success(synced)",
            syncMessage: "Synced.",
            lastRestoreReport: ICloudDriveSyncDiagnosticsSnapshot.RestoreReportSummary(
                expectedItemCount: 4,
                restoredItemCount: 3,
                missingItemCount: 1,
                failedItemCount: 0
            ),
            recentEvents: [
                ICloudDriveSyncLogEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    timestamp: Date(timeIntervalSince1970: 1_800_000_050),
                    name: "icloud_sync_completed",
                    level: .info,
                    data: ["automatic": "false"]
                )
            ]
        )

        let data = try XCTUnwrap(snapshot.jsonString(prettyPrinted: false).data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let restoreReport = try XCTUnwrap(object["lastRestoreReport"] as? [String: Any])
        let recentEvents = try XCTUnwrap(object["recentEvents"] as? [[String: Any]])

        XCTAssertEqual(object["appName"] as? String, "Diagnostics Host")
        XCTAssertEqual(object["deviceID"] as? String, "device-1")
        XCTAssertEqual(object["autoSyncMode"] as? String, "always")
        XCTAssertEqual(object["syncOutcomeDescription"] as? String, "success(synced)")
        XCTAssertEqual(object["backupByteCount"] as? Int, 2048)
        let metadata = try XCTUnwrap(object["lastRestoredHostSchemaMetadata"] as? [String: Any])
        XCTAssertEqual(metadata["dataSchemaVersion"] as? Int, 2)
        XCTAssertEqual(metadata["appVersion"] as? String, "1.1")
        XCTAssertEqual(restoreReport["missingItemCount"] as? Int, 1)
        XCTAssertEqual(restoreReport["failedItemCount"] as? Int, 0)
        XCTAssertEqual(recentEvents.first?["name"] as? String, "icloud_sync_completed")
    }

    private func makeEngine(
        appName: String = "Diagnostics Tests",
        eventLogCapacity: Int = 100,
        isICloudAvailable: Bool = true
    ) -> ICloudDriveSyncEngine {
        let config = ICloudDriveSyncConfig(
            appName: appName,
            defaultAutoSyncMode: .off,
            userDefaultsKeyPrefix: "diagnostics_",
            eventLogCapacity: eventLogCapacity
        )
        return ICloudDriveSyncEngine(
            config: config,
            userDefaults: defaults,
            backupEnvelopeURL: {
                isICloudAvailable ? URL(fileURLWithPath: "/tmp/DiagnosticsBackup.json") : nil
            },
            ioPrimitives: InMemoryCloudStore().ioPrimitives
        )
    }

    private func logEntry(name: String, level: ICloudDriveSyncLogEntry.Level) -> ICloudDriveSyncLogEntry {
        ICloudDriveSyncLogEntry(timestamp: Date(timeIntervalSince1970: 1_800_000_000), name: name, level: level, data: [:])
    }
}
