import Foundation

/// Raw backup bytes a non-SwiftUI host can hand to the engine without
/// writing its own `ICloudDriveSyncDataSource` conformance. This is useful
/// for Flutter, React Native, Capacitor, or any other bridge layer whose
/// app model already serializes to JSON/Data outside Swift.
public struct ICloudDriveSyncPayload: Equatable, Sendable {
    public var manifest: Data
    public var items: [String: Data]
    public var modifiedAt: [String: Date]
    public var hostSchemaMetadata: ICloudDriveHostSchemaMetadata?

    public init(
        manifest: Data,
        items: [String: Data],
        modifiedAt: [String: Date] = [:],
        hostSchemaMetadata: ICloudDriveHostSchemaMetadata? = nil
    ) {
        self.manifest = manifest
        self.items = items
        self.modifiedAt = modifiedAt
        self.hostSchemaMetadata = hostSchemaMetadata
    }
}

/// A durable, framework-agnostic adapter for bridge-based apps. The host
/// writes raw payload bytes into this store, points `ICloudDriveSyncEngine`
/// at it as `dataSource`, then calls the normal engine APIs. When a restore
/// completes, the restored bytes are written back here for the bridge layer
/// to import into Dart/JavaScript/etc.
public final class ICloudDriveSyncPayloadDataSource: ICloudDriveSyncDataSource {
    public var onDataRestored: ((ICloudDriveSyncPayload) -> Void)?
    public var onPreferencesRestored: ((Data) -> Void)?
    public var restoredHostSchemaValidator: ((ICloudDriveHostSchemaMetadata?) throws -> Void)?

    private struct Metadata: Codable {
        var hasLocalData: Bool
        var itemIDs: [String]
        var modifiedAt: [String: Date]
        var hostSchemaMetadata: ICloudDriveHostSchemaMetadata?

        static let empty = Metadata(
            hasLocalData: false,
            itemIDs: [],
            modifiedAt: [:],
            hostSchemaMetadata: nil
        )
    }

    private let storageDirectory: URL
    private let manifestURL: URL
    private let preferencesURL: URL
    private let itemsDirectoryURL: URL
    private let metadataURL: URL
    private let lock = NSRecursiveLock()
    private var pendingRestoredHostSchemaMetadata: ICloudDriveHostSchemaMetadata?

    public init(storageDirectory: URL) throws {
        self.storageDirectory = storageDirectory
        self.manifestURL = storageDirectory.appendingPathComponent("Manifest.data")
        self.preferencesURL = storageDirectory.appendingPathComponent("Preferences.data")
        self.itemsDirectoryURL = storageDirectory.appendingPathComponent("Items", isDirectory: true)
        self.metadataURL = storageDirectory.appendingPathComponent("PayloadMetadata.json")
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: itemsDirectoryURL, withIntermediateDirectories: true)
    }

    /// Convenience location under Application Support for hosts that do not
    /// need an app-group container.
    public convenience init(appName: String = "ICloudDriveSyncPayload") throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(storageDirectory: base.appendingPathComponent(appName, isDirectory: true))
    }

    public func replaceData(
        manifest: Data,
        items: [String: Data],
        modifiedAt: [String: Date] = [:],
        hostSchemaMetadata: ICloudDriveHostSchemaMetadata? = nil,
        hasLocalData: Bool = true
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: itemsDirectoryURL, withIntermediateDirectories: true)
        try manifest.write(to: manifestURL, options: [.atomic])

        let oldMetadata = readMetadataLocked()
        for staleID in Set(oldMetadata.itemIDs).subtracting(items.keys) {
            try? FileManager.default.removeItem(at: itemURL(for: staleID))
        }

        for (itemID, data) in items {
            let url = itemURL(for: itemID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        }

        let now = Date()
        let completeModifiedAt = Dictionary(uniqueKeysWithValues: items.keys.map { itemID in
            (itemID, modifiedAt[itemID] ?? now)
        })
        try writeMetadataLocked(Metadata(
            hasLocalData: hasLocalData,
            itemIDs: Array(items.keys).sorted(),
            modifiedAt: completeModifiedAt,
            hostSchemaMetadata: hostSchemaMetadata
        ))
    }

    public func clearData() throws {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: manifestURL)
        try? FileManager.default.removeItem(at: itemsDirectoryURL)
        try FileManager.default.createDirectory(at: itemsDirectoryURL, withIntermediateDirectories: true)
        try writeMetadataLocked(.empty)
    }

    public func replacePreferences(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try data.write(to: preferencesURL, options: [.atomic])
    }

    public func clearPreferences() throws {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: preferencesURL)
    }

    public func currentPayload() throws -> ICloudDriveSyncPayload {
        lock.lock()
        defer { lock.unlock() }
        return try currentPayloadLocked()
    }

    public func currentPreferences() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: preferencesURL)
    }

    public func hasLocalData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readMetadataLocked().hasLocalData
    }

    public func allDataItemIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(readMetadataLocked().itemIDs)
    }

    public func exportData(
        changedItemIDs: Set<String>?,
        deletedItemIDs: Set<String>
    ) -> (manifest: Data, items: [String: Data], modifiedAt: [String: Date]) {
        lock.lock()
        defer { lock.unlock() }

        let metadata = readMetadataLocked()
        let ids = changedItemIDs ?? Set(metadata.itemIDs)
        let manifest = (try? Data(contentsOf: manifestURL)) ?? Data()
        var items: [String: Data] = [:]
        for itemID in ids {
            guard metadata.itemIDs.contains(itemID),
                  let data = try? Data(contentsOf: itemURL(for: itemID)) else { continue }
            items[itemID] = data
        }
        return (
            manifest: manifest,
            items: items,
            modifiedAt: metadata.modifiedAt.filter { ids.contains($0.key) }
        )
    }

    public func hostSchemaMetadata() -> ICloudDriveHostSchemaMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return readMetadataLocked().hostSchemaMetadata
    }

    public func validateRestoredHostSchemaMetadata(_ metadata: ICloudDriveHostSchemaMetadata?) throws {
        try restoredHostSchemaValidator?(metadata)
        lock.lock()
        defer { lock.unlock() }
        pendingRestoredHostSchemaMetadata = metadata
    }

    public func applyRestoredData(manifest: Data, items: [String: Data]) throws {
        lock.lock()
        let metadata = pendingRestoredHostSchemaMetadata
        pendingRestoredHostSchemaMetadata = nil
        lock.unlock()

        let payload = ICloudDriveSyncPayload(manifest: manifest, items: items, hostSchemaMetadata: metadata)
        try replaceData(
            manifest: payload.manifest,
            items: payload.items,
            modifiedAt: payload.modifiedAt,
            hostSchemaMetadata: payload.hostSchemaMetadata,
            hasLocalData: true
        )
        onDataRestored?(try currentPayload())
    }

    public func exportPreferences() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return (try? Data(contentsOf: preferencesURL)) ?? Data()
    }

    public func applyRestoredPreferences(_ data: Data) throws {
        try replacePreferences(data)
        onPreferencesRestored?(data)
    }

    private func currentPayloadLocked() throws -> ICloudDriveSyncPayload {
        let metadata = readMetadataLocked()
        let manifest = try Data(contentsOf: manifestURL)
        var items: [String: Data] = [:]
        for itemID in metadata.itemIDs {
            items[itemID] = try Data(contentsOf: itemURL(for: itemID))
        }
        return ICloudDriveSyncPayload(
            manifest: manifest,
            items: items,
            modifiedAt: metadata.modifiedAt,
            hostSchemaMetadata: metadata.hostSchemaMetadata
        )
    }

    private func itemURL(for itemID: String) -> URL {
        ICloudDriveFileIO.itemURL(for: itemID, in: itemsDirectoryURL)
    }

    private func readMetadataLocked() -> Metadata {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder.icloudDriveSync.decode(Metadata.self, from: data) else {
            return .empty
        }
        return metadata
    }

    private func writeMetadataLocked(_ metadata: Metadata) throws {
        let data = try JSONEncoder.icloudDriveSync.encode(metadata)
        try data.write(to: metadataURL, options: [.atomic])
    }
}
