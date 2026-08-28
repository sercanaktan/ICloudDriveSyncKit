import XCTest
import Foundation
@testable import ICloudDriveSyncKit

@MainActor
final class HostSchemaMetadataTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var store: InMemoryCloudStore!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var backupURL: URL!
    private var manifestURL: URL!
    private var itemsURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        store = InMemoryCloudStore()
        suiteName = "ICloudDriveSyncKitTests.HostSchemaMetadata.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        backupURL = tempDir.url.appendingPathComponent("Backup.json")
        manifestURL = tempDir.url.appendingPathComponent("Manifest.json")
        itemsURL = tempDir.url.appendingPathComponent("Items", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        itemsURL = nil
        manifestURL = nil
        backupURL = nil
        defaults = nil
        suiteName = nil
        store = nil
        tempDir = nil
        super.tearDown()
    }

    func testEngineExportsHostSchemaMetadataIntoEnvelope() async throws {
        let metadata = ICloudDriveHostSchemaMetadata(
            dataSchemaVersion: 2,
            minimumSupportedDataSchemaVersion: 1,
            appVersion: "1.1",
            appBuild: "42"
        )
        let dataSource = HostSchemaMetadataDataSource(
            hasLocalData: true,
            items: ["note-1": Data("local".utf8)],
            hostSchemaMetadata: metadata
        )
        let engine = makeEngine(dataSource: dataSource)

        await engine.syncManually()

        let storedEnvelopeData = await store.file(at: backupURL)
        let envelopeData = try XCTUnwrap(storedEnvelopeData)
        let envelope = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData)
        XCTAssertEqual(envelope.hostSchemaMetadata, metadata)
    }

    func testEnginePublishesRestoredHostSchemaMetadataAfterSuccessfulRestore() async throws {
        let metadata = ICloudDriveHostSchemaMetadata(dataSchemaVersion: 1, appVersion: "1.0")
        let dataSource = HostSchemaMetadataDataSource(hasLocalData: true)
        try await seedBackup(metadata: metadata)
        let engine = makeEngine(dataSource: dataSource)

        await engine.restoreManually()

        XCTAssertEqual(dataSource.validatedMetadata, metadata)
        XCTAssertNotNil(dataSource.appliedData)
        XCTAssertEqual(engine.lastRestoredHostSchemaMetadata, metadata)
        XCTAssertEqual(engine.makeDiagnosticsSnapshot().lastRestoredHostSchemaMetadata, metadata)
    }

    func testRestoreValidationRunsBeforeApplyingDataAndCanRejectUnsupportedSchema() async throws {
        let metadata = ICloudDriveHostSchemaMetadata(dataSchemaVersion: 99)
        let dataSource = HostSchemaMetadataDataSource(hasLocalData: true)
        dataSource.validationError = HostSchemaMetadataTestError.unsupportedSchema
        try await seedBackup(metadata: metadata)
        let engine = makeEngine(dataSource: dataSource)

        await engine.restoreManually()

        XCTAssertEqual(dataSource.validatedMetadata, metadata)
        XCTAssertNil(dataSource.appliedData)
        XCTAssertNil(engine.lastRestoredHostSchemaMetadata)
        XCTAssertEqual(engine.syncOutcome, .failure(.restoreFailed))
    }

    func testLegacyBackupWithoutHostSchemaMetadataStillRestoresByDefault() async throws {
        let dataSource = HostSchemaMetadataDataSource(hasLocalData: true)
        try await seedBackup(metadata: nil)
        let engine = makeEngine(dataSource: dataSource)

        await engine.restoreManually()

        XCTAssertNil(dataSource.validatedMetadata)
        XCTAssertNotNil(dataSource.appliedData)
        XCTAssertNil(engine.lastRestoredHostSchemaMetadata)
        XCTAssertTrue(engine.syncOutcome.isSuccess)
    }

    private func makeEngine(dataSource: HostSchemaMetadataDataSource) -> ICloudDriveSyncEngine {
        let config = ICloudDriveSyncConfig(
            appName: "Host Schema Metadata Tests",
            backupFileName: "Backup.json",
            manifestFileName: "Manifest.json",
            itemsDirectoryName: "Items",
            defaultAutoSyncMode: .off,
            userDefaultsKeyPrefix: "hostSchemaMetadata_",
            minimumInitialRestoreOverlayDuration: 0
        )
        let resolvedBackupURL = backupURL!
        let engine = ICloudDriveSyncEngine(
            config: config,
            userDefaults: defaults,
            backupEnvelopeURL: { resolvedBackupURL },
            ioPrimitives: store.ioPrimitives
        )
        engine.dataSource = dataSource
        return engine
    }

    private func seedBackup(metadata: ICloudDriveHostSchemaMetadata?) async throws {
        let itemURL = ICloudDriveFileIO.itemURL(for: "note-1", in: itemsURL)
        try FileManager.default.createDirectory(at: itemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: backupURL)
        try Data().write(to: manifestURL)
        try Data().write(to: itemURL)
        let envelope = BackupEnvelope(
            appName: "Host Schema Metadata Tests",
            schemaVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            itemIDs: ["note-1"],
            deviceID: "device-1",
            itemModifiedAt: ["note-1": Date(timeIntervalSince1970: 1_800_000_000)],
            hostSchemaMetadata: metadata
        )
        await store.seed(backupURL, try JSONEncoder.icloudDriveSync.encode(envelope))
        await store.seed(manifestURL, Data("manifest".utf8))
        await store.seed(itemURL, Data("cloud".utf8))
    }
}

private enum HostSchemaMetadataTestError: LocalizedError {
    case unsupportedSchema

    var errorDescription: String? {
        "Unsupported host schema."
    }
}

@MainActor
private final class HostSchemaMetadataDataSource: ICloudDriveSyncDataSource {
    var hasLocalDataValue: Bool
    var items: [String: Data]
    var metadata: ICloudDriveHostSchemaMetadata?
    var validationError: Error?
    var validatedMetadata: ICloudDriveHostSchemaMetadata?
    var appliedData: (manifest: Data, items: [String: Data])?
    var appliedPreferences: Data?

    init(
        hasLocalData: Bool,
        items: [String: Data] = [:],
        hostSchemaMetadata: ICloudDriveHostSchemaMetadata? = nil
    ) {
        self.hasLocalDataValue = hasLocalData
        self.items = items
        self.metadata = hostSchemaMetadata
    }

    func hasLocalData() -> Bool {
        hasLocalDataValue
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
            modifiedAt: Dictionary(uniqueKeysWithValues: ids.map { ($0, Date(timeIntervalSince1970: 1_800_000_100)) })
        )
    }

    func hostSchemaMetadata() -> ICloudDriveHostSchemaMetadata? {
        metadata
    }

    func validateRestoredHostSchemaMetadata(_ metadata: ICloudDriveHostSchemaMetadata?) throws {
        validatedMetadata = metadata
        if let validationError {
            throw validationError
        }
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
