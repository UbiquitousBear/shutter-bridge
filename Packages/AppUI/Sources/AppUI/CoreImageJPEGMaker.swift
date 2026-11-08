#if canImport(CoreImage) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes the JPEG for *Copy as JPEG* and *Share as JPEG…* with Apple frameworks only (backlog section 6):
///
/// - **RAW:** rendered at full resolution with Core Image's RAW decoding (`CIRAWFilter(imageURL:)`, scale 1, the
///   filter's own orientation). If iOS can't decode the file (no filter, or no output image), the largest image
///   embedded in it is used instead (ImageIO: each index's embedded thumbnail and every image index but the RAW's
///   own, never a downscaled thumbnail), and the report says so, for the UI's message. If the RAW decodes but its
///   render can't be written, that is a conversion failure, not the fallback: the message about decoding would be
///   false, and a second attempt would most likely fail the same way. Every RAW's report carries the largest
///   embedded preview's pixel size, for the week-1 bench check.
/// - **HEIF:** decoded with Core Image (orientation applied) and re-encoded.
///
/// Every JPEG is 8-bit sRGB at quality 0.9, written upright (orientation 1), with the source's Exif (capture date
/// among it), TIFF and GPS dictionaries carried over. The work runs on a detached task, off the main actor; one image
/// is held in memory at a time.
public struct CoreImageJPEGMaker: JPEGMaking {
    /// `kCGImageDestinationLossyCompressionQuality`.
    public static let quality = 0.9

    public init() {}

    public func makeJPEG(from input: URL, conversion: JPEGConversion, to output: URL) async throws(JPEGMakingFailure)
        -> JPEGMakingReport
    {
        let work = Task.detached(priority: .userInitiated) { () -> Result<JPEGMakingReport, JPEGMakingFailure> in
            Self.make(from: input, conversion: conversion, to: output)
        }
        // A render can't be interrupted part way; a cancel is seen by the caller once it returns.
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        switch result {
        case let .success(report): return report
        case let .failure(failure): throw failure
        }
    }

    public func pixelSize(ofImageAt url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = Self.properties(of: source, at: CGImageSourceGetPrimaryImageIndex(source)),
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    // MARK: - The work, off the main actor

    static func make(from input: URL, conversion: JPEGConversion, to output: URL)
        -> Result<JPEGMakingReport, JPEGMakingFailure>
    {
        let start = ContinuousClock.now
        let source = CGImageSourceCreateWithURL(input as CFURL, nil)
        let metadata = source.flatMap { properties(of: $0, at: CGImageSourceGetPrimaryImageIndex($0)) } ?? [:]
        switch conversion {
        case .renderRAW:
            var notes: [String] = []
            // Whether this iOS lists the α7C II's RAW at all (its model code is ILCE-7CM2), for the bench check.
            let listed = CIRAWFilter.supportedCameraModels.filter { $0.uppercased().contains("7CM2") }.count
            notes.append("CIRAWFilter.supportedCameraModels matching 7CM2: \(listed)")
            if let filter = CIRAWFilter(imageURL: input) {
                notes.append("native-px=\(Int(filter.nativeSize.width))x\(Int(filter.nativeSize.height))")
                if let image = filter.outputImage {
                    guard let size = writeJPEG(image, metadata: metadata, to: output) else {
                        try? FileManager.default.removeItem(at: output)   // anything a failed write left
                        return .failure(JPEGMakingFailure(
                            "the RAW decoded but its render couldn't be written; " + notes.joined(separator: "; ")))
                    }
                    let renderSeconds = seconds(since: start)
                    // Thumbnails only: no second RAW decode. Timed apart from the render.
                    let preview = source.flatMap { largestEmbeddedImage(in: $0, thumbnailsOnly: true) }
                    notes.append("largest-preview=\(preview?.candidate ?? "none")")
                    return .success(JPEGMakingReport(
                        usedEmbeddedPreview: false, outputPixelSize: size, seconds: renderSeconds,
                        largestPreviewPixelSize: preview?.size, notes: notes))
                } else {
                    notes.append("CIRAWFilter outputImage was nil")
                }
            } else {
                notes.append("CIRAWFilter(imageURL:) returned nil")
            }
            guard let source, let preview = largestEmbeddedImage(in: source, thumbnailsOnly: false) else {
                return .failure(JPEGMakingFailure(
                    "no RAW decode and no embedded image; " + notes.joined(separator: "; ")))
            }
            notes.append("largest-preview=\(preview.candidate)")
            let previewSize = preview.size
            let image = CIImage(cgImage: preview.image).oriented(orientation(in: metadata))
            guard let size = writeJPEG(image, metadata: metadata, to: output) else {
                try? FileManager.default.removeItem(at: output)
                return .failure(JPEGMakingFailure(
                    "the embedded preview (\(previewSize)) couldn't be written; " + notes.joined(separator: "; ")))
            }
            return .success(JPEGMakingReport(
                usedEmbeddedPreview: true, outputPixelSize: size, seconds: seconds(since: start),
                largestPreviewPixelSize: previewSize, notes: notes))

        case .reencodeHEIF:
            guard let image = CIImage(contentsOf: input, options: [.applyOrientationProperty: true]) else {
                return .failure(JPEGMakingFailure("CIImage(contentsOf:) couldn't read the HEIF"))
            }
            guard let size = writeJPEG(image, metadata: metadata, to: output) else {
                return .failure(JPEGMakingFailure("the HEIF couldn't be written as a JPEG"))
            }
            return .success(JPEGMakingReport(
                usedEmbeddedPreview: false, outputPixelSize: size, seconds: seconds(since: start)))

        case .asIs:
            return .failure(JPEGMakingFailure("a JPG used as it is needs no conversion"))
        }
    }

    /// An image embedded in a file, and where it came from (`thumbnail@0`, `image@1`), so the bench log can't read
    /// a decoded image as an embedded preview.
    struct EmbeddedImage {
        var image: CGImage
        var candidate: String
        var size: PixelSize { PixelSize(width: image.width, height: image.height) }
    }

    /// The largest image embedded in the file, by pixel count: each index's embedded thumbnail, never made from the
    /// full image (so nothing is downscaled), and, unless `thumbnailsOnly`, each image index too, except the primary
    /// one of a RAW, which is the RAW decode itself, not something embedded. For an ARW that is the camera's
    /// embedded preview.
    static func largestEmbeddedImage(in source: CGImageSource, thumbnailsOnly: Bool) -> EmbeddedImage? {
        var best: EmbeddedImage?
        func consider(_ image: CGImage?, _ candidate: @autoclosure () -> String) {
            guard let image else { return }
            if image.width * image.height > (best.map { $0.image.width * $0.image.height } ?? 0) {
                best = EmbeddedImage(image: image, candidate: candidate())
            }
        }
        let isRAW = (CGImageSourceGetType(source).flatMap { UTType($0 as String) })?.conforms(to: .rawImage) ?? false
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ] as CFDictionary
        for index in 0..<CGImageSourceGetCount(source) {
            if !thumbnailsOnly, !(isRAW && index == primary) {
                consider(CGImageSourceCreateImageAtIndex(source, index, nil), "image@\(index)")
            }
            consider(CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions), "thumbnail@\(index)")
        }
        return best
    }

    /// Renders `image` into 8-bit sRGB and writes it as a JPEG; the pixel size written, or nil on failure.
    static func writeJPEG(_ image: CIImage, metadata: [String: Any], to url: URL) -> PixelSize? {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false, .outputColorSpace: srgb])
        guard let cgImage = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: srgb) else {
            return nil
        }
        let size = PixelSize(width: cgImage.width, height: cgImage.height)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, outputProperties(from: metadata, size: size) as CFDictionary)
        return CGImageDestinationFinalize(destination) ? size : nil
    }

    /// The JPEG's properties: quality, upright, and the source's Exif, TIFF and GPS dictionaries with the pixel size
    /// and orientation corrected.
    static func outputProperties(from metadata: [String: Any], size: PixelSize) -> [String: Any] {
        var properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
            kCGImagePropertyOrientation as String: 1,
        ]
        if var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = size.width
            exif[kCGImagePropertyExifPixelYDimension as String] = size.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let gps = metadata[kCGImagePropertyGPSDictionary as String] {
            properties[kCGImagePropertyGPSDictionary as String] = gps
        }
        return properties
    }

    static func properties(of source: CGImageSource, at index: Int) -> [String: Any]? {
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
    }

    static func orientation(in metadata: [String: Any]) -> CGImagePropertyOrientation {
        guard let raw = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value else { return .up }
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        JPEGPipeline.seconds(ContinuousClock.now - start)
    }
}
#endif
