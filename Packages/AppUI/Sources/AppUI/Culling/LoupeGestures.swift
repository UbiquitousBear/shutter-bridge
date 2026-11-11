import Foundation

/// What one drag across the loupe means (backlog section 7.3): left and right move between units, up keeps, down
/// rejects. Pure, so the thresholds are tested on Linux; `LoupeView` hands it the drag's translation and SwiftUI's
/// predicted end. While the photo is zoomed in, a drag pans it instead and isn't read here.
public enum LoupeSwipe: Sendable, Hashable {
    case next
    case previous
    case keep
    case reject

    /// How far, in points, a drag must go (or be flung towards) to count.
    public static let horizontalThreshold: Double = 60
    public static let verticalThreshold: Double = 90

    /// The swipe a drag makes, or nil for one too short or too diagonal to say. The farther of the translation and the
    /// predicted end is used, so a short quick flick counts. A drag counts along an axis only if it goes at least
    /// half as far again along it as across it.
    public static func of(translationX dx: Double, translationY dy: Double, predictedX px: Double = 0,
                          predictedY py: Double = 0) -> LoupeSwipe? {
        let x = abs(px) > abs(dx) ? px : dx
        let y = abs(py) > abs(dy) ? py : dy
        if abs(x) >= horizontalThreshold, abs(x) >= abs(y) * 1.5 {
            return x < 0 ? .next : .previous
        }
        if abs(y) >= verticalThreshold, abs(y) >= abs(x) * 1.5 {
            return y < 0 ? .keep : .reject
        }
        return nil
    }
}

/// The loupe's zoom: from fitting the screen (1) up to the original's 100 % (one pixel of the photo to one screen pixel),
/// and at least `minimumMaximum` so a small photo can still be looked into. Pure.
///
/// The preview the prefetcher holds is screen-sized, so past its own 100 % the loupe draws the region on screen decoded
/// from the original (`detailRegion`, `CullLoupe.showDetail`). A preview with no `fullPixelSize` (a RAW whose render
/// isn't possible) zooms to its own 100 % only.
public enum LoupeZoom {
    /// The largest scale is never below this, even for a photo no larger than the screen.
    public static let minimumMaximum: Double = 2
    /// Nor above this, whatever the photo's size: an α7C II frame (7008 × 4672) reaches its 100 % at about 6× on an
    /// iPhone held upright.
    public static let ceiling: Double = 8
    /// How far past the preview's own 100 % the zoom must go before the original's pixels are decoded for the region.
    public static let detailThreshold: Double = 1.05

    /// The scale at which an image of this pixel size meets the screen's pixels one to one, given the space it is
    /// fitted into (points) and the screen's scale (pixels a point); nil for an empty size.
    public static func oneToOneScale(pixelWidth: Int, pixelHeight: Int, fittingWidth: Double, fittingHeight: Double,
                                     displayScale: Double) -> Double? {
        guard pixelWidth > 0, pixelHeight > 0, fittingWidth > 0, fittingHeight > 0, displayScale > 0,
              fittingWidth.isFinite, fittingHeight.isFinite, displayScale.isFinite
        else { return nil }
        let aspect = Double(pixelWidth) / Double(pixelHeight)
        let fittedWidth = min(fittingWidth, fittingHeight * aspect)
        return Double(pixelWidth) / (fittedWidth * displayScale)
    }

    /// `oneToOneScale` clamped to `minimumMaximum`...`ceiling`.
    public static func maximumScale(pixelWidth: Int, pixelHeight: Int, fittingWidth: Double, fittingHeight: Double,
                                    displayScale: Double) -> Double {
        guard let oneToOne = oneToOneScale(pixelWidth: pixelWidth, pixelHeight: pixelHeight, fittingWidth: fittingWidth,
                                           fittingHeight: fittingHeight, displayScale: displayScale)
        else { return minimumMaximum }
        return min(max(oneToOne, minimumMaximum), ceiling)
    }

    /// The loupe's largest scale for a preview: the original's 100 % when its pixels can be decoded
    /// (`LoadedPreview.fullPixelSize`), else the preview's own.
    public static func maximumScale<Image>(for preview: LoadedPreview<Image>?, fittingWidth: Double,
                                           fittingHeight: Double, displayScale: Double) -> Double {
        guard let preview else { return minimumMaximum }
        let size = preview.fullPixelSize ?? preview.pixelSize
        return maximumScale(pixelWidth: size.width, pixelHeight: size.height, fittingWidth: fittingWidth,
                            fittingHeight: fittingHeight, displayScale: displayScale)
    }

    /// `scale` kept within 1...`maximum`.
    public static func clamped(_ scale: Double, maximum: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(max(scale, 1), max(maximum, 1))
    }

    /// The part of the photo on screen: a photo of `aspect` (width over height) fitted and centred in the space, scaled
    /// by `scale` about its centre and moved by the offset (points, as `LoupeView` draws it). Nil when none of it is on
    /// screen.
    public static func visibleRegion(scale: Double, offsetX: Double, offsetY: Double, fittingWidth: Double,
                                     fittingHeight: Double, aspect: Double) -> LoupeRegion? {
        guard scale > 0, aspect > 0, fittingWidth > 0, fittingHeight > 0, scale.isFinite, aspect.isFinite,
              offsetX.isFinite, offsetY.isFinite
        else { return nil }
        let width = min(fittingWidth, fittingHeight * aspect) * scale
        let height = width / aspect
        let left = fittingWidth / 2 + offsetX - width / 2
        let top = fittingHeight / 2 + offsetY - height / 2
        return LoupeRegion(x: -left / width, y: -top / height, width: fittingWidth / width,
                           height: fittingHeight / height).clipped
    }

    /// The region to decode from the original, or nil when the preview's own pixels are enough: at `scale` no further
    /// than `detailThreshold` past the preview's 100 %, or a preview with no `fullPixelSize`.
    public static func detailRegion<Image>(for preview: LoadedPreview<Image>?, scale: Double, offsetX: Double,
                                           offsetY: Double, fittingWidth: Double, fittingHeight: Double,
                                           displayScale: Double) -> LoupeRegion? {
        guard let preview, preview.fullPixelSize != nil,
              let previewOneToOne = oneToOneScale(pixelWidth: preview.pixelSize.width,
                                                  pixelHeight: preview.pixelSize.height, fittingWidth: fittingWidth,
                                                  fittingHeight: fittingHeight, displayScale: displayScale),
              scale > previewOneToOne * detailThreshold
        else { return nil }
        let aspect = Double(preview.pixelSize.width) / Double(preview.pixelSize.height)
        return visibleRegion(scale: scale, offsetX: offsetX, offsetY: offsetY, fittingWidth: fittingWidth,
                             fittingHeight: fittingHeight, aspect: aspect)
    }
}
