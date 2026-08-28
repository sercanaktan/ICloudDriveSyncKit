// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ICloudDriveSyncKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ICloudDriveSyncKit",
            targets: ["ICloudDriveSyncKit"]
        ),
        .library(
            name: "ICloudDriveSyncKitUI",
            targets: ["ICloudDriveSyncKitUI"]
        )
    ],
    targets: [
        .target(
            name: "ICloudDriveSyncKit",
            path: "Sources/ICloudDriveSyncKit"
        ),
        .target(
            name: "ICloudDriveSyncKitUI",
            dependencies: ["ICloudDriveSyncKit"],
            path: "Sources/ICloudDriveSyncKitUI"
        ),
        .testTarget(
            name: "ICloudDriveSyncKitTests",
            dependencies: ["ICloudDriveSyncKit"],
            path: "Tests/ICloudDriveSyncKitTests"
        )
    ]
)
