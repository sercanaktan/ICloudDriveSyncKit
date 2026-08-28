import XCTest
import Foundation
@testable import ICloudDriveSyncKit

@MainActor
final class SnapshotBackupTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var store: InMemoryCloudStore!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var currentBackupURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        store = InMemoryCloudStore()
        suiteName = "ICloudDriveSyncKitTests.SnapshotBackup.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        currentBackupURL = tempDir.url
            .appendingPathComponent("Current", isDirectory: true)
            .appendingPathComponent("Backup.json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        currentBackupURL = nil
        defaults = nil
        suiteName = nil
        store = nil
        tempDir = nil
        super.tearDown()
    }

    func testCreateSnapshotBackupWritesSeparateSnapshotWithoutTouchingCurrentBackup() async throws {
        let metadata = ICloudDriveHostSchemaMetadata(dataSchemaVersion: 3, appVersion: "2.0", appBuild: "9")
        let dataSource = SnapshotDataSource(
            items: [
                "note-1": Data("one".utf8),
                "folder/note-2": Data("two".utf8)
            ],
            preferences: Data("prefs".utf8),
            metadata: metadata
        )
        let engine = makeEngine(dataSource: dataSource)

        let descriptor = try await engine.createSnapshotBackup(label: "Before migration")

        XCTAssertEqual(descriptor.label, "Before migration")
        XCTAssertEqual(descriptor.appName, "Snapshot Tests")
        XCTAssertEqual(descriptor.appVersion, "2.0")
        XCTAssertEqual(descriptor.appBuild, "9")
        XCTAssertEqual(descriptor.hostSchemaMetadata, metadata)
        XCTAssertEqual(descriptor.itemCount, 2)
        XCTAssertGreaterThan(descriptor.byteCount ?? 0, 0)

        let snapshotURL = snapshotBackupURL(id: descriptor.id)
        let snapshotItemsURL = snapshotURL.deletingLastPathComponent().appendingPathComponent("Items", isDirectory: true)
        let files = await store.allFiles()
        XCTAssertNil(files[currentBackupURL], "snapshot creation must not write the normal current backup envelope")
        XCTAssertNotNil(files[snapshotURL])
        XCTAssertEqual(files[snapshotURL.deletingLastPathComponent().appendingPathComponent("Manifest.json")], Data("manifest".utf8))
        XCTAssertEqual(files[snapshotURL.deletingLastPathComponent().appendingPathComponent("Preferences.json")], Data("prefs".utf8))
        XCTAssertEqual(files[ICloudDriveFileIO.itemURL(for: "folder/note-2", in: snapshotItemsURL)], Data("two".utf8))

        let envelopeData = try XCTUnwrap(files[snapshotURL])
        let envelope = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData)
        XCTAssertEqual(envelope.backupID, descriptor.id)
        XCTAssertEqual(envelope.label, "Before migration")
    }

    func testListSnapshotBackupsReturnsDescriptorsSortedNewestFirst() async throws {
        let olderDate = Date(timeIntervalSince1970: 1_800_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_800_000_100)
        try await seedSnapshot(
            id: "older",
            label: "Older backup",
            exportedAt: olderDate,
            items: ["a": Data("A".utf8)],
            metadata: ICloudDriveHostSchemaMetadata(dataSchemaVersion: 1, appVersion: "1.0")
        )
        try await seedSnapshot(
            id: "newer",
            label: "Newer backup",
            exportedAt: newerDate,
            items: ["b": Data("B".utf8), "c": Data("C".utf8)],
            metadata: ICloudDriveHostSchemaMetadata(dataSchemaVersion: 2, appVersion: "1.1")
        )
        let dataSource = SnapshotDataSource()
        let engine = makeEngine(dataSource: dataSource)

        let backups = try await engine.listSnapshotBackups()

        XCTAssertEqual(backups.map(\.id), ["newer", "older"])
        XCTAssertEqual(backups.first?.label, "Newer backup")
        XCTAssertEqual(backups.first?.itemCount, 2)
        XCTAssertEqual(backups.first?.hostSchemaMetadata?.dataSchemaVersion, 2)
        XCTAssertEqual(backups.first?.appVersion, "1.1")
    }

    func testRestoreSnapshotBackupAppliesOnlyTheSelectedSnapshot() async throws {
        let selectedMetadata = ICloudDriveHostSchemaMetadata(dataSchemaVersion: 2, appVersion: "1.1")
        let dataSource = SnapshotDataSource()
        try await seedSnapshot(
            id: "old",
            label: nil,
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            items: ["note": Data("old".utf8)],
            preferences: Data("old-prefs".utf8),
            metadata: ICloudDriveHostSchemaMetadata(dataSchemaVersion: 1, appVersion: "1.0")
        )
        try await seedSnapshot(
            id: "selected",
            label: nil,
            exportedAt: Date(timeIntervalSince1970: 1_800_000_100),
            items: ["note": Data("selected".utf8)],
            preferences: Data("selected-prefs".utf8),
            metadata: selectedMetadata
        )
        let engine = makeEngine(dataSource: dataSource)

        let report = try await engine.restoreSnapshotBackup(id: "selected")

        XCTAssertEqual(report.expectedItemCount, 1)
        XCTAssertEqual(report.restoredItemCount, 1)
        XCTAssertEqual(dataSource.validatedMetadata, selectedMetadata)
        XCTAssertEqual(dataSource.appliedData?.manifest, Data("manifest-selected".utf8))
        XCTAssertEqual(dataSource.appliedData?.items["note"], Data("selected".utf8))
        XCTAssertEqual(dataSource.appliedPreferences, Data("selected-prefs".utf8))
        XCTAssertEqual(engine.lastRestoredHostSchemaMetadata, selectedMetadata)
        XCTAssertTrue(engine.syncOutcome.isSuccess)
    }

    func testDeleteSnapshotBackupDeletesOnlyTheRequestedSnapshot() async throws {
        try await seedCurrentBackup()
        try await seedSnapshot(id: "keep", label: nil, exportedAt: Date(), items: ["keep": Data("keep".utf8)])
        try await seedSnapshot(id: "delete-me", label: nil, exportedAt: Date(), items: ["gone": Data("gone".utf8)])
        let dataSource = SnapshotDataSource()
        let engine = makeEngine(dataSource: dataSource)

        try await engine.deleteSnapshotBackup(id: "delete-me")

        let files = await store.allFiles()
        XCTAssertNotNil(files[currentBackupURL])
        XCTAssertNotNil(files[snapshotBackupURL(id: "keep")])
        XCTAssertNil(files[snapshotBackupURL(id: "delete-me")])
        XCTAssertNil(files[ICloudDriveFileIO.itemURL(
            for: "gone",
            in: snapshotBackupURL(id: "delete-me").deletingLastPathComponent().appendingPathComponent("Items", isDirectory: true)
        )])
    }

    func testInvalidSnapshotIDIsRejectedBeforeTouchingICloud() async throws {
        try await seedSnapshot(id: "keep", label: nil, exportedAt: Date(), items: ["a": Data("A".utf8)])
        let dataSource = SnapshotDataSource()
        let engine = makeEngine(dataSource: dataSource)

        do {
            try await engine.deleteSnapshotBackup(id: "../keep")
            XCTFail("expected path-like snapshot ids to be rejected")
        } catch {
            // expected
        }

        let keptSnapshot = await store.file(at: snapshotBackupURL(id: "keep"))
        let deleteCallCount = await store.deleteCallCount()
        XCTAssertNotNil(keptSnapshot)
        XCTAssertEqual(deleteCallCount, 0)
    }

    private func makeEngine(dataSource: SnapshotDataSource) -> ICloudDriveSyncEngine {
        let config = ICloudDriveSyncConfig(
            appName: "Snapshot Tests",
            backupFileName: "Backup.json",
            manifestFileName: "Manifest.json",
            itemsDirectoryName: "Items",
            preferencesFileName: "Preferences.json",
            defaultAutoSyncMode: .off,
            userDefaultsKeyPrefix: "snapshotBackup_",
            minimumInitialRestoreOverlayDuration: 0
        )
        let resolvedCurrentBackupURL = currentBackupURL!
        let engine = ICloudDriveSyncEngine(
            config: config,
            userDefaults: defaults,
            backupEnvelopeURL: { resolvedCurrentBackupURL },
            ioPrimitives: store.ioPrimitives
        )
        engine.dataSource = dataSource
        return engine
    }

    private func seedCurrentBackup() async throws {
        try FileManager.default.createDirectory(at: currentBackupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: currentBackupURL)
        let envelope = BackupEnvelope(
            appName: "Snapshot Tests",
            schemaVersion: 1,
            exportedAt: Date(),
            itemIDs: [],
            deviceID: "current-device",
            itemModifiedAt: [:]
        )
        await store.seed(currentBackupURL, try JSONEncoder.icloudDriveSync.encode(envelope))
    }

    private func seedSnapshot(
        id backupID: String,
        label: String?,
        exportedAt: Date,
        items: [String: Data],
        preferences: Data = Data("prefs".utf8),
        metadata: ICloudDriveHostSchemaMetadata? = nil
    ) async throws {
        let backupURL = snapshotBackupURL(id: backupID)
        let directoryURL = backupURL.deletingLastPathComponent()
        let manifestURL = directoryURL.appendingPathComponent("Manifest.json")
        let preferencesURL = directoryURL.appendingPathComponent("Preferences.json")
        let itemsURL = directoryURL.appendingPathComponent("Items", isDirectory: true)
        try FileManager.default.createDirectory(at: itemsURL, withIntermediateDirectories: true)
        let envelope = BackupEnvelope(
            appName: "Snapshot Tests",
            schemaVersion: 1,
            exportedAt: exportedAt,
            itemIDs: Array(items.keys).sorted(),
            deviceID: "snapshot-device-\(backupID)",
            itemModifiedAt: Dictionary(uniqueKeysWithValues: items.keys.map { ($0, exportedAt) }),
            backupID: backupID,
            label: label,
            hostSchemaMetadata: metadata
        )
        let envelopeData = try JSONEncoder.icloudDriveSync.encode(envelope)
        try envelopeData.write(to: backupURL)
        try Data("manifest-\(backupID)".utf8).write(to: manifestURL)
        try preferences.write(to: preferencesURL)
        for itemID in items.keys {
            let itemURL = ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL)
            try FileManager.default.createDirectory(at: itemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: itemURL)
        }

        await store.seed(backupURL, envelopeData)
        await store.seed(manifestURL, Data("manifest-\(backupID)".utf8))
        await store.seed(preferencesURL, preferences)
        for (itemID, data) in items {
            await store.seed(ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL), data)
        }
    }

    private func snapshotBackupURL(id backupID: String) -> URL {
        currentBackupURL
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots", isDirectory: true)
            .appendingPathComponent(backupID, isDirectory: true)
            .appendingPathComponent("Backup.json")
    }
}

@MainActor
private final class SnapshotDataSource: ICloudDriveSyncDataSource {
    var items: [String: Data]
    var preferences: Data
    var metadata: ICloudDriveHostSchemaMetadata?
    var validatedMetadata: ICloudDriveHostSchemaMetadata?
    var appliedData: (manifest: Data, items: [String: Data])?
    var appliedPreferences: Data?

    init(
        items: [String: Data] = [:],
        preferences: Data = Data("{}".utf8),
        metadata: ICloudDriveHostSchemaMetadata? = nil
    ) {
        self.items = items
        self.preferences = preferences
        self.metadata = metadata
    }

    func hasLocalData() -> Bool {
        !items.isEmpty
    }

    func allDataItemIDs() -> Set<String> {
        Set(items.keys)
    }

    func exportData(
        changedItemIDs: Set<String>?,
        deletedItemIDs: Set<String>
    ) -> (manifest: Data, items: [String: Data], modifiedAt: [String: Date]) {
        let ids = changedItemIDs ?? Set(items.keys)
        return (
            manifest: Data("manifest".utf8),
            items: items.filter { ids.contains($0.key) },
            modifiedAt: Dictionary(uniqueKeysWithValues: ids.map { ($0, Date(timeIntervalSince1970: 1_800_000_000)) })
        )
    }

    func hostSchemaMetadata() -> ICloudDriveHostSchemaMetadata? {
        metadata
    }

    func validateRestoredHostSchemaMetadata(_ metadata: ICloudDriveHostSchemaMetadata?) throws {
        validatedMetadata = metadata
    }

    func applyRestoredData(manifest: Data, items: [String: Data]) throws {
        appliedData = (manifest, items)
    }

    func exportPreferences() -> Data {
        preferences
    }

    func applyRestoredPreferences(_ data: Data) throws {
        appliedPreferences = data
    }
}
