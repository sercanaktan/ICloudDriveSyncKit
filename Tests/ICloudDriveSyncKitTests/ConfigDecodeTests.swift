import XCTest
import Foundation
@testable import ICloudDriveSyncKit

final class ConfigDecodeTests: XCTestCase {
    func testEmptyJSONDecodesToDocumentedDefaults() throws {
        let config = try decode("{}")
        let defaults = ICloudDriveSyncConfig()

        XCTAssertNil(config.containerIdentifier)
        XCTAssertEqual(config.appName, defaults.appName)
        XCTAssertEqual(config.backupDirectoryName, defaults.backupDirectoryName)
        XCTAssertEqual(config.backupFileName, defaults.backupFileName)
        XCTAssertEqual(config.manifestFileName, defaults.manifestFileName)
        XCTAssertEqual(config.itemsDirectoryName, defaults.itemsDirectoryName)
        XCTAssertEqual(config.preferencesFileName, defaults.preferencesFileName)
        XCTAssertEqual(config.largeBackupThresholdBytes, defaults.largeBackupThresholdBytes)
        XCTAssertEqual(config.defaultAutoSyncMode, defaults.defaultAutoSyncMode)
        XCTAssertEqual(config.userDefaultsKeyPrefix, defaults.userDefaultsKeyPrefix)
        XCTAssertEqual(config.minimumInitialRestoreOverlayDuration, defaults.minimumInitialRestoreOverlayDuration)
        XCTAssertEqual(config.initialRestoreCheckAttemptLimitWiFi, defaults.initialRestoreCheckAttemptLimitWiFi)
        XCTAssertEqual(config.initialRestoreCheckAttemptLimitCellular, defaults.initialRestoreCheckAttemptLimitCellular)
        XCTAssertEqual(config.downloadAttemptLimitWiFi, defaults.downloadAttemptLimitWiFi)
        XCTAssertEqual(config.downloadAttemptLimitCellular, defaults.downloadAttemptLimitCellular)
        XCTAssertEqual(config.pollIntervalSeconds, defaults.pollIntervalSeconds)
        XCTAssertEqual(config.autoSyncDebounceSeconds, defaults.autoSyncDebounceSeconds)
        XCTAssertEqual(config.eventLogCapacity, defaults.eventLogCapacity)
        XCTAssertEqual(config.conflictPolicy, defaults.conflictPolicy)
    }

    func testTopLevelOverridesDecodeWithoutTouchingUnspecifiedDefaults() throws {
        let config = try decode("""
        {
          "containerIdentifier": "iCloud.com.example.notes",
          "appName": "Notes Pro",
          "backupDirectoryName": "NotesBackup",
          "backupFileName": "Envelope.json",
          "manifestFileName": "Roster.json",
          "itemsDirectoryName": "Records",
          "preferencesFileName": "Prefs.json",
          "largeBackupThresholdBytes": 123456,
          "defaultAutoSyncMode": "wifi",
          "userDefaultsKeyPrefix": "notes_",
          "minimumInitialRestoreOverlayDuration": 0.25,
          "initialRestoreCheckAttemptLimitWiFi": 3,
          "initialRestoreCheckAttemptLimitCellular": 9,
          "downloadAttemptLimitWiFi": 11,
          "downloadAttemptLimitCellular": 7,
          "pollIntervalSeconds": 0.1,
          "autoSyncDebounceSeconds": 4.5,
          "eventLogCapacity": 12,
          "conflictPolicy": "manual"
        }
        """)

        XCTAssertEqual(config.containerIdentifier, "iCloud.com.example.notes")
        XCTAssertEqual(config.appName, "Notes Pro")
        XCTAssertEqual(config.backupDirectoryName, "NotesBackup")
        XCTAssertEqual(config.backupFileName, "Envelope.json")
        XCTAssertEqual(config.manifestFileName, "Roster.json")
        XCTAssertEqual(config.itemsDirectoryName, "Records")
        XCTAssertEqual(config.preferencesFileName, "Prefs.json")
        XCTAssertEqual(config.largeBackupThresholdBytes, 123456)
        XCTAssertEqual(config.defaultAutoSyncMode, .wifi)
        XCTAssertEqual(config.userDefaultsKeyPrefix, "notes_")
        XCTAssertEqual(config.minimumInitialRestoreOverlayDuration, 0.25)
        XCTAssertEqual(config.initialRestoreCheckAttemptLimitWiFi, 3)
        XCTAssertEqual(config.initialRestoreCheckAttemptLimitCellular, 9)
        XCTAssertEqual(config.downloadAttemptLimitWiFi, 11)
        XCTAssertEqual(config.downloadAttemptLimitCellular, 7)
        XCTAssertEqual(config.pollIntervalSeconds, 0.1)
        XCTAssertEqual(config.autoSyncDebounceSeconds, 4.5)
        XCTAssertEqual(config.eventLogCapacity, 12)
        XCTAssertEqual(config.conflictPolicy, .manual)
        XCTAssertEqual(config.imageAssets.directoryName, ICloudDriveSyncConfig.ImageAssetConfig().directoryName)
        XCTAssertEqual(config.messages.syncedMessage, ICloudDriveSyncConfig.Messages().syncedMessage)
    }

    func testPartialImageAssetConfigMergesWithDefaults() throws {
        let config = try decode("""
        {
          "imageAssets": {
            "directoryName": "Photos",
            "preferredFormat": "jpeg"
          }
        }
        """)
        let imageDefaults = ICloudDriveSyncConfig.ImageAssetConfig()

        XCTAssertEqual(config.imageAssets.directoryName, "Photos")
        XCTAssertEqual(config.imageAssets.preferredFormat, .jpeg)
        XCTAssertEqual(config.imageAssets.compressionQuality, imageDefaults.compressionQuality)
        XCTAssertEqual(config.imageAssets.maxFileSizeBytes, imageDefaults.maxFileSizeBytes)
        XCTAssertEqual(config.imageAssets.maxLongEdgePixels, imageDefaults.maxLongEdgePixels)
    }

    func testFullImageAssetConfigOverridesDecode() throws {
        let config = try decode("""
        {
          "imageAssets": {
            "directoryName": "Media",
            "preferredFormat": "heic",
            "compressionQuality": 0.55,
            "maxFileSizeBytes": 777,
            "maxLongEdgePixels": 640
          }
        }
        """)

        XCTAssertEqual(config.imageAssets.directoryName, "Media")
        XCTAssertEqual(config.imageAssets.preferredFormat, .heic)
        XCTAssertEqual(config.imageAssets.compressionQuality, 0.55)
        XCTAssertEqual(config.imageAssets.maxFileSizeBytes, 777)
        XCTAssertEqual(config.imageAssets.maxLongEdgePixels, 640)
    }

    func testPartialMessagesConfigMergesWithDefaults() throws {
        let config = try decode("""
        {
          "messages": {
            "syncedMessage": "Backup complete.",
            "restoreRetrySucceeded": "Recovered missing records.",
            "errorImageNotFoundPrefix": "Photo unavailable."
          }
        }
        """)
        let messageDefaults = ICloudDriveSyncConfig.Messages()

        XCTAssertEqual(config.messages.syncedMessage, "Backup complete.")
        XCTAssertEqual(config.messages.restoreRetrySucceeded, "Recovered missing records.")
        XCTAssertEqual(config.messages.errorImageNotFoundPrefix, "Photo unavailable.")
        XCTAssertEqual(config.messages.iCloudDriveUnavailable, messageDefaults.iCloudDriveUnavailable)
        XCTAssertEqual(config.messages.errorDownloadTimedOut, messageDefaults.errorDownloadTimedOut)
        XCTAssertEqual(config.messages.deleteBackupSucceededMessage, messageDefaults.deleteBackupSucceededMessage)
    }

    func testUnknownKeysAreIgnoredForForwardCompatibility() throws {
        let config = try decode("""
        {
          "appName": "Forward Compatible",
          "futureTopLevelSetting": true,
          "imageAssets": {
            "futureImageSetting": "ignored"
          },
          "messages": {
            "futureMessage": "ignored"
          }
        }
        """)

        XCTAssertEqual(config.appName, "Forward Compatible")
        XCTAssertEqual(config.imageAssets.directoryName, ICloudDriveSyncConfig.ImageAssetConfig().directoryName)
        XCTAssertEqual(config.messages.syncedMessage, ICloudDriveSyncConfig.Messages().syncedMessage)
    }

    func testInvalidEnumValueThrowsInsteadOfFallingBackSilently() {
        XCTAssertThrowsError(try decode("""
        {
          "defaultAutoSyncMode": "wifiOnly"
        }
        """))

        XCTAssertThrowsError(try decode("""
        {
          "conflictPolicy": "askEveryTime"
        }
        """))

        XCTAssertThrowsError(try decode("""
        {
          "imageAssets": {
            "preferredFormat": "png"
          }
        }
        """))
    }

    private func decode(_ json: String) throws -> ICloudDriveSyncConfig {
        try ICloudDriveSyncConfig.load(from: Data(json.utf8))
    }
}
