import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Pixel dimensions of an image, read without decoding its bitmap — see
/// `ICloudDriveImageInspector.pixelSize(of:)`. Internal — an implementation
/// detail of `ICloudDriveImageAssetStore`'s validation/normalization, not
/// part of the package's public surface.
struct ICloudDriveImagePixelSize: Equatable {
    let width: Int
    let height: Int

    /// `max(width, height)` — what `ICloudDriveSyncConfig.ImageAssetConfig.maxLongEdgePixels`
    /// is measured against, so a portrait and a landscape photo of the same
    /// quality are held to the same standard.
    var longEdge: Int { max(width, height) }
}

/// Low-level ImageIO primitives `ICloudDriveImageAssetStore` builds on —
/// pulled into their own file since they're independently useful/testable
/// (no ubiquity container, no `Codable`, no async — just bytes in, bytes or
/// numbers out) and because none of this has anything to do with *storing*
/// an image, only with *inspecting and re-encoding* one.
///
/// Every function here goes through `ImageIO`/`CoreGraphics`, never
/// `UIImage`. That's deliberate, not a style preference: `UIImage(data:)`
/// decodes the entire bitmap into memory before you can do anything with it
/// — including just checking its pixel dimensions — which is exactly the
/// "load the whole thing just to look at it" cost this type exists to avoid
/// for a package that has to assume nothing about how big an image a host
/// might hand it. `CGImageSourceCopyPropertiesAtIndex` reads an image's
/// header/metadata only; `CGImageSourceCreateThumbnailAtIndex` decodes
/// straight to a target size without ever materializing the full-resolution
/// bitmap. Both are the same techniques Apple demonstrates in WWDC 2018's
/// "Image and Graphics Best Practices" session for downsampling
/// picked/captured photos efficiently.
enum ICloudDriveImageInspector {
    /// Reads an image's pixel dimensions from its header/metadata only —
    /// does not decode the bitmap. Returns `nil` if `data` isn't a format
    /// ImageIO can parse at all (corrupt file, or genuinely not an image).
    static func pixelSize(of data: Data) -> ICloudDriveImagePixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return ICloudDriveImagePixelSize(width: width, height: height)
    }

    /// The concrete format `data` is actually encoded as (HEIC, JPEG, PNG,
    /// ...), read from its header — not assumed from a file extension or
    /// caller-supplied hint, since neither is reliable. `nil` if ImageIO
    /// doesn't recognize the data as any image type.
    static func utType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return nil
        }
        return UTType(type as String)
    }

    /// Decodes `data` directly to a bitmap no larger than
    /// `maxPixelDimension` on its longer edge — the full-resolution bitmap
    /// is never created, even transiently, regardless of how large the
    /// source image actually is. `nil` if `data` isn't decodable.
    static func downsampledCGImage(from data: Data, maxPixelDimension: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            // Bakes the image's own EXIF orientation into the decoded pixels
            // — without this, a photo shot in portrait can come back
            // sideways once its orientation tag is discarded downstream.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// Encodes `image` to `format` at `compressionQuality` (`0`–`1`). If
    /// `format` is `.heic` and HEIC encoding isn't available on this
    /// device/OS (rare — mainly older simulators), falls back to `.jpeg`
    /// automatically rather than failing outright — the returned tuple's
    /// `format` reflects whichever one actually got encoded, so a caller
    /// choosing a file extension from it never mislabels the bytes it just
    /// got back. `nil` only if both attempts fail.
    static func encode(_ image: CGImage, format: ICloudDriveImageFormat, compressionQuality: Double) -> (data: Data, format: ICloudDriveImageFormat)? {
        if let data = encode(image, utType: format.utType, compressionQuality: compressionQuality) {
            return (data, format)
        }
        guard format == .heic else { return nil }
        guard let data = encode(image, utType: .jpeg, compressionQuality: compressionQuality) else { return nil }
        return (data, .jpeg)
    }

    private static func encode(_ image: CGImage, utType: UTType, compressionQuality: Double) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, utType.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
