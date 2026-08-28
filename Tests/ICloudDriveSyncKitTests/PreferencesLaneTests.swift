import XCTest
import Foundation
@testable import ICloudDriveSyncKit

private struct PreferencesProgressEvent: Equatable, Sendable {
    let phase: ICloudDriveSyncProgressPhase
    let completed: Int
    let total: Int?
    let itemID: String?
}

final class PreferencesLaneTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var store: InMemoryCloudStore!
    private var worker: ICloudDriveSyncWorker!
    private var preferencesURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        store = InMemoryCloudStore()
        worker = ICloudDriveSyncWorker()
        preferencesURL = tempDir.url.appendingPathComponent("Preferences.json")
    }

    override func tearDown() {
        tempDir = nil
        store = nil
        worker = nil
        preferencesURL = nil
        super.tearDown()
    }

    func testUploadPreferencesWritesOneWholeFileAndReportsProgress() async throws {
        let recorder = PreferencesProgressRecorder()
        let preferences = Data(#"{"theme":"dark"}"#.utf8)

        try await worker.uploadPreferences(
            preferences,
            preferencesURL: preferencesURL,
            io: store.ioPrimitives,
            onProgress: { phase, completed, total, itemID in
                await recorder.append(PreferencesProgressEvent(phase: phase, completed: completed, total: total, itemID: itemID))
            }
        )

        let storedPreferences = await store.file(at: preferencesURL)
        let writeCallCount = await store.writeCallCount()
        let events = await recorder.snapshot()
        XCTAssertEqual(storedPreferences, preferences)
        XCTAssertEqual(writeCallCount, 1)
        XCTAssertEqual(events, [
            PreferencesProgressEvent(phase: .uploadingPreferences, completed: 0, total: 1, itemID: nil),
            PreferencesProgressEvent(phase: .uploadingPreferences, completed: 1, total: 1, itemID: nil)
        ])
    }

    func testUploadPreferencesDoesNotTouchDataItemURLs() async throws {
        let itemURL = ICloudDriveFileIO.itemURL(for: "note-1", in: tempDir.url.appendingPathComponent("Items", isDirectory: true))
        await store.seed(itemURL, Data("existing item".utf8))

        try await worker.uploadPreferences(
            Data("prefs".utf8),
            preferencesURL: preferencesURL,
            io: store.ioPrimitives,
            onProgress: { _, _, _, _ in }
        )

        let storedItem = await store.file(at: itemURL)
        let allFiles = await store.allFiles()
        XCTAssertEqual(storedItem, Data("existing item".utf8))
        XCTAssertEqual(Set(allFiles.keys), [itemURL, preferencesURL])
    }

    func testReadPreferencesReturnsNilWithoutDownloadOrProgressWhenFileIsMissing() async throws {
        let recorder = PreferencesProgressRecorder()

        let data = try await worker.readPreferencesIfAvailable(
            preferencesURL: preferencesURL,
            io: store.ioPrimitives,
            onProgress: { phase, completed, total, itemID in
                await recorder.append(PreferencesProgressEvent(phase: phase, completed: completed, total: total, itemID: itemID))
            }
        )

        let downloadCallCount = await store.downloadCallCount()
        let events = await recorder.snapshot()
        XCTAssertNil(data)
        XCTAssertEqual(downloadCallCount, 0)
        XCTAssertTrue(events.isEmpty)
    }

    func testReadPreferencesDownloadsTheWholeFileAndReportsProgress() async throws {
        let recorder = PreferencesProgressRecorder()
        let preferences = Data(#"{"defaultCategory":"Diary"}"#.utf8)
        try Data().write(to: preferencesURL)
        await store.seed(preferencesURL, preferences)

        let data = try await worker.readPreferencesIfAvailable(
            preferencesURL: preferencesURL,
            io: store.ioPrimitives,
            onProgress: { phase, completed, total, itemID in
                await recorder.append(PreferencesProgressEvent(phase: phase, completed: completed, total: total, itemID: itemID))
            }
        )

        let downloadCallCount = await store.downloadCallCount()
        let events = await recorder.snapshot()
        XCTAssertEqual(data, preferences)
        XCTAssertEqual(downloadCallCount, 1)
        XCTAssertEqual(events, [
            PreferencesProgressEvent(phase: .downloadingPreferences, completed: 0, total: 1, itemID: nil),
            PreferencesProgressEvent(phase: .downloadingPreferences, completed: 1, total: 1, itemID: nil)
        ])
    }

    func testReadPreferencesCanPreserveOuterRestoreProgressTotals() async throws {
        let recorder = PreferencesProgressRecorder()
        let preferences = Data("prefs".utf8)
        try Data().write(to: preferencesURL)
        await store.seed(preferencesURL, preferences)

        _ = try await worker.readPreferencesIfAvailable(
            preferencesURL: preferencesURL,
            completedOffset: 5,
            totalUnitCount: 8,
            io: store.ioPrimitives,
            onProgress: { phase, completed, total, itemID in
                await recorder.append(PreferencesProgressEvent(phase: phase, completed: completed, total: total, itemID: itemID))
            }
        )

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            PreferencesProgressEvent(phase: .downloadingPreferences, completed: 5, total: 8, itemID: nil),
            PreferencesProgressEvent(phase: .downloadingPreferences, completed: 6, total: 8, itemID: nil)
        ])
    }

    func testReadPreferencesDownloadFailurePropagates() async throws {
        try Data().write(to: preferencesURL)
        await store.setDownloadFailure(preferencesURL, error: TestFailure.notFound)

        do {
            _ = try await worker.readPreferencesIfAvailable(
                preferencesURL: preferencesURL,
                io: store.ioPrimitives,
                onProgress: { _, _, _, _ in }
            )
            XCTFail("expected preferences download failure to propagate")
        } catch TestFailure.notFound {
            // expected
        }
    }
}

private actor PreferencesProgressRecorder {
    private var events: [PreferencesProgressEvent] = []

    func append(_ event: PreferencesProgressEvent) {
        events.append(event)
    }

    func snapshot() -> [PreferencesProgressEvent] {
        events
    }
}
