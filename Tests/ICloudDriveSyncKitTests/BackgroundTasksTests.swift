import XCTest
import Foundation
@testable import ICloudDriveSyncKit

final class BackgroundTasksTests: XCTestCase {
    func testDoesNotScheduleWithoutARegisteredIdentifier() {
        let request = ICloudDriveBackgroundSyncDecision.scheduleRequest(
            identifier: nil,
            autoSyncMode: .always,
            hasPendingChanges: true,
            requestedEarliestBeginDate: nil,
            now: referenceDate,
            autoSyncDebounceSeconds: 2
        )

        XCTAssertNil(request)
    }

    func testDoesNotScheduleWhenAutoSyncIsOff() {
        let request = ICloudDriveBackgroundSyncDecision.scheduleRequest(
            identifier: "com.example.sync",
            autoSyncMode: .off,
            hasPendingChanges: true,
            requestedEarliestBeginDate: nil,
            now: referenceDate,
            autoSyncDebounceSeconds: 2
        )

        XCTAssertNil(request)
    }

    func testDoesNotScheduleWithoutPendingChanges() {
        let request = ICloudDriveBackgroundSyncDecision.scheduleRequest(
            identifier: "com.example.sync",
            autoSyncMode: .always,
            hasPendingChanges: false,
            requestedEarliestBeginDate: nil,
            now: referenceDate,
            autoSyncDebounceSeconds: 2
        )

        XCTAssertNil(request)
    }

    func testUsesExplicitEarliestBeginDateWhenProvided() {
        let explicitDate = referenceDate.addingTimeInterval(42)

        let request = ICloudDriveBackgroundSyncDecision.scheduleRequest(
            identifier: "com.example.sync",
            autoSyncMode: .always,
            hasPendingChanges: true,
            requestedEarliestBeginDate: explicitDate,
            now: referenceDate,
            autoSyncDebounceSeconds: 2
        )

        XCTAssertEqual(request, ICloudDriveBackgroundSyncRequest(identifier: "com.example.sync", earliestBeginDate: explicitDate))
    }

    func testDefaultEarliestBeginDateUsesAtLeastFifteenMinutes() {
        let request = ICloudDriveBackgroundSyncDecision.scheduleRequest(
            identifier: "com.example.sync",
            autoSyncMode: .always,
            hasPendingChanges: true,
            requestedEarliestBeginDate: nil,
            now: referenceDate,
            autoSyncDebounceSeconds: 2
        )

        XCTAssertEqual(request?.earliestBeginDate, referenceDate.addingTimeInterval(15 * 60))
    }

    func testDefaultEarliestBeginDateRespectsLongerDebounce() {
        let request = ICloudDriveBackgroundSyncDecision.scheduleRequest(
            identifier: "com.example.sync",
            autoSyncMode: .wifi,
            hasPendingChanges: true,
            requestedEarliestBeginDate: nil,
            now: referenceDate,
            autoSyncDebounceSeconds: 30 * 60
        )

        XCTAssertEqual(request?.earliestBeginDate, referenceDate.addingTimeInterval(30 * 60))
    }

    private var referenceDate: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }
}
