import XCTest
import Foundation
@testable import ICloudDriveSyncKit

@MainActor
final class PendingDurableStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var config: ICloudDriveSyncConfig!

    override func setUp() {
        super.setUp()
        suiteName = "ICloudDriveSyncKitTests.PendingDurableState.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        config = ICloudDriveSyncConfig(
            appName: "Pending Durable State Tests",
            defaultAutoSyncMode: .off,
            userDefaultsKeyPrefix: "pendingDurable_",
            autoSyncDebounceSeconds: 0
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        config = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPendingDataChangesSurviveANewEngineInstance() {
        let firstLaunch = makeEngine()
        firstLaunch.notifyDataChanged(changedItemIDs: ["note-1", "note-2"], deletedItemIDs: ["note-3"])

        let relaunched = makeEngine()
        let snapshot = relaunched.makeDiagnosticsSnapshot()

        XCTAssertTrue(snapshot.hasPendingChanges)
        XCTAssertEqual(snapshot.pendingItemCount, 2)
        XCTAssertEqual(snapshot.pendingDeletedItemCount, 1)
        XCTAssertFalse(snapshot.hasPendingPreferencesChange)
    }

    func testPendingPreferencesChangeSurvivesANewEngineInstance() {
        let firstLaunch = makeEngine()
        firstLaunch.notifyPreferencesChanged()

        let relaunched = makeEngine()
        let snapshot = relaunched.makeDiagnosticsSnapshot()

        XCTAssertTrue(snapshot.hasPendingChanges)
        XCTAssertEqual(snapshot.pendingItemCount, 0)
        XCTAssertEqual(snapshot.pendingDeletedItemCount, 0)
        XCTAssertTrue(snapshot.hasPendingPreferencesChange)
    }

    func testDeletedItemIDsWinOverChangedItemIDsAcrossRelaunch() {
        let firstLaunch = makeEngine()
        firstLaunch.notifyDataChanged(changedItemIDs: ["note-1", "note-2"], deletedItemIDs: ["note-2", "note-3"])

        let relaunched = makeEngine()
        let snapshot = relaunched.makeDiagnosticsSnapshot()

        XCTAssertTrue(snapshot.hasPendingChanges)
        XCTAssertEqual(snapshot.pendingItemCount, 1)
        XCTAssertEqual(snapshot.pendingDeletedItemCount, 2)
    }

    func testPendingFlagsAccumulateAcrossMultipleLaunches() {
        let firstLaunch = makeEngine()
        firstLaunch.notifyDataChanged(changedItemIDs: ["note-1"])

        let secondLaunch = makeEngine()
        secondLaunch.notifyDataChanged(changedItemIDs: ["note-2"], deletedItemIDs: ["note-3"])
        secondLaunch.notifyPreferencesChanged()

        let thirdLaunch = makeEngine()
        let snapshot = thirdLaunch.makeDiagnosticsSnapshot()

        XCTAssertTrue(snapshot.hasPendingChanges)
        XCTAssertEqual(snapshot.pendingItemCount, 2)
        XCTAssertEqual(snapshot.pendingDeletedItemCount, 1)
        XCTAssertTrue(snapshot.hasPendingPreferencesChange)
    }

    func testEmptyPendingDefaultsRestoreAsNoPendingChanges() {
        defaults.set([], forKey: config.userDefaultsKeyPrefix + "pendingItemIDs")
        defaults.set([], forKey: config.userDefaultsKeyPrefix + "pendingDeletedItemIDs")
        defaults.set(false, forKey: config.userDefaultsKeyPrefix + "pendingPreferencesChange")

        let engine = makeEngine()
        let snapshot = engine.makeDiagnosticsSnapshot()

        XCTAssertFalse(snapshot.hasPendingChanges)
        XCTAssertEqual(snapshot.pendingItemCount, 0)
        XCTAssertEqual(snapshot.pendingDeletedItemCount, 0)
        XCTAssertFalse(snapshot.hasPendingPreferencesChange)
    }

    private func makeEngine() -> ICloudDriveSyncEngine {
        ICloudDriveSyncEngine(config: config, userDefaults: defaults)
    }
}
