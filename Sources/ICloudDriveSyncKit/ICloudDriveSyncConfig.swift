import Foundation
import UniformTypeIdentifiers

/// Auto-sync behavior. `.wifi` and `.always` both sync automatically in the
/// background whenever there are pending local changes; `.wifi` waits for a
/// Wi-Fi connection on iOS, `.always` syncs over any connection (including
/// cellular). On macOS, `.wifi` behaves like "any connected network" because
/// the kit does not distinguish Wi-Fi from other non-cellular interfaces there.
public enum ICloudAutoSyncMode: String, Codable, CaseIterable, Sendable {
    case off
    case wifi
    case always
}

/// The on-disk format `ICloudDriveImageAssetStore` normalizes every saved
/// image to. Both are file-based, non-Base64 formats iCloud Drive stores and
/// syncs like any other document.
///
/// `.heic` is Apple's own modern format (see WWDC 2017's "Introducing HEIF
/// and HEVC") and typically comes in at roughly half the file size of a JPEG
/// at comparable visual quality — it's the default for exactly that reason.
/// `.jpeg` is offered as a fallback for the rare case where HEIC encoding
/// isn't available (`ICloudDriveImageAssetStore` falls back to it
/// automatically if HEIC encoding fails on-device) and for hosts that
/// specifically need universal compatibility with tooling that can't read
/// HEIC.
public enum ICloudDriveImageFormat: String, Codable, Sendable {
    case heic
    case jpeg

    var utType: UTType {
        self == .heic ? .heic : .jpeg
    }

    var fileExtension: String {
        self == .heic ? "heic" : "jpg"
    }
}

/// Everything about this component that's meant to differ *per host app*
/// lives here, and this whole struct is meant to be filled out once from a
/// plain JSON file bundled in each project (see `ICloudDriveSyncConfig.load`)
/// — the Swift sources in this package should never need editing between
/// projects, only this file's JSON contents and the two functions in your
/// `ICloudDriveSyncDataSource` conformance.
///
/// Every field decodes leniently (missing keys fall back to the default
/// shown below), so a project's JSON only needs to specify the handful of
/// values it actually wants to change.
public struct ICloudDriveSyncConfig: Codable, Sendable {
    /// The iCloud ubiquity container identifier to sync into, e.g.
    /// `"iCloud.com.yourcompany.yourapp"`. Pass `nil` to use the app's
    /// first/default ubiquity container (matches its entitlements file) —
    /// that's almost always what you want unless the app declares more than
    /// one container.
    public var containerIdentifier: String?

    /// Written into the backup envelope purely as a human-readable label —
    /// useful if the user (or you) ever opens the raw JSON file in iCloud
    /// Drive. Not used for any matching/validation.
    public var appName: String

    /// Folder name inside the ubiquity container's `Documents/` directory
    /// that holds this app's backup. Keep this stable once shipped — renaming
    /// it orphans any backup already sitting in a user's iCloud Drive.
    public var backupDirectoryName: String

    /// File name of the engine's own small bookkeeping envelope (export
    /// date, item id roster, schema version) inside `backupDirectoryName`.
    public var backupFileName: String

    /// File name, alongside `backupFileName`, that holds your Data lane's
    /// `exportData(...).manifest` bytes verbatim — written and read as raw
    /// `Data`, never re-wrapped in JSON, so nothing about its contents or
    /// shape is this package's business.
    public var manifestFileName: String

    /// Subfolder (inside `backupDirectoryName`) that holds one JSON file per
    /// Data item your `ICloudDriveSyncDataSource` hands the engine. Mirrors
    /// `backupFileName`'s directory, one level down. An item id containing
    /// `/` is stored in a matching subfolder here (see
    /// `ICloudDriveSyncDataSource.allDataItemIDs()`), so this can end up
    /// holding per-category (or deeper) folders rather than one flat pile of
    /// files.
    public var itemsDirectoryName: String

    /// File name, alongside `backupFileName`, that holds your Preferences
    /// lane's `exportPreferences()` bytes verbatim — a separate small file,
    /// synced independently of Data entirely (see
    /// `ICloudDriveSyncDataSource`'s "Two lanes" doc comment). Rewritten in
    /// full every time preferences sync; keep it small.
    public var preferencesFileName: String

    /// Total backup size (manifest + all items, in bytes) above which the
    /// engine will surface `showLargeBackupWarning` the first time auto-sync
    /// mode is `.always`. Defaults to 10 MB.
    public var largeBackupThresholdBytes: Int64

    /// Auto-sync mode a fresh install starts with, before the person has
    /// ever touched the setting.
    public var defaultAutoSyncMode: ICloudAutoSyncMode

    /// Prefix applied to every `UserDefaults` key the engine persists under
    /// (auto-sync mode, last-sync date, pending-restore flags, ...). Give
    /// each app on a shared device/simulator its own prefix if that ever
    /// matters; otherwise the default is fine.
    public var userDefaultsKeyPrefix: String

    /// The initial "restoring from iCloud" overlay stays up at least this
    /// long even if the restore itself finishes faster, so it never just
    /// flashes on screen. In seconds.
    public var minimumInitialRestoreOverlayDuration: Double

    /// How many ~`pollIntervalSeconds` polls the startup restore check waits
    /// for a first-ever backup to appear, on Wi-Fi vs. cellular (cellular
    /// gets a longer budget since iCloud is often slower to hand back
    /// status there).
    public var initialRestoreCheckAttemptLimitWiFi: Int
    public var initialRestoreCheckAttemptLimitCellular: Int

    /// How many ~`pollIntervalSeconds` polls a single file download waits
    /// before giving up, on Wi-Fi vs. cellular.
    public var downloadAttemptLimitWiFi: Int
    public var downloadAttemptLimitCellular: Int

    /// Spacing between polls while waiting on a download or an initial
    /// backup check. In seconds.
    public var pollIntervalSeconds: Double

    /// After a local change, how long the engine waits (debounced, restarted
    /// on every further change) before kicking off an automatic sync. In
    /// seconds.
    public var autoSyncDebounceSeconds: Double

    /// How many recent lifecycle events `ICloudDriveSyncEngine.recentEvents`
    /// keeps in memory — oldest entries drop off past this. Small by design;
    /// this is meant for "what just happened" debugging and
    /// `ICloudDriveSyncEngine.makeDiagnosticsSnapshot()`, not a full audit
    /// log. Defaults to 100.
    public var eventLogCapacity: Int

    /// How the engine resolves a Data item that a *different* device edited
    /// on the cloud side after this device last knew about it, while this
    /// device also has a local edit pending for the same item — see
    /// `ICloudDriveSyncConflictPolicy`'s own cases for what each does.
    /// Defaults to `.lastWriteWins`. Irrelevant for an app that never syncs
    /// the same account from more than one device.
    public var conflictPolicy: ICloudDriveSyncConflictPolicy

    /// Config for `ICloudDriveImageAssetStore` — storing images in the same
    /// ubiquity container, alongside (but independent of) the Data/Preferences
    /// backup above. See that type's doc comment for the full design; this
    /// struct is just its knobs, decoded the same lenient way as every other
    /// field on `ICloudDriveSyncConfig`.
    public var imageAssets: ImageAssetConfig

    /// All user-facing copy the engine ever shows, so it can be reworded or
    /// localized per app without touching Swift code.
    public var messages: Messages

    public init(
        containerIdentifier: String? = nil,
        appName: String = "App",
        backupDirectoryName: String = "Backup",
        backupFileName: String = "Backup.json",
        manifestFileName: String = "Manifest.json",
        itemsDirectoryName: String = "Items",
        preferencesFileName: String = "Preferences.json",
        largeBackupThresholdBytes: Int64 = 10 * 1024 * 1024,
        defaultAutoSyncMode: ICloudAutoSyncMode = .always,
        userDefaultsKeyPrefix: String = "icloudDriveSync_",
        minimumInitialRestoreOverlayDuration: Double = 1,
        initialRestoreCheckAttemptLimitWiFi: Int = 8,
        initialRestoreCheckAttemptLimitCellular: Int = 30,
        downloadAttemptLimitWiFi: Int = 180,
        downloadAttemptLimitCellular: Int = 30,
        pollIntervalSeconds: Double = 0.5,
        autoSyncDebounceSeconds: Double = 2,
        eventLogCapacity: Int = 100,
        conflictPolicy: ICloudDriveSyncConflictPolicy = .lastWriteWins,
        imageAssets: ImageAssetConfig = ImageAssetConfig(),
        messages: Messages = Messages()
    ) {
        self.containerIdentifier = containerIdentifier
        self.appName = appName
        self.backupDirectoryName = backupDirectoryName
        self.backupFileName = backupFileName
        self.manifestFileName = manifestFileName
        self.itemsDirectoryName = itemsDirectoryName
        self.preferencesFileName = preferencesFileName
        self.largeBackupThresholdBytes = largeBackupThresholdBytes
        self.defaultAutoSyncMode = defaultAutoSyncMode
        self.userDefaultsKeyPrefix = userDefaultsKeyPrefix
        self.minimumInitialRestoreOverlayDuration = minimumInitialRestoreOverlayDuration
        self.initialRestoreCheckAttemptLimitWiFi = initialRestoreCheckAttemptLimitWiFi
        self.initialRestoreCheckAttemptLimitCellular = initialRestoreCheckAttemptLimitCellular
        self.downloadAttemptLimitWiFi = downloadAttemptLimitWiFi
        self.downloadAttemptLimitCellular = downloadAttemptLimitCellular
        self.pollIntervalSeconds = pollIntervalSeconds
        self.autoSyncDebounceSeconds = autoSyncDebounceSeconds
        self.eventLogCapacity = eventLogCapacity
        self.conflictPolicy = conflictPolicy
        self.imageAssets = imageAssets
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case containerIdentifier, appName, backupDirectoryName, backupFileName, manifestFileName, itemsDirectoryName
        case preferencesFileName
        case largeBackupThresholdBytes, defaultAutoSyncMode, userDefaultsKeyPrefix
        case minimumInitialRestoreOverlayDuration
        case initialRestoreCheckAttemptLimitWiFi, initialRestoreCheckAttemptLimitCellular
        case downloadAttemptLimitWiFi, downloadAttemptLimitCellular
        case pollIntervalSeconds, autoSyncDebounceSeconds, eventLogCapacity, conflictPolicy, imageAssets, messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ICloudDriveSyncConfig()
        containerIdentifier = try c.decodeIfPresent(String.self, forKey: .containerIdentifier)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? defaults.appName
        backupDirectoryName = try c.decodeIfPresent(String.self, forKey: .backupDirectoryName) ?? defaults.backupDirectoryName
        backupFileName = try c.decodeIfPresent(String.self, forKey: .backupFileName) ?? defaults.backupFileName
        manifestFileName = try c.decodeIfPresent(String.self, forKey: .manifestFileName) ?? defaults.manifestFileName
        itemsDirectoryName = try c.decodeIfPresent(String.self, forKey: .itemsDirectoryName) ?? defaults.itemsDirectoryName
        preferencesFileName = try c.decodeIfPresent(String.self, forKey: .preferencesFileName) ?? defaults.preferencesFileName
        largeBackupThresholdBytes = try c.decodeIfPresent(Int64.self, forKey: .largeBackupThresholdBytes) ?? defaults.largeBackupThresholdBytes
        defaultAutoSyncMode = try c.decodeIfPresent(ICloudAutoSyncMode.self, forKey: .defaultAutoSyncMode) ?? defaults.defaultAutoSyncMode
        userDefaultsKeyPrefix = try c.decodeIfPresent(String.self, forKey: .userDefaultsKeyPrefix) ?? defaults.userDefaultsKeyPrefix
        minimumInitialRestoreOverlayDuration = try c.decodeIfPresent(Double.self, forKey: .minimumInitialRestoreOverlayDuration) ?? defaults.minimumInitialRestoreOverlayDuration
        initialRestoreCheckAttemptLimitWiFi = try c.decodeIfPresent(Int.self, forKey: .initialRestoreCheckAttemptLimitWiFi) ?? defaults.initialRestoreCheckAttemptLimitWiFi
        initialRestoreCheckAttemptLimitCellular = try c.decodeIfPresent(Int.self, forKey: .initialRestoreCheckAttemptLimitCellular) ?? defaults.initialRestoreCheckAttemptLimitCellular
        downloadAttemptLimitWiFi = try c.decodeIfPresent(Int.self, forKey: .downloadAttemptLimitWiFi) ?? defaults.downloadAttemptLimitWiFi
        downloadAttemptLimitCellular = try c.decodeIfPresent(Int.self, forKey: .downloadAttemptLimitCellular) ?? defaults.downloadAttemptLimitCellular
        pollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? defaults.pollIntervalSeconds
        autoSyncDebounceSeconds = try c.decodeIfPresent(Double.self, forKey: .autoSyncDebounceSeconds) ?? defaults.autoSyncDebounceSeconds
        eventLogCapacity = try c.decodeIfPresent(Int.self, forKey: .eventLogCapacity) ?? defaults.eventLogCapacity
        conflictPolicy = try c.decodeIfPresent(ICloudDriveSyncConflictPolicy.self, forKey: .conflictPolicy) ?? defaults.conflictPolicy
        imageAssets = try c.decodeIfPresent(ImageAssetConfig.self, forKey: .imageAssets) ?? defaults.imageAssets
        messages = try c.decodeIfPresent(Messages.self, forKey: .messages) ?? defaults.messages
    }

    /// Knobs for `ICloudDriveImageAssetStore`. Every field decodes leniently
    /// with the same sane-default fallback as the rest of `ICloudDriveSyncConfig`.
    ///
    /// **On `maxFileSizeBytes`/`maxLongEdgePixels`:** Apple does not publish a
    /// hard per-file size or pixel-dimension limit for documents stored in an
    /// iCloud Drive ubiquity container (only overall account storage is
    /// capped, at whatever plan the person is on). These two numbers are this
    /// package's own conservative, override-anytime defaults — not an Apple
    /// mandate — chosen so a single image can't quietly balloon a person's
    /// backup or eat their cellular data: 4096px covers full-bleed display on
    /// any current device with headroom to spare, and 8 MB is comfortably
    /// above what a photo normalized to HEIC/JPEG at `compressionQuality`
    /// actually needs even at that resolution. Raise or lower either to suit
    /// your app.
    public struct ImageAssetConfig: Codable, Sendable {
        /// Subfolder (inside `backupDirectoryName`, alongside `itemsDirectoryName`)
        /// that holds one file per saved image, named after the id
        /// `ICloudDriveImageAssetStore.save(_:id:)` returns/accepts. Supports
        /// the same `/`-in-id folder partitioning as Data items (see
        /// `ICloudDriveFileIO.assetURL(for:extension:in:)`).
        public var directoryName: String

        /// The format every saved image is normalized to on write (see
        /// `ICloudDriveImageFormat`). `ICloudDriveImageAssetStore` writes an
        /// already-matching, already-within-limits image through unchanged;
        /// anything else gets decoded and re-encoded to this format.
        public var preferredFormat: ICloudDriveImageFormat

        /// Lossy compression quality (`0`–`1`) used whenever
        /// `ICloudDriveImageAssetStore` has to encode/re-encode an image —
        /// i.e. whenever the source isn't already `preferredFormat` and
        /// within limits, and whenever `fitToLimits(_:)` runs. `0.8` is a
        /// standard "visually lossless for a photo, meaningfully smaller than
        /// max quality" starting point; tune per app if needed.
        public var compressionQuality: Double

        /// Per-image byte-count ceiling `validate(_:)`/`save(_:id:)` enforce
        /// against the *original*, as-given data — see the type-level doc
        /// comment above for why this number isn't an Apple-documented limit.
        public var maxFileSizeBytes: Int64

        /// Per-image pixel ceiling on the longer edge (width or height,
        /// whichever is larger) that `validate(_:)`/`save(_:id:)` enforce —
        /// see the type-level doc comment above for why this number isn't an
        /// Apple-documented limit.
        public var maxLongEdgePixels: Int

        public init(
            directoryName: String = "Images",
            preferredFormat: ICloudDriveImageFormat = .heic,
            compressionQuality: Double = 0.8,
            maxFileSizeBytes: Int64 = 8 * 1024 * 1024,
            maxLongEdgePixels: Int = 4096
        ) {
            self.directoryName = directoryName
            self.preferredFormat = preferredFormat
            self.compressionQuality = compressionQuality
            self.maxFileSizeBytes = maxFileSizeBytes
            self.maxLongEdgePixels = maxLongEdgePixels
        }

        enum CodingKeys: String, CodingKey {
            case directoryName, preferredFormat, compressionQuality, maxFileSizeBytes, maxLongEdgePixels
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ImageAssetConfig()
            directoryName = try c.decodeIfPresent(String.self, forKey: .directoryName) ?? d.directoryName
            preferredFormat = try c.decodeIfPresent(ICloudDriveImageFormat.self, forKey: .preferredFormat) ?? d.preferredFormat
            compressionQuality = try c.decodeIfPresent(Double.self, forKey: .compressionQuality) ?? d.compressionQuality
            maxFileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .maxFileSizeBytes) ?? d.maxFileSizeBytes
            maxLongEdgePixels = try c.decodeIfPresent(Int.self, forKey: .maxLongEdgePixels) ?? d.maxLongEdgePixels
        }
    }

    /// Decode a config from raw JSON `Data` — the "hand it JSON" entry point
    /// this whole package is built around.
    public static func load(from data: Data) throws -> ICloudDriveSyncConfig {
        try JSONDecoder().decode(ICloudDriveSyncConfig.self, from: data)
    }

    /// Convenience for the common case: a `.json` file added to the host
    /// app's bundle (e.g. `ICloudSyncConfig.json`, target-membership checked).
    public static func load(
        resource name: String,
        withExtension ext: String = "json",
        bundle: Bundle = .main
    ) throws -> ICloudDriveSyncConfig {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ICloudDriveSyncConfigError.resourceNotFound("\(name).\(ext)")
        }
        return try load(from: try Data(contentsOf: url))
    }

    /// All user-facing strings the engine can show. Every field has an
    /// English default, so a project's JSON only needs to override the ones
    /// it wants to change (or none at all).
    public struct Messages: Codable, Sendable {
        public var iCloudDriveUnavailable: String
        public var noBackupFoundYet: String
        public var checkingBackup: String
        public var tryWithWiFi: String
        public var downloadingBackup: String
        public var restoringData: String
        public var autoSyncedMessage: String
        public var syncedMessage: String
        public var restoredMessage: String
        public var waitingForNetwork: String
        public var waitingForWiFi: String
        public var autoSyncOffMessage: String
        public var waitingCellularLowDataMessage: String
        public var waitingCellularMessage: String
        public var manualBackupOverwriteWarning: String
        public var manualRestoreWarning: String
        public var restoreNeedsWiFiOrOverwrite: String
        /// `syncMessage`/`restoreWarningMessage` after a restore finishes
        /// with some items missing or failed (`ICloudDriveRestoreReport.hasIssues`).
        /// Used as a lead-in — same pattern as the `...Prefix` fields below
        /// — with a parenthetical `(N missing, M failed)`-style detail the
        /// engine appends itself, so this string doesn't need to (and
        /// can't cleanly) embed the counts.
        public var partialRestoreWarning: String
        public var restoreRetryNoItems: String
        public var restoreRetryRequiresItemApplyHandler: String
        public var restoreRetrySucceeded: String
        /// Shown as a blocking alert (not just the transient `syncMessage`)
        /// when the startup restore found a backup but genuinely could not
        /// finish downloading/applying it — e.g. a stuck iCloud file — so
        /// the person always gets a clear "this failed" signal instead of
        /// the restore overlay just quietly disappearing with nothing to
        /// show for it.
        public var restoreFailedPleaseRetry: String

        /// Error copy — `errorDescription` on `ICloudDriveSyncError` reads
        /// these.
        public var errorICloudUnavailable: String
        public var errorCellularUnavailable: String
        public var errorDownloadFailedPrefix: String
        public var errorDownloadTimedOut: String
        public var errorReadFailedPrefix: String

        /// Error copy for `ICloudDriveImageAssetStore` — read by
        /// `ICloudDriveSyncError`'s image-related cases the same way the
        /// backup/sync errors above read theirs. The engine appends the
        /// actual-vs-limit numbers itself; these are just the lead-in
        /// sentence.
        public var errorImageTooLargeFileSizePrefix: String
        public var errorImageTooLargeDimensionsPrefix: String
        public var errorImageDecodeFailedPrefix: String
        public var errorImageEncodeFailedPrefix: String
        public var errorImageNotFoundPrefix: String

        /// Shown in the confirmation alert `ICloudDriveSyncSettingsSection`
        /// presents before `ICloudDriveSyncEngine.deleteBackupManually()`
        /// runs, when its delete-backup option is enabled — the whole reason
        /// that confirmation exists, so make sure any reworded copy still
        /// says the action is permanent.
        public var deleteBackupConfirmationMessage: String
        /// `syncMessage` after a successful `deleteBackupManually()`.
        public var deleteBackupSucceededMessage: String
        /// Error copy — `errorDescription` on `ICloudDriveSyncError` doesn't
        /// have its own delete-backup case (the underlying `Error` from
        /// `FileManager`/`NSFileCoordinator` is appended to this prefix
        /// directly instead, the same way `errorDownloadFailedPrefix` is
        /// used).
        public var errorDeleteBackupFailedPrefix: String

        public init(
            iCloudDriveUnavailable: String = "iCloud Drive is not available.",
            noBackupFoundYet: String = "No iCloud backup found yet.",
            checkingBackup: String = "Checking iCloud backup...",
            tryWithWiFi: String = "Try with Wi-Fi.",
            downloadingBackup: String = "Downloading iCloud backup...",
            restoringData: String = "Restoring data from iCloud...",
            autoSyncedMessage: String = "Auto synced with iCloud.",
            syncedMessage: String = "Synced with iCloud.",
            restoredMessage: String = "Restored from iCloud.",
            waitingForNetwork: String = "Waiting for network to sync with iCloud.",
            waitingForWiFi: String = "Waiting for Wi-Fi to sync with iCloud.",
            autoSyncOffMessage: String = "Auto sync is off.",
            waitingCellularLowDataMessage: String = "iCloud is waiting on cellular data. Low Data Mode may be delaying the backup.",
            waitingCellularMessage: String = "Waiting for iCloud over cellular data...",
            manualBackupOverwriteWarning: String = "There is iCloud data we could not restore. Backing up now will overwrite it. Do you confirm?",
            manualRestoreWarning: String = "Any unsaved data can get lost.",
            restoreNeedsWiFiOrOverwrite: String = "Restore needs Wi-Fi, or back up to overwrite.",
            partialRestoreWarning: String = "Restore completed, but some items could not be restored from iCloud.",
            restoreRetryNoItems: String = "No missing items to retry.",
            restoreRetryRequiresItemApplyHandler: String = "This app does not support retrying individual restored items.",
            restoreRetrySucceeded: String = "Missing items restored.",
            restoreFailedPleaseRetry: String = "Could not restore your data from iCloud. You can try again from Settings.",
            errorICloudUnavailable: String = "iCloud Drive is not available. Make sure iCloud Drive is enabled for this Apple ID.",
            errorCellularUnavailable: String = "iCloud may be turned off for cellular data. Connect to Wi-Fi and try restoring again.",
            errorDownloadFailedPrefix: String = "iCloud backup could not be downloaded.",
            errorDownloadTimedOut: String = "iCloud backup is still downloading. Keep the app open while iCloud makes the file available.",
            errorReadFailedPrefix: String = "iCloud backup could not be opened.",
            errorImageTooLargeFileSizePrefix: String = "This image is too large to back up.",
            errorImageTooLargeDimensionsPrefix: String = "This image's resolution is too large to back up.",
            errorImageDecodeFailedPrefix: String = "This file doesn't appear to be a valid image.",
            errorImageEncodeFailedPrefix: String = "This image could not be prepared for backup.",
            errorImageNotFoundPrefix: String = "This image could not be found in iCloud.",
            deleteBackupConfirmationMessage: String = "This can't be undone. Your iCloud backup will be permanently deleted.",
            deleteBackupSucceededMessage: String = "iCloud backup deleted.",
            errorDeleteBackupFailedPrefix: String = "iCloud backup could not be deleted."
        ) {
            self.iCloudDriveUnavailable = iCloudDriveUnavailable
            self.noBackupFoundYet = noBackupFoundYet
            self.checkingBackup = checkingBackup
            self.tryWithWiFi = tryWithWiFi
            self.downloadingBackup = downloadingBackup
            self.restoringData = restoringData
            self.autoSyncedMessage = autoSyncedMessage
            self.syncedMessage = syncedMessage
            self.restoredMessage = restoredMessage
            self.waitingForNetwork = waitingForNetwork
            self.waitingForWiFi = waitingForWiFi
            self.autoSyncOffMessage = autoSyncOffMessage
            self.waitingCellularLowDataMessage = waitingCellularLowDataMessage
            self.waitingCellularMessage = waitingCellularMessage
            self.manualBackupOverwriteWarning = manualBackupOverwriteWarning
            self.manualRestoreWarning = manualRestoreWarning
            self.restoreNeedsWiFiOrOverwrite = restoreNeedsWiFiOrOverwrite
            self.partialRestoreWarning = partialRestoreWarning
            self.restoreRetryNoItems = restoreRetryNoItems
            self.restoreRetryRequiresItemApplyHandler = restoreRetryRequiresItemApplyHandler
            self.restoreRetrySucceeded = restoreRetrySucceeded
            self.restoreFailedPleaseRetry = restoreFailedPleaseRetry
            self.errorICloudUnavailable = errorICloudUnavailable
            self.errorCellularUnavailable = errorCellularUnavailable
            self.errorDownloadFailedPrefix = errorDownloadFailedPrefix
            self.errorDownloadTimedOut = errorDownloadTimedOut
            self.errorReadFailedPrefix = errorReadFailedPrefix
            self.errorImageTooLargeFileSizePrefix = errorImageTooLargeFileSizePrefix
            self.errorImageTooLargeDimensionsPrefix = errorImageTooLargeDimensionsPrefix
            self.errorImageDecodeFailedPrefix = errorImageDecodeFailedPrefix
            self.errorImageEncodeFailedPrefix = errorImageEncodeFailedPrefix
            self.errorImageNotFoundPrefix = errorImageNotFoundPrefix
            self.deleteBackupConfirmationMessage = deleteBackupConfirmationMessage
            self.deleteBackupSucceededMessage = deleteBackupSucceededMessage
            self.errorDeleteBackupFailedPrefix = errorDeleteBackupFailedPrefix
        }

        enum CodingKeys: String, CodingKey {
            case iCloudDriveUnavailable, noBackupFoundYet, checkingBackup, tryWithWiFi, downloadingBackup
            case restoringData, autoSyncedMessage, syncedMessage, restoredMessage, waitingForNetwork, waitingForWiFi
            case autoSyncOffMessage, waitingCellularLowDataMessage, waitingCellularMessage
            case manualBackupOverwriteWarning, manualRestoreWarning, restoreNeedsWiFiOrOverwrite
            case partialRestoreWarning, restoreRetryNoItems, restoreRetryRequiresItemApplyHandler, restoreRetrySucceeded
            case restoreFailedPleaseRetry
            case errorICloudUnavailable, errorCellularUnavailable, errorDownloadFailedPrefix
            case errorDownloadTimedOut, errorReadFailedPrefix
            case errorImageTooLargeFileSizePrefix, errorImageTooLargeDimensionsPrefix
            case errorImageDecodeFailedPrefix, errorImageEncodeFailedPrefix, errorImageNotFoundPrefix
            case deleteBackupConfirmationMessage, deleteBackupSucceededMessage, errorDeleteBackupFailedPrefix
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Messages()
            iCloudDriveUnavailable = try c.decodeIfPresent(String.self, forKey: .iCloudDriveUnavailable) ?? d.iCloudDriveUnavailable
            noBackupFoundYet = try c.decodeIfPresent(String.self, forKey: .noBackupFoundYet) ?? d.noBackupFoundYet
            checkingBackup = try c.decodeIfPresent(String.self, forKey: .checkingBackup) ?? d.checkingBackup
            tryWithWiFi = try c.decodeIfPresent(String.self, forKey: .tryWithWiFi) ?? d.tryWithWiFi
            downloadingBackup = try c.decodeIfPresent(String.self, forKey: .downloadingBackup) ?? d.downloadingBackup
            restoringData = try c.decodeIfPresent(String.self, forKey: .restoringData) ?? d.restoringData
            autoSyncedMessage = try c.decodeIfPresent(String.self, forKey: .autoSyncedMessage) ?? d.autoSyncedMessage
            syncedMessage = try c.decodeIfPresent(String.self, forKey: .syncedMessage) ?? d.syncedMessage
            restoredMessage = try c.decodeIfPresent(String.self, forKey: .restoredMessage) ?? d.restoredMessage
            waitingForNetwork = try c.decodeIfPresent(String.self, forKey: .waitingForNetwork) ?? d.waitingForNetwork
            waitingForWiFi = try c.decodeIfPresent(String.self, forKey: .waitingForWiFi) ?? d.waitingForWiFi
            autoSyncOffMessage = try c.decodeIfPresent(String.self, forKey: .autoSyncOffMessage) ?? d.autoSyncOffMessage
            waitingCellularLowDataMessage = try c.decodeIfPresent(String.self, forKey: .waitingCellularLowDataMessage) ?? d.waitingCellularLowDataMessage
            waitingCellularMessage = try c.decodeIfPresent(String.self, forKey: .waitingCellularMessage) ?? d.waitingCellularMessage
            manualBackupOverwriteWarning = try c.decodeIfPresent(String.self, forKey: .manualBackupOverwriteWarning) ?? d.manualBackupOverwriteWarning
            manualRestoreWarning = try c.decodeIfPresent(String.self, forKey: .manualRestoreWarning) ?? d.manualRestoreWarning
            restoreNeedsWiFiOrOverwrite = try c.decodeIfPresent(String.self, forKey: .restoreNeedsWiFiOrOverwrite) ?? d.restoreNeedsWiFiOrOverwrite
            partialRestoreWarning = try c.decodeIfPresent(String.self, forKey: .partialRestoreWarning) ?? d.partialRestoreWarning
            restoreRetryNoItems = try c.decodeIfPresent(String.self, forKey: .restoreRetryNoItems) ?? d.restoreRetryNoItems
            restoreRetryRequiresItemApplyHandler = try c.decodeIfPresent(String.self, forKey: .restoreRetryRequiresItemApplyHandler) ?? d.restoreRetryRequiresItemApplyHandler
            restoreRetrySucceeded = try c.decodeIfPresent(String.self, forKey: .restoreRetrySucceeded) ?? d.restoreRetrySucceeded
            restoreFailedPleaseRetry = try c.decodeIfPresent(String.self, forKey: .restoreFailedPleaseRetry) ?? d.restoreFailedPleaseRetry
            errorICloudUnavailable = try c.decodeIfPresent(String.self, forKey: .errorICloudUnavailable) ?? d.errorICloudUnavailable
            errorCellularUnavailable = try c.decodeIfPresent(String.self, forKey: .errorCellularUnavailable) ?? d.errorCellularUnavailable
            errorDownloadFailedPrefix = try c.decodeIfPresent(String.self, forKey: .errorDownloadFailedPrefix) ?? d.errorDownloadFailedPrefix
            errorDownloadTimedOut = try c.decodeIfPresent(String.self, forKey: .errorDownloadTimedOut) ?? d.errorDownloadTimedOut
            errorReadFailedPrefix = try c.decodeIfPresent(String.self, forKey: .errorReadFailedPrefix) ?? d.errorReadFailedPrefix
            errorImageTooLargeFileSizePrefix = try c.decodeIfPresent(String.self, forKey: .errorImageTooLargeFileSizePrefix) ?? d.errorImageTooLargeFileSizePrefix
            errorImageTooLargeDimensionsPrefix = try c.decodeIfPresent(String.self, forKey: .errorImageTooLargeDimensionsPrefix) ?? d.errorImageTooLargeDimensionsPrefix
            errorImageDecodeFailedPrefix = try c.decodeIfPresent(String.self, forKey: .errorImageDecodeFailedPrefix) ?? d.errorImageDecodeFailedPrefix
            errorImageEncodeFailedPrefix = try c.decodeIfPresent(String.self, forKey: .errorImageEncodeFailedPrefix) ?? d.errorImageEncodeFailedPrefix
            errorImageNotFoundPrefix = try c.decodeIfPresent(String.self, forKey: .errorImageNotFoundPrefix) ?? d.errorImageNotFoundPrefix
            deleteBackupConfirmationMessage = try c.decodeIfPresent(String.self, forKey: .deleteBackupConfirmationMessage) ?? d.deleteBackupConfirmationMessage
            deleteBackupSucceededMessage = try c.decodeIfPresent(String.self, forKey: .deleteBackupSucceededMessage) ?? d.deleteBackupSucceededMessage
            errorDeleteBackupFailedPrefix = try c.decodeIfPresent(String.self, forKey: .errorDeleteBackupFailedPrefix) ?? d.errorDeleteBackupFailedPrefix
        }
    }
}

public enum ICloudDriveSyncConfigError: LocalizedError {
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "ICloudDriveSyncKit: could not find \"\(name)\" in the given bundle. Check its target membership."
        }
    }
}
