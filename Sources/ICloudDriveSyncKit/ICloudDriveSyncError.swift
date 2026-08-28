import Foundation

/// Every error the engine can throw or surface as `syncMessage`. All copy is
/// sourced from `ICloudDriveSyncConfig.Messages` (see `ICloudDriveSyncConfig.swift`)
/// so a host app can localize/reword everything from its JSON config without
/// touching this file.
public enum ICloudDriveSyncError: LocalizedError {
    case iCloudUnavailable
    case cellularUnavailable
    case downloadFailed(String?)
    case downloadTimedOut(String?)
    case readFailed(String?)
    case dataSourceMissing

    /// `ICloudDriveImageAssetStore.validate(_:)`/`save(_:id:)` reject the
    /// image outright — the *original* byte count exceeded
    /// `ICloudDriveSyncConfig.ImageAssetConfig.maxFileSizeBytes`. Both
    /// numbers are exact, so a caller can show them straight in a UI alert
    /// without recomputing anything.
    case imageFileTooLarge(sizeBytes: Int64, limitBytes: Int64)
    /// Same as `imageFileTooLarge`, but for
    /// `ImageAssetConfig.maxLongEdgePixels` — `longEdgePixels` is
    /// `max(width, height)` of the original image.
    case imageDimensionsTooLarge(longEdgePixels: Int, limitPixels: Int)
    /// The given bytes couldn't be read as an image at all (corrupt data, or
    /// a format ImageIO doesn't recognize) — surfaced while inspecting
    /// pixel size or while decoding for re-encoding/downsampling.
    case imageDecodeFailed
    /// A decoded image failed to re-encode to
    /// `ImageAssetConfig.preferredFormat` (and, for `.heic`, its JPEG
    /// fallback also failed) — extremely rare in practice.
    case imageEncodeFailed
    /// `ICloudDriveImageAssetStore.loadData(id:)` was asked for an id with
    /// no corresponding file in the ubiquity container.
    case imageNotFound

    /// Set once by `ICloudDriveSyncEngine.init(config:)`, so `errorDescription`
    /// can read config-provided copy without every call site having to thread
    /// the config through by hand. Deliberately simple: this assumes a
    /// single `ICloudDriveSyncEngine` per process (the normal case — one
    /// engine per app). If you ever construct more than one engine with
    /// different `Messages`, whichever was constructed last wins for every
    /// engine's error copy.
    static var messages = ICloudDriveSyncConfig.Messages()

    public var errorDescription: String? {
        let m = Self.messages
        switch self {
        case .iCloudUnavailable:
            return m.errorICloudUnavailable
        case .cellularUnavailable:
            return m.errorCellularUnavailable
        case .downloadFailed(let detail):
            if let detail, !detail.isEmpty {
                return "\(m.errorDownloadFailedPrefix) \(detail)"
            }
            return m.errorDownloadFailedPrefix
        case .downloadTimedOut:
            return m.errorDownloadTimedOut
        case .readFailed(let detail):
            if let detail, !detail.isEmpty {
                return "\(m.errorReadFailedPrefix) \(detail)"
            }
            return m.errorReadFailedPrefix
        case .dataSourceMissing:
            return "ICloudDriveSyncEngine has no dataSource set."
        case .imageFileTooLarge(let sizeBytes, let limitBytes):
            return "\(m.errorImageTooLargeFileSizePrefix) (\(Self.formatBytes(sizeBytes)), limit \(Self.formatBytes(limitBytes)))"
        case .imageDimensionsTooLarge(let longEdgePixels, let limitPixels):
            return "\(m.errorImageTooLargeDimensionsPrefix) (\(longEdgePixels)px, limit \(limitPixels)px)"
        case .imageDecodeFailed:
            return m.errorImageDecodeFailedPrefix
        case .imageEncodeFailed:
            return m.errorImageEncodeFailedPrefix
        case .imageNotFound:
            return m.errorImageNotFoundPrefix
        }
    }

    private static func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
