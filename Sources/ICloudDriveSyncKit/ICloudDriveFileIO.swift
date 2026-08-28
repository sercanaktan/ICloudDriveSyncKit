import Foundation

/// File-coordinated reads/writes against the ubiquity container, plus the
/// "wait for a ubiquitous item to actually download" polling loop. Kept
/// free of any network-state *decisions* (Wi-Fi vs. cellular messaging,
/// attempt-limit choice) — the engine owns those, since it's the one
/// tracking connectivity; this type just does the I/O it's told to.
enum ICloudDriveFileIO {
    private struct UbiquitousItemState: Sendable {
        let isWaitingForDownload: Bool
        let downloadErrorDescription: String?
    }

    static func coordinatedReadData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try coordinatedReadDataSync(from: url)
        }.value
    }

    private static func coordinatedReadDataSync(from url: URL) throws -> Data {
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            readResult = Result { try Data(contentsOf: coordinatedURL) }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let readResult else {
            throw ICloudDriveSyncError.readFailed(nil)
        }
        return try readResult.get()
    }

    static func coordinatedWriteData(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try coordinatedWriteDataSync(data, to: url)
        }.value
    }

    private static func coordinatedWriteDataSync(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeResult: Result<Void, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            writeResult = Result { try data.write(to: coordinatedURL, options: [.atomic]) }
        }

        if let coordinationError {
            throw coordinationError
        }
        try writeResult?.get()
    }

    /// Deletes a file or folder (recursively — `FileManager.removeItem`
    /// already handles a directory's contents) through a file coordinator
    /// using `.forDeleting`, the option Apple's coordination APIs expect for
    /// a delete specifically — distinct from `.forReplacing` above, which is
    /// for a write that keeps the item around. Used by
    /// `ICloudDriveSyncEngine.deleteBackupManually()` to remove an entire
    /// `backupDirectoryName` folder at once. A no-op (not an error) if
    /// nothing exists at `url` already.
    static func coordinatedDeleteItem(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try coordinatedDeleteItemSync(at: url)
        }.value
    }

    private static func coordinatedDeleteItemSync(at url: URL) throws {
        var coordinationError: NSError?
        var deleteResult: Result<Void, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            deleteResult = Result {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                try FileManager.default.removeItem(at: coordinatedURL)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        try deleteResult?.get()
    }

    /// Recursively lists every regular file under `directoryURL`, coordinated
    /// as a read so it doesn't race an in-flight coordinated write/delete
    /// elsewhere. Used by the reconciliation sweep to see what's *actually*
    /// on disk (as opposed to what the host's `itemIDs` list says should be
    /// there) — everything else in this file resolves an id to a URL and
    /// acts on it; this is the one place that walks the directory itself.
    /// Returns `[]` (not an error) if `directoryURL` doesn't exist yet, since
    /// "nothing to reconcile" is the normal state before a first export.
    static func coordinatedListFiles(under directoryURL: URL) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            try coordinatedListFilesSync(under: directoryURL)
        }.value
    }

    private static func coordinatedListFilesSync(under directoryURL: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }

        var coordinationError: NSError?
        var listResult: Result<[URL], Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: directoryURL, options: [], error: &coordinationError) { coordinatedURL in
            listResult = Result {
                guard let enumerator = FileManager.default.enumerator(
                    at: coordinatedURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    return []
                }

                var files: [URL] = []
                for case let fileURL as URL in enumerator {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { continue }
                    files.append(callerRelativeURL(for: fileURL, coordinatedDirectoryURL: coordinatedURL, callerDirectoryURL: directoryURL))
                }
                return files
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        return try listResult?.get() ?? []
    }

    /// Starts (or resumes) downloading a ubiquitous item and polls until it's
    /// actually available locally, then reads it. Throws
    /// `.downloadFailed`/`.downloadTimedOut` on failure/exhaustion — the
    /// caller decides whether a timeout should be re-surfaced as
    /// `.cellularUnavailable` based on its own network state.
    ///
    /// `onWaitingTick` is called on the first attempt and then every 10th
    /// attempt while still waiting, so a caller can throttle a "downloading…"
    /// message instead of re-publishing it every single poll.
    static func downloadAndRead(
        at url: URL,
        attemptLimit: Int,
        pollInterval: TimeInterval,
        onWaitingTick: () -> Void
    ) async throws -> Data {
        let fileManager = FileManager.default
        var lastReadError: Error?
        var attempt = 0
        // `URL.resourceValues(forKeys:)` caches whatever it fetches on the
        // URL value itself — querying the *same* `URL` repeatedly in a
        // polling loop like this one returns the same stale snapshot from
        // the first call forever, never reflecting the download actually
        // finishing. Force a fresh read every iteration.
        var pollURL = url

        while attempt < attemptLimit {
            // This is the loop where cancellation matters most in practice —
            // a stuck-on-cellular download can sit here for its entire
            // `attemptLimit`, and this is the only place in the package
            // where a wait is actually long enough for someone to notice.
            // Checked explicitly (not just left to `Task.sleep` below) so a
            // cancellation lands before starting another round of I/O, not
            // just before the next nap.
            try Task.checkCancellation()

            let state = await ubiquitousItemState(fileManager: fileManager, downloadURL: url, pollURL: pollURL)
            pollURL.removeAllCachedResourceValues()

            if let downloadErrorDescription = state.downloadErrorDescription {
                throw ICloudDriveSyncError.downloadFailed(downloadErrorDescription)
            }

            if !state.isWaitingForDownload {
                do {
                    return try await coordinatedReadData(from: url)
                } catch {
                    lastReadError = error
                }
            }

            if attempt == 0 || attempt % 10 == 0 {
                onWaitingTick()
            }
            attempt += 1
            // `try` here, deliberately not `try?` — `Task.sleep` throws
            // `CancellationError` when this task is cancelled mid-wait, and
            // that used to be silently swallowed, letting this loop poll
            // right through a cancellation for up to `attemptLimit` more
            // rounds. Letting it propagate is what actually makes
            // cancellation interrupt the single longest wait in this
            // package instead of just skipping the *next* item.
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        throw ICloudDriveSyncError.downloadTimedOut(lastReadError?.localizedDescription)
    }

    private static func ubiquitousItemState(fileManager: FileManager, downloadURL: URL, pollURL: URL) async -> UbiquitousItemState {
        await Task.detached(priority: .utility) {
            try? fileManager.startDownloadingUbiquitousItem(at: downloadURL)

            let values = try? pollURL.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemDownloadingErrorKey
            ])

            let isUbiquitous = values?.isUbiquitousItem == true
            let isWaitingForDownload = isUbiquitous && (
                values?.ubiquitousItemIsDownloading == true ||
                values?.ubiquitousItemDownloadingStatus == .notDownloaded
            )

            return UbiquitousItemState(
                isWaitingForDownload: isWaitingForDownload,
                downloadErrorDescription: values?.ubiquitousItemDownloadingError?.localizedDescription
            )
        }.value
    }

    static func byteCount(at url: URL) async throws -> Int64? {
        try await Task.detached(priority: .utility) {
            try byteCountSync(at: url)
        }.value
    }

    private static func byteCountSync(at url: URL) throws -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let directoryURL = url.deletingLastPathComponent()
        if let directorySize = try? directoryByteCountSync(at: directoryURL), directorySize > 0 {
            return directorySize
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize {
            return Int64(fileSize)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let byteCount = attributes[.size] as? NSNumber {
            return byteCount.int64Value
        }
        return nil
    }

    private static func directoryByteCountSync(at url: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Same directory walk as `byteCount(at:)`'s directory-total fallback,
    /// but returns every regular file's own size instead of a single summed
    /// total. `ICloudDriveSyncEngine` uses this to (re)seed its incremental
    /// per-item byte ledger from whatever's really on disk — once, for an
    /// install upgrading from a kit version that predates that ledger, and
    /// again after `refreshBackupStatus()` or `reconcileOrphanedItems()`,
    /// both of which already do a comparable walk of their own — rather than
    /// ever letting `backupByteCount` silently drift from reality.
    /// Returns `[:]` (not an error) if `directoryURL` doesn't exist yet,
    /// same as `coordinatedListFiles(under:)`. Not coordinated — same as
    /// `byteCount(at:)`'s own walk, this is a read-only size query, not a
    /// write, so it's fine for it to occasionally race a concurrent write.
    static func fileSizes(under directoryURL: URL) async throws -> [URL: Int64] {
        try await Task.detached(priority: .utility) {
            try fileSizesSync(under: directoryURL)
        }.value
    }

    private static func fileSizesSync(under directoryURL: URL) throws -> [URL: Int64] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return [:]
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var sizes: [URL: Int64] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            sizes[fileURL] = Int64(values.fileSize ?? 0)
        }
        return sizes
    }

    /// Percent-encodes an arbitrary item id into a safe file name — item ids
    /// can be anything the host uses (UUIDs, slugs, ...), file names can't.
    /// Used as the fallback by `itemURL(for:in:)` below for an id with no
    /// `/` in it; exposed on its own too since it's occasionally useful
    /// standalone.
    static func fileName(for itemID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let encoded = itemID.addingPercentEncoding(withAllowedCharacters: allowed) ?? itemID
        return "\(encoded).json"
    }

    /// Resolves a Data item id to its on-disk URL inside the items
    /// directory — this is what actually gives a host "free" folder
    /// partitioning by naming its ids with `/`. Each `/`-separated
    /// component is percent-encoded on its own (rather than encoding the
    /// `/` itself away), so `"diary/2024-01-01-abc123"` becomes
    /// `Items/diary/2024-01-01-abc123.json`, `"diary/2024/01-abc123"`
    /// becomes `Items/diary/2024/01-abc123.json`, and a plain id with no
    /// `/` becomes a single flat file exactly as before — a host that
    /// doesn't care about this ignores it completely and nothing changes.
    /// Callers writing through this URL still need to create its parent
    /// directory first (`FileManager` doesn't do that implicitly); reading
    /// and deleting don't.
    static func itemURL(for itemID: String, in itemsDirectory: URL) -> URL {
        assetURL(for: itemID, extension: "json", in: itemsDirectory)
    }

    /// Same `/`-partitioning convention as `itemURL(for:in:)`, generalized to
    /// any file extension — this is what lets `ICloudDriveImageAssetStore`
    /// reuse the exact same "id containing `/` becomes a subfolder" rule for
    /// image files instead of `.json` items, without duplicating the
    /// splitting/percent-encoding logic. `itemURL(for:in:)` is just this
    /// with `extension: "json"`.
    static func assetURL(for id: String, extension ext: String, in directory: URL) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let components = id.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
            return directory.appendingPathComponent("\(encoded).\(ext)")
        }

        var url = directory
        for (index, component) in components.enumerated() {
            let pathComponent = String(component)
            if index == components.count - 1 {
                url = url.appendingPathComponent("\(pathComponent).\(ext)")
            } else {
                url = url.appendingPathComponent(pathComponent, isDirectory: true)
            }
        }
        return url
    }

    private static func callerRelativeURL(
        for fileURL: URL,
        coordinatedDirectoryURL: URL,
        callerDirectoryURL: URL
    ) -> URL {
        let coordinatedBasePath = coordinatedDirectoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath == coordinatedBasePath || filePath.hasPrefix(coordinatedBasePath + "/") else {
            return fileURL
        }

        let relativePath = String(filePath.dropFirst(coordinatedBasePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { return callerDirectoryURL }
        return callerDirectoryURL.appendingPathComponent(relativePath)
    }
}
