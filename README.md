# ICloudDriveSyncKit

A drop-in, app-agnostic engine for backing arbitrary app data up to (and
restoring it from) a folder in the user's iCloud Drive ubiquity container —
no CloudKit record schema, just JSON files. It's the iCloud sync design
originally built for **Timeline - Daily Notes**, pulled out so it can be
carried into other projects without re-solving the same problem: manual vs.
automatic sync, Wi-Fi/cellular-aware retry and messaging, a "large backup"
warning, the first-launch "restore before showing anything" flow, and —
covered in depth below — keeping a sync efficient as an app's data grows.

**What moves between projects unmodified:** the core `ICloudDriveSyncKit`
product, plus the optional `ICloudDriveSyncKitUI` product if you want the
ready-made SwiftUI settings section. **What you write per project:** one
small JSON config file, and a handful of functions on your existing data
store (the `ICloudDriveSyncDataSource` protocol).

## Adding this to a project

1. In Xcode: **File → Add Package Dependencies… → Add Local…**, then pick
   this folder (`ICloudDriveSyncKit/`). Add `ICloudDriveSyncKit` to your app
   target. Add `ICloudDriveSyncKitUI` too if you want the built-in SwiftUI
   settings section.
   *(This one step has to happen in Xcode — nothing here can do it for you.)*
2. Make sure your target's entitlements already grant an iCloud container —
   this package doesn't add capabilities, it just uses one you've already
   set up:
   ```xml
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array><string>iCloud.com.yourcompany.yourapp</string></array>
   <key>com.apple.developer.icloud-services</key>
   <array><string>CloudDocuments</string></array>
   <key>com.apple.developer.ubiquity-container-identifiers</key>
   <array><string>iCloud.com.yourcompany.yourapp</string></array>
   ```
3. Add a JSON config file to your app target (see below), implement the
   `ICloudDriveSyncDataSource` protocol on your store, and wire up the
   engine — all in the next sections.

### Flutter / hybrid app hosts

Flutter, React Native, Capacitor, and similar hosts cannot import a Swift
package directly from Dart/JavaScript. Add `ICloudDriveSyncKit` to the iOS
or macOS native target, then expose the operations you need through that
framework's native bridge (`MethodChannel`, native module, plugin method,
etc.).

For bridge-based hosts that already serialize their app state outside
Swift, use `ICloudDriveSyncPayloadDataSource` instead of writing a custom
Swift store conformance:

```swift
import ICloudDriveSyncKit

final class CloudSyncBridge {
    let payloadStore: ICloudDriveSyncPayloadDataSource
    let engine: ICloudDriveSyncEngine

    init() throws {
        payloadStore = try ICloudDriveSyncPayloadDataSource(appName: "MyHybridAppCloudPayload")
        engine = ICloudDriveSyncEngine(config: ICloudDriveSyncConfig())
        engine.dataSource = payloadStore
        engine.start()
    }

    func replacePayloadFromBridge(manifest: Data, items: [String: Data]) throws {
        try payloadStore.replaceData(manifest: manifest, items: items)
        engine.notifyDataChanged(changedItemIDs: Set(items.keys))
    }

    func currentPayloadForBridge() throws -> ICloudDriveSyncPayload {
        try payloadStore.currentPayload()
    }
}
```

The bridge layer is still responsible for turning Dart/JavaScript objects
into `Data` and back. The kit stays framework-agnostic: it stores the raw
payload durably, exports it through the normal engine, and writes restored
payload bytes back for the bridge to import.

## Designing your Data/Preferences split

Read this section before writing any code. Getting this split right up
front is most of what makes a sync efficient — retrofitting it later means
re-touching every mutation call site in your app.

Everything a host app syncs falls into one of two lanes, and the protocol
keeps them structurally separate:

- **Data** — the app's actual content: notes, tasks, workouts, receipts,
  whatever the app is *for*. Usually the large, numerous, ever-growing part
  of an app's state. Data is partitioned **per item** — each item is its own
  JSON file in iCloud Drive — so a single edit re-uploads one small file,
  never the whole collection.
- **Preferences** — the app's own settings: theme, defaults, feature flags,
  onboarding flags, anything that's small and shaped nothing like Data.
  Preferences is always a **single whole-file blob**, synced completely
  independently of Data. Toggling a setting never touches a single Data item
  file, and a Data sync never has to know or care what today's theme is.

Put a value in the wrong lane and you lose exactly the efficiency this
package exists to provide: settings inside the Data manifest means every
settings change triggers a manifest re-export (cheap, but still coupling two
unrelated concerns); Data-shaped content treated as a "preference" means a
whole collection gets rewritten as one blob on every change, which is the
single-file-backup problem this design is meant to avoid in the first place.

**Rule of thumb:** if the user has one of it (the current theme, the current
default category, a feature flag), it's Preferences. If the user has *many*
of it, and creates/edits/deletes them individually over time (notes, tasks,
entries, records), it's Data, and each one is its own item.

### Category-based (or deeper) item partitioning

Within the Data lane, an item id containing `/` is stored in a matching
subfolder automatically — no extra API, just a naming convention:

| Item id                          | Stored at                                    |
|-----------------------------------|-----------------------------------------------|
| `"note-abc123"`                   | `Items/note-abc123.json` (flat, as always)     |
| `"diary/2024-01-01-abc123"`       | `Items/diary/2024-01-01-abc123.json`           |
| `"diary/2024/01-abc123"`          | `Items/diary/2024/01-abc123.json`              |

This is entirely optional and entirely up to how you build your ids — the
engine and `ICloudDriveFileIO` don't know what a "category" is, they just
split on `/`. A few ways apps have used this:

- **By category** (the common case): `"\(category)/\(itemID)"` — every
  category gets its own folder in iCloud Drive, so browsing the raw backup
  is legible, and (more importantly) a rename/delete/bulk-edit confined to
  one category never touches another category's files on disk.
- **By category, then by time**: `"\(category)/\(year)/\(itemID)"` — useful
  once a single category alone gets large enough that one flat folder of
  thousands of files becomes unwieldy.
- **Flat** (no `/` at all) — perfectly fine for small collections, or a
  first pass before deciding partitioning is worth it. Nothing else in this
  package requires it, and switching a flat id scheme to a partitioned one
  later is non-breaking (see below).

**This is non-breaking, both ways.** An id's shape only affects where its
*own* file lives — it's not a schema migration. Existing flat-id items keep
working exactly as before if you never adopt this; new items can start using
`/`-partitioned ids going forward without touching anything already synced,
because every item is independent. TimeNote's own adoption (see
`TimeNoteStore.noteId(category:date:)`) is exactly this: newly created or
newly-renamed-category notes get partitioned ids, already-existing notes
keep their old flat ids indefinitely, and both forms are read back
identically since nothing else in the app parses a note id's structure.

## 1. The config JSON

Add a file like `ICloudSyncConfig.json` to your app target (target
membership matters — it has to ship in the app bundle):

```json
{
  "containerIdentifier": null,
  "appName": "My App",
  "backupDirectoryName": "MyApp",
  "backupFileName": "Backup.json",
  "manifestFileName": "Manifest.json",
  "itemsDirectoryName": "Items",
  "preferencesFileName": "Preferences.json",
  "largeBackupThresholdBytes": 10485760,
  "defaultAutoSyncMode": "always",
  "userDefaultsKeyPrefix": "icloudDriveSync_",
  "messages": {
    "iCloudDriveUnavailable": "iCloud Drive is not available."
  }
}
```

Every field is optional and falls back to a sane default (see
`ICloudDriveSyncConfig.swift` for the full list and every message string) —
a project can start with just `{}` and override fields one at a time.
`containerIdentifier: null` means "use this app's default ubiquity
container," which is what you want unless your entitlements declare more
than one. `preferencesFileName` is the file, alongside `manifestFileName`,
that holds your Preferences lane's export — rewritten in full every time,
so keep whatever you put there small.

`messages` carries every piece of user-facing copy the engine can show —
override only what you want reworded/localized; everything else keeps its
English default.

## 2. Implement `ICloudDriveSyncDataSource`

The engine never sees your model types — it only ever moves `Data` (JSON)
you hand it, on two independent lanes. Conform your existing store to the
protocol:

```swift
import ICloudDriveSyncKit

extension MyStore: ICloudDriveSyncDataSource {
    // MARK: Data

    func hasLocalData() -> Bool {
        !items.isEmpty || hasLoadedAnything
    }

    func allDataItemIDs() -> Set<String> {
        // `category/id` here is what actually gives you the per-category
        // folder partitioning described above — plain `id` works too if you
        // don't want that.
        Set(items.map { "\($0.category)/\($0.id)" })
    }

    func exportData(
        changedItemIDs: Set<String>?,
        deletedItemIDs: Set<String>
    ) -> (manifest: Data, items: [String: Data], modifiedAt: [String: Date]) {
        let idsToExport = changedItemIDs ?? allDataItemIDs()
        let itemsByCloudID = Dictionary(uniqueKeysWithValues: items.map { ("\($0.category)/\($0.id)", $0) })

        var itemsData: [String: Data] = [:]
        var modifiedAt: [String: Date] = [:]
        for id in idsToExport {
            guard let item = itemsByCloudID[id] else { continue }
            itemsData[id] = try? encoder.encode(item)
            modifiedAt[id] = item.updatedAt
        }

        // Whatever isn't per-item — categories, a lightweight item index —
        // goes in the manifest. It's opaque to the engine. No settings here:
        // that's the Preferences lane's job, below.
        let manifest = try! encoder.encode(MyBackupManifest(categories: categories))
        return (manifest, itemsData, modifiedAt)
    }

    func hostSchemaMetadata() -> ICloudDriveHostSchemaMetadata? {
        ICloudDriveHostSchemaMetadata(
            dataSchemaVersion: 2,
            minimumSupportedDataSchemaVersion: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    func validateRestoredHostSchemaMetadata(_ metadata: ICloudDriveHostSchemaMetadata?) throws {
        guard let metadata else { return } // legacy backup; migrate in `applyRestoredData`
        guard metadata.dataSchemaVersion <= 2 else {
            throw MyRestoreError.backupFromNewerUnsupportedVersion
        }
    }

    func applyRestoredData(manifest: Data, items: [String: Data]) throws {
        let decodedManifest = try decoder.decode(MyBackupManifest.self, from: manifest)
        // Values only — a restored item's own `id`/`category` fields (not
        // the dictionary's cloud-partitioning key) are what you use to
        // reconstruct it locally.
        let decodedItems = try items.values.map { try decoder.decode(MyItem.self, from: $0) }
        self.items = decodedItems
        self.categories = decodedManifest.categories
    }

    // MARK: Preferences

    func exportPreferences() -> Data {
        (try? encoder.encode(settings)) ?? Data()
    }

    func applyRestoredPreferences(_ data: Data) throws {
        settings = try decoder.decode(MySettings.self, from: data)
    }
}
```

## 3. Wire up the engine

Typically owned by the same object that conforms to the protocol above:

```swift
@MainActor
final class MyStore: ObservableObject {
    let cloudSync: ICloudDriveSyncEngine

    init() {
        load() // populate `items`/`settings` etc. from local disk first

        let config = (try? ICloudDriveSyncConfig.load(resource: "ICloudSyncConfig"))
            ?? ICloudDriveSyncConfig()
        cloudSync = ICloudDriveSyncEngine(config: config)
        cloudSync.dataSource = self   // `self` fully initialized by now
        cloudSync.onEvent = { name, data in MyAnalytics.shared.track(name, data: data) }
        cloudSync.start()
    }

    // MARK: Data mutations — notify the Data lane, and only the Data lane.

    func saveItem(_ item: MyItem) {
        // ...update `items`, persist locally...
        cloudSync.notifyDataChanged(changedItemIDs: ["\(item.category)/\(item.id)"])
    }

    func deleteItem(_ item: MyItem) {
        // ...remove from `items`, persist locally...
        cloudSync.notifyDataChanged(deletedItemIDs: ["\(item.category)/\(item.id)"])
    }

    // MARK: Preferences mutations — notify the Preferences lane, and only
    // the Preferences lane. This is the one that's easy to forget: a
    // settings screen that mutates `settings` directly and never calls
    // this will silently never sync those changes to iCloud at all.

    func saveSettings() {
        // ...persist locally...
        cloudSync.notifyPreferencesChanged()
    }
}
```

**Don't conflate the two.** A single generic `save()` that notifies both
lanes on every call (because it's easier than threading two call paths
through the app) defeats the whole point of the split — every settings
toggle would also re-export the Data manifest, and vice versa. Give
Data-affecting mutations and Preferences-affecting mutations their own
notify call, even if that means two small store methods instead of one.

Call sites elsewhere in the app:

```swift
// At launch, and again on every foreground transition:
.task { await store.cloudSync.runStartupRestoreCheckIfNeeded() }
.onChange(of: scenePhase) { phase in
    if phase == .active {
        Task { await store.cloudSync.runStartupRestoreCheckIfNeeded() }
    } else if phase == .background {
        store.cloudSync.flushPendingChangesNow()
        store.cloudSync.scheduleBackgroundSync()
    }
}

// Full-screen "restoring…" overlay:
if store.cloudSync.isInitialRestoreBlocking {
    ICloudDriveInitialRestoreOverlay(engine: store.cloudSync)
}

// Structured progress for custom UIs:
if store.cloudSync.syncProgress.isActive {
    let progress = store.cloudSync.syncProgress
    let phase = progress.phase
    let percent = progress.percentCompleted
    let completed = progress.completedUnitCount
    let total = progress.totalUnitCount
    let currentItemID = progress.currentItemID
}

// Large-backup / cellular-restore alerts — `syncMessage`,
// `restoreWarningMessage`, `showLargeBackupWarning`, `hasUnrestoredBackup`,
// `dismissLargeBackupWarning()`, `dismissRestoreWarning()` are all
// `@Published`/plain methods on the engine, bind to them same as any other
// ObservableObject.
```

### Background sync on iOS

The core engine can register a `BGAppRefreshTask` to let iOS wake the app
opportunistically and upload pending changes. The host app still owns the
platform setup:

```swift
cloudSync.registerBackgroundSyncTask(identifier: "com.yourcompany.yourapp.icloud-sync")
```

Add the same identifier to `BGTaskSchedulerPermittedIdentifiers` in the app's
Info.plist. If your app uses Background Modes, enable app refresh/fetch too.
This is best-effort scheduling: iOS decides when the task actually runs.

## 4. Embed the ready-made settings section

```swift
import ICloudDriveSyncKitUI

ICloudDriveSyncSettingsSection(
    engine: store.cloudSync,
    style: ICloudDriveSyncSectionStyle(
        accentColor: Color.tnAccent,
        cardBackground: { content in
            AnyView(content.padding(15).tnCard())   // match your app's card look
        }
    )
)
```

Everything else — the toggle, manual Back Up/Restore buttons (which only
appear when relevant), loading states, confirmation alerts, last-sync/storage
info — is handled internally. No extra `@State` needed in your settings
screen.

### Delete backup (optional)

Off by default — pass `showDeleteBackupOption: true` to add a destructive
Delete Backup button directly below Back Up/Restore (so it only ever appears
alongside them — manual-sync mode, or an unrestored-backup state) that wipes
**everything** this app has backed up to iCloud (envelope, manifest,
Preferences file, `Items/`, and `Images/` if you also adopted
`ICloudDriveImageAssetStore`, since it all lives under the same
`backupDirectoryName` folder):

```swift
ICloudDriveSyncSettingsSection(
    engine: store.cloudSync,
    style: ...,
    showDeleteBackupOption: true
)
```

Tapping it shows the kit's own confirmation alert first — the section
handles this exactly like it already handles Restore's "any unsaved data can
get lost" warning, so nothing extra is needed on your end. The alert's
message (`config.messages.deleteBackupConfirmationMessage`, default: *"This
can't be undone. Your iCloud backup will be permanently deleted."*) makes the
"can't be undone" part explicit; reword it in your config's `messages` block
if you want different copy, but keep that warning in whatever you write.

This only ever deletes the iCloud copy — local data on the device is never
touched, so the person keeps whatever they had locally and a later edit still
syncs normally afterward (as a fresh full backup, since the old one is gone).
The section's own "Last Sync"/"iCloud Storage" info row reflects the delete
immediately — `lastSyncAt` goes back to `neverSyncedLabel` ("Never" by
default) and `backupByteCount` back to `0` (shown as `noBackupLabel`, "No
backup" by default), the same way they'd read on a fresh install that's never
backed up at all.

Building a custom delete-confirmation UI instead of the ready-made section?
Call `await engine.deleteBackupManually()` directly — it does **not** show
any alert itself, so confirm with the person first.

## 5. Snapshot backups (optional)

The normal engine path is still one authoritative "current" backup. Auto
sync and `syncManually()` keep using that exact current backup and never
create backup history on their own.

If a host app wants backup history, migration safety points, or a "restore
an older copy" UI, it can opt into snapshot backups separately:

```swift
let descriptor = try await engine.createSnapshotBackup(label: "Before migration")
let backups = try await engine.listSnapshotBackups()
let report = try await engine.restoreSnapshotBackup(id: descriptor.id)
try await engine.deleteSnapshotBackup(id: descriptor.id)
```

Snapshots live under the same `backupDirectoryName`, but in their own
`Snapshots/<backupID>/` folder, with their own envelope, manifest, items,
and preferences file. Restoring a snapshot applies that snapshot locally but
does **not** overwrite or delete the current backup; your host decides if
the restored state should later be pushed to the current backup by following
its usual change-notification/sync flow.

`listSnapshotBackups()` returns `ICloudDriveBackupDescriptor` values with
safe display metadata: label, exported date, app version/build, host schema
metadata, item count, byte count when available, and device id. The kit
validates snapshot ids before restore/delete so path-like ids are rejected
before any iCloud file operation.

## 6. Image assets (optional)

`ICloudDriveImageAssetStore` stores images in the same ubiquity container as
the backup above — as discrete files, one per image, never as Base64 embedded
in JSON. It's fully independent of `ICloudDriveSyncEngine`: use one, the
other, or both. Nothing in TimeNote adopts this today; it exists in the kit
for the next project that needs it.

### Why not Base64

A Base64 string embedded in a JSON item inflates the bytes actually
transferred by roughly a third, defeats any partial/incremental sync (the
*whole* item file has to be rewritten and re-uploaded any time the image
changes, even if nothing else about that item did), and forces every read of
that JSON to hold the fully-decoded image in memory just to parse the rest of
the item. This is also what Apple's own ["Designing for Documents in
iCloud"](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)
guide recommends for structured metadata alongside large binary content:
store the binary as its own file and let iCloud's upload/download machinery
move it independently of everything else.

### The contract: an id, never bytes, in your own JSON

```swift
let images = ICloudDriveImageAssetStore(config: config)   // same config the engine uses

// Saving — store *only* the returned id on your own model, e.g. `var photoID: String?`
let photoID = try await images.save(pickedImageData)

// Reading back — call this wherever you need the actual bytes (displaying it, exporting it, ...)
let data = try await images.loadData(id: photoID)

// Deleting
images.deleteImage(id: photoID)
```

Your item's own JSON — and the Data lane's manifest/items it sits alongside —
never contain image bytes, only ever this id. Ids support the same
`/`-partitioned-by-category convention Data items do (`"diary/2024-01-01-abc123"`
→ its own subfolder), so you can pass one in explicitly if you want that;
otherwise a fresh UUID string is generated for you.

### Efficient by construction

- **Inspecting an image never decodes its bitmap.** Checking whether a
  multi-megabyte photo is too large reads only its ImageIO header/metadata.
- **Downsampling an oversized image never materializes the full-resolution
  bitmap either** — decoding happens straight to the target size via
  `CGImageSourceCreateThumbnailAtIndex`, the technique Apple demonstrates in
  WWDC 2018's "Image and Graphics Best Practices" for shrinking a
  picked/captured photo before storing or uploading it.
- **Every saved image is normalized to HEIC on disk** (configurable — see
  below), regardless of what format it arrived in. HEIC is Apple's own newer
  format and typically runs about half the size of an equivalent-quality
  JPEG (WWDC 2017, "Introducing HEIF and HEVC"). An image that's already
  HEIC and already within your configured limits is written through
  unchanged — no pointless re-encode.
- **Picking bytes on your side:** `PhotosUI`'s
  `PhotosPickerItem.loadTransferable(type: Data.self)` (iOS 16+) hands you a
  picked photo's original bytes directly, without your own code ever
  constructing a `UIImage` just to throw it away again. Pass that straight to
  `save(_:id:)`.

### Size/pixel limits: a warning, on your terms

**Apple does not publish a hard per-file size or pixel-dimension limit for
documents stored in an iCloud Drive ubiquity container** — only overall
account storage is capped, at whatever plan the person is on. What this
package enforces instead is its own conservative, entirely-overridable
default: **8 MB** per image and **4096px** on the longer edge. These aren't
an Apple mandate, just sane guardrails so one picked photo can't quietly
balloon someone's backup or eat their cellular data — override either in your
config's `imageAssets` block.

```swift
images.validate(pickedImageData)   // throws before you even attempt a save
```

Call `validate(_:)` the instant a person picks/captures an image, so you can
warn them immediately — it throws `ICloudDriveSyncError.imageFileTooLarge`
or `.imageDimensionsTooLarge`, each carrying the exact actual-vs-limit
numbers, with an `errorDescription` ready to show as-is (e.g. *"This image is
too large to back up. (12.4 MB, limit 8 MB)"*). `save(_:id:)` calls
`validate(_:)` first too, so a too-large image is rejected there the same
way even if you skip the standalone check.

Neither `validate(_:)` nor `save(_:id:)` downsamples anything automatically
— rejecting with a clear message is the default. If you'd rather offer
"resize and continue" than reject outright, call `fitToLimits(_:)` explicitly
and pass its result to `save(_:id:)`:

```swift
do {
    try images.validate(pickedImageData)
    let id = try await images.save(pickedImageData)
} catch let error as ICloudDriveSyncError {
    // Show error.localizedDescription, optionally offer to resize:
    let resized = try images.fitToLimits(pickedImageData)
    let id = try await images.save(resized)
}
```

### Config

All optional — add an `imageAssets` block to the same JSON config file from
step 1 only to override the defaults:

```json
{
  "imageAssets": {
    "directoryName": "Images",
    "preferredFormat": "heic",
    "compressionQuality": 0.8,
    "maxFileSizeBytes": 8388608,
    "maxLongEdgePixels": 4096
  }
}
```

`preferredFormat` is `"heic"` or `"jpeg"` — `ICloudDriveImageAssetStore`
falls back to JPEG automatically if HEIC encoding isn't available on-device
for a given image (rare — mainly older simulators), so `.jpeg` is really only
worth setting explicitly if you need every stored image to be readable by
tooling that can't decode HEIC at all.

### Cleanup

There's no manifest for images the way there is for Data items — call
`images.allImageIDs()` to enumerate every id currently stored (by walking the
`Images/` folder), and delete whichever ones your own local Data no longer
references, from whatever periodic/maintenance pass makes sense for your app.

## How a sync decides what to export

- **Manual** (`syncManually()` / the settings section's "Back Up" button)
  always exports **both** lanes, unconditionally — the person explicitly
  asked for a backup, so it should be complete regardless of what's
  "pending."
- **Automatic** (debounced, triggered by `notifyDataChanged`/
  `notifyPreferencesChanged`) exports **only** the lane(s) that actually have
  a pending change. A settings-only change auto-syncs as a single small
  `Preferences.json` rewrite; a note edit auto-syncs as one item file (plus
  a small manifest) — never both, never the whole collection, unless both
  genuinely changed.
- Restore is the mirror image: a Data restore (`applyRestoredData`) always
  runs when there's a backup to restore; a Preferences restore
  (`applyRestoredPreferences`) runs alongside it on a best-effort basis — a
  missing or unreadable `Preferences.json` (e.g. a backup written before an
  app adopted this lane) never fails or blocks the Data restore next to it.

## Deliberate trade-offs vs. a hand-rolled, single-app implementation

- **Auto-sync mode isn't carried inside the backup itself.** The engine
  persists it locally (`UserDefaults`, under your `userDefaultsKeyPrefix`)
  instead of inside the exported JSON, so the engine never needs to know
  about your settings type. Restoring onto a brand-new device won't carry
  over the previous auto-sync preference — it starts from
  `config.defaultAutoSyncMode` instead. Small, one-time UX difference; worth
  it for the engine to have zero dependency on your app's settings model.
- **One debounce, not two.** A local disk write and a cloud sync used to be
  debounced separately in the app this was pulled out of. Here,
  `notifyDataChanged`/`notifyPreferencesChanged` start a single
  `autoSyncDebounceSeconds` (default 2s) timer directly — simpler, and sync
  reads from your in-memory state anyway so it never depended on the local
  write finishing first.
- **`.wifi` auto-sync mode gates on "any network," not Wi-Fi specifically**,
  for *outgoing* auto-sync — see the comment on `autoSyncCanRun` in
  `ICloudDriveSyncEngine.swift`. The Wi-Fi-only guarantee applies to
  *restoring* a backup, not to sending one. Tighten this in your fork if
  your app wants `.wifi` mode to be stricter.
- **Preferences restore is best-effort by design, Data restore isn't.** A
  broken/missing Preferences file quietly falls back to whatever settings
  are already local; a broken/missing Data backup surfaces as a real
  failure (`restoreWarningMessage`). This asymmetry is intentional —
  settings have a reasonable local fallback (keep what's already there),
  content usually doesn't.

## No compiler in the loop

This package was written and reviewed without access to a Swift compiler or
Xcode. Before shipping, build the app, then exercise: fresh install first-run
restore, manual backup, manual restore, auto-sync in each mode (change a
setting only and confirm just `Preferences.json` gets rewritten; change an
item only and confirm just that item's file plus the manifest get rewritten),
the large-backup warning (temporarily lower `largeBackupThresholdBytes` to
trigger it easily), restoring while on cellular/Low Data Mode, and — if you
adopted `/`-partitioned item ids — that the resulting folder structure inside
the iCloud Drive container actually nests the way you expect (Files app →
Browse → iCloud Drive → your app's `backupDirectoryName` folder).

If you adopt `ICloudDriveImageAssetStore`, also exercise: saving a normal
photo (confirm it lands in `Images/` as `.heic` in Files app, and that its
file size is meaningfully smaller than the original), saving an image that
already exceeds `maxFileSizeBytes`/`maxLongEdgePixels` (confirm `validate(_:)`
throws with sensible actual-vs-limit numbers instead of silently succeeding
or crashing), `fitToLimits(_:)` on that same oversized image followed by
`save(_:id:)`, and `loadData(id:)` for an image that hasn't downloaded to
this device yet (airplane mode after a fresh install is the easiest way to
force that path).

If you enable `showDeleteBackupOption`, also exercise: the confirmation alert
actually appears and Cancel truly does nothing, a confirmed delete removes
the whole `backupDirectoryName` folder from Files app → Browse → iCloud
Drive (not just the envelope), local data is untouched afterward, and a
subsequent edit produces a fresh full backup rather than erroring or silently
no-op'ing.
