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
    /// The original's pixel size, upright, when a region of it can be decoded at that resolution
    /// (`PreviewLoading.loadDetail`), so the loupe can zoom to the original's 100 %; nil when this preview's pixels are
    /// all there is (a RAW's stand-in, or its embedded preview when the render isn't possible).
    public var fullPixelSize: PixelSize?

    public init(image: Image, pixelSize: PixelSize, quality: PreviewQuality, byteCost: Int? = nil,
                fullPixelSize: PixelSize? = nil) {
        self.image = image
        self.pixelSize = pixelSize
        self.quality = quality
        self.byteCost = byteCost ?? pixelSize.pixelCount * 4
        self.fullPixelSize = fullPixelSize
    }
}

/// A part of a photo, as fractions of its upright width and height from its top-left corner: what the loupe shows
/// while zoomed in, which `PreviewLoading.loadDetail` decodes from the original. Pure.
public struct LoupeRegion: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole photo.
    public static let whole = LoupeRegion(x: 0, y: 0, width: 1, height: 1)

    /// This region within the photo (0...1 on both axes), or nil when nothing of it is in the photo.
    public var clipped: LoupeRegion? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        let left = max(x, 0), top = max(y, 0)
        let right = min(x + width, 1), bottom = min(y + height, 1)
        guard right > left, bottom > top else { return nil }
        return LoupeRegion(x: left, y: top, width: right - left, height: bottom - top)
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

    /// Decodes `region` of the original at its own resolution, scaled down only so its longer side is at most
    /// `maxPixelSize`: what the loupe draws over the preview once it is zoomed in past the preview's own pixels. Called
    /// only for a preview with a `fullPixelSize`. Throws when it can't. Honours cancellation.
    func loadDetail(_ source: PreviewSource, region: LoupeRegion, maxPixelSize: Int) async throws -> LoadedPreview<Image>
}

extension PreviewLoading {
    /// A loader with no detail decode: the loupe zooms into the preview alone.
    public func loadDetail(_ source: PreviewSource, region: LoupeRegion,
                           maxPixelSize: Int) async throws -> LoadedPreview<Image> {
        throw PreviewLoadingFailure("no detail decode")
    }
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
///
/// Zoomed in past the preview's own pixels, the loupe asks for the region on screen at the original's resolution
/// (`loadDetail`): Core Image crops the JPG or HEIF (orientation applied), or the `CIRAWFilter` output at scale 1, and
/// renders only that rectangle, at most screen-sized. Whether Core Image decodes the whole file to crop it (the JPG, or
/// the RAW's demosaic), and so the time and peak memory of one detail decode of a 33 MP frame, are `unverified` until
/// the bench (I5) measures them.
public struct ImageIOPreviewLoader: PreviewLoading {
    public typealias Image = DecodedPreviewImage

    /// One context for every decode: setting one up (Metal device, caches) is costly, and it is thread-safe.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func load(_ source: PreviewSource, maxPixelSize: Int,
                     deliver: @Sendable (LoadedPreview<DecodedPreviewImage>) async -> Void) async throws {
        switch source {
        case let .image(file, _):
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decodeImage(at: file.url, maxPixelSize: maxPixelSize)
            }.value
            guard let decoded else { throw PreviewLoadingFailure("ImageIO couldn't decode the image") }
            await deliver(Self.loaded(decoded.image, .final, full: decoded.full))

        case let .raw(file):
            let embedded = await Self.offMain { Self.decodeEmbedded(at: file.url, maxPixelSize: maxPixelSize) }
            if let embedded { await deliver(Self.loaded(embedded, .standIn)) }
            try Task.checkCancellation()
            let rendered = await Task.detached(priority: .userInitiated) {
                Self.render(at: file.url, maxPixelSize: maxPixelSize)
            }.value
            if let rendered {
                await deliver(Self.loaded(rendered.image, .final, full: rendered.full))
            } else if let embedded {
                await deliver(Self.loaded(embedded, .embeddedOnly))
            } else {
                throw PreviewLoadingFailure("no RAW decode and no embedded preview")
            }

        case .none:
            throw PreviewLoadingFailure("nothing to preview")
        }
    }

    public func loadDetail(_ source: PreviewSource, region: LoupeRegion,
                           maxPixelSize: Int) async throws -> LoadedPreview<DecodedPreviewImage> {
        let image: DecodedPreviewImage?
        switch source {
        case let .image(file, _):
            image = await Self.offMain { Self.detailOfImage(at: file.url, region: region, maxPixelSize: maxPixelSize) }
        case let .raw(file):
            image = await Self.offMain { Self.detailOfRAW(at: file.url, region: region, maxPixelSize: maxPixelSize) }
        case .none:
            image = nil
        }
        try Task.checkCancellation()
        guard let image else { throw PreviewLoadingFailure("no detail decode of the region") }
        return Self.loaded(image, .final)
    }

    private static func loaded(_ image: DecodedPreviewImage, _ quality: PreviewQuality,
                               full: PixelSize? = nil) -> LoadedPreview<DecodedPreviewImage> {
        LoadedPreview(image: image, pixelSize: PixelSize(width: image.cgImage.width, height: image.cgImage.height),
                      quality: quality, byteCost: image.cgImage.bytesPerRow * image.cgImage.height,
                      fullPixelSize: full)
    }

    /// A decoded image with the original's upright pixel size, when known.
    struct Decoded: Sendable {
        var image: DecodedPreviewImage
        var full: PixelSize?
    }

    private static func offMain(_ work: @escaping @Sendable () -> DecodedPreviewImage?) async -> DecodedPreviewImage? {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// A JPG or HEIF decoded straight to at most `maxPixelSize`, upright, without making the full bitmap first, with
    /// the original's upright pixel size from its properties.
    static func decodeImage(at url: URL, maxPixelSize: Int) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
        return Decoded(image: DecodedPreviewImage(image), full: uprightSize(of: source, at: index))
    }

    /// The image's pixel size with its orientation applied (a quarter turn swaps width and height).
    private static func uprightSize(of source: CGImageSource, at index: Int) -> PixelSize? {
        guard let metadata = CoreImageJPEGMaker.properties(of: source, at: index),
              let width = (metadata[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (metadata[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        switch CoreImageJPEGMaker.orientation(in: metadata) {
        case .left, .leftMirrored, .right, .rightMirrored: return PixelSize(width: height, height: width)
        default: return PixelSize(width: width, height: height)
        }
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

    /// The `CIRAWFilter` render at (about) `maxPixelSize`, with the size of its output at scale 1 (upright, the
    /// filter's own orientation), or nil if iOS can't decode the file.
    static func render(at url: URL, maxPixelSize: Int) -> Decoded? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let longSide = max(filter.nativeSize.width, filter.nativeSize.height)
        guard longSide > 0 else { return nil }
        // The output's extent at scale 1 is only a recipe: nothing is decoded until the image is rendered.
        let full = filter.outputImage.map(\.extent).flatMap { extent -> PixelSize? in
            guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
            return PixelSize(width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
        }
        filter.scaleFactor = Float(min(1, CGFloat(maxPixelSize) / longSide))
        guard let output = filter.outputImage, let image = scaledImage(output, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return Decoded(image: image, full: full)
    }

    /// `region` of a JPG or HEIF at its own resolution (orientation applied), at most `maxPixelSize` on its longer side.
    static func detailOfImage(at url: URL, region: LoupeRegion, maxPixelSize: Int) -> DecodedPreviewImage? {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        return crop(image, to: region, maxPixelSize: maxPixelSize)
    }

    /// `region` of the `CIRAWFilter` output at scale 1, at most `maxPixelSize` on its longer side.
    static func detailOfRAW(at url: URL, region: LoupeRegion, maxPixelSize: Int) -> DecodedPreviewImage? {
        guard let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage else { return nil }
        return crop(output, to: region, maxPixelSize: maxPixelSize)
    }

    /// Renders only `region` of `image`. Core Image's origin is the bottom left; the region's is the top left.
    private static func crop(_ image: CIImage, to region: LoupeRegion, maxPixelSize: Int) -> DecodedPreviewImage? {
        let extent = image.extent
        guard let region = region.clipped, extent.width > 0, extent.height > 0, extent.width.isFinite,
              extent.height.isFinite
        else { return nil }
        let rect = CGRect(x: extent.minX + extent.width * region.x,
                          y: extent.minY + extent.height * (1 - region.y - region.height),
                          width: extent.width * region.width, height: extent.height * region.height)
            .integral.intersection(extent)
        guard !rect.isEmpty else { return nil }
        let cropped = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return scaledImage(cropped, maxPixelSize: maxPixelSize)
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
