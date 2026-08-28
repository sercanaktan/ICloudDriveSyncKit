import XCTest
import Foundation
@testable import ICloudDriveSyncKit

/// `itemURL(for:in:)`/`assetURL(for:extension:in:)` are the one piece of
/// this package where a bug is silent and permanent: every read, write, and
/// delete in the whole kit — including the reconciliation sweep's orphan
/// detection — goes through this id-to-path mapping. Two different ids that
/// happen to resolve to the same URL would silently overwrite one item with
/// another on the very next export, with no error anywhere. These tests
/// exist to pin that mapping down.
final class ICloudDriveFileIOTests: XCTestCase {
    private let baseDirectory = URL(fileURLWithPath: "/tmp/icloud-drive-sync-kit-tests/items", isDirectory: true)

    func testFlatIDResolvesToASingleFileInTheItemsDirectory() {
        let url = ICloudDriveFileIO.itemURL(for: "abc123", in: baseDirectory)
        XCTAssertEqual(url, baseDirectory.appendingPathComponent("abc123.json"))
    }

    func testSlashInAnIDBecomesARealSubfolder() {
        let url = ICloudDriveFileIO.itemURL(for: "diary/2024-01-01-abc123", in: baseDirectory)
        let expected = baseDirectory
            .appendingPathComponent("diary", isDirectory: true)
            .appendingPathComponent("2024-01-01-abc123.json")
        XCTAssertEqual(url, expected)
    }

    func testMultipleSlashesNestSubfoldersInOrder() {
        let url = ICloudDriveFileIO.itemURL(for: "diary/2024/01-abc123", in: baseDirectory)
        let expected = baseDirectory
            .appendingPathComponent("diary", isDirectory: true)
            .appendingPathComponent("2024", isDirectory: true)
            .appendingPathComponent("01-abc123.json")
        XCTAssertEqual(url, expected)
    }

    /// The point of percent-encoding each component isn't to sanitize the
    /// id — it's to make an otherwise-unsafe id (spaces, `?`, ...)
    /// representable as a real file/folder name without silently mangling
    /// or truncating it. Round-tripping back through `lastPathComponent`
    /// (which decodes) must reproduce the original text exactly.
    func testUnsafeCharactersSurviveEncodingRoundTrip() {
        let url = ICloudDriveFileIO.itemURL(for: "a b/c?d", in: baseDirectory)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "a b")
        XCTAssertEqual(url.lastPathComponent, "c?d.json")
    }

    /// A regression guard on the scheme itself: visibly different ids must
    /// never resolve to the same on-disk URL.
    func testDifferentIDsNeverResolveToTheSameURL() {
        let ids = [
            "abc", "a/bc", "a-bc", "diary/abc", "diary-abc",
            "a/b/c", "ab/c", "diary/2024/abc", "diary/2024-abc",
            "", "abc.json", "ABC"
        ]
        var seenURLs = Set<URL>()
        for id in ids {
            let url = ICloudDriveFileIO.itemURL(for: id, in: baseDirectory)
            XCTAssertTrue(seenURLs.insert(url).inserted, "Collision for id \"\(id)\" at \(url)")
        }
    }

    func testSameIDAlwaysResolvesToTheSameURL() {
        let first = ICloudDriveFileIO.itemURL(for: "diary/2024-01-01-abc123", in: baseDirectory)
        let second = ICloudDriveFileIO.itemURL(for: "diary/2024-01-01-abc123", in: baseDirectory)
        XCTAssertEqual(first, second)
    }

    func testEmptyIDStillProducesAValidFlatFile() {
        // `split(separator:omittingEmptySubsequences:)` on an empty string
        // returns no components at all — this exercises `assetURL`'s
        // `guard !components.isEmpty` fallback branch directly.
        let url = ICloudDriveFileIO.itemURL(for: "", in: baseDirectory)
        XCTAssertEqual(url, baseDirectory.appendingPathComponent(".json"))
    }

    func testAssetURLUsesTheGivenExtensionInsteadOfJSON() {
        let url = ICloudDriveFileIO.assetURL(for: "photo1", extension: "jpg", in: baseDirectory)
        XCTAssertEqual(url, baseDirectory.appendingPathComponent("photo1.jpg"))
    }

    func testAssetURLNestsSubfoldersJustLikeItemURL() {
        let url = ICloudDriveFileIO.assetURL(for: "album/cover", extension: "jpg", in: baseDirectory)
        let expected = baseDirectory
            .appendingPathComponent("album", isDirectory: true)
            .appendingPathComponent("cover.jpg")
        XCTAssertEqual(url, expected)
    }

    func testFileNameEncodesTheWholeIDAsOneUnitIncludingSlashes() {
        // Unlike `itemURL`, `fileName(for:)` never partitions on `/` — it's
        // the flat, no-subfolder fallback, so a `/` inside the id must be
        // encoded away like any other unsafe character rather than treated
        // as a path separator.
        let name = ICloudDriveFileIO.fileName(for: "a/b c")
        XCTAssertTrue(name.hasSuffix(".json"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(" "))
    }

    /// Lists every real regular file under a directory — this is the
    /// primitive the reconciliation sweep uses to see what's *actually* on
    /// disk. It must see nested files, skip directories themselves, and
    /// never throw just because the directory doesn't exist yet.
    func testCoordinatedListFilesFindsNestedFilesAndIgnoresDirectoriesThemselves() async throws {
        let tempDir = TempDirectory()
        let flatURL = ICloudDriveFileIO.itemURL(for: "flat", in: tempDir.url)
        let nestedURL = ICloudDriveFileIO.itemURL(for: "diary/2024-01-01", in: tempDir.url)
        try FileManager.default.createDirectory(at: nestedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("flat".utf8).write(to: flatURL)
        try Data("nested".utf8).write(to: nestedURL)

        let files = try await ICloudDriveFileIO.coordinatedListFiles(under: tempDir.url)

        XCTAssertEqual(Set(files), [flatURL, nestedURL])
    }

    func testCoordinatedListFilesOnAMissingDirectoryReturnsEmptyNotAnError() async throws {
        let tempDir = TempDirectory()
        let neverCreated = tempDir.url.appendingPathComponent("NeverCreated", isDirectory: true)

        let files = try await ICloudDriveFileIO.coordinatedListFiles(under: neverCreated)

        XCTAssertTrue(files.isEmpty)
    }
}
