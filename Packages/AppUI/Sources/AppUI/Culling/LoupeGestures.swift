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

/// The loupe's zoom: from fitting the screen (1) up to the preview's own pixels at 100 % (one image pixel to one
/// screen pixel), and at least `minimumMaximum` so a small preview can still be looked into. Pure.
public enum LoupeZoom {
    /// The largest scale is never below this, even for a preview no larger than the screen.
    public static let minimumMaximum: Double = 2
    /// Nor above this, whatever the preview's size.
    public static let ceiling: Double = 8

    /// The scale at which the image's pixels meet the screen's one to one, given the image's pixel size, the space it
    /// is fitted into (points) and the screen's scale (pixels a point), clamped to `minimumMaximum`...`ceiling`.
    public static func maximumScale(pixelWidth: Int, pixelHeight: Int, fittingWidth: Double, fittingHeight: Double,
                                    displayScale: Double) -> Double {
        guard pixelWidth > 0, pixelHeight > 0, fittingWidth > 0, fittingHeight > 0, displayScale > 0 else {
            return minimumMaximum
        }
        let aspect = Double(pixelWidth) / Double(pixelHeight)
        let fittedWidth = min(fittingWidth, fittingHeight * aspect)
        let oneToOne = Double(pixelWidth) / (fittedWidth * displayScale)
        return min(max(oneToOne, minimumMaximum), ceiling)
    }

    /// `scale` kept within 1...`maximum`.
    public static func clamped(_ scale: Double, maximum: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(max(scale, 1), max(maximum, 1))
    }
}
