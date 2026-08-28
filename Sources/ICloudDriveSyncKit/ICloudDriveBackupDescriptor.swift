import Foundation

/// A lightweight, host-displayable summary of one optional snapshot backup.
/// Snapshot backups are separate from the engine's normal "current" backup:
/// auto sync never writes to them unless the host explicitly calls the
/// snapshot API.
public struct ICloudDriveBackupDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String?
    public let createdAt: Date
    public let exportedAt: Date
    public let appName: String
    public let appVersion: String?
    public let appBuild: String?
    public let hostSchemaMetadata: ICloudDriveHostSchemaMetadata?
    public let itemCount: Int
    public let byteCount: Int64?
    public let deviceID: String

    public init(
        id: String,
        label: String? = nil,
        createdAt: Date,
        exportedAt: Date,
        appName: String,
        appVersion: String? = nil,
        appBuild: String? = nil,
        hostSchemaMetadata: ICloudDriveHostSchemaMetadata? = nil,
        itemCount: Int,
        byteCount: Int64? = nil,
        deviceID: String
    ) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.exportedAt = exportedAt
        self.appName = appName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.hostSchemaMetadata = hostSchemaMetadata
        self.itemCount = itemCount
        self.byteCount = byteCount
        self.deviceID = deviceID
    }
}
