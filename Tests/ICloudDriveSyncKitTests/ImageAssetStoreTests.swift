import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ICloudDriveSyncKit

final class ImageAssetStoreTests: XCTestCase {
    private var tempDir: TempDirectory!
    private var imagesURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDirectory()
        imagesURL = tempDir.url.appendingPathComponent("Images", isDirectory: true)
    }

    override func tearDown() {
        imagesURL = nil
        tempDir = nil
        super.tearDown()
    }

    func testValidateAcceptsImageWithinConfiguredLimits() throws {
        let store = makeStore(maxFileSizeBytes: 64_000, maxLongEdgePixels: 32)
        let image = try makeImageData(width: 16, height: 10)

        XCTAssertNoThrow(try store.validate(image))
    }

    func testValidateRejectsNonImageData() {
        let store = makeStore()

        XCTAssertThrowsError(try store.validate(Data("not an image".utf8))) { error in
            guard case .imageDecodeFailed = error as? ICloudDriveSyncError else {
                return XCTFail("expected imageDecodeFailed")
            }
        }
    }

    func testValidateRejectsImagesOverByteLimit() throws {
        let store = makeStore(maxFileSizeBytes: 4)
        let image = try makeImageData(width: 16, height: 10)

        XCTAssertThrowsError(try store.validate(image)) { error in
            guard case .imageFileTooLarge(let sizeBytes, let limitBytes) = error as? ICloudDriveSyncError else {
                return XCTFail("expected imageFileTooLarge")
            }
            XCTAssertEqual(sizeBytes, Int64(image.count))
            XCTAssertEqual(limitBytes, 4)
        }
    }

    func testValidateRejectsImagesOverPixelLimit() throws {
        let store = makeStore(maxLongEdgePixels: 12)
        let image = try makeImageData(width: 16, height: 10)

        XCTAssertThrowsError(try store.validate(image)) { error in
            guard case .imageDimensionsTooLarge(let longEdgePixels, let limitPixels) = error as? ICloudDriveSyncError else {
                return XCTFail("expected imageDimensionsTooLarge")
            }
            XCTAssertEqual(longEdgePixels, 16)
            XCTAssertEqual(limitPixels, 12)
        }
    }

    func testSaveWithExplicitNestedIDWritesPreferredFormatAndLoadReadsItBack() async throws {
        let store = makeStore()
        let image = try makeImageData(width: 20, height: 12)

        let id = try await store.save(image, id: "diary/photo-1")
        let expectedURL = imagesURL
            .appendingPathComponent("diary", isDirectory: true)
            .appendingPathComponent("photo-1.jpg")
        let savedData = try Data(contentsOf: expectedURL)
        let loadedData = try await store.loadData(id: id, attemptLimit: 1)

        XCTAssertEqual(id, "diary/photo-1")
        XCTAssertEqual(savedData, loadedData)
        XCTAssertEqual(ICloudDriveImageInspector.utType(of: savedData), .jpeg)
    }

    func testSaveWithoutIDGeneratesAnIDAndMakesItDiscoverable() async throws {
        let store = makeStore()
        let image = try makeImageData(width: 20, height: 12)

        let id = try await store.save(image)

        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(store.allImageIDs(), [id])
    }

    func testLoadFallsBackToExistingFileWithDifferentExtension() async throws {
        let store = makeStore(preferredFormat: .heic)
        let image = try makeImageData(width: 20, height: 12)
        let jpegURL = imagesURL.appendingPathComponent("legacy.jpg")
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try image.write(to: jpegURL)

        let loadedData = try await store.loadData(id: "legacy", attemptLimit: 1)

        XCTAssertEqual(loadedData, image)
    }

    func testDeleteImageRemovesExistingFileAndIgnoresMissingFiles() async throws {
        let store = makeStore()
        let image = try makeImageData(width: 20, height: 12)
        _ = try await store.save(image, id: "photo-to-delete")
        let expectedURL = imagesURL.appendingPathComponent("photo-to-delete.jpg")

        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
        store.deleteImage(id: "photo-to-delete")
        store.deleteImage(id: "photo-to-delete")

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    func testUnavailableDirectoryThrowsOrReturnsSafeEmptyValues() async {
        let store = makeStore(imagesDirectoryProvider: { nil })

        await XCTAssertThrowsErrorAsync(try await store.save(try makeImageData(width: 12, height: 12))) { error in
            guard case .iCloudUnavailable = error as? ICloudDriveSyncError else {
                return XCTFail("expected iCloudUnavailable")
            }
        }
        await XCTAssertThrowsErrorAsync(try await store.loadData(id: "missing", attemptLimit: 1)) { error in
            guard case .iCloudUnavailable = error as? ICloudDriveSyncError else {
                return XCTFail("expected iCloudUnavailable")
            }
        }
        XCTAssertEqual(store.allImageIDs(), [])
        store.deleteImage(id: "missing")
    }

    private func makeStore(
        preferredFormat: ICloudDriveImageFormat = .jpeg,
        maxFileSizeBytes: Int64 = 128_000,
        maxLongEdgePixels: Int = 128,
        imagesDirectoryProvider: (@Sendable () -> URL?)? = nil
    ) -> ICloudDriveImageAssetStore {
        let imageConfig = ICloudDriveSyncConfig.ImageAssetConfig(
            preferredFormat: preferredFormat,
            maxFileSizeBytes: maxFileSizeBytes,
            maxLongEdgePixels: maxLongEdgePixels
        )
        let config = ICloudDriveSyncConfig(imageAssets: imageConfig)
        let resolvedImagesURL = imagesURL
        return ICloudDriveImageAssetStore(config: config, imagesDirectoryURL: imagesDirectoryProvider ?? { resolvedImagesURL })
    }

    private func makeImageData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestFailure.notFound
        }
        context.setFillColor(CGColor(red: 0.12, green: 0.42, blue: 0.34, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let encoded = ICloudDriveImageInspector.encode(image, format: .jpeg, compressionQuality: 0.8) else {
            throw TestFailure.notFound
        }
        return encoded.data
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
