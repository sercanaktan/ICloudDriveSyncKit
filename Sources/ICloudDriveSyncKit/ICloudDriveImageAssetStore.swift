import Foundation

/// Stores images in the same iCloud Drive ubiquity container the
/// Data/Preferences backup uses — as discrete files, one per image, never as
/// Base64 embedded in JSON. Completely independent of `ICloudDriveSyncEngine`
/// (a host can use one, the other, or both): images are typically saved the
/// moment a person picks/captures one, not batched into a debounced sync
/// cycle, so this type has its own small, synchronous-feeling API rather
/// than participating in the engine's pending-changes/auto-sync machinery.
///
/// ## Why files, not Base64-in-JSON
///
/// This mirrors what Apple's own "Designing for Documents in iCloud" guide
/// recommends for exactly this situation (structured metadata alongside
/// large binary content): store the binary as its own file, and let iCloud's
/// upload/download machinery move it independently of everything else — a
/// Base64 string embedded in a JSON item would inflate the bytes actually
/// transferred by roughly a third, defeat any partial/incremental sync (the
/// *whole* item file has to be rewritten and re-uploaded any time the image
/// changes, even if nothing else about it did), and force every read of that
/// JSON to hold the fully-decoded image in memory just to parse the rest of
/// the item.
///
/// ## The contract: an id, never bytes, in your own JSON
///
/// `save(_:id:)` returns a plain `String` id — store *only* that id on your
/// own model/item (e.g. `var photoID: String?`), the same way a foreign key
/// works. When you need the actual bytes (displaying the image, exporting
/// it, whatever), call `loadData(id:)` with that id. Your item's JSON, and
/// the Data-lane manifest/items this sits alongside, never contain image
/// bytes — only ever this id.
///
/// ## Efficient by construction
///
/// - **Inspecting an image never decodes its bitmap.** `validate(_:)` reads
///   only ImageIO header/metadata (see `ICloudDriveImageInspector`), so
///   checking whether a multi-megabyte photo is too large costs nothing
///   close to what actually loading it would.
/// - **Normalizing/downsampling an oversized image never materializes the
///   full-resolution bitmap either** — `CGImageSourceCreateThumbnailAtIndex`
///   decodes straight to the target size. This is the same technique Apple
///   demonstrates in WWDC 2018's "Image and Graphics Best Practices" for
///   shrinking a picked/captured photo before storing or uploading it.
/// - **Every saved image is HEIC (or your configured format) on disk,
///   never whatever format happened to be handed in** — `save(_:id:)` writes
///   already-conforming input through unchanged, and transparently
///   re-encodes anything else. HEIC is Apple's own newer format and
///   typically runs about half the size of an equivalent-quality JPEG (see
///   WWDC 2017's "Introducing HEIF and HEVC").
///
/// ## Picking bytes on the host side
///
/// This type only ever deals in `Data` — it has no opinion on how you got
/// it. `PhotosUI`'s `PhotosPickerItem.loadTransferable(type: Data.self)`
/// (iOS 16+) is the SwiftUI-native way to get a picked photo's original
/// bytes directly, without your own code ever constructing a `UIImage` just
/// to throw it away again — pass what that hands you straight to `save(_:id:)`.
///
/// ## Size/pixel limits: a warning, on your terms
///
/// Apple doesn't publish a hard per-file size or pixel-dimension limit for
/// iCloud Drive documents (see the doc comment on
/// `ICloudDriveSyncConfig.ImageAssetConfig` for what's actually documented
/// vs. this package's own defaults). `validate(_:)` and `save(_:id:)` both
/// throw a specific, ready-to-display `ICloudDriveSyncError` (`.imageFileTooLarge`/
/// `.imageDimensionsTooLarge`, each carrying the exact actual-vs-limit
/// numbers) the moment either configured limit is exceeded — call
/// `validate(_:)` the instant a person picks an image to warn them
/// immediately, before you'd otherwise even attempt a save. Neither function
/// downsamples anything automatically; if you'd rather offer "resize and
/// continue" than reject outright, call `fitToLimits(_:)` explicitly and
/// pass its result to `save(_:id:)`.
public struct ICloudDriveImageAssetStore: Sendable {
    private let config: ICloudDriveSyncConfig
    private let imagesDirectoryProvider: @Sendable () -> URL?

    /// `ICloudDriveSyncError.messages` is shared, process-wide, static state
    /// (see its own doc comment) — normally set by `ICloudDriveSyncEngine.init`.
    /// Since this store is designed to work perfectly well with no engine in
    /// the picture at all, it sets the same static state itself, so a host
    /// using only image assets still gets its own `config.messages` copy in
    /// thrown errors instead of silently falling back to the English
    /// defaults. Harmless, and a no-op in the common case where a host
    /// constructs this with the exact same config it already gave the
    /// engine.
    public init(config: ICloudDriveSyncConfig) {
        self.config = config
        self.imagesDirectoryProvider = {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: config.containerIdentifier) else {
                return nil
            }
            return containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(config.backupDirectoryName, isDirectory: true)
                .appendingPathComponent(config.imageAssets.directoryName, isDirectory: true)
        }
        ICloudDriveSyncError.messages = config.messages
    }

    init(config: ICloudDriveSyncConfig, imagesDirectoryURL: @escaping @Sendable () -> URL?) {
        self.config = config
        self.imagesDirectoryProvider = imagesDirectoryURL
        ICloudDriveSyncError.messages = config.messages
    }

    // MARK: Validation

    /// Checks `data` against `config.imageAssets.maxFileSizeBytes` and
    /// `.maxLongEdgePixels` — the original, as-given bytes, before any
    /// normalization `save(_:id:)` might otherwise apply. Does nothing else
    /// (no write, no re-encode); call this the moment a person picks/captures
    /// an image so you can warn them immediately, independent of when/whether
    /// you actually call `save(_:id:)`.
    ///
    /// Throws `.imageFileTooLarge`, `.imageDimensionsTooLarge`, or
    /// `.imageDecodeFailed` (data isn't a recognizable image at all) — every
    /// case's `localizedDescription` is ready to show as-is.
    public func validate(_ data: Data) throws {
        let limitBytes = config.imageAssets.maxFileSizeBytes
        guard Int64(data.count) <= limitBytes else {
            throw ICloudDriveSyncError.imageFileTooLarge(sizeBytes: Int64(data.count), limitBytes: limitBytes)
        }
        guard let pixelSize = ICloudDriveImageInspector.pixelSize(of: data) else {
            throw ICloudDriveSyncError.imageDecodeFailed
        }
        let limitPixels = config.imageAssets.maxLongEdgePixels
        guard pixelSize.longEdge <= limitPixels else {
            throw ICloudDriveSyncError.imageDimensionsTooLarge(longEdgePixels: pixelSize.longEdge, limitPixels: limitPixels)
        }
    }

    /// Downsamples and/or re-compresses `data` until it satisfies both
    /// configured limits, instead of `validate(_:)`/`save(_:id:)` rejecting
    /// it outright. Opt-in — nothing in this type calls this automatically.
    /// Use it from your own "this photo is too large, resize it?" flow, then
    /// pass the result to `save(_:id:)` (which will pass `validate(_:)` this
    /// time and, since the result is already `preferredFormat`, write
    /// through without a second re-encode).
    ///
    /// Throws `.imageDecodeFailed` if `data` isn't decodable, or
    /// `.imageFileTooLarge` in the rare case a busy/noisy image is still over
    /// the byte-size limit even fully downsampled at the lowest quality step
    /// tried.
    public func fitToLimits(_ data: Data) throws -> Data {
        guard let pixelSize = ICloudDriveImageInspector.pixelSize(of: data) else {
            throw ICloudDriveSyncError.imageDecodeFailed
        }
        let maxPixels = config.imageAssets.maxLongEdgePixels
        let targetPixels = min(pixelSize.longEdge, maxPixels)
        guard let cgImage = ICloudDriveImageInspector.downsampledCGImage(from: data, maxPixelDimension: targetPixels) else {
            throw ICloudDriveSyncError.imageDecodeFailed
        }

        var quality = config.imageAssets.compressionQuality
        var lastEncoded: Data?
        // A handful of decreasing-quality passes covers the rare case where
        // even a correctly-downsampled image is still too many bytes (busy,
        // high-detail photos compress worse) — cheap, since each pass just
        // re-runs the lossy encoder over the same already-downsampled
        // `cgImage` rather than re-decoding anything.
        for _ in 0..<4 {
            guard let attempt = ICloudDriveImageInspector.encode(cgImage, format: config.imageAssets.preferredFormat, compressionQuality: quality) else {
                throw ICloudDriveSyncError.imageEncodeFailed
            }
            lastEncoded = attempt.data
            if Int64(attempt.data.count) <= config.imageAssets.maxFileSizeBytes {
                return attempt.data
            }
            quality *= 0.7
        }
        throw ICloudDriveSyncError.imageFileTooLarge(
            sizeBytes: Int64(lastEncoded?.count ?? 0),
            limitBytes: config.imageAssets.maxFileSizeBytes
        )
    }

    // MARK: Save / load / delete

    /// Validates, normalizes, and writes `data` to the ubiquity container,
    /// returning the id to store on your own model — `id` echoed back if you
    /// supplied one (useful for the same `/`-partitioned-by-category
    /// convention `ICloudDriveSyncDataSource` items use, e.g.
    /// `"diary/2024-01-01-abc123"`), otherwise a freshly generated UUID
    /// string.
    ///
    /// Throws whatever `validate(_:)` throws (this calls it first, so a
    /// too-large image is rejected here exactly the same way), plus
    /// `.iCloudUnavailable` if iCloud Drive isn't available right now and
    /// `.imageEncodeFailed` if normalization fails outright (extremely rare
    /// — see `ICloudDriveImageInspector.encode`).
    @discardableResult
    public func save(_ data: Data, id: String? = nil) async throws -> String {
        try validate(data)
        let normalized = try normalize(data)
        guard let directoryURL = imagesDirectoryURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }

        let resolvedID = id ?? UUID().uuidString
        let url = ICloudDriveFileIO.assetURL(for: resolvedID, extension: normalized.format.fileExtension, in: directoryURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ICloudDriveFileIO.coordinatedWriteData(normalized.data, to: url)
        return resolvedID
    }

    /// Downloads (if needed) and reads back the bytes `save(_:id:)` wrote for
    /// `id`. Waits for the file to actually be present locally the same way
    /// `ICloudDriveSyncEngine` waits on a backup download — pass
    /// `attemptLimit` to tune how long to wait (defaults to
    /// `config.downloadAttemptLimitWiFi`; use the shorter cellular limit,
    /// `config.downloadAttemptLimitCellular`, if you already know the device
    /// is on cellular).
    ///
    /// Throws `.imageNotFound` if there's no file for `id`,
    /// `.iCloudUnavailable` if iCloud Drive isn't available, or
    /// `.downloadFailed`/`.downloadTimedOut` if the file exists but couldn't
    /// be fetched.
    public func loadData(id: String, attemptLimit: Int? = nil) async throws -> Data {
        guard let directoryURL = imagesDirectoryURL() else {
            throw ICloudDriveSyncError.iCloudUnavailable
        }
        guard let url = resolveExistingURL(forID: id, in: directoryURL) else {
            throw ICloudDriveSyncError.imageNotFound
        }
        return try await ICloudDriveFileIO.downloadAndRead(
            at: url,
            attemptLimit: attemptLimit ?? config.downloadAttemptLimitWiFi,
            pollInterval: config.pollIntervalSeconds,
            onWaitingTick: {}
        )
    }

    /// Removes the file for `id`, if any. Silently does nothing if `id` has
    /// no file (already deleted, or never saved) or iCloud Drive isn't
    /// available right now — deleting is always best-effort cleanup, never
    /// something worth failing a host's own delete flow over.
    public func deleteImage(id: String) {
        guard let directoryURL = imagesDirectoryURL(),
              let url = resolveExistingURL(forID: id, in: directoryURL) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every image id currently stored, discovered by walking the images
    /// folder on disk — there's no manifest for images the way there is for
    /// Data items, so this is what a host uses for its own orphan cleanup
    /// (e.g. deleting images whose owning note no longer references them).
    /// Returns an empty set if iCloud Drive isn't available right now rather
    /// than throwing, since "nothing to clean up yet" and "couldn't check"
    /// are both safe to treat the same way for a cleanup pass.
    public func allImageIDs() -> Set<String> {
        guard let directoryURL = imagesDirectoryURL(),
              let enumerator = FileManager.default.enumerator(
                  at: directoryURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var ids = Set<String>()
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relativeComponents = relativePathComponents(for: fileURL.deletingPathExtension(), under: directoryURL)
            let id = relativeComponents
                .map { $0.removingPercentEncoding ?? String($0) }
                .joined(separator: "/")
            guard !id.isEmpty else { continue }
            ids.insert(id)
        }
        return ids
    }

    private func relativePathComponents(for fileURL: URL, under directoryURL: URL) -> [String] {
        let baseComponents = directoryURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let fileComponents = fileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
              Array(fileComponents.prefix(baseComponents.count)) == baseComponents else {
            return Array(fileURL.deletingPathExtension().lastPathComponent.split(separator: "/").map(String.init))
        }
        return Array(fileComponents.dropFirst(baseComponents.count))
    }

    // MARK: Normalization

    /// Write-through if `data` is already `preferredFormat` (already
    /// confirmed within limits by `validate(_:)`, called just before this by
    /// every caller) — re-encoding an image that's already the right format
    /// would only cost a lossy generation for no benefit. Otherwise decodes
    /// and re-encodes to `preferredFormat`, capped at `maxLongEdgePixels`
    /// (a no-op ceiling here in practice, since `validate(_:)` already
    /// confirmed the image is within that limit — this just gives
    /// `CGImageSourceCreateThumbnailAtIndex` a size to decode at).
    private func normalize(_ data: Data) throws -> (data: Data, format: ICloudDriveImageFormat) {
        let preferredFormat = config.imageAssets.preferredFormat
        if ICloudDriveImageInspector.utType(of: data) == preferredFormat.utType {
            return (data, preferredFormat)
        }
        guard let cgImage = ICloudDriveImageInspector.downsampledCGImage(
            from: data,
            maxPixelDimension: config.imageAssets.maxLongEdgePixels
        ) else {
            throw ICloudDriveSyncError.imageDecodeFailed
        }
        guard let encoded = ICloudDriveImageInspector.encode(
            cgImage,
            format: preferredFormat,
            compressionQuality: config.imageAssets.compressionQuality
        ) else {
            throw ICloudDriveSyncError.imageEncodeFailed
        }
        return encoded
    }

    // MARK: URLs

    private func imagesDirectoryURL() -> URL? {
        imagesDirectoryProvider()
    }

    /// Resolves `id` to its actual on-disk URL. Tries the fast path first —
    /// `config.imageAssets.preferredFormat`'s extension, no directory
    /// listing — which is correct for every image `save(_:id:)` ever wrote
    /// under the current config. Falls back to scanning the id's parent
    /// folder for a same-stem file under a different extension only if that
    /// fails, which only ever happens if `preferredFormat` was changed after
    /// some images were already saved under the old one, or a HEIC encode
    /// silently fell back to JPEG for a specific image (see
    /// `ICloudDriveImageInspector.encode`) — both rare, both still handled
    /// correctly rather than reporting a false "not found."
    private func resolveExistingURL(forID id: String, in directoryURL: URL) -> URL? {
        let fastPathURL = ICloudDriveFileIO.assetURL(for: id, extension: config.imageAssets.preferredFormat.fileExtension, in: directoryURL)
        if FileManager.default.fileExists(atPath: fastPathURL.path) {
            return fastPathURL
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let components = id.split(separator: "/", omittingEmptySubsequences: true)
        guard let lastComponent = components.last else { return nil }

        var parentURL = directoryURL
        for component in components.dropLast() {
            let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(component)
            parentURL = parentURL.appendingPathComponent(encoded, isDirectory: true)
        }
        let stem = lastComponent.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(lastComponent)

        guard let entries = try? FileManager.default.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first { $0.deletingPathExtension().lastPathComponent == stem }
    }
}
