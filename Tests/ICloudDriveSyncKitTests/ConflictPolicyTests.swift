import XCTest
import Foundation
@testable import ICloudDriveSyncKit

@MainActor
final class ConflictPolicyTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var store: InMemoryCloudStore!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var backupURL: URL!
    private var itemsURL: URL!
    private var manifestURL: URL!
    private var dataSource: ConflictPolicyDataSource!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        store = InMemoryCloudStore()
        suiteName = "ICloudDriveSyncKitTests.ConflictPolicy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        backupURL = tempDir.url.appendingPathComponent("Backup.json")
        itemsURL = tempDir.url.appendingPathComponent("Items", isDirectory: true)
        manifestURL = tempDir.url.appendingPathComponent("Manifest.json")
        dataSource = ConflictPolicyDataSource()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        dataSource = nil
        manifestURL = nil
        itemsURL = nil
        backupURL = nil
        defaults = nil
        suiteName = nil
        store = nil
        tempDir = nil
        super.tearDown()
    }

    func testLocalWinsUploadsLocalBytesOverANewerCloudConflict() async throws {
        let localTime = Date(timeIntervalSince1970: 100)
        let cloudTime = Date(timeIntervalSince1970: 200)
        dataSource.items = ["note-1": Data("local".utf8)]
        dataSource.modifiedAt = ["note-1": localTime]
        try await seedCloudBackup(itemID: "note-1", data: Data("cloud".utf8), modifiedAt: cloudTime)

        let engine = makeEngine(policy: .localWins)

        await engine.syncManually()

        let itemURL = ICloudDriveFileIO.itemURL(for: "note-1", in: itemsURL)
        let storedItem = await store.file(at: itemURL)
        XCTAssertEqual(storedItem, Data("local".utf8))
        XCTAssertTrue(engine.pendingConflicts.isEmpty)
        XCTAssertEqual(dataSource.appliedConflictItems, [:])
        XCTAssertTrue(engine.syncOutcome.isSuccess)
    }

    func testCloudWinsAppliesCloudBytesAndDoesNotOverwriteTheCloudItem() async throws {
        let localTime = Date(timeIntervalSince1970: 100)
        let cloudTime = Date(timeIntervalSince1970: 200)
        let cloudData = Data("cloud".utf8)
        dataSource.items = ["note-1": Data("local".utf8)]
        dataSource.modifiedAt = ["note-1": localTime]
        try await seedCloudBackup(itemID: "note-1", data: cloudData, modifiedAt: cloudTime)

        let engine = makeEngine(policy: .cloudWins)

        await engine.syncManually()

        let itemURL = ICloudDriveFileIO.itemURL(for: "note-1", in: itemsURL)
        let storedItem = await store.file(at: itemURL)
        XCTAssertEqual(dataSource.appliedConflictItems, ["note-1": cloudData])
        XCTAssertEqual(storedItem, cloudData)
        XCTAssertTrue(engine.pendingConflicts.isEmpty)
        XCTAssertFalse(engine.makeDiagnosticsSnapshot().hasPendingChanges)
    }

    func testLastWriteWinsKeepsTheNewerCloudBytesWhenCloudIsNewer() async throws {
        let localTime = Date(timeIntervalSince1970: 100)
        let cloudTime = Date(timeIntervalSince1970: 200)
        let cloudData = Data("cloud".utf8)
        dataSource.items = ["note-1": Data("local".utf8)]
        dataSource.modifiedAt = ["note-1": localTime]
        try await seedCloudBackup(itemID: "note-1", data: cloudData, modifiedAt: cloudTime)

        let engine = makeEngine(policy: .lastWriteWins)

        await engine.syncManually()

        XCTAssertEqual(dataSource.appliedConflictItems, ["note-1": cloudData])
        XCTAssertTrue(engine.pendingConflicts.isEmpty)
        XCTAssertFalse(engine.makeDiagnosticsSnapshot().hasPendingChanges)
    }

    func testManualPolicyRecordsConflictAndLeavesTheLocalEditPending() async throws {
        let localTime = Date(timeIntervalSince1970: 100)
        let cloudTime = Date(timeIntervalSince1970: 200)
        let localData = Data("local".utf8)
        let cloudData = Data("cloud".utf8)
        dataSource.items = ["note-1": localData]
        dataSource.modifiedAt = ["note-1": localTime]
        try await seedCloudBackup(itemID: "note-1", data: cloudData, modifiedAt: cloudTime)

        let engine = makeEngine(policy: .manual)
        engine.itemDisplayNameResolver = { id in id == "note-1" ? "First Note" : nil }

        await engine.syncManually()

        XCTAssertEqual(engine.pendingConflicts.count, 1)
        let conflict = try XCTUnwrap(engine.pendingConflicts.first)
        XCTAssertEqual(conflict.itemID, "note-1")
        XCTAssertEqual(conflict.displayName, "First Note")
        XCTAssertEqual(conflict.localData, localData)
        XCTAssertEqual(conflict.localModifiedAt, localTime)
        XCTAssertEqual(conflict.cloudData, cloudData)
        XCTAssertEqual(conflict.cloudModifiedAt, cloudTime)
        XCTAssertTrue(engine.makeDiagnosticsSnapshot().hasPendingChanges)
    }

    func testResolvingManualConflictWithCloudAppliesCloudAndClearsPendingChange() async throws {
        let cloudTime = Date(timeIntervalSince1970: 200)
        let cloudData = Data("cloud".utf8)
        dataSource.items = ["note-1": Data("local".utf8)]
        dataSource.modifiedAt = ["note-1": Date(timeIntervalSince1970: 100)]
        try await seedCloudBackup(itemID: "note-1", data: cloudData, modifiedAt: cloudTime)

        let engine = makeEngine(policy: .manual)
        await engine.syncManually()
        let conflict = try XCTUnwrap(engine.pendingConflicts.first)

        await engine.resolveConflict(conflict, keep: .keepCloud)

        XCTAssertEqual(dataSource.appliedConflictItems, ["note-1": cloudData])
        XCTAssertTrue(engine.pendingConflicts.isEmpty)
        XCTAssertFalse(engine.makeDiagnosticsSnapshot().hasPendingChanges)
    }

    func testResolvingManualConflictWithLocalKeepsTheItemPendingForNextUpload() async throws {
        dataSource.items = ["note-1": Data("local".utf8)]
        dataSource.modifiedAt = ["note-1": Date(timeIntervalSince1970: 100)]
        try await seedCloudBackup(
            itemID: "note-1",
            data: Data("cloud".utf8),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let engine = makeEngine(policy: .manual)
        await engine.syncManually()
        let conflict = try XCTUnwrap(engine.pendingConflicts.first)

        await engine.resolveConflict(conflict, keep: .keepLocal)

        let snapshot = engine.makeDiagnosticsSnapshot()
        XCTAssertTrue(engine.pendingConflicts.isEmpty)
        XCTAssertTrue(snapshot.hasPendingChanges)
        XCTAssertEqual(snapshot.pendingItemCount, 1)
    }

    private func makeEngine(policy: ICloudDriveSyncConflictPolicy) -> ICloudDriveSyncEngine {
        let config = ICloudDriveSyncConfig(
            appName: "Conflict Policy Tests",
            backupFileName: "Backup.json",
            manifestFileName: "Manifest.json",
            itemsDirectoryName: "Items",
            defaultAutoSyncMode: .off,
            userDefaultsKeyPrefix: "conflictPolicy_",
            conflictPolicy: policy
        )
        let resolvedBackupURL = backupURL!
        let engine = ICloudDriveSyncEngine(
            config: config,
            userDefaults: defaults,
            backupEnvelopeURL: { resolvedBackupURL },
            ioPrimitives: store.ioPrimitives
        )
        engine.dataSource = dataSource
        engine.applyRestoredItemsHandler = { [weak dataSource] items in
            dataSource?.appliedConflictItems.merge(items) { _, new in new }
        }
        engine.notifyDataChanged(changedItemIDs: Set(dataSource.items.keys))
        return engine
    }

    private func seedCloudBackup(itemID: String, data: Data, modifiedAt: Date) async throws {
        let itemURL = ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL)
        try FileManager.default.createDirectory(at: itemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: backupURL)
        try Data().write(to: itemURL)
        let envelope = BackupEnvelope(
            appName: "Conflict Policy Tests",
            schemaVersion: 1,
            exportedAt: modifiedAt,
            itemIDs: [itemID],
            deviceID: "other-device",
            itemModifiedAt: [itemID: modifiedAt]
        )
        await store.seed(backupURL, try JSONEncoder.icloudDriveSync.encode(envelope))
        await store.seed(itemURL, data)
        await store.seed(manifestURL, Data("{}".utf8))
    }
}

@MainActor
private final class ConflictPolicyDataSource: ICloudDriveSyncDataSource {
    var items: [String: Data] = [:]
    var modifiedAt: [String: Date] = [:]
    var appliedData: (manifest: Data, items: [String: Data])?
    var appliedPreferences: Data?
    var appliedConflictItems: [String: Data] = [:]

    func hasLocalData() -> Bool {
        true
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
            manifest: Data("{}".utf8),
            items: items.filter { ids.contains($0.key) },
            modifiedAt: modifiedAt.filter { ids.contains($0.key) }
        )
    }

    func applyRestoredData(manifest: Data, items: [String: Data]) throws {
        appliedData = (manifest, items)
    }

    func exportPreferences() -> Data {
        Data("{}".utf8)
    }

    func applyRestoredPreferences(_ data: Data) throws {
        appliedPreferences = data
    }
}
