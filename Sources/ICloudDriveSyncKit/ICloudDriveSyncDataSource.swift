import Foundation

/// The one seam between this package and a host app's own model types. The
/// engine never knows what a "note" or a "task" or a "workout" is — it only
/// ever moves `Data` (JSON, in practice) that the host hands it or hands
/// back. Implement this once per app; nothing else in the package changes.
///
/// A typical conformer is the app's existing data store/`ObservableObject`
/// (see the migration README for a full example). Marked `@MainActor` to
/// match `ICloudDriveSyncEngine` itself — the engine calls these
/// synchronously, and a typical SwiftUI `ObservableObject` store is already
/// `@MainActor` anyway, so this keeps a conforming type's implementation
/// simple (no `nonisolated`/`await` gymnastics needed just to satisfy the
/// protocol).
///
/// ## Two lanes: Data and Preferences
///
/// What a host syncs splits into two lanes with very different shapes and
/// change patterns, and the protocol keeps them separate on purpose:
///
/// - **Data** — the app's actual content (notes, tasks, workouts, whatever
///   the app is *for*). Usually large, usually numerous, usually changes one
///   record at a time. The `...Data` methods below are partitioned by item
///   id so a single edit only ever re-uploads that one item, never the whole
///   collection — see `exportData(changedItemIDs:deletedItemIDs:)`.
/// - **Preferences** — the app's own settings (theme, defaults, feature
///   flags, ...). Usually small, usually one blob, and — critically —
///   *independent of Data*. Toggling a preference shouldn't touch a single
///   item file, and a large Data export shouldn't need to know or care what
///   the current theme is. The `...Preferences` methods below are a totally
///   separate, always-whole-file export/restore pair for exactly this
///   reason. Keep this blob small; it's rewritten in full every time
///   preferences sync (that's fine — it's supposed to be cheap).
///
/// Getting this split right is most of what makes a host app's sync
/// efficient. See the README's "Designing your Data/Preferences split"
/// section before implementing this protocol.
@MainActor
public protocol ICloudDriveSyncDataSource: AnyObject {
    // MARK: Data

    /// Whether the host already has *any* local Data. The engine uses this
    /// to decide whether a cold launch should attempt a first-run restore
    /// before anything else (a fresh install has none; a normal relaunch
    /// does). Preferences don't factor into this — a host that somehow has
    /// preferences but no data should still return `false` here.
    func hasLocalData() -> Bool

    /// Every Data item id the host currently has, whether or not it changed
    /// recently. Written into the backup's manifest on every export so a
    /// later restore knows the complete roster of item files to fetch —
    /// independent of which individual files a given export actually
    /// rewrote.
    ///
    /// If you want items organized into folders in iCloud Drive (by
    /// category, by year, by whatever makes sense for your app — see the
    /// README), encode that directly into the id: an id like
    /// `"diary/2024-01-01-abc123"` is stored at `Items/diary/2024-01-01-abc123.json`
    /// automatically. A plain id with no `/` is stored as a flat file,
    /// exactly as if you'd never read this paragraph.
    func allDataItemIDs() -> Set<String>

    /// Build the payload for a Data export.
    ///
    /// - `changedItemIDs`: item ids the engine believes changed since the
    ///   last successful export (from your `notifyDataChanged` calls). `nil`
    ///   means "this is a full export" — hand back every item.
    /// - `deletedItemIDs`: item ids that were deleted locally and should be
    ///   removed from the iCloud copy. Always concrete (never `nil`), may be
    ///   empty.
    /// - Returns: `manifest` — one small JSON blob for whatever structural
    ///   information isn't per-item (categories, an index/metadata list,
    ///   whatever your restore needs to make sense of the item files — your
    ///   call what goes in here, but keep it an *index*, not the content
    ///   itself, or you lose the whole point of per-item export). `items` —
    ///   one JSON `Data` value per item id the engine asked about via
    ///   `changedItemIDs` (or, for a full export, every item you have). Each
    ///   is written to its own file in iCloud Drive, so large collections
    ///   only ever re-upload what actually changed. `modifiedAt` — that same
    ///   item's own last-modified time, from your model (a `lastModified`/
    ///   `updatedAt` field you already track, or `Date()` at export time if
    ///   you don't). Powers `ICloudDriveSyncConfig.conflictPolicy` — an id
    ///   with no entry here is simply never conflict-checked, so this can be
    ///   partial (or empty, on a host that doesn't sync from more than one
    ///   device per account and doesn't need conflict detection at all) but
    ///   every id you *do* include should be genuinely accurate: this is the
    ///   only signal the engine has for "did someone else change this since
    ///   I last knew about it."
    ///
    /// Do **not** put app settings/preferences in `manifest` — that's what
    /// `exportPreferences()` is for. Mixing the two means a settings-only
    /// change forces a full Data re-sync (or, worse, a Data change silently
    /// carries along stale settings) — exactly the coupling this split
    /// exists to avoid.
    func exportData(
        changedItemIDs: Set<String>?,
        deletedItemIDs: Set<String>
    ) -> (manifest: Data, items: [String: Data], modifiedAt: [String: Date])

    /// Optional metadata for the host app's own Data schema. The engine
    /// stores this in its backup envelope, outside the opaque host manifest
    /// and item JSON, so future app versions can inspect what they're about
    /// to restore before decoding/migrating it.
    ///
    /// Return `nil` if your app does not version its backup schema yet. A
    /// robust host should return at least `dataSchemaVersion` once it has
    /// shipped a restore path, then use `validateRestoredHostSchemaMetadata`
    /// and `applyRestoredData` to migrate older versions.
    func hostSchemaMetadata() -> ICloudDriveHostSchemaMetadata?

    /// Apply a Data payload just downloaded from iCloud. Called after a
    /// manual restore, an automatic first-run restore, or an automatic-sync
    /// fallback restore (when auto-sync notices there's no local data yet).
    /// Throw to fail the restore — your error's `localizedDescription`
    /// becomes the engine's `syncMessage`.
    ///
    /// `items` contains every item file found in the backup's items folder,
    /// keyed by the same ids you used when exporting. A single stuck/corrupt
    /// item in iCloud doesn't fail the whole restore — the engine skips it
    /// and hands you everything else it *could* download, so `items` may
    /// occasionally be missing an id `allDataItemIDs()` would otherwise
    /// report; handle that as "this one item didn't come back" rather than
    /// throwing.
    func applyRestoredData(manifest: Data, items: [String: Data]) throws

    /// Called after the engine reads the backup envelope, before it calls
    /// `applyRestoredData`. Use this to reject an unsupported host schema
    /// version with a clear error before any destructive local restore work
    /// begins. The default accepts everything, including older backups that
    /// do not have host schema metadata yet.
    func validateRestoredHostSchemaMetadata(_ metadata: ICloudDriveHostSchemaMetadata?) throws

    // MARK: Preferences

    /// Export the app's current preferences/settings as a single opaque
    /// blob. Called far more cheaply than `exportData` — this file is
    /// rewritten in full every time preferences sync, so keep whatever you
    /// return here small (this is not the place for anything that grows
    /// with the user's data).
    func exportPreferences() -> Data

    /// Apply preferences just downloaded from iCloud. Throw to fail —
    /// your error's `localizedDescription` becomes the engine's
    /// `syncMessage`. A Preferences restore failure never blocks or fails a
    /// Data restore (or vice versa); the two are restored independently.
    func applyRestoredPreferences(_ data: Data) throws
}

public extension ICloudDriveSyncDataSource {
    func hostSchemaMetadata() -> ICloudDriveHostSchemaMetadata? {
        nil
    }

    func validateRestoredHostSchemaMetadata(_ metadata: ICloudDriveHostSchemaMetadata?) throws {}
}
