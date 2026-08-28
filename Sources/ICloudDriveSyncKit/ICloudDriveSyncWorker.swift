import Foundation

/// The engine's own small bookkeeping file — never the host's manifest
/// itself (that's written to `manifestFileName` as raw `Data`, untouched by
/// this package). Just enough to know what to fetch on restore, and (via
/// `deviceID`/`itemModifiedAt`) what a future export needs to detect a
/// conflict against. Lives here (rather than in `ICloudDriveSyncEngine.swift`)
/// because both halves of the old monolithic engine need to encode/decode
/// it: `ICloudDriveSyncWorker` builds one on every export and parses one on
/// every restore or conflict check; `ICloudDriveSyncEngine` still owns the
/// actual public-facing restore result, but composes it from what this type
/// hands back.
struct BackupEnvelope: Codable {
    var appName: String
    var schemaVersion: Int
    var exportedAt: Date
    var itemIDs: [String]
    /// The device that wrote this envelope — see `ICloudDriveSyncEngine.deviceID`.
    /// Decodes to `""` on an envelope written before conflict detection
    /// existed (or by anything else that never sends one); an empty string
    /// never equals a real device's id, so it's always treated as "some
    /// other device" wherever this is compared — the conservative, safe
    /// default rather than a decode failure that would make an existing
    /// backup unrestorable.
    var deviceID: String
    /// Per-item last-modified time, as reported by the host's own
    /// `ICloudDriveSyncDataSource.exportData(...)` at the moment each item
    /// was last (re)uploaded. Decodes to `[:]` on an older envelope — an id
    /// with no entry here is simply never treated as a conflict candidate
    /// (see `ICloudDriveSyncWorker.detectConflicts`), so a pre-existing
    /// backup just starts conflict-blind until its items sync again, rather
    /// than failing to restore.
    var itemModifiedAt: [String: Date]
    /// Present only for optional snapshot backups. The normal current backup
    /// leaves this nil so existing hosts keep the exact same envelope shape
    /// unless they opt into snapshots.
    var backupID: String?
    var label: String?
    /// Optional host-app schema label for the opaque Data manifest/items.
    /// This is not the kit's own envelope `schemaVersion`; it belongs to the
    /// app using the kit and lets future app versions decide how to migrate
    /// or reject restored data before decoding it.
    var hostSchemaMetadata: ICloudDriveHostSchemaMetadata?

    private enum CodingKeys: String, CodingKey {
        case appName, schemaVersion, exportedAt, itemIDs, deviceID, itemModifiedAt, backupID, label, hostSchemaMetadata
    }

    init(
        appName: String,
        schemaVersion: Int,
        exportedAt: Date,
        itemIDs: [String],
        deviceID: String,
        itemModifiedAt: [String: Date],
        backupID: String? = nil,
        label: String? = nil,
        hostSchemaMetadata: ICloudDriveHostSchemaMetadata? = nil
    ) {
        self.appName = appName
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.itemIDs = itemIDs
        self.deviceID = deviceID
        self.itemModifiedAt = itemModifiedAt
        self.backupID = backupID
        self.label = label
        self.hostSchemaMetadata = hostSchemaMetadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appName = try c.decode(String.self, forKey: .appName)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        itemIDs = try c.decode([String].self, forKey: .itemIDs)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        itemModifiedAt = try c.decodeIfPresent([String: Date].self, forKey: .itemModifiedAt) ?? [:]
        backupID = try c.decodeIfPresent(String.self, forKey: .backupID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        hostSchemaMetadata = try c.decodeIfPresent(ICloudDriveHostSchemaMetadata.self, forKey: .hostSchemaMetadata)
    }
}

extension JSONEncoder {
    static let icloudDriveSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension JSONDecoder {
    static let icloudDriveSync: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The mechanical half of what used to be one 1500-line `ICloudDriveSyncEngine`
/// file: everything that actually walks a backup's directory structure,
/// writes/deletes individual item files, and builds/parses the envelope +
/// manifest during an export or restore — with **zero** engine state of its
/// own. No `@Published` properties, no `UserDefaults`, no `NWPathMonitor`, no
/// knowledge of Wi-Fi vs. cellular, no `@MainActor`.
///
/// `ICloudDriveSyncEngine` (still `@MainActor`, still the only public type a
/// host ever talks to) keeps every *decision*: what a fresh export should
/// even contain (that means calling the `@MainActor`-isolated
/// `ICloudDriveSyncDataSource`), how many attempts a download gets on
/// cellular vs. Wi-Fi, when to give up and surface "connect to Wi-Fi,"
/// which `@Published` property a given moment of progress should update.
/// This type only ever gets handed the *primitives* to carry a decision out
/// — `IOPrimitives.write`/`.download`/`.delete`/`.byteCount`, all supplied
/// fresh by the engine on every call — plus a place to report progress
/// (`onProgress`). It never touches `ICloudDriveFileIO` for policy reasons of
/// its own; it just calls whatever `IOPrimitives` it was given.
///
/// That split is what makes this half callable — and unit-testable — without
/// a `@MainActor` context, a real `ObservableObject`, or a live iCloud
/// container: every method here is a pure function of its explicit
/// parameters, `IOPrimitives`' four closures included. A test can construct
/// an in-memory `IOPrimitives` (a `[URL: Data]` dictionary standing in for
/// the ubiquity container) and exercise the exact same upload/restore
/// ordering, retry-report-merging, and progress-sequencing logic this
/// package ships, with no iCloud account, no `NSFileCoordinator`, and no
/// simulator involved.
///
/// Only the two genuinely complex, loop-heavy, multi-step operations moved
/// here: the full Data export upload, and a backup restore (whole or
/// item-by-item retry). Preferences export/restore and delete-backup stayed
/// on `ICloudDriveSyncEngine` — each is one or two I/O calls wrapped in state
/// bookkeeping, and splitting those out would add indirection without
/// making anything more testable that isn't already trivial to read.
struct ICloudDriveSyncWorker {
    /// The coordinated-I/O primitives this type needs, supplied fresh by
    /// `ICloudDriveSyncEngine` on every call (see `ICloudDriveSyncEngine.ioPrimitives`)
    /// so every network-state-aware policy decision — cellular attempt
    /// limits, Wi-Fi-only waiting, which error a stuck download should
    /// surface as — stays owned by the engine, where its `@Published`
    /// connectivity state already lives. This type never imports `Network`
    /// or asks "are we on Wi-Fi?" itself.
    struct IOPrimitives {
        var write: (Data, URL) async throws -> Void
        var download: (URL) async throws -> Data
        var delete: (URL) async throws -> Void
        var byteCount: (URL) async throws -> Int64?
    }

    /// A restore-item issue with no `displayName` resolved yet —
    /// `itemDisplayNameResolver` is a host-supplied closure the engine
    /// always called on `@MainActor` (a typical resolver reads a
    /// `@MainActor`-isolated in-memory title lookup), so resolving it inside
    /// this type — which runs with no actor isolation of its own — would
    /// silently change which thread that closure gets called on. Instead
    /// this type reports the raw issue, and `ICloudDriveSyncEngine` resolves
    /// `displayName` itself afterward, back on `@MainActor`, exactly as it
    /// always did.
    struct RawRestoreItemIssue {
        let itemID: String
        let reason: ICloudDriveRestoreItemIssueReason
        let errorDescription: String?
    }

    struct RawRestoreReport {
        let expectedItemCount: Int
        let restoredItemCount: Int
        let missingItems: [RawRestoreItemIssue]
        let failedItems: [RawRestoreItemIssue]
    }

    struct RawRestoreItemsResult {
        let items: [String: Data]
        let report: RawRestoreReport
    }

    struct RawRestoreResult {
        let envelope: BackupEnvelope
        let manifest: Data
        let items: [String: Data]
        let report: RawRestoreReport
        /// The envelope's own byte size, computed directly from the
        /// downloaded `Data` rather than a real disk read — see
        /// `UploadDataResult.envelopeByteCount` for why. Every item's own
        /// size is already available from `items` itself
        /// (`items.mapValues { Int64($0.count) }`), so unlike
        /// `UploadDataResult` there's no separate per-item field here.
        let envelopeByteCount: Int64
    }

    struct UploadDataResult {
        /// `items.keys` from the export payload — on a full export every
        /// item got (re)written regardless of what was actually pending, so
        /// this (not whatever the caller thought was pending going in) is
        /// what a host's own "still needs export" bookkeeping should
        /// actually clear.
        let exportedItemIDs: Set<String>
        /// Byte size of each just-written item, keyed by the exact URL it
        /// was written to (`ICloudDriveFileIO.itemURL(for:in:)`) — computed
        /// straight from the `Data` already in hand, never a disk read, so
        /// a caller can maintain a running byte total without ever reading
        /// these files back to ask how big they are. See
        /// `ICloudDriveSyncEngine.itemByteSizeCache`.
        let exportedItemByteSizes: [URL: Int64]
        let envelopeByteCount: Int64
    }

    // MARK: Upload

    /// How many item transfers (uploads, downloads, or deletes) `uploadData`,
    /// `readBackupItems`, and `reconcileOrphanedItems` let run at once. Bounded rather than unbounded
    /// — a large backup firing off hundreds of simultaneous
    /// `NSFileCoordinator` operations would just contend with itself and
    /// with iCloud's own transfer scheduling — but still real overlap
    /// instead of the one-file-at-a-time sequencing this used to do, which
    /// made a big backup's export/restore time scale linearly with item
    /// count even though each individual transfer spends most of its time
    /// simply waiting on the network.
    private static let maxConcurrentItemTransfers = 4

    /// Deletes each `deletedItemIDs` file (best-effort — a file that's
    /// already gone isn't an error), writes every `items` entry, then writes
    /// `manifest` and a freshly-built envelope — in that order, matching
    /// what used to be `ICloudDriveSyncEngine.exportDataToICloud()`'s inline
    /// loop. The delete and write passes each run up to
    /// `maxConcurrentItemTransfers` items at once rather than strictly one
    /// at a time; `completedUnits`/progress still advance one tick per
    /// finished item, just not in the same order the items were handed in.
    func uploadData(
        items: [String: Data],
        deletedItemIDs: Set<String>,
        manifest: Data,
        allItemIDs: Set<String>,
        appName: String,
        exportedAt: Date,
        deviceID: String,
        itemModifiedAt: [String: Date],
        backupID: String? = nil,
        label: String? = nil,
        hostSchemaMetadata: ICloudDriveHostSchemaMetadata? = nil,
        itemsURL: URL,
        manifestURL: URL,
        envelopeURL: URL,
        io: IOPrimitives,
        onProgress: (ICloudDriveSyncProgressPhase, Int, Int?, String?) async -> Void
    ) async throws -> UploadDataResult {
        try Task.checkCancellation()

        let totalUnits = deletedItemIDs.count + items.count + 2
        var completedUnits = 0

        // Individual delete failures are still best-effort (`try?` swallows
        // them, same as always) — but cancellation is not: a `CancellationError`
        // thrown here (from the `try Task.checkCancellation()` between items
        // below) is not caught by that `try?`, so it propagates straight out
        // of this group and aborts the whole export, same as a write failure
        // does further down.
        try await withThrowingTaskGroup(of: String.self) { group in
            var iterator = deletedItemIDs.makeIterator()
            for _ in 0..<Self.maxConcurrentItemTransfers {
                guard let itemID = iterator.next() else { break }
                group.addTask {
                    let url = ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL)
                    try? await io.delete(url)
                    return itemID
                }
            }
            while let itemID = try await group.next() {
                completedUnits += 1
                await onProgress(.uploadingItems, completedUnits, totalUnits, itemID)
                try Task.checkCancellation()
                if let nextItemID = iterator.next() {
                    group.addTask {
                        let url = ICloudDriveFileIO.itemURL(for: nextItemID, in: itemsURL)
                        try? await io.delete(url)
                        return nextItemID
                    }
                }
            }
        }

        // Not best-effort — a single item write failure here still aborts
        // the whole export, exactly as it always did (nothing past this
        // point, including the manifest and envelope, gets written). The
        // difference under concurrency: up to `maxConcurrentItemTransfers`
        // writes (or deletes, above) may already be in flight when a
        // failure — or a cancellation, checked between items below — hits,
        // so a few more items can land before the throwing group unwinds
        // and cancels whatever's left. Never fewer, and iCloud Drive item
        // files are independent anyway, so a handful of "extra" successful
        // writes on an aborted export attempt is harmless (the next export
        // attempt just re-covers everything from `pendingItemIDs` regardless).
        try await withThrowingTaskGroup(of: String.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<Self.maxConcurrentItemTransfers {
                guard let (itemID, itemData) = iterator.next() else { break }
                group.addTask {
                    let url = ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL)
                    // `itemURL(for:in:)` may resolve into a nested subfolder
                    // (an id containing `/`) that doesn't exist yet —
                    // `FileManager` never creates intermediate directories
                    // implicitly on a write.
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await io.write(itemData, url)
                    return itemID
                }
            }
            while let itemID = try await group.next() {
                completedUnits += 1
                await onProgress(.uploadingItems, completedUnits, totalUnits, itemID)
                try Task.checkCancellation()
                if let (nextItemID, nextItemData) = iterator.next() {
                    group.addTask {
                        let url = ICloudDriveFileIO.itemURL(for: nextItemID, in: itemsURL)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try await io.write(nextItemData, url)
                        return nextItemID
                    }
                }
            }
        }

        try Task.checkCancellation()
        await onProgress(.uploadingManifest, completedUnits, totalUnits, nil)
        try await io.write(manifest, manifestURL)
        completedUnits += 1
        await onProgress(.uploadingManifest, completedUnits, totalUnits, nil)

        let envelope = BackupEnvelope(
            appName: appName,
            schemaVersion: 1,
            exportedAt: exportedAt,
            itemIDs: Array(allItemIDs).sorted(),
            deviceID: deviceID,
            itemModifiedAt: itemModifiedAt,
            backupID: backupID,
            label: label,
            hostSchemaMetadata: hostSchemaMetadata
        )
        let envelopeData = try JSONEncoder.icloudDriveSync.encode(envelope)
        await onProgress(.uploadingEnvelope, completedUnits, totalUnits, nil)
        try await io.write(envelopeData, envelopeURL)
        completedUnits += 1
        await onProgress(.uploadingEnvelope, completedUnits, totalUnits, nil)

        // Every item's size is already known from the `Data` just written —
        // no disk read needed to report it. The old code asked `io` for the
        // *whole backup folder's* total here instead (`io.byteCount`, a full
        // directory walk under the hood), which is what made every export's
        // final step cost as much as the biggest possible export regardless
        // of how few items this particular one actually touched.
        let exportedItemByteSizes = Dictionary(uniqueKeysWithValues: items.map { itemID, itemData in
            (ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL), Int64(itemData.count))
        })
        return UploadDataResult(
            exportedItemIDs: Set(items.keys),
            exportedItemByteSizes: exportedItemByteSizes,
            envelopeByteCount: Int64(envelopeData.count)
        )
    }

    // MARK: Restore

    // MARK: Preferences

    /// Writes the Preferences lane as one whole-file blob. This stays
    /// intentionally separate from `uploadData`: a settings-only sync should
    /// never touch item files, and a data-only sync should never need a
    /// preferences payload.
    func uploadPreferences(
        _ preferences: Data,
        preferencesURL: URL,
        io: IOPrimitives,
        onProgress: (ICloudDriveSyncProgressPhase, Int, Int?, String?) async -> Void
    ) async throws {
        try Task.checkCancellation()
        await onProgress(.uploadingPreferences, 0, 1, nil)
        try await io.write(preferences, preferencesURL)
        await onProgress(.uploadingPreferences, 1, 1, nil)
    }

    /// Downloads the Preferences lane if this backup has one. Missing
    /// preferences are a normal no-op so older backups remain restorable.
    func readPreferencesIfAvailable(
        preferencesURL: URL,
        completedOffset: Int = 0,
        totalUnitCount: Int? = nil,
        io: IOPrimitives,
        onProgress: (ICloudDriveSyncProgressPhase, Int, Int?, String?) async -> Void
    ) async throws -> Data? {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            return nil
        }

        try Task.checkCancellation()
        await onProgress(.downloadingPreferences, completedOffset, totalUnitCount ?? 1, nil)
        let data = try await io.download(preferencesURL)
        await onProgress(.downloadingPreferences, completedOffset + 1, totalUnitCount ?? 1, nil)
        return data
    }

    /// Downloads the envelope, the manifest, and every item the envelope
    /// lists, in that order — `nil` if there's no envelope file at
    /// `backupURL` at all (no backup exists yet). Matches what used to be
    /// `ICloudDriveSyncEngine.readBackup()`.
    func readBackup(
        backupURL: URL,
        manifestURL: URL,
        itemsURL: URL,
        io: IOPrimitives,
        onProgress: (ICloudDriveSyncProgressPhase, Int, Int?, String?) async -> Void
    ) async throws -> RawRestoreResult? {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            return nil
        }

        try Task.checkCancellation()
        await onProgress(.downloadingEnvelope, 0, nil, nil)
        let envelopeData = try await io.download(backupURL)
        let envelope = try JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData)
        try Task.checkCancellation()
        await onProgress(.downloadingManifest, 1, envelope.itemIDs.count + 2, nil)
        let manifestData = try await io.download(manifestURL)
        await onProgress(.downloadingManifest, 2, envelope.itemIDs.count + 2, nil)

        let itemResult = try await readBackupItems(
            requestedItemIDs: Set(envelope.itemIDs),
            envelopeItemIDs: envelope.itemIDs,
            itemsURL: itemsURL,
            completedOffset: 2,
            totalUnitCount: envelope.itemIDs.count + 2,
            io: io,
            onProgress: onProgress
        )

        // Same reasoning as `uploadData` above — `envelopeData` was just
        // downloaded, so its size is already known without asking `io` to
        // walk the whole backup folder again.
        return RawRestoreResult(
            envelope: envelope,
            manifest: manifestData,
            items: itemResult.items,
            report: itemResult.report,
            envelopeByteCount: Int64(envelopeData.count)
        )
    }

    /// One item download's outcome — used only to get a child task's result
    /// back across the `TaskGroup` boundary in `readBackupItems` below.
    private enum ItemDownloadOutcome {
        case downloaded(itemID: String, data: Data)
        case missing(RawRestoreItemIssue)
        case failed(RawRestoreItemIssue)
    }

    /// One item's worth of the `readBackupItems` download loop body —
    /// pulled out to a `static` function (rather than duplicated inline at
    /// both of the loop's two `group.addTask` call sites below) purely to
    /// avoid repeating this same guard/guard/do-catch chain twice.
    ///
    /// Throwing (cancellation only — see below) rather than folding
    /// everything into `ItemDownloadOutcome` is deliberate: a single item's
    /// real download failure is still tolerated and reported as `.failed`,
    /// but `io.download`'s underlying poll loop (`ICloudDriveFileIO.downloadAndRead`,
    /// for a not-yet-materialized iCloud item) can itself throw
    /// `CancellationError` now that it actually honors cancellation — and
    /// that must abort the whole restore/export via `readBackupItems`'s
    /// `try Task.checkCancellation()`, not get miscategorized as "this one
    /// item failed" and quietly folded into `failedItems` while every other
    /// item keeps downloading regardless.
    private static func downloadOneItem(
        _ itemID: String,
        envelopeItemIDSet: Set<String>,
        itemsURL: URL,
        io: IOPrimitives
    ) async throws -> ItemDownloadOutcome {
        guard envelopeItemIDSet.contains(itemID) else {
            return .missing(RawRestoreItemIssue(itemID: itemID, reason: .missingFile, errorDescription: nil))
        }
        let itemURL = ICloudDriveFileIO.itemURL(for: itemID, in: itemsURL)
        guard FileManager.default.fileExists(atPath: itemURL.path) else {
            return .missing(RawRestoreItemIssue(itemID: itemID, reason: .missingFile, errorDescription: nil))
        }
        do {
            return .downloaded(itemID: itemID, data: try await io.download(itemURL))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(RawRestoreItemIssue(
                itemID: itemID,
                reason: Self.restoreIssueReason(for: error),
                errorDescription: error.localizedDescription
            ))
        }
    }

    /// Downloads every item in `requestedItemIDs` that the envelope actually
    /// has (an id the envelope doesn't list, or that has no file on disk,
    /// counts as a missing item rather than a download attempt), reporting
    /// progress and collecting missing/failed items into a report rather
    /// than throwing on the first bad item — a single stuck item should
    /// never fail an entire restore. Matches what used to be
    /// `ICloudDriveSyncEngine.readBackupItems(_:envelopeItemIDs:backupURL:completedOffset:totalUnitCount:)`.
    ///
    /// Downloads up to `maxConcurrentItemTransfers` items at once instead of
    /// one at a time; `missingItems`/`failedItems` end up with the same
    /// members either way (order doesn't matter — both are consumed as
    /// sets/by id everywhere they're read), and `completedOffset + index`'s
    /// job — turning "which item just finished" into a progress tick — is
    /// now just a plain counter, since "index" no longer means anything
    /// once items can finish out of order.
    ///
    /// Throws only for cancellation (checked between items, same as
    /// `uploadData`'s loops) — a single item's own download failure is
    /// still tolerated and folded into `failedItems`, never thrown. This is
    /// the one behavior change from this method's previous, non-throwing
    /// signature: a caller whose Task gets cancelled mid-restore (a person
    /// backgrounding the app during a large restore, a host's own
    /// `.task { }` view getting torn down, ...) now actually stops making
    /// new download requests instead of grinding through every remaining
    /// item regardless.
    func readBackupItems(
        requestedItemIDs: Set<String>,
        envelopeItemIDs: [String],
        itemsURL: URL,
        completedOffset: Int = 0,
        totalUnitCount: Int? = nil,
        io: IOPrimitives,
        onProgress: (ICloudDriveSyncProgressPhase, Int, Int?, String?) async -> Void
    ) async throws -> RawRestoreItemsResult {
        try Task.checkCancellation()

        let envelopeItemIDSet = Set(envelopeItemIDs)
        let orderedItemIDs = envelopeItemIDs.filter { requestedItemIDs.contains($0) }
            + requestedItemIDs.subtracting(envelopeItemIDSet).sorted()
        var items: [String: Data] = [:]
        var missingItems: [RawRestoreItemIssue] = []
        var failedItems: [RawRestoreItemIssue] = []
        let total = totalUnitCount ?? orderedItemIDs.count
        var completedUnits = completedOffset

        try await withThrowingTaskGroup(of: ItemDownloadOutcome.self) { group in
            var iterator = orderedItemIDs.makeIterator()
            for _ in 0..<Self.maxConcurrentItemTransfers {
                guard let itemID = iterator.next() else { break }
                group.addTask {
                    try await Self.downloadOneItem(itemID, envelopeItemIDSet: envelopeItemIDSet, itemsURL: itemsURL, io: io)
                }
            }
            while let outcome = try await group.next() {
                var completedItemID: String?
                switch outcome {
                case .downloaded(let itemID, let data):
                    items[itemID] = data
                    completedItemID = itemID
                case .missing(let issue):
                    missingItems.append(issue)
                    completedItemID = issue.itemID
                case .failed(let issue):
                    failedItems.append(issue)
                    completedItemID = issue.itemID
                }
                completedUnits += 1
                await onProgress(.downloadingItems, completedUnits, total, completedItemID)
                try Task.checkCancellation()
                if let nextItemID = iterator.next() {
                    group.addTask {
                        try await Self.downloadOneItem(nextItemID, envelopeItemIDSet: envelopeItemIDSet, itemsURL: itemsURL, io: io)
                    }
                }
            }
        }

        return RawRestoreItemsResult(
            items: items,
            report: RawRestoreReport(
                expectedItemCount: orderedItemIDs.count,
                restoredItemCount: items.count,
                missingItems: missingItems,
                failedItems: failedItems
            )
        )
    }

    // MARK: Conflict detection

    struct ConflictCheckResult {
        /// Items where the cloud's `itemModifiedAt` entry is newer than the
        /// local edit this device is about to upload for the same id, on an
        /// envelope written by a device other than `ourDeviceID`. Empty
        /// whenever there's nothing to compare against yet (no envelope on
        /// the cloud side) or the current cloud envelope was written by this
        /// same device (nothing to conflict with — a device never conflicts
        /// with its own prior sync).
        let conflictedItemIDs: Set<String>
        /// The envelope the conflict check downloaded, so
        /// `ICloudDriveSyncEngine` doesn't have to fetch it a second time to
        /// resolve what it just found — `nil` whenever `conflictedItemIDs`
        /// is empty (nothing to resolve, nothing worth keeping around).
        let cloudEnvelope: BackupEnvelope?
    }

    /// Downloads the current cloud envelope (a no-op, empty result if none
    /// exists yet, or if it was written by `ourDeviceID` itself — this
    /// device's own prior sync is never a conflict) and compares
    /// `localModifiedAt` for each of `candidateItemIDs` against the cloud's
    /// `itemModifiedAt` for that same id. An id missing from either side is
    /// simply skipped — a partial `localModifiedAt` map (see
    /// `ICloudDriveSyncDataSource.exportData`'s doc comment) degrades to
    /// "not conflict-checkable" for those ids, never a false positive or a
    /// thrown error.
    func detectConflicts(
        candidateItemIDs: Set<String>,
        localModifiedAt: [String: Date],
        ourDeviceID: String,
        envelopeURL: URL,
        io: IOPrimitives
    ) async -> ConflictCheckResult {
        guard FileManager.default.fileExists(atPath: envelopeURL.path),
              let envelopeData = try? await io.download(envelopeURL),
              let envelope = try? JSONDecoder.icloudDriveSync.decode(BackupEnvelope.self, from: envelopeData),
              envelope.deviceID != ourDeviceID else {
            return ConflictCheckResult(conflictedItemIDs: [], cloudEnvelope: nil)
        }

        var conflicted: Set<String> = []
        for itemID in candidateItemIDs {
            guard let cloudModifiedAt = envelope.itemModifiedAt[itemID],
                  let localTime = localModifiedAt[itemID],
                  cloudModifiedAt > localTime else { continue }
            conflicted.insert(itemID)
        }
        return ConflictCheckResult(conflictedItemIDs: conflicted, cloudEnvelope: conflicted.isEmpty ? nil : envelope)
    }

    // MARK: Reconciliation

    struct RawReconciliationResult {
        let removedItemCount: Int
        let removedRelativePaths: [String]
    }

    /// Compares `expectedItemIDs` (the host's own current roster —
    /// `ICloudDriveSyncDataSource.allDataItemIDs()`, the freshest available
    /// truth) against every file actually sitting under `itemsURL`, and
    /// deletes whatever's on disk but not expected. Nothing in the normal
    /// sync/restore path ever leaves an orphan behind on its own — this
    /// exists for the cases that can: a delete that got interrupted mid-way
    /// (`uploadData`'s delete pass is best-effort per item, not transactional
    /// across the whole set), an id the host renamed without ever deleting
    /// the old one, or a backup written by an older/different version of the
    /// host's export logic. None of that happens often enough to justify
    /// running this automatically on every sync — see
    /// `ICloudDriveSyncEngine.reconcileOrphanedItems()`'s doc comment for why
    /// it's host-triggered only.
    ///
    /// Deletes run with the same bounded concurrency and cancellation
    /// checking as `uploadData`'s delete pass. Unlike that pass, a failed
    /// delete here is dropped from `removedRelativePaths` rather than
    /// reported as handled — the whole point of this method's result is
    /// telling the host what's actually gone, so a file that's still there
    /// after a failed delete attempt should never be claimed as removed.
    /// One stuck file's delete failure never aborts the rest of the sweep.
    func reconcileOrphanedItems(
        expectedItemIDs: Set<String>,
        itemsURL: URL,
        io: IOPrimitives
    ) async throws -> RawReconciliationResult {
        try Task.checkCancellation()

        let expectedURLs = Set(expectedItemIDs.map { ICloudDriveFileIO.itemURL(for: $0, in: itemsURL) })
        let actualURLs = try await ICloudDriveFileIO.coordinatedListFiles(under: itemsURL)
        let orphanURLs = actualURLs.filter { !expectedURLs.contains($0) }

        guard !orphanURLs.isEmpty else {
            return RawReconciliationResult(removedItemCount: 0, removedRelativePaths: [])
        }

        var removedRelativePaths: [String] = []

        try await withThrowingTaskGroup(of: URL?.self) { group in
            var iterator = orphanURLs.makeIterator()
            for _ in 0..<Self.maxConcurrentItemTransfers {
                guard let url = iterator.next() else { break }
                group.addTask {
                    do {
                        try await io.delete(url)
                        return url
                    } catch {
                        return nil
                    }
                }
            }
            while let deletedURL = try await group.next() {
                if let deletedURL {
                    removedRelativePaths.append(Self.relativePath(of: deletedURL, under: itemsURL))
                }
                try Task.checkCancellation()
                if let nextURL = iterator.next() {
                    group.addTask {
                        do {
                            try await io.delete(nextURL)
                            return nextURL
                        } catch {
                            return nil
                        }
                    }
                }
            }
        }

        return RawReconciliationResult(
            removedItemCount: removedRelativePaths.count,
            removedRelativePaths: removedRelativePaths
        )
    }

    /// `url`'s path relative to `baseURL`, for a human-readable report — e.g.
    /// `"diary/2024-01-01-abc123.json"` rather than the full sandbox path.
    /// Falls back to just the last path component if `url` somehow isn't
    /// actually under `baseURL` (shouldn't happen, since every URL here came
    /// from enumerating `baseURL` itself, but this is a report field, not a
    /// path used for further I/O, so a degraded-but-harmless fallback beats
    /// a crash or a thrown error).
    private static func relativePath(of url: URL, under baseURL: URL) -> String {
        let urlPath = url.standardizedFileURL.path
        let basePath = baseURL.standardizedFileURL.path
        guard urlPath.hasPrefix(basePath) else { return url.lastPathComponent }
        let relative = urlPath.dropFirst(basePath.count)
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : String(relative)
    }

    private static func restoreIssueReason(for error: Error) -> ICloudDriveRestoreItemIssueReason {
        guard let syncError = error as? ICloudDriveSyncError else { return .readFailed }
        switch syncError {
        case .downloadFailed, .downloadTimedOut, .cellularUnavailable:
            return .downloadFailed
        case .readFailed:
            return .readFailed
        default:
            return .readFailed
        }
    }
}
