import Foundation
#if os(iOS)
import BackgroundTasks
#endif

public enum ICloudDriveSyncOutcome: Equatable, Sendable {
    case idle
    case success(ICloudDriveSyncSuccess)
    case failure(ICloudDriveSyncFailure)
    case warning(ICloudDriveSyncWarning)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

public enum ICloudDriveSyncSuccess: String, Codable, Sendable {
    case synced
    case autoSynced
    case restored
    case restoredWithIssues
    case backupDeleted
    case retrySucceeded
    case partialRetry
}

public enum ICloudDriveSyncFailure: String, Codable, Sendable {
    case iCloudUnavailable
    case dataSourceMissing
    case noBackupFound
    case syncFailed
    case restoreFailed
    case deleteBackupFailed
    case retryFailed
    case individualRetryUnsupported
}

public enum ICloudDriveSyncWarning: String, Codable, Sendable {
    case checkingBackup
    case downloadingBackup
    case restoringData
    case waitingForNetwork
    case waitingForWiFi
    case waitingForICloudDownload
    case autoSyncOff
    case cellularUnavailable
    case busy
    case noRetryableItems
}

public enum ICloudDriveSyncProgressPhase: String, Codable, Sendable {
    case idle
    case checkingBackup
    case waitingForNetwork
    case downloadingEnvelope
    case downloadingManifest
    case downloadingItems
    case downloadingPreferences
    case applyingRestore
    case uploadingItems
    case uploadingManifest
    case uploadingPreferences
    case uploadingEnvelope
    case deletingBackup
    case refreshingStatus
    case finished
    case failed
}

public struct ICloudDriveSyncProgress: Equatable, Sendable {
    public let phase: ICloudDriveSyncProgressPhase
    public let completedUnitCount: Int
    public let totalUnitCount: Int?
    public let currentItemID: String?

    public var isActive: Bool {
        switch phase {
        case .idle, .finished, .failed:
            return false
        default:
            return true
        }
    }

    public var fractionCompleted: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else { return nil }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }

    public var percentCompleted: Int? {
        fractionCompleted.map { Int(($0 * 100).rounded()) }
    }

    public init(
        phase: ICloudDriveSyncProgressPhase,
        completedUnitCount: Int = 0,
        totalUnitCount: Int? = nil,
        currentItemID: String? = nil
    ) {
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.currentItemID = currentItemID
    }

    public static let idle = ICloudDriveSyncProgress(phase: .idle)
}

public enum ICloudDriveRestoreItemIssueReason: String, Codable, Sendable {
    case missingFile
    case downloadFailed
    case readFailed
}

public struct ICloudDriveRestoreItemIssue: Identifiable, Equatable, Sendable {
    public var id: String { "\(itemID)#\(reason.rawValue)" }
    public let itemID: String
    public let displayName: String?
    public let reason: ICloudDriveRestoreItemIssueReason
    public let errorDescription: String?

    public init(
        itemID: String,
        displayName: String?,
        reason: ICloudDriveRestoreItemIssueReason,
        errorDescription: String? = nil
    ) {
        self.itemID = itemID
        self.displayName = displayName
        self.reason = reason
        self.errorDescription = errorDescription
    }
}

public struct ICloudDriveRestoreReport: Equatable, Sendable {
    public let expectedItemCount: Int
    public let restoredItemCount: Int
    public let missingItems: [ICloudDriveRestoreItemIssue]
    public let failedItems: [ICloudDriveRestoreItemIssue]

    public var issueCount: Int { missingItems.count + failedItems.count }
    public var hasIssues: Bool { issueCount > 0 }
    public var retryableItemIDs: Set<String> {
        Set(missingItems.map(\.itemID)).union(failedItems.map(\.itemID))
    }

    public init(
        expectedItemCount: Int,
        restoredItemCount: Int,
        missingItems: [ICloudDriveRestoreItemIssue] = [],
        failedItems: [ICloudDriveRestoreItemIssue] = []
    ) {
        self.expectedItemCount = expectedItemCount
        self.restoredItemCount = restoredItemCount
        self.missingItems = missingItems
        self.failedItems = failedItems
    }
}

/// The result of `ICloudDriveSyncEngine.reconcileOrphanedItems()` — what got
/// removed from the cloud `Items/` folder because it no longer matched
/// anything in the host's own current roster (`ICloudDriveSyncDataSource.allDataItemIDs()`).
public struct ICloudDriveReconciliationResult: Equatable, Sendable {
    public let removedItemCount: Int
    /// Each removed file's path relative to the `Items/` folder (e.g.
    /// `"diary/2024-01-01-abc123.json"`), for a host that wants to log or
    /// display exactly what was cleaned up. Empty whenever `removedItemCount`
    /// is `0`.
    public let removedRelativePaths: [String]

    public init(removedItemCount: Int, removedRelativePaths: [String] = []) {
        self.removedItemCount = removedItemCount
        self.removedRelativePaths = removedRelativePaths
    }
}

/// Drop-in, app-agnostic engine for backing arbitrary app data up to (and
/// restoring it from) a folder in the user's iCloud Drive — the same
/// "export everything to a JSON file + one JSON file per item in a
/// subfolder" approach, generalized behind `ICloudDriveSyncDataSource` so it
/// never needs to know what a "note" or "task" or "workout" is.
///
/// Usage (see the package README for the full walkthrough):
/// ```swift
/// let config = try ICloudDriveSyncConfig.load(resource: "ICloudSyncConfig")
/// let engine = ICloudDriveSyncEngine(config: config)
/// engine.dataSource = myStore   // myStore: ICloudDriveSyncDataSource
/// engine.start()
/// ```
@MainActor
public final class ICloudDriveSyncEngine: ObservableObject {
    // MARK: Published state

    @Published public private(set) var isSyncing = false
    @Published public private(set) var isNetworkConnected = false
    @Published public private(set) var isWiFiConnected = false
    @Published public private(set) var isCellularConnected = false
    @Published public private(set) var isLowDataModeEnabled = false
    /// True while the app should show a full-screen "restoring from
    /// iCloud..." overlay — set right at launch (before any check has even
    /// run) whenever the host has no local data yet, or a restore was
    /// interrupted last time, so there's never a flash of empty state.
    @Published public private(set) var isInitialRestoreBlocking = false
    /// Latest human-readable status line — safe to show directly in UI.
    @Published public var syncMessage: String?
    /// Non-nil while a "you're on cellular, want to wait for Wi-Fi?"-style
    /// warning should be shown as a blocking alert.
    @Published public var restoreWarningMessage: String?
    /// True once a backup crosses `config.largeBackupThresholdBytes` while
    /// auto-sync is `.always` — surface as a one-time alert, then call
    /// `dismissLargeBackupWarning()`.
    @Published public var showLargeBackupWarning = false
    /// True when the last restore attempt failed in a way that makes the
    /// iCloud copy authoritative-but-unfetched — auto-sync pauses itself
    /// (to avoid overwriting cloud data with a stale local copy) until the
    /// person either restores successfully or explicitly overwrites via a
    /// manual backup.
    @Published public private(set) var hasUnrestoredBackup = false
    @Published public private(set) var autoSyncMode: ICloudAutoSyncMode
    @Published public private(set) var lastSyncAt: Date?
    @Published public private(set) var backupByteCount: Int64 = 0
    @Published public private(set) var lastRestoreReport: ICloudDriveRestoreReport?
    @Published public private(set) var syncOutcome: ICloudDriveSyncOutcome = .idle
    @Published public private(set) var syncProgress: ICloudDriveSyncProgress = .idle
    @Published public private(set) var lastRestoredHostSchemaMetadata: ICloudDriveHostSchemaMetadata?
    /// A small, most-recent-`config.eventLogCapacity`-first-out window of
    /// lifecycle events — the same ones `onEvent` forwards to a host's own
    /// analytics, kept here too for a "recent activity" debug view or an
    /// `ICloudDriveSyncDiagnosticsSnapshot` export (see `makeDiagnosticsSnapshot()`).
    @Published public private(set) var recentEvents: [ICloudDriveSyncLogEntry] = []
    /// The most recent `.error`-level entry from `recentEvents`, if any —
    /// `nil` until the first error this engine instance has logged. A
    /// convenience for a host that just wants "what went wrong last" without
    /// scanning `recentEvents` itself.
    @Published public private(set) var lastError: ICloudDriveSyncLogEntry?
    /// Data items where a different device's cloud edit and this device's
    /// local edit both happened since they last agreed on the item's
    /// state — only ever populated when `ICloudDriveSyncConfig.conflictPolicy`
    /// is `.manual`. Resolve each one with `resolveConflict(_:keep:)`.
    @Published public private(set) var pendingConflicts: [ICloudDriveSyncConflict] = []

    // MARK: Wiring

    /// The host's data. `weak` so the common ownership direction (host owns
    /// this engine as a property) never creates a retain cycle. Set this
    /// before calling `start()`.
    public weak var dataSource: ICloudDriveSyncDataSource?

    /// Optional analytics hook — called with an event name and a flat
    /// string payload wherever the old hand-rolled code used to call into
    /// an app-specific analytics singleton. Wire it to whatever your app
    /// already uses; the engine has no analytics dependency of its own.
    public var onEvent: ((_ name: String, _ data: [String: String]) -> Void)?

    /// Called right after a successful Data export, with exactly the item
    /// ids that were just exported/deleted and cleared from the engine's
    /// in-memory pending set. The engine's pending set doesn't survive an
    /// app relaunch (it's in-memory only) — if your own local storage keeps
    /// its own durable "still needs cloud export" bookkeeping across
    /// launches (recommended for large collections — see the README), use
    /// this to clear that bookkeeping in step with the engine, instead of
    /// re-uploading everything again next launch.
    public var onDataExportSucceeded: ((_ exportedItemIDs: Set<String>, _ deletedItemIDs: Set<String>) -> Void)?

    /// Called right after a successful Preferences export. Preferences are
    /// always exported as a single whole-file blob (never partitioned like
    /// Data items are), so there's no item-id bookkeeping to hand back here
    /// — just a signal that it happened, in case your own code wants to
    /// clear a "preferences pending sync" indicator of its own.
    public var onPreferencesExportSucceeded: (() -> Void)?

    /// Called right after a sync attempt succeeds, with `isAutomatic`
    /// mirroring `syncToICloud`'s own private parameter — `true` for a
    /// debounced/background sync, `false` for one the person explicitly
    /// triggered. Never called for a failed or cancelled sync (matching
    /// `onDataExportSucceeded`/`onPreferencesExportSucceeded`'s "Succeeded"
    /// naming above), so there's nothing to check inside the closure itself.
    /// A typical use: call `reconcileOrphanedItems()` when `isAutomatic` is
    /// `false`, to sweep orphaned cloud files after a person-initiated sync
    /// without paying that cost on every automatic one too.
    public var onSyncSucceeded: ((_ isAutomatic: Bool) -> Void)?

    /// Called right after a restore attempt succeeds — never for a failed or
    /// cancelled one. A typical use: call `reconcileOrphanedItems()`
    /// afterward, since a fresh restore is exactly when the local roster
    /// (`ICloudDriveSyncDataSource.allDataItemIDs()`) and the cloud copy are
    /// both most likely to have just been reconciled anyway, making this a
    /// cheap time to also catch any pre-existing orphan.
    public var onRestoreSucceeded: (() -> Void)?
    public var itemDisplayNameResolver: ((_ itemID: String) -> String?)?
    public var applyRestoredItemsHandler: ((_ items: [String: Data]) throws -> Void)?

    /// Read-only access to the config's user-facing copy — handy for a
    /// custom settings UI that wants the exact same wording the engine
    /// itself uses (see `ICloudDriveSyncSettingsSection` for a ready-made
    /// example that reads this).
    public var messages: ICloudDriveSyncConfig.Messages { config.messages }
    public var hasPendingChanges: Bool {
        !pendingItemIDs.isEmpty || !pendingDeletedItemIDs.isEmpty || hasPendingPreferencesChange
    }

    private let config: ICloudDriveSyncConfig
    private let backupEnvelopeURLProvider: @Sendable () -> URL?
    private let injectedIOPrimitives: ICloudDriveSyncWorker.IOPrimitives?
    private let networkMonitor = ICloudDriveNetworkMonitor()
    /// Where every bit of this engine's own persisted state lives (auto-sync
    /// mode, `lastSyncAt`, the pending-item sets, `deviceID`, the
    /// conflict-detection `itemModifiedAt` cache, ...) — all under
    /// `config.userDefaultsKeyPrefix`-prefixed keys, so it's safe to share
    /// a suite with the rest of the host app. Defaults to `.standard` but is
    /// injectable via `init(config:userDefaults:)`: pass a scratch
    /// `UserDefaults(suiteName:)` in unit tests so they don't read or leave
    /// behind state in the real app's defaults, and never need a live
    /// iCloud container to exercise this engine's persistence logic.
    private let defaults: UserDefaults
    /// The mechanical half of what used to be this file alone — see
    /// `ICloudDriveSyncWorker`'s own doc comment for the full split. Stateless
    /// by design (a fresh, cheap-to-construct value type), so there's no
    /// lifecycle to manage here beyond this one `let`.
    private let worker = ICloudDriveSyncWorker()
    /// Backing store for `recentEvents` — see `ICloudDriveSyncEventLog`. Not
    /// given a default here since its capacity comes from `config`, which
    /// isn't available until `init` runs.
    private var eventLog: ICloudDriveSyncEventLog
    /// A stable per-install identifier — generated once and persisted in
    /// `UserDefaults` (a reinstall gets a new one, which is correct: a
    /// reinstalled app has no memory of what it previously synced, so
    /// treating it as a "new device" for conflict detection is the right
    /// call). Written into every envelope this engine uploads
    /// (`BackupEnvelope.deviceID`) and compared against on every future
    /// export's conflict check — see `ICloudDriveSyncWorker.detectConflicts`.
    /// Exposed publicly mostly for a host's own diagnostics/support UI
    /// ("synced from this device" vs. "another device").
    public let deviceID: String
    /// Local cache of `BackupEnvelope.itemModifiedAt` — what this device
    /// last knew about every item's modification time, kept here (rather
    /// than re-fetched from the cloud on every export) so a conflict check
    /// works even under `.localWins` (which skips it) and doesn't need an
    /// extra round-trip beyond the one `detectConflicts` already does.
    /// Replaced wholesale on a successful restore (the cloud's copy becomes
    /// authoritative), updated incrementally on a successful export, and
    /// cleared on `deleteBackupManually()`.
    private var itemModifiedAtCache: [String: Date] = [:]

    /// Running per-item byte-size ledger for the Data lane, keyed by each
    /// item's resolved on-disk URL (`ICloudDriveFileIO.itemURL(for:in:)`) —
    /// lets `backupByteCount` be reported as a cheap in-memory sum instead
    /// of a full `Items/` directory walk on every single export/restore. A
    /// written item's entry is set to its exact byte size (already known
    /// from the `Data` just uploaded/downloaded — no extra I/O); a deleted
    /// item's entry is removed. Replaced wholesale on a successful restore
    /// (every downloaded item's size is already known too), and resynced
    /// from a real local directory listing by `refreshBackupStatus()` and by
    /// `reconcileOrphanedItems()` when it actually removes something — both
    /// of those already do a comparable walk of their own, so resyncing the
    /// ledger there costs nothing extra and can never let it drift for long.
    ///
    /// URL-keyed rather than item-id-keyed specifically so a from-disk
    /// reseed can be built straight from a raw directory listing without
    /// ever reversing an id out of a file path — the same "id → URL is
    /// trusted, URL → id is fragile" reasoning `reconcileOrphanedItems()`
    /// already relies on for its own orphan detection.
    private var itemByteSizeCache: [URL: Int64] = [:]
    /// The single-file components of `backupByteCount` that aren't part of
    /// `itemByteSizeCache` — each set straight from the `Data` just
    /// written/downloaded at its own call site, never from a disk read.
    /// Persisted individually (not just folded into the combined
    /// `backupByteCount`) so a fresh launch that only touches one lane (e.g.
    /// a Preferences-only sync) doesn't have to guess the other components
    /// it isn't updating right now.
    private var envelopeByteSize: Int64 = 0
    private var manifestByteSize: Int64 = 0
    private var preferencesByteSize: Int64 = 0
    /// Everything in the backup folder `itemByteSizeCache` +
    /// `envelopeByteSize`/`manifestByteSize`/`preferencesByteSize` can't
    /// account for — most notably `ICloudDriveImageAssetStore`'s `Images/`
    /// folder, which writes there completely outside this engine's own
    /// upload/restore path, so this engine has no way to track it
    /// incrementally. Set only by `refreshBackupStatus()`, as the gap
    /// between its real full-folder walk and everything this engine *does*
    /// track — carrying that gap forward is what keeps `backupByteCount`
    /// from silently shrinking back down the moment a normal (incremental)
    /// sync runs after a refresh. Stays accurate only as of the last
    /// `refreshBackupStatus()` call, same as the reconciliation sweep is
    /// only ever as fresh as the last time it ran.
    private var untrackedByteSize: Int64 = 0

    private var pendingItemIDs = Set<String>()
    private var pendingDeletedItemIDs = Set<String>()
    /// Preferences lane's equivalent of `pendingItemIDs` — there's nothing
    /// to partition (Preferences is always one whole-file blob), so this is
    /// just a flag rather than a set of ids.
    private var hasPendingPreferencesChange = false
    private var pendingAutoSyncTask: Task<Void, Never>?
    private var hasResolvedNetworkPath = false
    private var didRunStartupCheck = false
    private var shouldRetryRestoreOnWiFi = false
    private var didStart = false
    #if os(iOS)
    private var backgroundSyncTaskIdentifier: String?
    #endif

    /// Builds a new engine instance. See the type-level doc comment above
    /// for the typical `config` + `dataSource` + `start()` usage.
    ///
    /// - Parameters:
    ///   - config: The engine's static configuration — messages, policies,
    ///     thresholds, the iCloud container identifier. See
    ///     `ICloudDriveSyncConfig`.
    ///   - userDefaults: Where this engine's own persisted state (see
    ///     `defaults`'s doc comment) lives. Defaults to `.standard`, which
    ///     is what every real app wants; pass a dedicated
    ///     `UserDefaults(suiteName:)` from a unit test to isolate that
    ///     test's engine instance from both the real app's defaults and
    ///     from other tests running in the same process.
    public init(config: ICloudDriveSyncConfig, userDefaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = userDefaults
        self.backupEnvelopeURLProvider = {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: config.containerIdentifier) else {
                return nil
            }
            return containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(config.backupDirectoryName, isDirectory: true)
                .appendingPathComponent(config.backupFileName)
        }
        self.injectedIOPrimitives = nil
        self.eventLog = ICloudDriveSyncEventLog(capacity: config.eventLogCapacity)
        let deviceIDKey = config.userDefaultsKeyPrefix + "deviceID"
        if let existingDeviceID = ICloudDriveSyncEngine.readDeviceID(defaults: defaults, key: deviceIDKey) {
            self.deviceID = existingDeviceID
        } else {
            let generatedDeviceID = UUID().uuidString
            defaults.set(generatedDeviceID, forKey: deviceIDKey)
            self.deviceID = generatedDeviceID
        }
        ICloudDriveSyncError.messages = config.messages
        autoSyncMode = ICloudDriveSyncEngine.readAutoSyncMode(defaults: defaults, key: config.userDefaultsKeyPrefix + "autoSyncMode")
            ?? config.defaultAutoSyncMode
        lastSyncAt = defaults.object(forKey: config.userDefaultsKeyPrefix + "lastSyncAt") as? Date
        backupByteCount = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "backupByteCount"))
        hasUnrestoredBackup = defaults.bool(forKey: config.userDefaultsKeyPrefix + "unrestoredBackup")
        restorePendingChanges()
        itemModifiedAtCache = ICloudDriveSyncEngine.readItemModifiedAt(defaults: defaults, key: config.userDefaultsKeyPrefix + "itemModifiedAt")
        itemByteSizeCache = ICloudDriveSyncEngine.readItemByteSizeCache(defaults: defaults, key: config.userDefaultsKeyPrefix + "itemByteSizeCache")
        envelopeByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "envelopeByteSize"))
        manifestByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "manifestByteSize"))
        preferencesByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "preferencesByteSize"))
        untrackedByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "untrackedByteSize"))
    }

    init(
        config: ICloudDriveSyncConfig,
        userDefaults: UserDefaults = .standard,
        backupEnvelopeURL: @escaping @Sendable () -> URL?,
        ioPrimitives: ICloudDriveSyncWorker.IOPrimitives
    ) {
        self.config = config
        self.defaults = userDefaults
        self.backupEnvelopeURLProvider = backupEnvelopeURL
        self.injectedIOPrimitives = ioPrimitives
        self.eventLog = ICloudDriveSyncEventLog(capacity: config.eventLogCapacity)
        let deviceIDKey = config.userDefaultsKeyPrefix + "deviceID"
        if let existingDeviceID = ICloudDriveSyncEngine.readDeviceID(defaults: defaults, key: deviceIDKey) {
            self.deviceID = existingDeviceID
        } else {
            let generatedDeviceID = UUID().uuidString
            defaults.set(generatedDeviceID, forKey: deviceIDKey)
            self.deviceID = generatedDeviceID
        }
        ICloudDriveSyncError.messages = config.messages
        autoSyncMode = ICloudDriveSyncEngine.readAutoSyncMode(defaults: defaults, key: config.userDefaultsKeyPrefix + "autoSyncMode")
            ?? config.defaultAutoSyncMode
        lastSyncAt = defaults.object(forKey: config.userDefaultsKeyPrefix + "lastSyncAt") as? Date
        backupByteCount = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "backupByteCount"))
        hasUnrestoredBackup = defaults.bool(forKey: config.userDefaultsKeyPrefix + "unrestoredBackup")
        restorePendingChanges()
        itemModifiedAtCache = ICloudDriveSyncEngine.readItemModifiedAt(defaults: defaults, key: config.userDefaultsKeyPrefix + "itemModifiedAt")
        itemByteSizeCache = ICloudDriveSyncEngine.readItemByteSizeCache(defaults: defaults, key: config.userDefaultsKeyPrefix + "itemByteSizeCache")
        envelopeByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "envelopeByteSize"))
        manifestByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "manifestByteSize"))
        preferencesByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "preferencesByteSize"))
        untrackedByteSize = Int64(defaults.integer(forKey: config.userDefaultsKeyPrefix + "untrackedByteSize"))
    }

    /// Call once, after `dataSource` is set. Synchronously flags whether the
    /// app should show the initial restore overlay (mirroring what the
    /// original hand-rolled code did in its store's own `init()`), and
    /// starts network monitoring. Safe to call more than once — later calls
    /// are ignored.
    public func start() {
        guard !didStart else { return }
        didStart = true

        let hasLocalData = dataSource?.hasLocalData() ?? true
        if !hasLocalData || pendingRestoreFlag {
            isInitialRestoreBlocking = true
        }

        networkMonitor.onUpdate = { [weak self] state in
            Task { @MainActor in
                self?.handleNetworkUpdate(state)
            }
        }
        networkMonitor.start()

        if hasPendingChanges {
            scheduleBackgroundSyncIfNeeded()
            scheduleAutoSyncIfNeeded()
        }
    }

    deinit {
        pendingAutoSyncTask?.cancel()
        networkMonitor.cancel()
    }

    // MARK: Local-change notifications

    /// Tell the engine that local Data changed. Call this right after your
    /// own local persistence happens — from the same spot the old code used
    /// to flip `settings.iCloudPendingChanges = true`. Schedules a debounced
    /// auto-sync if `autoSyncMode` allows one right now. See
    /// `notifyPreferencesChanged()` for the Preferences-lane equivalent.
    public func notifyDataChanged(changedItemIDs: Set<String> = [], deletedItemIDs: Set<String> = []) {
        pendingItemIDs.formUnion(changedItemIDs)
        for id in deletedItemIDs {
            pendingItemIDs.remove(id)
        }
        pendingDeletedItemIDs.formUnion(deletedItemIDs)
        persistPendingChanges()
        scheduleBackgroundSyncIfNeeded()
        scheduleAutoSyncIfNeeded()
    }

    /// Tell the engine that local Preferences changed. Call this right
    /// after your own local persistence of a settings change happens —
    /// mirrors `notifyDataChanged`, but for the Preferences lane (a single
    /// whole-file blob, not partitioned by item id). Schedules a debounced
    /// auto-sync if `autoSyncMode` allows one right now.
    public func notifyPreferencesChanged() {
        hasPendingPreferencesChange = true
        persistPendingChanges()
        scheduleBackgroundSyncIfNeeded()
        scheduleAutoSyncIfNeeded()
    }

    /// Marks every Data item the data source currently reports as changed.
    /// Use this after a migration, or right after `start()` if your own
    /// local storage already remembers which items were still unsynced from
    /// a previous launch (pass those ids to `notifyDataChanged` directly
    /// instead if you track them individually — that avoids a full
    /// re-upload).
    public func markAllDataItemsChanged() {
        notifyDataChanged(changedItemIDs: dataSource?.allDataItemIDs() ?? [])
    }

    /// Cancels any pending debounce and attempts a sync immediately if
    /// conditions allow — call this when the app is about to background.
    /// Fire-and-forget; check `syncMessage`/`isSyncing` if you need the
    /// outcome.
    public func flushPendingChangesNow() {
        pendingAutoSyncTask?.cancel()
        pendingAutoSyncTask = nil
        guard autoSyncMode != .off,
              !pendingItemIDs.isEmpty || !pendingDeletedItemIDs.isEmpty || hasPendingPreferencesChange else { return }
        Task { await syncToICloud(isAutomatic: true) }
        scheduleBackgroundSyncIfNeeded()
    }

    // MARK: Public actions

    #if os(iOS)
    /// Registers an iOS `BGAppRefreshTask` that lets the system wake the app
    /// opportunistically to push pending changes. The host app must also add
    /// this identifier to `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    @discardableResult
    public func registerBackgroundSyncTask(identifier: String) -> Bool {
        backgroundSyncTaskIdentifier = identifier
        let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            Task { @MainActor in
                await self?.handleBackgroundSyncTask(task)
            }
        }

        if didRegister {
            scheduleBackgroundSyncIfNeeded()
        } else {
            logEvent("icloud_background_sync_register_failed", ["identifier": identifier], level: .error)
        }
        return didRegister
    }

    /// Schedules the registered background sync task if there are still
    /// pending changes. iOS decides the actual run time; this is a request,
    /// not a guarantee.
    public func scheduleBackgroundSync(earliestBeginDate: Date? = nil) {
        guard let backgroundRequest = ICloudDriveBackgroundSyncDecision.scheduleRequest(
            identifier: backgroundSyncTaskIdentifier,
            autoSyncMode: autoSyncMode,
            hasPendingChanges: hasPendingChanges,
            requestedEarliestBeginDate: earliestBeginDate,
            autoSyncDebounceSeconds: config.autoSyncDebounceSeconds
        ) else { return }

        let request = BGAppRefreshTaskRequest(identifier: backgroundRequest.identifier)
        request.earliestBeginDate = backgroundRequest.earliestBeginDate

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundRequest.identifier)
            try BGTaskScheduler.shared.submit(request)
            logEvent("icloud_background_sync_scheduled", ["identifier": backgroundRequest.identifier], level: .info)
        } catch {
            logEvent("icloud_background_sync_schedule_failed", [
                "identifier": backgroundRequest.identifier,
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }
    #endif

    public func refreshBackupStatus() async {
        guard let backupURL = backupEnvelopeURL() else {
            setSyncMessage(config.messages.iCloudDriveUnavailable, outcome: .failure(.iCloudUnavailable))
            finishSyncProgress(success: false)
            return
        }

        do {
            if let byteCount = try await ICloudDriveFileIO.byteCount(at: backupURL) {
                setBackupByteCount(byteCount)
                // This is the one place that still pays for a full
                // directory walk — deliberately, since it's the only way to
                // see bytes this engine's own incremental ledger
                // (`itemByteSizeCache` + `envelopeByteSize`/
                // `manifestByteSize`/`preferencesByteSize`, each set
                // straight from `Data` already in hand elsewhere, no disk
                // read) can never know about on its own: anything else
                // living in the same backup folder, most notably
                // `ICloudDriveImageAssetStore`'s `Images/` folder, which
                // writes there completely outside this engine's own
                // upload/restore path. Recording the gap between the two as
                // `untrackedByteSize` lets the *next* incremental sync's
                // cheap total keep including it, instead of the reported
                // size silently shrinking back down to "just what the
                // ledger knows" the moment a normal sync runs after this.
                if let itemSizes = try? await ICloudDriveFileIO.fileSizes(under: itemsDirectoryURL(for: backupURL)) {
                    itemByteSizeCache = itemSizes
                    persistItemByteSizeCache()
                    markItemByteSizeCacheSeeded()
                    setUntrackedByteSize(max(0, byteCount - trackedContentByteCount()))
                }
            } else {
                setBackupByteCount(0)
                setLastSyncAt(nil)
                setSyncMessage(config.messages.noBackupFoundYet, outcome: .failure(.noBackupFound))
            }
        } catch {
            setSyncMessage(error.localizedDescription, outcome: .failure(syncFailure(for: error)))
        }
    }

    public func syncManually() async {
        if await syncToICloud(isAutomatic: false) {
            clearUnrestoredBackup()
        }
    }

    public func restoreManually() async {
        guard !isSyncing else { return }
        #if os(iOS)
        if hasUnrestoredBackup, !isWiFiConnected {
            setSyncMessage(config.messages.tryWithWiFi, outcome: .warning(.waitingForWiFi))
            return
        }
        #endif
        markPendingRestore()
        isSyncing = true
        setSyncProgress(.downloadingEnvelope)
        setSyncMessage(config.messages.downloadingBackup, outcome: .warning(.downloadingBackup))
        defer {
            isSyncing = false
            clearPendingRestore()
        }
        _ = await restoreLatestBackupIfAvailable(showMissingBackupMessage: true)
    }

    /// Creates an optional point-in-time snapshot backup without touching
    /// the normal current backup used by auto sync/manual sync. Hosts that
    /// want backup history can call this from their own UI; hosts that do
    /// not call it keep the exact same single-backup behavior as before.
    @discardableResult
    public func createSnapshotBackup(label: String? = nil) async throws -> ICloudDriveBackupDescriptor {
        guard !isSyncing else {
            throw ICloudDriveSyncError.readFailed("A sync is already in progress.")
        }
        guard let dataSource else {
            throw ICloudDriveSyncError.dataSourceMissing
        }
        guard let currentBackupURL = backupEnvelopeURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }

        let backupID = UUID().uuidString
        let exportDate = Date()
        let snapshotBackupURL = snapshotEnvelopeURL(id: backupID, currentBackupURL: currentBackupURL)
        let snapshotDirectoryURL = snapshotBackupURL.deletingLastPathComponent()
        let snapshotItemsURL = itemsDirectoryURL(for: snapshotBackupURL)
        try FileManager.default.createDirectory(at: snapshotDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotItemsURL, withIntermediateDirectories: true)

        isSyncing = true
        defer { isSyncing = false }

        let payload = dataSource.exportData(changedItemIDs: nil, deletedItemIDs: [])
        let metadata = dataSource.hostSchemaMetadata()
        let allItemIDs = dataSource.allDataItemIDs()
        let result = try await worker.uploadData(
            items: payload.items,
            deletedItemIDs: [],
            manifest: payload.manifest,
            allItemIDs: allItemIDs,
            appName: config.appName,
            exportedAt: exportDate,
            deviceID: deviceID,
            itemModifiedAt: payload.modifiedAt,
            backupID: backupID,
            label: label,
            hostSchemaMetadata: metadata,
            itemsURL: snapshotItemsURL,
            manifestURL: manifestURL(for: snapshotBackupURL),
            envelopeURL: snapshotBackupURL,
            io: ioPrimitives,
            onProgress: progressReporter
        )

        let preferencesData = dataSource.exportPreferences()
        try await worker.uploadPreferences(
            preferencesData,
            preferencesURL: preferencesURL(for: snapshotBackupURL),
            io: ioPrimitives,
            onProgress: progressReporter
        )

        let byteCount = result.envelopeByteCount
            + Int64(payload.manifest.count)
            + result.exportedItemByteSizes.values.reduce(0, +)
            + Int64(preferencesData.count)
        let descriptor = ICloudDriveBackupDescriptor(
            id: backupID,
            label: label,
            createdAt: exportDate,
            exportedAt: exportDate,
            appName: config.appName,
            appVersion: metadata?.appVersion,
            appBuild: metadata?.appBuild,
            hostSchemaMetadata: metadata,
            itemCount: allItemIDs.count,
            byteCount: byteCount,
            deviceID: deviceID
        )
        finishSyncProgress(success: true)
        logEvent("icloud_snapshot_backup_created", [
            "backup_id": backupID,
            "item_count": String(descriptor.itemCount)
        ], level: .info)
        return descriptor
    }

    /// Lists optional snapshot backups. The normal current backup is not
    /// included here; callers that never opt into snapshots will simply get
    /// an empty list.
    public func listSnapshotBackups() async throws -> [ICloudDriveBackupDescriptor] {
        guard let currentBackupURL = backupEnvelopeURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }
        let snapshotsURL = snapshotsDirectoryURL(currentBackupURL: currentBackupURL)
        guard FileManager.default.fileExists(atPath: snapshotsURL.path) else {
            return []
        }

        let snapshotDirectories = try FileManager.default.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        var descriptors: [ICloudDriveBackupDescriptor] = []
        for directoryURL in snapshotDirectories {
            let backupID = directoryURL.lastPathComponent
            guard isValidSnapshotID(backupID) else { continue }
            let envelopeURL = directoryURL.appendingPathComponent(config.backupFileName)
            guard FileManager.default.fileExists(atPath: envelopeURL.path) else { continue }
            var envelopeData = try? await ioPrimitives.download(envelopeURL)
            if envelopeData == nil {
                envelopeData = try? await ICloudDriveFileIO.coordinatedReadData(from: envelopeURL)
            }
            guard let envelopeData,
                  let envelope = try? JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData) else {
                continue
            }
            let values = try? directoryURL.resourceValues(forKeys: [.creationDateKey])
            let byteCount = try? await ioPrimitives.byteCount(directoryURL)
            descriptors.append(snapshotDescriptor(
                id: envelope.backupID ?? backupID,
                directoryCreatedAt: values?.creationDate,
                envelope: envelope,
                byteCount: byteCount
            ))
        }

        return descriptors.sorted { lhs, rhs in
            if lhs.exportedAt != rhs.exportedAt {
                return lhs.exportedAt > rhs.exportedAt
            }
            return lhs.id < rhs.id
        }
    }

    /// Restores one optional snapshot backup by id. This does not change or
    /// delete the normal current backup; hosts can choose whether restoring
    /// an older snapshot should later be pushed to the current backup by
    /// calling their usual change-notification/sync flow.
    @discardableResult
    public func restoreSnapshotBackup(id backupID: String) async throws -> ICloudDriveRestoreReport {
        guard !isSyncing else {
            throw ICloudDriveSyncError.readFailed("A sync is already in progress.")
        }
        guard isValidSnapshotID(backupID) else {
            throw ICloudDriveSyncError.readFailed("Invalid snapshot backup id.")
        }
        guard let dataSource else {
            throw ICloudDriveSyncError.dataSourceMissing
        }
        guard let currentBackupURL = backupEnvelopeURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }

        isSyncing = true
        setSyncProgress(.downloadingEnvelope)
        setSyncMessage(config.messages.downloadingBackup, outcome: .warning(.downloadingBackup))
        defer { isSyncing = false }

        let snapshotBackupURL = snapshotEnvelopeURL(id: backupID, currentBackupURL: currentBackupURL)
        guard let result = try await readBackup(backupURL: snapshotBackupURL) else {
            finishSyncProgress(success: false)
            throw ICloudDriveSyncError.readFailed("Snapshot backup not found.")
        }

        setSyncProgress(.applyingRestore, completed: result.report.restoredItemCount, total: result.report.expectedItemCount)
        try dataSource.validateRestoredHostSchemaMetadata(result.envelope.hostSchemaMetadata)
        try dataSource.applyRestoredData(manifest: result.manifest, items: result.items)
        await restorePreferencesIfAvailable(backupURL: snapshotBackupURL)

        lastRestoredHostSchemaMetadata = result.envelope.hostSchemaMetadata
        lastRestoreReport = result.report
        setSyncMessage(
            result.report.hasIssues ? restoreSummaryMessage(for: result.report) : config.messages.restoredMessage,
            outcome: .success(result.report.hasIssues ? .restoredWithIssues : .restored)
        )
        finishSyncProgress(success: true)
        logEvent("icloud_snapshot_backup_restored", [
            "backup_id": backupID,
            "expected_count": String(result.report.expectedItemCount),
            "restored_count": String(result.report.restoredItemCount)
        ], level: .info)
        return result.report
    }

    /// Permanently deletes one optional snapshot backup by id. The normal
    /// current backup is never touched.
    public func deleteSnapshotBackup(id backupID: String) async throws {
        guard !isSyncing else {
            throw ICloudDriveSyncError.readFailed("A sync is already in progress.")
        }
        guard isValidSnapshotID(backupID) else {
            throw ICloudDriveSyncError.readFailed("Invalid snapshot backup id.")
        }
        guard let currentBackupURL = backupEnvelopeURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }

        isSyncing = true
        setSyncProgress(.deletingBackup)
        defer { isSyncing = false }

        let directoryURL = snapshotEnvelopeURL(id: backupID, currentBackupURL: currentBackupURL).deletingLastPathComponent()
        if injectedIOPrimitives != nil {
            try await ioPrimitives.delete(directoryURL)
        }
        try await ICloudDriveFileIO.coordinatedDeleteItem(at: directoryURL)
        finishSyncProgress(success: true)
        logEvent("icloud_snapshot_backup_deleted", ["backup_id": backupID], level: .info)
    }

    @discardableResult
    public func retryLastMissingRestoreItems() async -> ICloudDriveRestoreReport? {
        guard let lastRestoreReport else {
            setSyncMessage(config.messages.restoreRetryNoItems, outcome: .warning(.noRetryableItems))
            return nil
        }
        return await retryRestoreItems(lastRestoreReport.retryableItemIDs)
    }

    @discardableResult
    public func retryRestoreItems(_ itemIDs: Set<String>) async -> ICloudDriveRestoreReport? {
        guard !isSyncing else { return nil }
        guard !itemIDs.isEmpty else {
            setSyncMessage(config.messages.restoreRetryNoItems, outcome: .warning(.noRetryableItems))
            return lastRestoreReport
        }
        guard let applyRestoredItemsHandler else {
            setSyncMessage(config.messages.restoreRetryRequiresItemApplyHandler, outcome: .failure(.individualRetryUnsupported))
            return lastRestoreReport
        }
        guard let backupURL = backupEnvelopeURL() else {
            setSyncMessage(config.messages.iCloudDriveUnavailable, outcome: .failure(.iCloudUnavailable))
            return lastRestoreReport
        }

        isSyncing = true
        setSyncProgress(.downloadingItems, completed: 0, total: itemIDs.count)
        setSyncMessage(config.messages.downloadingBackup, outcome: .warning(.downloadingBackup))
        defer { isSyncing = false }

        do {
            let retryResult = try await readBackupItems(itemIDs, backupURL: backupURL)
            if !retryResult.items.isEmpty {
                setSyncProgress(.applyingRestore, completed: retryResult.items.count, total: itemIDs.count)
                try applyRestoredItemsHandler(retryResult.items)
                // Same reasoning as the full restore path — every retried
                // item's size is already known from the `Data` just
                // downloaded, so fold it straight into the ledger.
                let itemsURL = itemsDirectoryURL(for: backupURL)
                for (itemID, data) in retryResult.items {
                    itemByteSizeCache[ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL)] = Int64(data.count)
                }
                persistItemByteSizeCache()
                setBackupByteCount(recomputedBackupByteCount())
            }
            let mergedReport = mergeLastRestoreReport(
                retryReport: retryResult.report,
                restoredItemIDs: Set(retryResult.items.keys)
            )
            lastRestoreReport = mergedReport
            setSyncMessage(
                mergedReport.hasIssues ? restoreSummaryMessage(for: mergedReport) : config.messages.restoreRetrySucceeded,
                outcome: .success(mergedReport.hasIssues ? .partialRetry : .retrySucceeded)
            )
            if mergedReport.hasIssues {
                restoreWarningMessage = restoreSummaryMessage(for: mergedReport)
            }
            logEvent("icloud_restore_items_retried", [
                "requested_count": String(itemIDs.count),
                "restored_count": String(retryResult.items.count),
                "missing_count": String(retryResult.report.missingItems.count),
                "failed_count": String(retryResult.report.failedItems.count)
            ], level: .info)
            finishSyncProgress(success: true)
            return mergedReport
        } catch is CancellationError {
            // Not a failure — see `syncToICloud`'s identical branch. The
            // items just requested stay retryable; `lastRestoreReport` is
            // untouched, so a follow-up `retryRestoreItems` call sees the
            // exact same pending set it would have before this attempt.
            finishSyncProgress(success: false)
            logEvent("icloud_restore_items_retry_cancelled", ["requested_count": String(itemIDs.count)], level: .info)
            return lastRestoreReport
        } catch {
            setSyncMessage(error.localizedDescription, outcome: .failure(.retryFailed))
            finishSyncProgress(success: false)
            logEvent("icloud_restore_items_retry_failed", ["error_type": String(describing: type(of: error))], level: .error)
            return lastRestoreReport
        }
    }

    /// Compares the host's current data roster
    /// (`ICloudDriveSyncDataSource.allDataItemIDs()`) against every file
    /// actually sitting in the cloud `Items/` folder, and deletes whatever's
    /// there but isn't in that roster anymore.
    ///
    /// Nothing on the normal sync/restore path is supposed to leave an
    /// orphan behind, but a few things can still cause one to accumulate
    /// over time: an export interrupted mid-delete (`uploadData`'s per-item
    /// deletes are best-effort, not transactional as a set), a host that
    /// renamed an id without ever deleting the file at the old one, or a
    /// backup written by an older version of the host's own export logic
    /// before some ids were retired. None of that is common enough to
    /// justify running this automatically on every sync — it costs a full
    /// directory listing plus a diff against every expected id, unlike a
    /// normal incremental export — so this is **host-triggered only**: call
    /// it from a settings action ("Clean up iCloud backup"), on a periodic
    /// timer, or after a full export, on whatever cadence fits your app. It
    /// is never called from `syncToICloud`, `restoreLatestBackupIfAvailable`,
    /// or any other automatic path in this engine.
    ///
    /// Deliberately has no `isSyncing` guard, unlike every other public
    /// method here — running this concurrently with an in-flight sync is
    /// still *correct* (it only ever deletes a file that isn't in the
    /// current roster, and a concurrent export only ever writes files that
    /// are in it), just potentially wasteful in the rare case their timing
    /// overlaps (e.g. it might list the items folder just before a
    /// currently-running export finishes writing a brand new item, and
    /// delete it as an apparent orphan a moment before the export's own
    /// envelope update would have made it "expected" — never silent data
    /// loss on the *source of truth*, since `dataSource.allDataItemIDs()` is
    /// untouched, but the cloud copy of that one item would need a follow-up
    /// sync to reappear). Callers that want to avoid that entirely can check
    /// `isSyncing` themselves before calling this.
    ///
    /// Requires `dataSource` to be set (same as every export); throws
    /// `.dataSourceMissing` if it isn't. Returns a zero-count result rather
    /// than throwing if there's no backup in iCloud yet to reconcile against.
    @discardableResult
    public func reconcileOrphanedItems() async throws -> ICloudDriveReconciliationResult {
        guard let dataSource else {
            throw ICloudDriveSyncError.dataSourceMissing
        }
        guard let backupURL = backupEnvelopeURL() else {
            return ICloudDriveReconciliationResult(removedItemCount: 0)
        }
        let itemsURL = itemsDirectoryURL(for: backupURL)

        do {
            let raw = try await worker.reconcileOrphanedItems(
                expectedItemIDs: dataSource.allDataItemIDs(),
                itemsURL: itemsURL,
                io: ioPrimitives
            )
            if raw.removedItemCount > 0 {
                logEvent("icloud_reconciliation_removed_orphans", [
                    "removed_count": String(raw.removedItemCount)
                ], level: .warning)
                // The sweep just did a comparable local walk to find these
                // orphans in the first place, so resyncing the byte ledger
                // from a fresh listing here costs nothing extra — and it's
                // simpler and more robust than trying to subtract each
                // removed file's size individually from
                // `raw.removedRelativePaths`, which would mean either
                // reconstructing an item id from a file path (the exact
                // "fragile reverse-engineering" this whole feature already
                // avoids for orphan detection itself) or re-reading each
                // file's size before it's gone.
                if let itemSizes = try? await ICloudDriveFileIO.fileSizes(under: itemsURL) {
                    itemByteSizeCache = itemSizes
                    persistItemByteSizeCache()
                    setBackupByteCount(recomputedBackupByteCount())
                }
            } else {
                logEvent("icloud_reconciliation_clean", [:], level: .info)
            }
            return ICloudDriveReconciliationResult(
                removedItemCount: raw.removedItemCount,
                removedRelativePaths: raw.removedRelativePaths
            )
        } catch is CancellationError {
            logEvent("icloud_reconciliation_cancelled", [:], level: .info)
            throw CancellationError()
        } catch {
            logEvent("icloud_reconciliation_failed", ["error_type": String(describing: type(of: error))], level: .error)
            throw error
        }
    }

    /// Permanently deletes **everything** this app has backed up to iCloud —
    /// the envelope, manifest, Preferences file, the whole `Items/` folder,
    /// and (if the host also uses `ICloudDriveImageAssetStore` with the same
    /// `backupDirectoryName`, which is the normal setup) the whole `Images/`
    /// folder right along with it, since all of it lives under one shared
    /// `backupDirectoryName` folder in the ubiquity container. This does
    /// **not** touch any local data — only the iCloud copy. Irreversible;
    /// this method itself does not confirm anything (no alert, no "are you
    /// sure") — that's `ICloudDriveSyncSettingsSection`'s job when you enable
    /// its delete-backup option, or your own UI's job if you call this
    /// directly. Call only after the person has explicitly confirmed.
    ///
    /// No-ops (still reports success) if there's no backup to delete. A
    /// later local change still syncs normally afterward — `lastSyncAt` is
    /// cleared here, so the next export is a fresh full one rather than
    /// assuming incremental state that no longer exists in the cloud.
    public func deleteBackupManually() async {
        guard !isSyncing else { return }
        isSyncing = true
        setSyncProgress(.deletingBackup)
        pendingAutoSyncTask?.cancel()
        pendingAutoSyncTask = nil
        defer { isSyncing = false }

        guard let backupURL = backupEnvelopeURL() else {
            setSyncMessage(config.messages.iCloudDriveUnavailable, outcome: .failure(.iCloudUnavailable))
            return
        }

        do {
            try await ICloudDriveFileIO.coordinatedDeleteItem(at: backupURL.deletingLastPathComponent())
            pendingItemIDs.removeAll()
            pendingDeletedItemIDs.removeAll()
            hasPendingPreferencesChange = false
            persistPendingChanges()
            setLastSyncAt(nil)
            setBackupByteCount(0)
            setLargeBackupWarningShown(false)
            showLargeBackupWarning = false
            clearUnrestoredBackup()
            clearPendingRestore()
            // Nothing left in the cloud to have conflicted with — a stale
            // cache here would otherwise persist across an intentional wipe
            // and could spuriously flag conflicts against a backup that no
            // longer exists.
            itemModifiedAtCache.removeAll()
            clearPersistedItemModifiedAt()
            // Same reasoning — nothing left in the cloud for the byte
            // ledger to describe either, and leaving stale entries around
            // would make the *next* export's incremental total wrong from
            // the very first sync after this wipe.
            itemByteSizeCache.removeAll()
            clearPersistedItemByteSizeCache()
            setEnvelopeByteSize(0)
            setManifestByteSize(0)
            setPreferencesByteSize(0)
            setUntrackedByteSize(0)
            pendingConflicts.removeAll()
            setSyncMessage(config.messages.deleteBackupSucceededMessage, outcome: .success(.backupDeleted))
            finishSyncProgress(success: true)
            logEvent("icloud_backup_deleted", [:], level: .info)
        } catch {
            setSyncMessage("\(config.messages.errorDeleteBackupFailedPrefix) \(error.localizedDescription)", outcome: .failure(.deleteBackupFailed))
            finishSyncProgress(success: false)
            logEvent("icloud_delete_backup_failed", ["error_type": String(describing: type(of: error))], level: .error)
        }
    }

    /// Call from a `.task` (or equivalent) at app launch and again whenever
    /// the app returns to the foreground. Cheap to call repeatedly — it only
    /// actually does anything the first time, or if a previous restore was
    /// interrupted.
    public func runStartupRestoreCheckIfNeeded() async {
        let shouldResume = pendingRestoreFlag
        guard !isSyncing else { return }
        let hasLocalData = dataSource?.hasLocalData() ?? true
        guard !didRunStartupCheck || !hasLocalData || shouldResume else { return }
        didRunStartupCheck = true

        if !hasLocalData || shouldResume {
            isInitialRestoreBlocking = true
            setSyncProgress(.checkingBackup)
            setSyncMessage(config.messages.checkingBackup, outcome: .warning(.checkingBackup))
            await waitForInitialNetworkPath()
        }
        await restoreIfNeeded(force: shouldResume)
        await refreshBackupStatus()
    }

    public func selectAutoSyncMode(_ mode: ICloudAutoSyncMode) {
        autoSyncMode = mode
        persistAutoSyncMode()
        logEvent("icloud_auto_sync_mode_changed", ["mode": mode.rawValue], level: .info)
        if mode == .always {
            setLargeBackupWarningShown(false)
        }
        scheduleAutoSyncIfNeeded()
    }

    public func dismissLargeBackupWarning() {
        showLargeBackupWarning = false
        setLargeBackupWarningShown(true)
    }

    public func dismissRestoreWarning() {
        restoreWarningMessage = nil
    }

    /// A point-in-time snapshot of this engine's state, meant to sit behind
    /// a "Copy Diagnostics"/"Export Diagnostics" button in a host's own
    /// support flow — call `.jsonString()` on the result for something
    /// directly shareable. See `ICloudDriveSyncDiagnosticsSnapshot`'s own doc
    /// comment for exactly what it does (and deliberately doesn't) include.
    public func makeDiagnosticsSnapshot() -> ICloudDriveSyncDiagnosticsSnapshot {
        ICloudDriveSyncDiagnosticsSnapshot(
            generatedAt: Date(),
            appName: config.appName,
            deviceID: deviceID,
            isICloudAvailable: backupEnvelopeURL() != nil,
            autoSyncMode: autoSyncMode,
            isSyncing: isSyncing,
            isNetworkConnected: isNetworkConnected,
            isWiFiConnected: isWiFiConnected,
            isCellularConnected: isCellularConnected,
            isLowDataModeEnabled: isLowDataModeEnabled,
            hasUnrestoredBackup: hasUnrestoredBackup,
            hasPendingChanges: hasPendingChanges,
            pendingItemCount: pendingItemIDs.count,
            pendingDeletedItemCount: pendingDeletedItemIDs.count,
            pendingConflictCount: pendingConflicts.count,
            hasPendingPreferencesChange: hasPendingPreferencesChange,
            lastRestoredHostSchemaMetadata: lastRestoredHostSchemaMetadata,
            lastSyncAt: lastSyncAt,
            backupByteCount: backupByteCount,
            syncOutcomeDescription: syncOutcome.diagnosticsDescription,
            syncMessage: syncMessage,
            lastRestoreReport: lastRestoreReport.map {
                ICloudDriveSyncDiagnosticsSnapshot.RestoreReportSummary(
                    expectedItemCount: $0.expectedItemCount,
                    restoredItemCount: $0.restoredItemCount,
                    missingItemCount: $0.missingItems.count,
                    failedItemCount: $0.failedItems.count
                )
            },
            recentEvents: recentEvents
        )
    }

    private func setSyncMessage(_ message: String?, outcome: ICloudDriveSyncOutcome) {
        syncMessage = message
        syncOutcome = outcome
    }

    /// Records `name`/`data` into `recentEvents` (and `lastError` if
    /// `level` is `.error`) and forwards to `onEvent` — every call site that
    /// used to call `onEvent?(...)` directly calls this instead now, so the
    /// in-memory history and a host's own analytics hook always see exactly
    /// the same events.
    private func logEvent(_ name: String, _ data: [String: String] = [:], level: ICloudDriveSyncLogEntry.Level) {
        let entry = ICloudDriveSyncLogEntry(timestamp: Date(), name: name, level: level, data: data)
        eventLog.append(entry)
        recentEvents = eventLog.entries
        if level == .error {
            lastError = entry
        }
        onEvent?(name, data)
    }

    private func setSyncProgress(
        _ phase: ICloudDriveSyncProgressPhase,
        completed: Int = 0,
        total: Int? = nil,
        currentItemID: String? = nil
    ) {
        syncProgress = ICloudDriveSyncProgress(
            phase: phase,
            completedUnitCount: completed,
            totalUnitCount: total,
            currentItemID: currentItemID
        )
    }

    private func finishSyncProgress(success: Bool) {
        syncProgress = ICloudDriveSyncProgress(
            phase: success ? .finished : .failed,
            completedUnitCount: 1,
            totalUnitCount: 1
        )
    }

    // MARK: Network monitor callback

    private func handleNetworkUpdate(_ state: ICloudDriveNetworkMonitor.PathState) {
        hasResolvedNetworkPath = true
        isNetworkConnected = state.isConnected
        isWiFiConnected = state.isWiFi
        isCellularConnected = state.isCellular
        isLowDataModeEnabled = state.isConstrained

        if isWiFiConnected,
           shouldRetryRestoreOnWiFi,
           !(dataSource?.hasLocalData() ?? true),
           !isSyncing {
            shouldRetryRestoreOnWiFi = false
            Task { await restoreIfNeeded() }
            return
        }

        if autoSyncCanRun,
           !pendingItemIDs.isEmpty || !pendingDeletedItemIDs.isEmpty || hasPendingPreferencesChange,
           !isSyncing,
           !isInitialRestoreBlocking {
            scheduleAutoSyncIfNeeded()
        }
    }

    // MARK: Core sync flow

    private func scheduleAutoSyncIfNeeded() {
        scheduleBackgroundSyncIfNeeded()
        guard autoSyncMode != .off else { return }
        guard !isSyncing, !isInitialRestoreBlocking else { return }
        guard autoSyncCanRun else {
            setSyncMessage(autoSyncWaitingMessage, outcome: autoSyncWaitingOutcome)
            return
        }

        pendingAutoSyncTask?.cancel()
        pendingAutoSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.config.autoSyncDebounceSeconds * 1_000_000_000))
                await self.syncToICloud(isAutomatic: true)
            } catch {
                return
            }
        }
    }

    private func restoreIfNeeded(force: Bool = false) async {
        let hasLocalData = dataSource?.hasLocalData() ?? true
        guard force || !hasLocalData else { return }
        guard !isSyncing else { return }
        pendingAutoSyncTask?.cancel()
        markPendingRestore()
        let restoreStartedAt = Date()
        isInitialRestoreBlocking = true
        isSyncing = true
        setSyncProgress(.checkingBackup)
        setSyncMessage(config.messages.checkingBackup, outcome: .warning(.checkingBackup))

        var attempt = 0
        while attempt < initialRestoreCheckAttemptLimit {
            guard force || !(dataSource?.hasLocalData() ?? true) else { break }

            guard let backupURL = backupEnvelopeURL() else {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(config.pollIntervalSeconds * 1_000_000_000))
                continue
            }

            if FileManager.default.fileExists(atPath: backupURL.path) {
                setSyncMessage(config.messages.restoringData, outcome: .warning(.restoringData))
                _ = await restoreLatestBackupIfAvailable(showMissingBackupMessage: false)
                break
            }

            if attempt == 0 || attempt % 10 == 0 {
                setSyncProgress(.waitingForNetwork)
                setSyncMessage(cellularWaitingMessage, outcome: cellularWaitingOutcome)
            }
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(config.pollIntervalSeconds * 1_000_000_000))
        }

        if shouldSuggestWiFiForRestore, !(dataSource?.hasLocalData() ?? true) {
            showCellularRestoreWarning()
        }
        if syncProgress.isActive {
            finishSyncProgress(success: false)
        }
        await finishInitialRestore(startedAt: restoreStartedAt)
        clearPendingRestore()
    }

    private func waitForInitialNetworkPath() async {
        var attempt = 0
        while !hasResolvedNetworkPath && attempt < 6 {
            attempt += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func finishInitialRestore(startedAt: Date) async {
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = config.minimumInitialRestoreOverlayDuration - elapsed
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        isSyncing = false
        isInitialRestoreBlocking = false
        if !pendingItemIDs.isEmpty || !pendingDeletedItemIDs.isEmpty || hasPendingPreferencesChange {
            scheduleAutoSyncIfNeeded()
        }
    }

    @discardableResult
    private func syncToICloud(isAutomatic: Bool) async -> Bool {
        guard !isSyncing else {
            setSyncMessage(syncMessage, outcome: .warning(.busy))
            return false
        }
        guard !isInitialRestoreBlocking else {
            setSyncMessage(syncMessage, outcome: .warning(.busy))
            return false
        }
        if isAutomatic && !autoSyncCanRun {
            setSyncProgress(.waitingForNetwork)
            setSyncMessage(autoSyncWaitingMessage, outcome: autoSyncWaitingOutcome)
            return false
        }

        isSyncing = true
        defer { isSyncing = false }

        let hasLocalData = dataSource?.hasLocalData() ?? true
        if !hasLocalData,
           await restoreLatestBackupIfAvailable(showMissingBackupMessage: !isAutomatic) {
            return true
        }

        // A manual sync always exports both lanes unconditionally — the
        // person explicitly asked for a backup, so it should be complete.
        // An automatic/debounced sync only exports the lane(s) that
        // actually have pending changes — this is the whole point of the
        // Data/Preferences split: a settings-only change should never
        // re-upload the Data lane, and vice versa.
        let shouldExportData = !isAutomatic || !pendingItemIDs.isEmpty || !pendingDeletedItemIDs.isEmpty
        let shouldExportPreferences = !isAutomatic || hasPendingPreferencesChange

        do {
            if shouldExportData {
                try await exportDataToICloud()
            }
            if shouldExportPreferences {
                try await exportPreferencesToICloud()
            }
            setSyncMessage(
                isAutomatic ? config.messages.autoSyncedMessage : config.messages.syncedMessage,
                outcome: .success(isAutomatic ? .autoSynced : .synced)
            )
            finishSyncProgress(success: true)
            onSyncSucceeded?(isAutomatic)
            return true
        } catch is CancellationError {
            // Not a failure — the Task this sync was running in was
            // cancelled out from under it, almost always
            // `handleBackgroundSyncTask`'s `expirationHandler` running out
            // of background time. `exportDataToICloud()`'s upload loops now
            // actually check for this between items (see
            // `ICloudDriveSyncWorker`), so a cancelled background sync stops
            // promptly instead of racing the OS to finish regardless.
            // Nothing here is broken, so this deliberately skips the
            // "failed" message/outcome/error-level log a real error gets —
            // just quietly stop and let the normal retry machinery (the
            // next debounce, the next background window, or the person's
            // own next manual sync) pick it back up.
            finishSyncProgress(success: false)
            logEvent("icloud_sync_cancelled", ["automatic": String(isAutomatic)], level: .info)
            scheduleBackgroundSyncIfNeeded()
            return false
        } catch {
            setSyncMessage(error.localizedDescription, outcome: .failure(syncFailure(for: error)))
            finishSyncProgress(success: false)
            logEvent("icloud_sync_failed", [
                "automatic": String(isAutomatic),
                "auto_sync_mode": autoSyncMode.rawValue,
                "error_type": String(describing: type(of: error))
            ], level: .error)
            scheduleBackgroundSyncIfNeeded()
            return false
        }
    }

    private func exportDataToICloud() async throws {
        try Task.checkCancellation()
        guard let dataSource else { throw ICloudDriveSyncError.dataSourceMissing }
        guard let backupURL = backupEnvelopeURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }

        let exportDate = Date()
        let directoryURL = backupURL.deletingLastPathComponent()
        let itemsURL = itemsDirectoryURL(for: backupURL)
        let isFirstSync = lastSyncAt == nil
        let hadItemsDirectory = FileManager.default.fileExists(atPath: itemsURL.path)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: itemsURL, withIntermediateDirectories: true)
        await seedItemByteSizeCacheIfNeeded(itemsURL: itemsURL)

        let isFullExport = isFirstSync || !hadItemsDirectory
        let payload = dataSource.exportData(
            changedItemIDs: isFullExport ? nil : pendingItemIDs,
            deletedItemIDs: pendingDeletedItemIDs
        )

        var itemsToUpload = payload.items
        // Optimistic starting point: our own about-to-upload items at their
        // local time, layered over whatever we already knew. Conflict
        // resolution below corrects any entry that turns out to not
        // actually be getting uploaded this round.
        var mergedModifiedAt = itemModifiedAtCache.merging(payload.modifiedAt) { _, new in new }
        // Cleared from `pendingItemIDs` even though never uploaded — the
        // cloud version was applied locally instead, so there's no local
        // edit left to upload.
        var resolvedByApplyingCloud: Set<String> = []
        var excludedFromUpload: Set<String> = []

        // Conflict detection is skipped entirely under `.localWins` (this
        // device always wins, so there's nothing worth checking) and
        // whenever there's nothing pending to upload (nothing to conflict
        // over).
        if config.conflictPolicy != .localWins, !payload.items.isEmpty {
            let conflictResult = await worker.detectConflicts(
                candidateItemIDs: Set(payload.items.keys),
                localModifiedAt: payload.modifiedAt,
                ourDeviceID: deviceID,
                envelopeURL: backupURL,
                io: ioPrimitives
            )

            if !conflictResult.conflictedItemIDs.isEmpty, let cloudEnvelope = conflictResult.cloudEnvelope {
                switch config.conflictPolicy {
                case .localWins:
                    break
                case .lastWriteWins, .cloudWins:
                    // A conflict is only ever detected when the cloud side is
                    // already the newer one (see `ICloudDriveSyncWorker.detectConflicts`),
                    // so both policies resolve identically here: apply the
                    // cloud version locally and never upload the local edit.
                    let appliedIDs = try await applyCloudVersions(
                        for: conflictResult.conflictedItemIDs,
                        cloudEnvelope: cloudEnvelope,
                        itemsURL: itemsURL
                    )
                    resolvedByApplyingCloud = appliedIDs
                    // Every conflicted id is withheld from this export, not
                    // just the ones that were actually applied — an id whose
                    // cloud download/apply failed still shouldn't have its
                    // local (older-losing) edit clobber the cloud copy; it's
                    // simply retried (both the apply and the conflict check)
                    // on the next sync.
                    excludedFromUpload = conflictResult.conflictedItemIDs
                    if !appliedIDs.isEmpty {
                        logEvent("icloud_conflicts_resolved", [
                            "count": String(appliedIDs.count),
                            "policy": config.conflictPolicy.rawValue
                        ], level: .info)
                    }
                    if appliedIDs.count < conflictResult.conflictedItemIDs.count {
                        logEvent("icloud_conflicts_unresolved", [
                            "count": String(conflictResult.conflictedItemIDs.count - appliedIDs.count)
                        ], level: .warning)
                    }
                case .manual:
                    let recordedIDs = try await recordManualConflicts(
                        for: conflictResult.conflictedItemIDs,
                        cloudEnvelope: cloudEnvelope,
                        localItems: payload.items,
                        localModifiedAt: payload.modifiedAt,
                        itemsURL: itemsURL,
                        detectedAt: exportDate
                    )
                    excludedFromUpload = conflictResult.conflictedItemIDs
                    if !recordedIDs.isEmpty {
                        logEvent("icloud_conflicts_detected", [
                            "count": String(recordedIDs.count)
                        ], level: .warning)
                    }
                }

                // None of `excludedFromUpload` is actually getting uploaded
                // this round, so the cloud's own timestamp — not our local
                // one — is what's genuinely true of the item on iCloud right
                // now. Without this, the envelope we're about to write would
                // falsely claim a very recent local time for an item whose
                // cloud bytes never changed.
                for itemID in excludedFromUpload {
                    if let cloudTime = cloudEnvelope.itemModifiedAt[itemID] {
                        mergedModifiedAt[itemID] = cloudTime
                    }
                }
            }
        }

        for itemID in excludedFromUpload {
            itemsToUpload.removeValue(forKey: itemID)
        }

        try Task.checkCancellation()

        // The actual upload — item deletes, item writes, manifest, envelope,
        // in that order — is `ICloudDriveSyncWorker`'s job now; this method
        // keeps everything that has to happen on `@MainActor` (talking to
        // `dataSource`, the engine's own pending/persisted/conflict state).
        let result = try await worker.uploadData(
            items: itemsToUpload,
            deletedItemIDs: pendingDeletedItemIDs,
            manifest: payload.manifest,
            allItemIDs: dataSource.allDataItemIDs(),
            appName: config.appName,
            exportedAt: exportDate,
            deviceID: deviceID,
            itemModifiedAt: mergedModifiedAt,
            hostSchemaMetadata: dataSource.hostSchemaMetadata(),
            itemsURL: itemsURL,
            manifestURL: manifestURL(for: backupURL),
            envelopeURL: backupURL,
            io: ioPrimitives,
            onProgress: progressReporter
        )

        // `result.exportedItemIDs`, not `pendingItemIDs` — on a full export every
        // item got (re)written regardless of what was actually pending, so
        // this is what a host's own "still needs export" bookkeeping should
        // actually clear. An id left out above because it's an unresolved
        // manual conflict, or a cloud-wins resolution that couldn't be
        // applied locally, stays in `pendingItemIDs` and is retried next
        // sync; `resolvedByApplyingCloud` clears the ones that *were*
        // resolved even though they were never uploaded.
        let exportedIDs = result.exportedItemIDs
        let deletedIDs = pendingDeletedItemIDs
        pendingItemIDs.subtract(exportedIDs)
        pendingItemIDs.subtract(resolvedByApplyingCloud)
        pendingDeletedItemIDs.removeAll()
        persistPendingChanges()
        setLastSyncAt(exportDate)

        // Fold this export's own changes into the byte ledger — every
        // written item's exact size (`result.exportedItemByteSizes`,
        // already computed from the `Data` `uploadData` just wrote, no
        // extra I/O) replaces its old entry, and every deleted id's entry
        // disappears. `envelopeByteSize` mirrors what `uploadData` just
        // wrote; `manifestByteSize` comes straight from `payload.manifest`,
        // already in hand here too.
        for (url, size) in result.exportedItemByteSizes {
            itemByteSizeCache[url] = size
        }
        for deletedItemID in deletedIDs {
            itemByteSizeCache.removeValue(forKey: ICloudDriveFileIO.itemURL(for: deletedItemID, in: itemsURL))
        }
        persistItemByteSizeCache()
        setEnvelopeByteSize(result.envelopeByteCount)
        setManifestByteSize(Int64(payload.manifest.count))
        let newByteCount = recomputedBackupByteCount()
        setBackupByteCount(newByteCount)
        updateLargeBackupWarningState(forByteCount: newByteCount)

        itemModifiedAtCache = mergedModifiedAt
        persistItemModifiedAt()
        onDataExportSucceeded?(exportedIDs, deletedIDs)
    }

    /// Applies the cloud copy of each conflicted item locally (via
    /// `applyRestoredItemsHandler`) and reports which ids were actually
    /// applied. Used by `exportDataToICloud()` for `.lastWriteWins`/
    /// `.cloudWins` (where the cloud version always wins a detected
    /// conflict), and by `resolveConflict(_:keep: .keepCloud)` for a single
    /// `.manual` conflict. An id that fails to download, or that
    /// `applyRestoredItemsHandler` throws on, is simply left out of the
    /// result — its local edit stays pending rather than being silently
    /// lost, and it's retried on the next sync.
    private func applyCloudVersions(
        for itemIDs: Set<String>,
        cloudEnvelope: BackupEnvelope,
        itemsURL: URL
    ) async throws -> Set<String> {
        guard let applyRestoredItemsHandler else {
            logEvent("icloud_conflict_apply_cloud_missing_handler", [
                "count": String(itemIDs.count)
            ], level: .error)
            return []
        }
        guard !itemIDs.isEmpty else { return [] }

        let raw = try await worker.readBackupItems(
            requestedItemIDs: itemIDs,
            envelopeItemIDs: cloudEnvelope.itemIDs,
            itemsURL: itemsURL,
            io: ioPrimitives,
            onProgress: { _, _, _, _ in }
        )
        guard !raw.items.isEmpty else { return [] }

        do {
            try applyRestoredItemsHandler(raw.items)
            return Set(raw.items.keys)
        } catch {
            logEvent("icloud_conflict_apply_cloud_failed", [
                "count": String(raw.items.count),
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return []
        }
    }

    /// Downloads the cloud version of each `.manual`-policy conflicted item
    /// and turns it into an `ICloudDriveSyncConflict` (both versions' raw
    /// bytes), appended to `pendingConflicts` — replacing any existing
    /// entry for the same item id, so a repeat export attempt before the
    /// host resolves it doesn't pile up duplicates. Returns the ids that
    /// were successfully turned into a conflict; an id that fails to
    /// download the cloud side (or is missing a local counterpart) is left
    /// out entirely and simply retried as a normal upload attempt next
    /// sync.
    private func recordManualConflicts(
        for itemIDs: Set<String>,
        cloudEnvelope: BackupEnvelope,
        localItems: [String: Data],
        localModifiedAt: [String: Date],
        itemsURL: URL,
        detectedAt: Date
    ) async throws -> Set<String> {
        guard !itemIDs.isEmpty else { return [] }

        let raw = try await worker.readBackupItems(
            requestedItemIDs: itemIDs,
            envelopeItemIDs: cloudEnvelope.itemIDs,
            itemsURL: itemsURL,
            io: ioPrimitives,
            onProgress: { _, _, _, _ in }
        )

        var recordedIDs: Set<String> = []
        for itemID in itemIDs {
            guard let cloudData = raw.items[itemID],
                  let cloudModifiedAt = cloudEnvelope.itemModifiedAt[itemID],
                  let localData = localItems[itemID],
                  let localModifiedAtValue = localModifiedAt[itemID] else { continue }

            let conflict = ICloudDriveSyncConflict(
                itemID: itemID,
                displayName: itemDisplayNameResolver?(itemID),
                localData: localData,
                localModifiedAt: localModifiedAtValue,
                cloudData: cloudData,
                cloudModifiedAt: cloudModifiedAt,
                detectedAt: detectedAt
            )
            pendingConflicts.removeAll { $0.itemID == itemID }
            pendingConflicts.append(conflict)
            recordedIDs.insert(itemID)
        }
        return recordedIDs
    }

    /// Resolves one `.manual`-policy conflict from `pendingConflicts` —
    /// call after showing the host's own "keep mine / keep theirs" UI for
    /// it. Removes the conflict from `pendingConflicts` either way, so it's
    /// safe to call exactly once per user decision.
    public func resolveConflict(_ conflict: ICloudDriveSyncConflict, keep resolution: ICloudDriveSyncConflictResolution) async {
        pendingConflicts.removeAll { $0.itemID == conflict.itemID }

        switch resolution {
        case .keepLocal:
            // Re-marks the item as locally pending so the next sync uploads
            // it normally, overwriting the cloud copy.
            pendingItemIDs.insert(conflict.itemID)
            persistPendingChanges()
            logEvent("icloud_conflict_resolved", ["item_id": conflict.itemID, "kept": "local"], level: .info)
        case .keepCloud:
            guard let applyRestoredItemsHandler else {
                logEvent("icloud_conflict_resolve_missing_handler", ["item_id": conflict.itemID], level: .error)
                return
            }
            do {
                try applyRestoredItemsHandler([conflict.itemID: conflict.cloudData])
                pendingItemIDs.remove(conflict.itemID)
                persistPendingChanges()
                itemModifiedAtCache[conflict.itemID] = conflict.cloudModifiedAt
                persistItemModifiedAt()
                logEvent("icloud_conflict_resolved", ["item_id": conflict.itemID, "kept": "cloud"], level: .info)
            } catch {
                logEvent("icloud_conflict_resolve_failed", [
                    "item_id": conflict.itemID,
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
    }

    /// Exports the Preferences lane — always a single whole-file rewrite,
    /// never partitioned, and entirely independent of the Data lane above:
    /// a Data-only sync never touches this file, and this never touches a
    /// single Data item file.
    private func exportPreferencesToICloud() async throws {
        guard let dataSource else { throw ICloudDriveSyncError.dataSourceMissing }
        guard let backupURL = backupEnvelopeURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }

        let directoryURL = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let preferencesData = dataSource.exportPreferences()
        try await worker.uploadPreferences(
            preferencesData,
            preferencesURL: preferencesURL(for: backupURL),
            io: ioPrimitives,
            onProgress: progressReporter
        )

        hasPendingPreferencesChange = false
        persistPendingChanges()
        setLastSyncAt(Date())
        // Preferences' own size is already known from the `Data` just
        // written — no need for a fresh total the old way (a full walk of
        // the whole backup folder) just to report this one file changed.
        // Unlike the old walk, this also no longer depends on the envelope
        // file already existing — a Preferences-only sync before Data's own
        // first export now still updates `backupByteCount` correctly.
        setPreferencesByteSize(Int64(preferencesData.count))
        let newByteCount = recomputedBackupByteCount()
        setBackupByteCount(newByteCount)
        updateLargeBackupWarningState(forByteCount: newByteCount)
        onPreferencesExportSucceeded?()
    }

    private func restoreLatestBackupIfAvailable(showMissingBackupMessage: Bool) async -> Bool {
        guard let dataSource else {
            setSyncMessage(ICloudDriveSyncError.dataSourceMissing.localizedDescription, outcome: .failure(.dataSourceMissing))
            finishSyncProgress(success: false)
            return false
        }

        do {
            guard let result = try await readBackup() else {
                if shouldSuggestWiFiForRestore {
                    showCellularRestoreWarning()
                } else if showMissingBackupMessage {
                    setSyncMessage(config.messages.noBackupFoundYet, outcome: .failure(.noBackupFound))
                }
                finishSyncProgress(success: false)
                return false
            }

            setSyncProgress(.applyingRestore, completed: result.report.restoredItemCount, total: result.report.expectedItemCount)
            try dataSource.validateRestoredHostSchemaMetadata(result.envelope.hostSchemaMetadata)
            try dataSource.applyRestoredData(manifest: result.manifest, items: result.items)
            // Best-effort and independent of the Data restore above — a
            // Preferences hiccup (or a backup made before this app adopted
            // the Preferences lane at all) should never fail, or even
            // affect, the Data restore that just succeeded.
            await restorePreferencesIfAvailable()
            setLastSyncAt(result.envelope.exportedAt)
            // Every restored item's size is already known from the `Data`
            // just downloaded — rebuild the ledger wholesale from
            // `result.items` (a restore, unlike a normal export, always
            // downloads a complete, authoritative item set) rather than
            // trying to preserve whatever the ledger had before, which
            // could easily be stale relative to what the cloud just proved
            // is actually there. This also makes a restore just as good a
            // seed for the ledger as `refreshBackupStatus()`'s own walk, so
            // it's marked seeded here too.
            if let backupURL = backupEnvelopeURL() {
                let itemsURL = itemsDirectoryURL(for: backupURL)
                itemByteSizeCache = Dictionary(uniqueKeysWithValues: result.items.map { itemID, data in
                    (ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL), Int64(data.count))
                })
                persistItemByteSizeCache()
                markItemByteSizeCacheSeeded()
            }
            setManifestByteSize(Int64(result.manifest.count))
            setEnvelopeByteSize(result.envelopeByteCount)
            setBackupByteCount(recomputedBackupByteCount())
            pendingItemIDs.removeAll()
            pendingDeletedItemIDs.removeAll()
            hasPendingPreferencesChange = false
            persistPendingChanges()
            // The restored envelope is now this device's known-good view of
            // every item's cloud modification time — replace the cache
            // wholesale (not merge) so a stale entry from before this
            // restore can never linger and cause a false conflict later.
            itemModifiedAtCache = result.envelope.itemModifiedAt
            persistItemModifiedAt()
            shouldRetryRestoreOnWiFi = false
            lastRestoredHostSchemaMetadata = result.envelope.hostSchemaMetadata
            lastRestoreReport = result.report
            if result.report.hasIssues {
                let summary = restoreSummaryMessage(for: result.report)
                setSyncMessage(summary, outcome: .success(.restoredWithIssues))
                restoreWarningMessage = summary
            } else {
                setSyncMessage(config.messages.restoredMessage, outcome: .success(.restored))
            }
            finishSyncProgress(success: true)
            clearUnrestoredBackup()
            logEvent("icloud_restore_completed", [
                "expected_count": String(result.report.expectedItemCount),
                "restored_count": String(result.report.restoredItemCount),
                "missing_count": String(result.report.missingItems.count),
                "failed_count": String(result.report.failedItems.count)
            ], level: .info)
            onRestoreSucceeded?()
            return true
        } catch is CancellationError {
            // Not a failure — deliberately skips `markUnrestoredBackup()`
            // (which also flips `autoSyncMode = .off`, a sticky side effect
            // that should only ever follow a genuine restore failure) and
            // the "please retry" alert. A cancelled restore just tries
            // again next time exactly as if it had never started.
            finishSyncProgress(success: false)
            logEvent("icloud_restore_cancelled", [:], level: .info)
            return false
        } catch {
            let message = error.localizedDescription
            let backupExists = backupAppearsAvailable
            if backupExists {
                markUnrestoredBackup()
            }
            if shouldSuggestWiFiForRestore {
                showCellularRestoreWarning()
            } else {
                setSyncMessage(message, outcome: .failure(.restoreFailed))
                // A backup genuinely exists but couldn't be restored (and it
                // wasn't just "needs Wi-Fi," handled above) — surface this as
                // an actual alert, not just the overlay's transient message,
                // so it's never silently swallowed when the overlay closes.
                if backupExists {
                    restoreWarningMessage = config.messages.restoreFailedPleaseRetry
                }
            }
            logEvent("icloud_restore_failed", ["error_type": String(describing: type(of: error))], level: .error)
            finishSyncProgress(success: false)
            return false
        }
    }

    private struct RestoreResult {
        let envelope: BackupEnvelope
        let manifest: Data
        let items: [String: Data]
        let report: ICloudDriveRestoreReport
        let envelopeByteCount: Int64
    }

    private struct RestoreItemsResult {
        let items: [String: Data]
        let report: ICloudDriveRestoreReport
    }

    private func readBackup() async throws -> RestoreResult? {
        guard let backupURL = backupEnvelopeURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }
        return try await readBackup(backupURL: backupURL)
    }

    private func readBackup(backupURL: URL) async throws -> RestoreResult? {
        // `ICloudDriveSyncWorker.readBackup` returns `nil` itself if there's
        // no envelope file yet — same "no backup found" signal this method
        // always gave, just resolved a layer down now.
        guard let raw = try await worker.readBackup(
            backupURL: backupURL,
            manifestURL: manifestURL(for: backupURL),
            itemsURL: itemsDirectoryURL(for: backupURL),
            io: ioPrimitives,
            onProgress: progressReporter
        ) else {
            return nil
        }

        return RestoreResult(
            envelope: raw.envelope,
            manifest: raw.manifest,
            items: raw.items,
            report: resolvedReport(from: raw.report),
            envelopeByteCount: raw.envelopeByteCount
        )
    }

    private func readBackupItems(_ requestedItemIDs: Set<String>, backupURL: URL) async throws -> RestoreItemsResult {
        let envelopeData = try await downloadAndRead(at: backupURL)
        let envelope = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData)
        let raw = try await worker.readBackupItems(
            requestedItemIDs: requestedItemIDs,
            envelopeItemIDs: envelope.itemIDs,
            itemsURL: itemsDirectoryURL(for: backupURL),
            io: ioPrimitives,
            onProgress: progressReporter
        )
        return RestoreItemsResult(items: raw.items, report: resolvedReport(from: raw.report))
    }

    /// Resolves `itemDisplayNameResolver` for every issue
    /// `ICloudDriveSyncWorker` reported — always on `@MainActor`, exactly as
    /// this resolution always happened back when the loop that produced
    /// these issues lived directly in this class. `ICloudDriveSyncWorker`
    /// itself never calls a host-supplied closure — see its
    /// `RawRestoreItemIssue` doc comment for why.
    private func resolvedReport(from raw: ICloudDriveSyncWorker.RawRestoreReport) -> ICloudDriveRestoreReport {
        ICloudDriveRestoreReport(
            expectedItemCount: raw.expectedItemCount,
            restoredItemCount: raw.restoredItemCount,
            missingItems: raw.missingItems.map(resolvedIssue),
            failedItems: raw.failedItems.map(resolvedIssue)
        )
    }

    private func resolvedIssue(_ raw: ICloudDriveSyncWorker.RawRestoreItemIssue) -> ICloudDriveRestoreItemIssue {
        ICloudDriveRestoreItemIssue(
            itemID: raw.itemID,
            displayName: itemDisplayNameResolver?(raw.itemID),
            reason: raw.reason,
            errorDescription: raw.errorDescription
        )
    }

    /// `config.messages.partialRestoreWarning` used to sit unused — this
    /// method built its own hardcoded, non-localizable English sentences
    /// instead, so a host that set a custom (or translated)
    /// `partialRestoreWarning` never actually saw it. Fixed to use it as
    /// the lead-in, same `...Prefix`-style pattern the image-size and
    /// download-failure error messages already use elsewhere in this file
    /// (see `ICloudDriveSyncError`) — the engine appends only the
    /// genuinely dynamic part (the counts) as a parenthetical.
    private func restoreSummaryMessage(for report: ICloudDriveRestoreReport) -> String {
        guard report.hasIssues else { return config.messages.restoredMessage }
        let missingCount = report.missingItems.count
        let failedCount = report.failedItems.count
        let detail: String
        if missingCount > 0, failedCount > 0 {
            detail = "\(missingCount) missing, \(failedCount) failed"
        } else if missingCount > 0 {
            detail = "\(missingCount) missing"
        } else {
            detail = "\(failedCount) failed"
        }
        return "\(config.messages.partialRestoreWarning) (\(detail))"
    }

    private func mergeLastRestoreReport(
        retryReport: ICloudDriveRestoreReport,
        restoredItemIDs: Set<String>
    ) -> ICloudDriveRestoreReport {
        guard let lastRestoreReport else { return retryReport }
        let retryIssueIDs = retryReport.retryableItemIDs.union(restoredItemIDs)
        let missingItems = lastRestoreReport.missingItems
            .filter { !retryIssueIDs.contains($0.itemID) }
            + retryReport.missingItems
        let failedItems = lastRestoreReport.failedItems
            .filter { !retryIssueIDs.contains($0.itemID) }
            + retryReport.failedItems
        let restoredItemCount = min(
            lastRestoreReport.expectedItemCount,
            lastRestoreReport.restoredItemCount + restoredItemIDs.count
        )

        return ICloudDriveRestoreReport(
            expectedItemCount: lastRestoreReport.expectedItemCount,
            restoredItemCount: restoredItemCount,
            missingItems: missingItems,
            failedItems: failedItems
        )
    }

    /// Best-effort Preferences restore: does nothing (no throw, no message)
    /// if there's no preferences file in this backup yet, and swallows a
    /// download/apply failure rather than propagating it — the Data restore
    /// this is called alongside is the one that matters for whether the
    /// overall restore "succeeded."
    private func restorePreferencesIfAvailable(backupURL explicitBackupURL: URL? = nil) async {
        guard let dataSource, let backupURL = explicitBackupURL ?? backupEnvelopeURL() else { return }
        let url = preferencesURL(for: backupURL)
        let completed = syncProgress.completedUnitCount
        let total = syncProgress.totalUnitCount
        setSyncProgress(.downloadingPreferences, completed: completed, total: total)
        guard let data = try? await worker.readPreferencesIfAvailable(
            preferencesURL: url,
            completedOffset: completed,
            totalUnitCount: total,
            io: ioPrimitives,
            onProgress: progressReporter
        ) else { return }
        setSyncProgress(.applyingRestore, completed: completed, total: total)
        try? dataSource.applyRestoredPreferences(data)
    }

    private func downloadAndRead(at url: URL) async throws -> Data {
        do {
            return try await ICloudDriveFileIO.downloadAndRead(
                at: url,
                attemptLimit: downloadAttemptLimit,
                pollInterval: config.pollIntervalSeconds,
                // `ICloudDriveFileIO.downloadAndRead` is a plain (non-actor)
                // static function — after each `Task.sleep` suspension inside
                // its polling loop, it can resume on any thread from the
                // concurrency pool, not necessarily the main thread. Calling
                // this closure directly there would mutate `syncMessage` (a
                // `@Published` property) off the main thread, which Combine
                // rejects at runtime ("Publishing changes from background
                // threads is not allowed"). Hop back to the main actor
                // explicitly, same as `networkMonitor.onUpdate` does below.
                onWaitingTick: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.shouldShowWaitingProgressTick {
                            self.setSyncProgress(.waitingForNetwork)
                            self.setSyncMessage(self.cellularWaitingMessage, outcome: self.cellularWaitingOutcome)
                        }
                    }
                }
            )
        } catch ICloudDriveSyncError.downloadTimedOut(let detail) {
            if shouldSuggestWiFiForRestore {
                throw ICloudDriveSyncError.cellularUnavailable
            }
            throw ICloudDriveSyncError.downloadTimedOut(detail)
        }
    }

    /// `ICloudDriveSyncWorker`'s four I/O primitives, wired fresh on every
    /// access to this engine instance's own connectivity-aware policy —
    /// `download` in particular routes through `downloadAndRead(at:)` above,
    /// not a raw `ICloudDriveFileIO` call, so cellular/Wi-Fi attempt limits
    /// and timeout-to-`.cellularUnavailable` translation keep working
    /// exactly as before. `delete` intentionally stays a plain
    /// (uncoordinated) `FileManager.removeItem` — matching exactly what the
    /// old inline per-item-delete loop did — rather than routing through
    /// `ICloudDriveFileIO.coordinatedDeleteItem` (used elsewhere for
    /// removing the *whole* backup folder, a heavier, less frequent
    /// operation where coordination matters more).
    private var ioPrimitives: ICloudDriveSyncWorker.IOPrimitives {
        if let injectedIOPrimitives {
            return injectedIOPrimitives
        }
        return ICloudDriveSyncWorker.IOPrimitives(
            write: { data, url in try await ICloudDriveFileIO.coordinatedWriteData(data, to: url) },
            download: { url in try await self.downloadAndRead(at: url) },
            delete: { url in
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            },
            byteCount: { url in try await ICloudDriveFileIO.byteCount(at: url) }
        )
    }

    /// `ICloudDriveSyncWorker`'s progress callback, wired to this engine
    /// instance's own `@Published var syncProgress` via `setSyncProgress`.
    /// The engine owns this closure from the main actor, so progress updates
    /// stay on the same actor as the rest of the published state.
    private var progressReporter: (ICloudDriveSyncProgressPhase, Int, Int?, String?) async -> Void {
        { phase, completed, total, itemID in
            self.setSyncProgress(phase, completed: completed, total: total, currentItemID: itemID)
        }
    }

    // MARK: URLs

    private func backupEnvelopeURL() -> URL? {
        backupEnvelopeURLProvider()
    }

    private func manifestURL(for backupURL: URL) -> URL {
        backupURL.deletingLastPathComponent().appendingPathComponent(config.manifestFileName)
    }

    private func preferencesURL(for backupURL: URL) -> URL {
        backupURL.deletingLastPathComponent().appendingPathComponent(config.preferencesFileName)
    }

    private func itemsDirectoryURL(for backupURL: URL) -> URL {
        backupURL.deletingLastPathComponent().appendingPathComponent(config.itemsDirectoryName, isDirectory: true)
    }

    private func snapshotsDirectoryURL(currentBackupURL: URL) -> URL {
        currentBackupURL
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    private func snapshotEnvelopeURL(id backupID: String, currentBackupURL: URL) -> URL {
        snapshotsDirectoryURL(currentBackupURL: currentBackupURL)
            .appendingPathComponent(backupID, isDirectory: true)
            .appendingPathComponent(config.backupFileName)
    }

    private func isValidSnapshotID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func snapshotDescriptor(
        id backupID: String,
        directoryCreatedAt: Date?,
        envelope: BackupEnvelope,
        byteCount: Int64?
    ) -> ICloudDriveBackupDescriptor {
        ICloudDriveBackupDescriptor(
            id: backupID,
            label: envelope.label,
            createdAt: directoryCreatedAt ?? envelope.exportedAt,
            exportedAt: envelope.exportedAt,
            appName: envelope.appName,
            appVersion: envelope.hostSchemaMetadata?.appVersion,
            appBuild: envelope.hostSchemaMetadata?.appBuild,
            hostSchemaMetadata: envelope.hostSchemaMetadata,
            itemCount: envelope.itemIDs.count,
            byteCount: byteCount,
            deviceID: envelope.deviceID
        )
    }

    // MARK: Derived state

    private var autoSyncCanRun: Bool {
        guard !hasUnrestoredBackup else { return false }
        switch autoSyncMode {
        case .always:
            return isNetworkConnected
        case .wifi:
            #if os(iOS)
            return isWiFiConnected
            #else
            return isNetworkConnected
            #endif
        case .off:
            return false
        }
    }

    private var autoSyncWaitingMessage: String {
        switch autoSyncMode {
        case .always:
            return config.messages.waitingForNetwork
        case .wifi:
            #if os(iOS)
            return config.messages.waitingForWiFi
            #else
            return config.messages.waitingForNetwork
            #endif
        case .off:
            return config.messages.autoSyncOffMessage
        }
    }

    private var autoSyncWaitingOutcome: ICloudDriveSyncOutcome {
        switch autoSyncMode {
        case .always:
            return .warning(.waitingForNetwork)
        case .wifi:
            #if os(iOS)
            return .warning(.waitingForWiFi)
            #else
            return .warning(.waitingForNetwork)
            #endif
        case .off:
            return .warning(.autoSyncOff)
        }
    }

    private var backupAppearsAvailable: Bool {
        guard let backupURL = backupEnvelopeURL() else { return false }
        return FileManager.default.fileExists(atPath: backupURL.path)
    }

    private var shouldSuggestWiFiForRestore: Bool {
        #if os(iOS)
        !isWiFiConnected && (isNetworkConnected || isCellularConnected || !hasResolvedNetworkPath)
        #else
        false
        #endif
    }

    private var downloadAttemptLimit: Int {
        shouldSuggestWiFiForRestore ? config.downloadAttemptLimitCellular : config.downloadAttemptLimitWiFi
    }

    private var initialRestoreCheckAttemptLimit: Int {
        shouldSuggestWiFiForRestore ? config.initialRestoreCheckAttemptLimitCellular : config.initialRestoreCheckAttemptLimitWiFi
    }

    private var cellularWaitingMessage: String {
        if shouldSuggestWiFiForRestore {
            return isLowDataModeEnabled ? config.messages.waitingCellularLowDataMessage : config.messages.waitingCellularMessage
        }
        return config.messages.downloadingBackup
    }

    private var cellularWaitingOutcome: ICloudDriveSyncOutcome {
        shouldSuggestWiFiForRestore ? .warning(.cellularUnavailable) : .warning(.downloadingBackup)
    }

    #if os(iOS)
    private func scheduleBackgroundSyncIfNeeded() {
        scheduleBackgroundSync()
    }

    private func handleBackgroundSyncTask(_ task: BGTask) async {
        scheduleBackgroundSyncIfNeeded()

        let syncTask = Task { @MainActor in
            await runBackgroundSync()
        }
        task.expirationHandler = {
            syncTask.cancel()
        }

        let didComplete = await syncTask.value
        task.setTaskCompleted(success: didComplete)
    }

    private func runBackgroundSync() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard autoSyncMode != .off else { return true }
        guard hasPendingChanges else { return true }
        guard !isSyncing, !isInitialRestoreBlocking else {
            scheduleBackgroundSyncIfNeeded()
            return false
        }
        guard autoSyncCanRun else {
            scheduleBackgroundSyncIfNeeded()
            return false
        }

        let didSync = await syncToICloud(isAutomatic: true)
        if hasPendingChanges {
            scheduleBackgroundSyncIfNeeded()
        }
        return didSync
    }
    #else
    private func scheduleBackgroundSyncIfNeeded() {}
    #endif

    private var shouldShowWaitingProgressTick: Bool {
        switch syncProgress.phase {
        case .idle, .checkingBackup, .waitingForNetwork, .downloadingEnvelope:
            return true
        case .downloadingManifest,
             .downloadingItems,
             .downloadingPreferences,
             .applyingRestore,
             .uploadingItems,
             .uploadingManifest,
             .uploadingPreferences,
             .uploadingEnvelope,
             .deletingBackup,
             .refreshingStatus,
             .finished,
             .failed:
            return false
        }
    }

    private func showCellularRestoreWarning() {
        shouldRetryRestoreOnWiFi = true
        let message = ICloudDriveSyncError.cellularUnavailable.localizedDescription
        setSyncMessage(message, outcome: .warning(.cellularUnavailable))
        restoreWarningMessage = message
    }

    private func syncFailure(for error: Error) -> ICloudDriveSyncFailure {
        guard let syncError = error as? ICloudDriveSyncError else { return .syncFailed }
        switch syncError {
        case .iCloudUnavailable:
            return .iCloudUnavailable
        case .dataSourceMissing:
            return .dataSourceMissing
        case .downloadFailed, .downloadTimedOut, .readFailed, .cellularUnavailable:
            return .syncFailed
        default:
            return .syncFailed
        }
    }

    private func updateLargeBackupWarningState(forByteCount byteCount: Int64) {
        if byteCount <= config.largeBackupThresholdBytes {
            setLargeBackupWarningShown(false)
            return
        }
        guard autoSyncMode == .always, !largeBackupWarningShownFlag else { return }
        setLargeBackupWarningShown(true)
        showLargeBackupWarning = true
    }

    // MARK: Persisted (UserDefaults-backed) state

    private func setBackupByteCount(_ value: Int64) {
        backupByteCount = value
        defaults.set(value, forKey: config.userDefaultsKeyPrefix + "backupByteCount")
    }

    private func setLastSyncAt(_ value: Date?) {
        lastSyncAt = value
        defaults.set(value, forKey: config.userDefaultsKeyPrefix + "lastSyncAt")
    }

    private func persistAutoSyncMode() {
        defaults.set(autoSyncMode.rawValue, forKey: config.userDefaultsKeyPrefix + "autoSyncMode")
    }

    private static func readAutoSyncMode(defaults: UserDefaults, key: String) -> ICloudAutoSyncMode? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return ICloudAutoSyncMode(rawValue: raw)
    }

    /// Reads the persisted per-install device id, if one was already
    /// generated. `nil` means this is the first launch (or a reinstall —
    /// `UserDefaults.standard` doesn't survive an uninstall, so a reinstall
    /// intentionally gets a fresh device id, same as a brand-new device).
    private static func readDeviceID(defaults: UserDefaults, key: String) -> String? {
        defaults.string(forKey: key)
    }

    /// Reads the locally cached per-item modification times used by
    /// conflict detection. Stored as JSON `Data` (not a native UserDefaults
    /// dictionary type) because `Date` values need consistent encoding;
    /// missing/corrupt data decodes to an empty cache rather than throwing —
    /// worst case, every item looks "never locally tracked" and the next
    /// export/restore repopulates it.
    private static func readItemModifiedAt(defaults: UserDefaults, key: String) -> [String: Date] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private var itemModifiedAtKey: String { config.userDefaultsKeyPrefix + "itemModifiedAt" }

    private func persistItemModifiedAt() {
        guard let data = try? JSONEncoder().encode(itemModifiedAtCache) else { return }
        defaults.set(data, forKey: itemModifiedAtKey)
    }

    private func clearPersistedItemModifiedAt() {
        defaults.removeObject(forKey: itemModifiedAtKey)
    }

    /// Reads the persisted per-item byte-size ledger (see
    /// `itemByteSizeCache`'s own doc comment). Stored as `[String: Int64]`
    /// — `URL.absoluteString`, not `URL` itself — purely so this round-trips
    /// through `JSONEncoder`/`JSONDecoder` as an ordinary JSON object; a
    /// dictionary keyed by something other than `String`/`Int` encodes as a
    /// flat array of alternating keys and values instead, which would work
    /// too but isn't worth the extra indirection here. Missing/corrupt data
    /// decodes to an empty ledger rather than throwing — worst case,
    /// `backupByteCount` under-reports until the next export/restore/refresh
    /// repopulates it, the same graceful degradation `readItemModifiedAt`
    /// above already uses for conflict data.
    private static func readItemByteSizeCache(defaults: UserDefaults, key: String) -> [URL: Int64] {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { entry in
            URL(string: entry.key).map { ($0, entry.value) }
        })
    }

    private var itemByteSizeCacheKey: String { config.userDefaultsKeyPrefix + "itemByteSizeCache" }

    private func persistItemByteSizeCache() {
        let raw = Dictionary(uniqueKeysWithValues: itemByteSizeCache.map { ($0.key.absoluteString, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: itemByteSizeCacheKey)
    }

    private func clearPersistedItemByteSizeCache() {
        defaults.removeObject(forKey: itemByteSizeCacheKey)
    }

    private func setEnvelopeByteSize(_ value: Int64) {
        envelopeByteSize = value
        defaults.set(value, forKey: config.userDefaultsKeyPrefix + "envelopeByteSize")
    }

    private func setManifestByteSize(_ value: Int64) {
        manifestByteSize = value
        defaults.set(value, forKey: config.userDefaultsKeyPrefix + "manifestByteSize")
    }

    private func setPreferencesByteSize(_ value: Int64) {
        preferencesByteSize = value
        defaults.set(value, forKey: config.userDefaultsKeyPrefix + "preferencesByteSize")
    }

    private func setUntrackedByteSize(_ value: Int64) {
        untrackedByteSize = value
        defaults.set(value, forKey: config.userDefaultsKeyPrefix + "untrackedByteSize")
    }

    /// The tracked (Data lane + Preferences + envelope/manifest) portion of
    /// `backupByteCount` — everything this engine can compute from `Data`
    /// already in hand, with no disk read. Excludes `untrackedByteSize`
    /// deliberately, so `refreshBackupStatus()` can compute *that* as
    /// "real total minus this" without a circular dependency on itself.
    private func trackedContentByteCount() -> Int64 {
        itemByteSizeCache.values.reduce(0, +) + envelopeByteSize + manifestByteSize + preferencesByteSize
    }

    /// `backupByteCount`'s value recomputed from its cheap, already-in-memory
    /// components — an in-memory sum, never a disk read. Call after updating
    /// any component, then hand the result to `setBackupByteCount(_:)`.
    private func recomputedBackupByteCount() -> Int64 {
        trackedContentByteCount() + untrackedByteSize
    }

    /// One-time local directory walk that seeds `itemByteSizeCache` from
    /// whatever's already really on disk — needed for an install upgrading
    /// from a kit version that predates this ledger, whose next export
    /// might well be a small incremental one (only a handful of
    /// `pendingItemIDs`) that would otherwise leave every pre-existing
    /// item's bytes permanently invisible to the ledger. A brand-new
    /// install's first export is always a full export anyway (see
    /// `isFullExport` in `exportDataToICloud()`), so its own `items` dict
    /// already covers everything and this walk simply finds nothing to add.
    ///
    /// Gated by `hasSeededItemByteSizeCacheFlag` so it only ever runs once
    /// per install (`refreshBackupStatus()`'s own, more thorough reseed also
    /// sets that flag, so a host that calls it early — e.g. at launch —
    /// makes this a cheap no-op forever after). Best-effort (`try?`): a
    /// failure here just leaves the flag unset and this retries on the next
    /// export, never blocks the export itself.
    private func seedItemByteSizeCacheIfNeeded(itemsURL: URL) async {
        guard !hasSeededItemByteSizeCacheFlag else { return }
        guard let sizes = try? await ICloudDriveFileIO.fileSizes(under: itemsURL) else { return }
        for (url, size) in sizes where itemByteSizeCache[url] == nil {
            itemByteSizeCache[url] = size
        }
        persistItemByteSizeCache()
        markItemByteSizeCacheSeeded()
    }

    private var pendingItemIDsKey: String { config.userDefaultsKeyPrefix + "pendingItemIDs" }
    private var pendingDeletedItemIDsKey: String { config.userDefaultsKeyPrefix + "pendingDeletedItemIDs" }
    private var pendingPreferencesChangeKey: String { config.userDefaultsKeyPrefix + "pendingPreferencesChange" }

    private func restorePendingChanges() {
        pendingItemIDs = Set(defaults.stringArray(forKey: pendingItemIDsKey) ?? [])
        pendingDeletedItemIDs = Set(defaults.stringArray(forKey: pendingDeletedItemIDsKey) ?? [])
        hasPendingPreferencesChange = defaults.bool(forKey: pendingPreferencesChangeKey)

        for id in pendingDeletedItemIDs {
            pendingItemIDs.remove(id)
        }
    }

    private func persistPendingChanges() {
        if pendingItemIDs.isEmpty {
            defaults.removeObject(forKey: pendingItemIDsKey)
        } else {
            defaults.set(Array(pendingItemIDs).sorted(), forKey: pendingItemIDsKey)
        }

        if pendingDeletedItemIDs.isEmpty {
            defaults.removeObject(forKey: pendingDeletedItemIDsKey)
        } else {
            defaults.set(Array(pendingDeletedItemIDs).sorted(), forKey: pendingDeletedItemIDsKey)
        }

        if hasPendingPreferencesChange {
            defaults.set(true, forKey: pendingPreferencesChangeKey)
        } else {
            defaults.removeObject(forKey: pendingPreferencesChangeKey)
        }
    }

    private var largeBackupWarningShownFlag: Bool {
        get { defaults.bool(forKey: config.userDefaultsKeyPrefix + "largeBackupWarningShown") }
    }

    private func setLargeBackupWarningShown(_ value: Bool) {
        defaults.set(value, forKey: config.userDefaultsKeyPrefix + "largeBackupWarningShown")
    }

    /// Whether `itemByteSizeCache` has ever been seeded from a real
    /// directory listing — either by `seedItemByteSizeCacheIfNeeded(itemsURL:)`'s
    /// lightweight one-time walk, or by `refreshBackupStatus()`'s own
    /// (more thorough, always-current) reseed. Once true, neither ever
    /// walks the `Items/` directory again just to fill this in.
    private var hasSeededItemByteSizeCacheFlag: Bool {
        defaults.bool(forKey: config.userDefaultsKeyPrefix + "hasSeededItemByteSizeCache")
    }

    private func markItemByteSizeCacheSeeded() {
        defaults.set(true, forKey: config.userDefaultsKeyPrefix + "hasSeededItemByteSizeCache")
    }

    private var pendingRestoreFlag: Bool {
        defaults.bool(forKey: config.userDefaultsKeyPrefix + "pendingRestore")
    }

    private func markPendingRestore() {
        defaults.set(true, forKey: config.userDefaultsKeyPrefix + "pendingRestore")
    }

    private func clearPendingRestore() {
        defaults.removeObject(forKey: config.userDefaultsKeyPrefix + "pendingRestore")
    }

    private func markUnrestoredBackup() {
        hasUnrestoredBackup = true
        autoSyncMode = .off
        persistAutoSyncMode()
        defaults.set(true, forKey: config.userDefaultsKeyPrefix + "unrestoredBackup")
    }

    private func clearUnrestoredBackup() {
        hasUnrestoredBackup = false
        defaults.removeObject(forKey: config.userDefaultsKeyPrefix + "unrestoredBackup")
    }
}

// `BackupEnvelope` and the package's `JSONEncoder`/`JSONDecoder.icloudDriveSync`
// helpers now live in `ICloudDriveSyncWorker.swift` — both this class and
// `ICloudDriveSyncWorker` need them (this file still decodes an envelope
// directly in the `readBackupItems(_:backupURL:)` retry path above), so
// they moved to the file that's actually the more natural home for them.
