import Foundation

/// Where a unit's preview comes from (backlog section 7.3). Pure: which file, and how, never the pixels.
public enum PreviewSource: Sendable, Hashable {
    /// A JPG or HEIF, shown as it is, decoded to screen size: a lone one, or a RAW+JPEG pair's processed file (the
    /// RAW beside it is never read for the preview).
    case image(CullFile, pairedWithRAW: Bool)
    /// A RAW with nothing beside it: its embedded preview at once, then a `CIRAWFilter` render when that is ready
    /// (the embedded preview stays if iOS can't decode the α7C II's ARW).
    case raw(CullFile)
    /// Nothing to show (a video, a sidecar).
    case none

    /// The file that is read.
    public var file: CullFile? {
        switch self {
        case let .image(file, _), let .raw(file): file
        case .none: nil
        }
    }
}

/// How good a loaded preview is.
public enum PreviewQuality: Sendable, Hashable {
    /// A RAW's embedded preview, shown while the render is made.
    case standIn
    /// The file as it is, or the RAW's render.
    case final
    /// A RAW's embedded preview that stays, because the render isn't possible: the loupe says so, as *Copy as JPEG* does.
    case embeddedOnly
}

/// A decoded preview at screen size, with what it costs to hold.
public struct LoadedPreview<Image: Sendable>: Sendable {
    public var image: Image
    public var pixelSize: PixelSize
    public var quality: PreviewQuality
    /// Bytes held in memory; 4 bytes a pixel unless the loader says otherwise.
    public var byteCost: Int

    public init(image: Image, pixelSize: PixelSize, quality: PreviewQuality, byteCost: Int? = nil) {
        self.image = image
        self.pixelSize = pixelSize
        self.quality = quality
        self.byteCost = byteCost ?? pixelSize.pixelCount * 4
    }
}

/// Decodes a preview. The real one is `ImageIOPreviewLoader` (ImageIO and Core Image, behind `#if canImport`); tests use
/// a fake.
public protocol PreviewLoading<Image>: Sendable {
    associatedtype Image: Sendable

    /// Decodes `source` so its longer side is at most `maxPixelSize`, and hands each result to `deliver`, in order:
    /// a RAW delivers its embedded preview as `.standIn`, then the render as `.final` (or the same preview again as
    /// `.embeddedOnly`). Throws only when nothing was delivered. Honours cancellation.
    func load(_ source: PreviewSource, maxPixelSize: Int,
              deliver: @Sendable (LoadedPreview<Image>) async -> Void) async throws
}

public struct PreviewLoadingFailure: Error, Sendable, Hashable {
    public var detail: String
    public init(_ detail: String) { self.detail = detail }
}

#if canImport(CoreImage) && canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import CoreImage
import ImageIO

/// A decoded image for the loupe to draw.
public struct DecodedPreviewImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

/// The real loader: ImageIO for a JPG or HEIF, and for a RAW the largest embedded preview
/// (`CoreImageJPEGMaker.largestEmbeddedImage`, the one *Copy as JPEG* falls back to) and then a `CIRAWFilter` render at
/// screen size. Each decode runs off the main actor and holds one image at a time. Compiled only by CI's Xcode job.
public struct ImageIOPreviewLoader: PreviewLoading {
    public typealias Image = DecodedPreviewImage

    /// One context for every decode: setting one up (Metal device, caches) is costly, and it is thread-safe.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func load(_ source: PreviewSource, maxPixelSize: Int,
                     deliver: @Sendable (LoadedPreview<DecodedPreviewImage>) async -> Void) async throws {
        switch source {
        case let .image(file, _):
            let image = await Self.offMain { Self.decodeImage(at: file.url, maxPixelSize: maxPixelSize) }
            guard let image else { throw PreviewLoadingFailure("ImageIO couldn't decode the image") }
            await deliver(Self.loaded(image, .final))

        case let .raw(file):
            let embedded = await Self.offMain { Self.decodeEmbedded(at: file.url, maxPixelSize: maxPixelSize) }
            if let embedded { await deliver(Self.loaded(embedded, .standIn)) }
            try Task.checkCancellation()
            let rendered = await Self.offMain { Self.render(at: file.url, maxPixelSize: maxPixelSize) }
            if let rendered {
                await deliver(Self.loaded(rendered, .final))
            } else if let embedded {
                await deliver(Self.loaded(embedded, .embeddedOnly))
            } else {
                throw PreviewLoadingFailure("no RAW decode and no embedded preview")
            }

        case .none:
            throw PreviewLoadingFailure("nothing to preview")
        }
    }

    private static func loaded(_ image: DecodedPreviewImage, _ quality: PreviewQuality) -> LoadedPreview<DecodedPreviewImage> {
        LoadedPreview(image: image, pixelSize: PixelSize(width: image.cgImage.width, height: image.cgImage.height),
                      quality: quality, byteCost: image.cgImage.bytesPerRow * image.cgImage.height)
    }

    private static func offMain(_ work: @escaping @Sendable () -> DecodedPreviewImage?) async -> DecodedPreviewImage? {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// A JPG or HEIF decoded straight to at most `maxPixelSize`, upright, without making the full bitmap first.
    static func decodeImage(at url: URL, maxPixelSize: Int) -> DecodedPreviewImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options).map(DecodedPreviewImage.init)
    }

    /// The RAW's largest embedded image, upright, scaled down to `maxPixelSize` if it is larger.
    static func decodeEmbedded(at url: URL, maxPixelSize: Int) -> DecodedPreviewImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let embedded = CoreImageJPEGMaker.largestEmbeddedImage(in: source, thumbnailsOnly: false)
        else { return nil }
        let metadata = CoreImageJPEGMaker.properties(of: source, at: CGImageSourceGetPrimaryImageIndex(source)) ?? [:]
        let image = CIImage(cgImage: embedded.image).oriented(CoreImageJPEGMaker.orientation(in: metadata))
        return scaledImage(image, maxPixelSize: maxPixelSize)
    }

    /// The `CIRAWFilter` render at (about) `maxPixelSize`, or nil if iOS can't decode the file.
    static func render(at url: URL, maxPixelSize: Int) -> DecodedPreviewImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let longSide = max(filter.nativeSize.width, filter.nativeSize.height)
        guard longSide > 0 else { return nil }
        filter.scaleFactor = Float(min(1, CGFloat(maxPixelSize) / longSide))
        guard let output = filter.outputImage else { return nil }
        return scaledImage(output, maxPixelSize: maxPixelSize)
    }

    /// `image` rendered into a bitmap no larger than `maxPixelSize` on its longer side.
    private static func scaledImage(_ image: CIImage, maxPixelSize: Int) -> DecodedPreviewImage? {
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        guard longSide > 0, longSide.isFinite else { return nil }
        let scale = min(1, CGFloat(maxPixelSize) / longSide)
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return context.createCGImage(scaled, from: scaled.extent.integral).map(DecodedPreviewImage.init)
    }
}
#endif
