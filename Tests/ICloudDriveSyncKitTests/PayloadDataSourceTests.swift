import XCTest
import Foundation
@testable import ICloudDriveSyncKit

@MainActor
final class PayloadDataSourceTests: XCTestCase {
    private var tempDir: TempDirectory!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
    }

    override func tearDown() {
        tempDir = nil
        super.tearDown()
    }

    func testPayloadDataSourcePersistsRawDataForBridgeHosts() throws {
        let metadata = ICloudDriveHostSchemaMetadata(dataSchemaVersion: 2, appVersion: "1.1", appBuild: "7")
        let source = try makeSource()
        try source.replaceData(
            manifest: Data("manifest".utf8),
            items: [
                "a": Data("A".utf8),
                "folder/b": Data("B".utf8)
            ],
            modifiedAt: ["a": Date(timeIntervalSince1970: 1_800_000_001)],
            hostSchemaMetadata: metadata
        )

        let relaunched = try makeSource()
        let payload = try relaunched.currentPayload()

        XCTAssertTrue(relaunched.hasLocalData())
        XCTAssertEqual(relaunched.allDataItemIDs(), ["a", "folder/b"])
        XCTAssertEqual(payload.manifest, Data("manifest".utf8))
        XCTAssertEqual(payload.items["a"], Data("A".utf8))
        XCTAssertEqual(payload.items["folder/b"], Data("B".utf8))
        XCTAssertEqual(payload.hostSchemaMetadata, metadata)
        XCTAssertEqual(payload.modifiedAt["a"], Date(timeIntervalSince1970: 1_800_000_001))
        XCTAssertNotNil(payload.modifiedAt["folder/b"], "items without explicit timestamps get a usable default")
    }

    func testIncrementalExportReturnsOnlyRequestedExistingItems() throws {
        let source = try makeSource()
        try source.replaceData(
            manifest: Data("manifest".utf8),
            items: [
                "a": Data("A".utf8),
                "b": Data("B".utf8)
            ],
            modifiedAt: [
                "a": Date(timeIntervalSince1970: 1),
                "b": Date(timeIntervalSince1970: 2)
            ]
        )

        let export = source.exportData(changedItemIDs: ["b", "missing"], deletedItemIDs: [])

        XCTAssertEqual(export.manifest, Data("manifest".utf8))
        XCTAssertEqual(export.items, ["b": Data("B".utf8)])
        XCTAssertEqual(export.modifiedAt, ["b": Date(timeIntervalSince1970: 2)])
    }

    func testApplyRestoredDataStoresPayloadAndCallsBridgeCallback() throws {
        let metadata = ICloudDriveHostSchemaMetadata(dataSchemaVersion: 3, appVersion: "2.0")
        let source = try makeSource()
        var validatedMetadata: ICloudDriveHostSchemaMetadata?
        var callbackPayload: ICloudDriveSyncPayload?
        source.restoredHostSchemaValidator = { metadata in
            validatedMetadata = metadata
        }
        source.onDataRestored = { payload in
            callbackPayload = payload
        }

        try source.validateRestoredHostSchemaMetadata(metadata)
        try source.applyRestoredData(
            manifest: Data("cloud-manifest".utf8),
            items: ["cloud": Data("cloud-item".utf8)]
        )

        let payload = try source.currentPayload()
        XCTAssertEqual(validatedMetadata, metadata)
        XCTAssertEqual(callbackPayload, payload)
        XCTAssertEqual(payload.manifest, Data("cloud-manifest".utf8))
        XCTAssertEqual(payload.items, ["cloud": Data("cloud-item".utf8)])
        XCTAssertEqual(payload.hostSchemaMetadata, metadata)
    }

    func testPreferencesPersistAndRestoreCallbackFires() throws {
        let source = try makeSource()
        var restoredPreferences: Data?
        source.onPreferencesRestored = { data in
            restoredPreferences = data
        }

        try source.replacePreferences(Data("local-prefs".utf8))
        XCTAssertEqual(try makeSource().currentPreferences(), Data("local-prefs".utf8))

        try source.applyRestoredPreferences(Data("cloud-prefs".utf8))

        XCTAssertEqual(restoredPreferences, Data("cloud-prefs".utf8))
        XCTAssertEqual(try makeSource().currentPreferences(), Data("cloud-prefs".utf8))
    }

    func testPayloadDataSourceWorksWithEngineManualSync() async throws {
        let tempCloud = TempDirectory()
        let store = InMemoryCloudStore()
        let backupURL = tempCloud.url.appendingPathComponent("Backup.json")
        let source = try makeSource()
        try source.replaceData(
            manifest: Data("manifest".utf8),
            items: ["a": Data("A".utf8)],
            modifiedAt: ["a": Date(timeIntervalSince1970: 1)]
        )
        try source.replacePreferences(Data("prefs".utf8))
        let engine = makeEngine(source: source, backupURL: backupURL, store: store)

        await engine.syncManually()

        let files = await store.allFiles()
        XCTAssertNotNil(files[backupURL])
        XCTAssertEqual(files[backupURL.deletingLastPathComponent().appendingPathComponent("Manifest.json")], Data("manifest".utf8))
        XCTAssertEqual(files[backupURL.deletingLastPathComponent().appendingPathComponent("Preferences.json")], Data("prefs".utf8))
        XCTAssertEqual(
            files[ICloudDriveFileIO.itemURL(
                for: "a",
                in: backupURL.deletingLastPathComponent().appendingPathComponent("Items", isDirectory: true)
            )],
            Data("A".utf8)
        )
        XCTAssertTrue(engine.syncOutcome.isSuccess)
    }

    private func makeSource() throws -> ICloudDriveSyncPayloadDataSource {
        try ICloudDriveSyncPayloadDataSource(storageDirectory: tempDir.url.appendingPathComponent("Payload", isDirectory: true))
    }

    private func makeEngine(
        source: ICloudDriveSyncPayloadDataSource,
        backupURL: URL,
        store: InMemoryCloudStore
    ) -> ICloudDriveSyncEngine {
        let config = ICloudDriveSyncConfig(
            appName: "Payload Tests",
            backupFileName: "Backup.json",
            manifestFileName: "Manifest.json",
            itemsDirectoryName: "Items",
            preferencesFileName: "Preferences.json",
            defaultAutoSyncMode: .off,
            userDefaultsKeyPrefix: "payloadDataSource_",
            minimumInitialRestoreOverlayDuration: 0
        )
        let engine = ICloudDriveSyncEngine(
            config: config,
            userDefaults: UserDefaults(suiteName: "PayloadDataSourceTests.\(UUID().uuidString)")!,
            backupEnvelopeURL: { backupURL },
            ioPrimitives: store.ioPrimitives
        )
        engine.dataSource = source
        return engine
    }
}
