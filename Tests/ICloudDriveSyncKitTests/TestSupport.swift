import Foundation
@testable import ICloudDriveSyncKit

/// A thread-safe in-memory stand-in for the ubiquity container. Every
/// upload/restore/conflict test in this target builds its `IOPrimitives`
/// from one of these instead of touching real iCloud — this is exactly what
/// `ICloudDriveSyncWorker`'s own doc comment calls out as the point of
/// splitting the write/download/delete/byteCount primitives out into
/// injectable closures in the first place: "a test can construct an
/// in-memory `IOPrimitives`... and exercise the exact same upload/restore
/// ordering... with no iCloud account, no `NSFileCoordinator`, and no
/// simulator involved."
///
/// One important wrinkle this store does *not* paper over (deliberately —
/// see each test file's own comments): several Worker methods
/// (`readBackup`, `readBackupItems`/`downloadOneItem`, `detectConflicts`)
/// check `FileManager.default.fileExists(atPath:)` directly against real
/// disk *before* ever calling `io.download`, to distinguish "not
/// downloaded from iCloud yet" from "genuinely missing." Seeding this store
/// alone is not enough to make those methods take the "found it" path — a
/// real (content-irrelevant) placeholder file has to exist on disk too. See
/// `TempDirectory` below.
actor InMemoryCloudStore {
    private(set) var files: [URL: Data] = [:]
    private(set) var writeCalls: [URL] = []
    private(set) var downloadCalls: [URL] = []
    private(set) var deleteCalls: [URL] = []

    private var writeFailures: Set<URL> = []
    private var downloadFailureErrors: [URL: Error] = [:]
    private var deleteFailures: Set<URL> = []

    func write(_ data: Data, to url: URL) throws {
        writeCalls.append(url)
        if writeFailures.contains(url) {
            throw TestFailure.simulatedWriteFailure
        }
        files[url] = data
    }

    func download(_ url: URL) throws -> Data {
        downloadCalls.append(url)
        if let error = downloadFailureErrors[url] {
            throw error
        }
        guard let data = files[url] else {
            throw TestFailure.notFound
        }
        return data
    }

    func delete(_ url: URL) throws {
        deleteCalls.append(url)
        if deleteFailures.contains(url) {
            throw TestFailure.simulatedDeleteFailure
        }
        files.removeValue(forKey: url)
        files = files.filter { !$0.key.path.hasPrefix(url.path + "/") }
    }

    func byteCount(_ url: URL) -> Int64? {
        files[url].map { Int64($0.count) }
    }

    func seed(_ url: URL, _ data: Data) {
        files[url] = data
    }

    func setWriteFailure(_ url: URL) {
        writeFailures.insert(url)
    }

    func setDownloadFailure(_ url: URL, error: Error) {
        downloadFailureErrors[url] = error
    }

    func setDeleteFailure(_ url: URL) {
        deleteFailures.insert(url)
    }

    func writeCallCount() -> Int { writeCalls.count }
    func deleteCallCount() -> Int { deleteCalls.count }
    func downloadCallCount() -> Int { downloadCalls.count }
    func file(at url: URL) -> Data? { files[url] }
    func allFiles() -> [URL: Data] { files }

    /// `IOPrimitives`' four closures, wired to this store. `nonisolated`
    /// because building the closures themselves doesn't touch any
    /// actor-isolated state (only *calling* them later does, and each one
    /// `await`s into the actor at that point) — this lets a test read
    /// `store.ioPrimitives` synchronously instead of needing `await` just to
    /// assemble it.
    nonisolated var ioPrimitives: ICloudDriveSyncWorker.IOPrimitives {
        ICloudDriveSyncWorker.IOPrimitives(
            write: { data, url in try await self.write(data, to: url) },
            download: { url in try await self.download(url) },
            delete: { url in try await self.delete(url) },
            byteCount: { url in await self.byteCount(url) }
        )
    }
}

enum TestFailure: Error {
    case notFound
    case simulatedWriteFailure
    case simulatedDeleteFailure
}

/// A scratch directory on real disk, removed automatically when the owning
/// test tears it down. Needed by any test that exercises
/// `ICloudDriveFileIO.coordinatedListFiles(under:)` (walks a real
/// directory), the `FileManager.fileExists` checks described on
/// `InMemoryCloudStore` above, or `uploadData`'s write pass (which calls
/// `FileManager.createDirectory` for real, even when the actual byte write
/// underneath it is mocked).
///
/// Resolves symlinks in the base temp directory up front — on macOS,
/// `FileManager.default.temporaryDirectory` commonly lives under a `/var`
/// path that's itself a symlink into `/private/var`. Resolving once here,
/// rather than letting some URLs in a test be built from the symlinked form
/// and others (e.g. anything `FileManager`'s directory enumerator hands
/// back) end up in the resolved form, avoids two URLs that point at the
/// same real file failing a `Set`/`==` comparison purely because of string
/// representation.
final class TempDirectory {
    let url: URL

    init() {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appendingPathComponent("ICloudDriveSyncKitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Holds a `Task` so an `IOPrimitives` closure running *inside* that same
/// task can cancel it once some condition is met (e.g. "the 3rd item just
/// finished") — used by every cancellation test in this target instead of
/// the more obvious `let task = Task { ... }; task.cancel()`, which races:
/// the child task can start running (and in principle sail past every
/// `Task.checkCancellation()`) before the very next line even executes.
/// Assigning into this box *after* creating the task, and having the
/// closure retry on every call until the box is populated (`>=`, not `==`,
/// at each call site), removes that race — and using `task?.cancel()`
/// rather than a force-unwrap means an attempt that lands before the box is
/// populated just silently no-ops instead of crashing, relying on the next
/// call to actually cancel.
final class TaskCancelBox<Success> {
    var task: Task<Success, Error>?

    func cancelIfPresent() {
        task?.cancel()
    }
}
