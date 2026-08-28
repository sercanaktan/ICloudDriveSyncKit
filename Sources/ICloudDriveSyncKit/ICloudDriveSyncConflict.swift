import Foundation

/// How `ICloudDriveSyncEngine` should handle a Data item where the cloud
/// copy was written by a *different* device (see `ICloudDriveSyncEngine.deviceID`)
/// with a newer `modifiedAt` than the local edit this device is about to
/// upload for the same item — i.e. two devices touched the same item since
/// they last agreed on its state. Configured via
/// `ICloudDriveSyncConfig.conflictPolicy`; only matters for hosts syncing
/// the same iCloud account from more than one device (a single-device app
/// never has anything to conflict with).
public enum ICloudDriveSyncConflictPolicy: String, Codable, Sendable {
    /// Whichever edit happened later wins — compares each conflicted item's
    /// local `modifiedAt` against the cloud's for that same item. Since a
    /// conflict is only ever detected when the cloud's timestamp is already
    /// the newer one (see `ICloudDriveSyncEngine`'s conflict-detection doc
    /// comment), this always resolves to keeping the cloud version and
    /// applying it locally — the default, and usually what a person expects
    /// from "sync."
    case lastWriteWins
    /// Every conflict resolves to the cloud version, regardless of which
    /// edit is actually newer — for a host that wants one device (or
    /// "whichever last opened cleanly") to always be authoritative.
    case cloudWins
    /// Every conflict resolves to the local version — this device always
    /// overwrites the cloud copy no matter what's there. Also skips the
    /// conflict-detection envelope check entirely (there's nothing to
    /// decide), so this is the zero-extra-cost option, matching the
    /// engine's behavior before conflict detection existed.
    case localWins
    /// Neither side auto-wins — a conflicted item is left out of the
    /// export (neither uploaded nor overwritten locally) and instead
    /// appended to `ICloudDriveSyncEngine.pendingConflicts` with both
    /// versions' raw bytes, for a host to show its own "keep mine / keep
    /// theirs" UI and call `ICloudDriveSyncEngine.resolveConflict(_:keep:)`.
    case manual
}

/// Passed to `ICloudDriveSyncEngine.resolveConflict(_:keep:)` — which side
/// of a `.manual`-policy `ICloudDriveSyncConflict` to keep.
public enum ICloudDriveSyncConflictResolution: Sendable {
    /// Re-marks the item as locally pending so the next sync uploads it
    /// normally, overwriting the cloud copy.
    case keepLocal
    /// Applies the cloud copy locally (via `ICloudDriveSyncEngine.applyRestoredItemsHandler`)
    /// and discards the local edit.
    case keepCloud
}

/// One Data item where a different device's cloud edit and this device's
/// local edit both happened since they last agreed on the item's state —
/// only ever produced when `ICloudDriveSyncConfig.conflictPolicy` is
/// `.manual`; every other policy resolves conflicts on its own and never
/// populates `ICloudDriveSyncEngine.pendingConflicts`. Carries both
/// versions' raw bytes (exactly what `ICloudDriveSyncDataSource.exportData`
/// and the cloud's item file contained) so a host can decode and show both
/// — a diff view, a "keep mine / keep theirs" picker, whatever fits the
/// app — without a second round-trip to fetch either side.
public struct ICloudDriveSyncConflict: Identifiable, Sendable {
    public var id: String { itemID }
    public let itemID: String
    public let displayName: String?
    public let localData: Data
    public let localModifiedAt: Date
    public let cloudData: Data
    public let cloudModifiedAt: Date
    public let detectedAt: Date

    public init(
        itemID: String,
        displayName: String?,
        localData: Data,
        localModifiedAt: Date,
        cloudData: Data,
        cloudModifiedAt: Date,
        detectedAt: Date
    ) {
        self.itemID = itemID
        self.displayName = displayName
        self.localData = localData
        self.localModifiedAt = localModifiedAt
        self.cloudData = cloudData
        self.cloudModifiedAt = cloudModifiedAt
        self.detectedAt = detectedAt
    }
}
