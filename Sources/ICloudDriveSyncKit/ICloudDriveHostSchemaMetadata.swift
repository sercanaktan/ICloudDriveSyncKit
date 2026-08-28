import Foundation

/// Host-app schema information stored in the kit's backup envelope, next to
/// the kit's own bookkeeping. This deliberately does not wrap or reinterpret
/// the host's manifest/item JSON; it only labels that opaque data so a future
/// app version can decide how to migrate or reject it before decoding.
public struct ICloudDriveHostSchemaMetadata: Codable, Equatable, Sendable {
    public var dataSchemaVersion: Int
    public var minimumSupportedDataSchemaVersion: Int?
    public var appVersion: String?
    public var appBuild: String?
    public var additionalInfo: [String: String]

    public init(
        dataSchemaVersion: Int,
        minimumSupportedDataSchemaVersion: Int? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        additionalInfo: [String: String] = [:]
    ) {
        self.dataSchemaVersion = dataSchemaVersion
        self.minimumSupportedDataSchemaVersion = minimumSupportedDataSchemaVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.additionalInfo = additionalInfo
    }
}
