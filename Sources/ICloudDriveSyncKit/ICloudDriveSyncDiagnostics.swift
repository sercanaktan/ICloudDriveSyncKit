import Foundation

/// One recorded lifecycle event — the same information
/// `ICloudDriveSyncEngine.onEvent` forwards to a host's own analytics, kept
/// here too in a small in-memory history (`ICloudDriveSyncEngine.recentEvents`)
/// so a host can show "recent activity" in a debug/support screen, or fold
/// it straight into `ICloudDriveSyncDiagnosticsSnapshot`, without having to
/// wire up its own event log just to get that. Carries no item content or
/// ids — every `data` value the engine logs is already just counts, mode
/// names, and error type strings, the same information `onEvent` always
/// handed a host.
public struct ICloudDriveSyncLogEntry: Identifiable, Codable, Sendable {
    public enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let timestamp: Date
    public let name: String
    public let level: Level
    public let data: [String: String]

    public init(id: UUID = UUID(), timestamp: Date, name: String, level: Level, data: [String: String]) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.level = level
        self.data = data
    }
}

/// A small, fixed-capacity in-memory history of recent `ICloudDriveSyncLogEntry`
/// values — oldest entries drop off once `capacity` is exceeded (see
/// `ICloudDriveSyncConfig.eventLogCapacity`), so this never grows unbounded
/// across a long-lived app session. Internal: a host sees its contents
/// through `ICloudDriveSyncEngine.recentEvents`, never this type itself.
struct ICloudDriveSyncEventLog {
    private(set) var entries: [ICloudDriveSyncLogEntry] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ entry: ICloudDriveSyncLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

/// A point-in-time snapshot of everything about an `ICloudDriveSyncEngine`'s
/// state that's useful for debugging a sync problem — current connectivity,
/// pending-change counts, the last restore's issue counts, and recent event
/// history — with no item content or ids anywhere in it. Meant to sit behind
/// a "Copy Diagnostics"/"Export Diagnostics" button in a host's own support
/// flow: call `ICloudDriveSyncEngine.makeDiagnosticsSnapshot()` to get one,
/// then `jsonString()` on the result for something directly shareable (a
/// `Text`, a `ShareLink`, a pasted-into-an-email block).
public struct ICloudDriveSyncDiagnosticsSnapshot: Codable, Sendable {
    public struct RestoreReportSummary: Codable, Sendable {
        public let expectedItemCount: Int
        public let restoredItemCount: Int
        public let missingItemCount: Int
        public let failedItemCount: Int
    }

    public let generatedAt: Date
    public let appName: String
    /// This install's stable conflict-detection identity (see
    /// `ICloudDriveSyncEngine.deviceID`) — handy for telling apart which
    /// device wrote a support report when a person syncs from more than
    /// one.
    public let deviceID: String
    public let isICloudAvailable: Bool
    public let autoSyncMode: ICloudAutoSyncMode
    public let isSyncing: Bool
    public let isNetworkConnected: Bool
    public let isWiFiConnected: Bool
    public let isCellularConnected: Bool
    public let isLowDataModeEnabled: Bool
    public let hasUnrestoredBackup: Bool
    public let hasPendingChanges: Bool
    public let pendingItemCount: Int
    public let pendingDeletedItemCount: Int
    /// Only ever nonzero under `ICloudDriveSyncConfig.conflictPolicy == .manual`
    /// — every other policy resolves conflicts on its own and never leaves
    /// anything in `ICloudDriveSyncEngine.pendingConflicts`.
    public let pendingConflictCount: Int
    public let hasPendingPreferencesChange: Bool
    public let lastRestoredHostSchemaMetadata: ICloudDriveHostSchemaMetadata?
    public let lastSyncAt: Date?
    public let backupByteCount: Int64
    /// `ICloudDriveSyncOutcome` itself isn't `Codable` (its cases wrap other
    /// `Codable` enums, but a manual `Codable` conformance for the wrapper
    /// isn't worth adding just for this one export path), so this snapshot
    /// stores a short description string instead — e.g. `"failure(iCloudUnavailable)"`.
    public let syncOutcomeDescription: String
    public let syncMessage: String?
    public let lastRestoreReport: RestoreReportSummary?
    public let recentEvents: [ICloudDriveSyncLogEntry]

    /// Renders this snapshot as JSON — sorted keys, and (by default)
    /// pretty-printed, so it's directly usable behind a "Copy Diagnostics"
    /// button or dropped straight into a support email. Falls back to
    /// `"{}"` in the practically-impossible case encoding fails (every field
    /// here is a plain value type — dates, strings, numbers, an array of the
    /// same) — a diagnostics export should never itself throw and interrupt
    /// whatever debugging flow the host is in.
    public func jsonString(prettyPrinted: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

extension ICloudDriveSyncOutcome {
    var diagnosticsDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .success(let value):
            return "success(\(value.rawValue))"
        case .failure(let value):
            return "failure(\(value.rawValue))"
        case .warning(let value):
            return "warning(\(value.rawValue))"
        }
    }
}
