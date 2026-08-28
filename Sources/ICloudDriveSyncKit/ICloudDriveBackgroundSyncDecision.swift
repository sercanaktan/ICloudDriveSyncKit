import Foundation

struct ICloudDriveBackgroundSyncRequest: Equatable, Sendable {
    let identifier: String
    let earliestBeginDate: Date
}

enum ICloudDriveBackgroundSyncDecision {
    static let minimumLeadTime: TimeInterval = 15 * 60

    static func scheduleRequest(
        identifier: String?,
        autoSyncMode: ICloudAutoSyncMode,
        hasPendingChanges: Bool,
        requestedEarliestBeginDate: Date?,
        now: Date = Date(),
        autoSyncDebounceSeconds: Double
    ) -> ICloudDriveBackgroundSyncRequest? {
        guard let identifier,
              autoSyncMode != .off,
              hasPendingChanges else { return nil }

        let earliestBeginDate = requestedEarliestBeginDate
            ?? now.addingTimeInterval(max(autoSyncDebounceSeconds, minimumLeadTime))

        return ICloudDriveBackgroundSyncRequest(
            identifier: identifier,
            earliestBeginDate: earliestBeginDate
        )
    }
}
