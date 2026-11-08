import CameraTransport
import Foundation
import PhotosBridge

/// What *Copy as JPEG* and *Share as JPEG…* fetch for a file, and what they do with it (backlog section 6, *What
/// is copied or shared*).
public struct JPEGSource: Sendable, Hashable {
    /// The rule's four outcomes. The embedded-preview fallback isn't one of them: it is decided only once the RAW is
    /// on the phone and Core Image has tried it (`JPEGPath.previewFallback`).
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The file pressed is a JPG (on its own, or the JPG half of a RAW+JPEG pair): that file, as it is.
        case jpegAsIs
        /// The file pressed is a RAW whose RAW+JPEG pair JPG is on the card: the pair's JPG, as it is.
        case pairedJPEG
        /// A RAW with no JPG beside it: a JPEG rendered from the RAW at full resolution (Core Image).
        case rawRender
        /// A HEIF (`.HIF`) still: re-encoded as a JPEG (ImageIO). An open point in the backlog, confirmed in week 1.
        case heifReencode
    }

    /// The file that was pressed, which names the JPEG (its stem, with `.jpg`).
    public var pressed: CameraItem
    /// The file fetched from the camera: the pressed one, or its pair's JPG.
    public var fetched: CameraItem
    public var kind: Kind

    public init(pressed: CameraItem, fetched: CameraItem, kind: Kind) {
        self.pressed = pressed
        self.fetched = fetched
        self.kind = kind
    }

    /// What happens to the fetched file.
    public var conversion: JPEGConversion {
        switch kind {
        case .jpegAsIs, .pairedJPEG: .asIs
        case .rawRender: .renderRAW
        case .heifReencode: .reencodeHEIF
        }
    }
}

/// What is done to a fetched file to get the JPEG.
public enum JPEGConversion: String, Sendable, Hashable, CaseIterable {
    /// Nothing: the camera's own JPG, no render and no re-encode.
    case asIs
    /// Rendered from the RAW (`CIRAWFilter`), or the RAW's embedded preview if iOS can't decode it.
    case renderRAW
    /// Re-encoded from the HEIF (ImageIO).
    case reencodeHEIF
}

/// The path an action actually took, for the bench log (backlog section 6, *Bench check, week 1*).
public enum JPEGPath: String, Sendable, Hashable, CaseIterable {
    case jpegAsIs = "jpg-as-is"
    case pairedJPEG = "pair-jpg"
    case rawRender = "raw-render"
    case previewFallback = "preview-fallback"
    case heifReencode = "heif-reencode"

    public init(_ kind: JPEGSource.Kind, usedEmbeddedPreview: Bool) {
        switch kind {
        case .jpegAsIs: self = .jpegAsIs
        case .pairedJPEG: self = .pairedJPEG
        case .rawRender: self = usedEmbeddedPreview ? .previewFallback : .rawRender
        case .heifReencode: self = .heifReencode
        }
    }
}

/// Picks the source for each file in one listing (backlog section 6). Built once per listing, so pressing a file
/// costs a dictionary lookup, not a scan of the card.
///
/// The pairing is section 5's rule itself, PhotosBridge's `RawPairingRule`: a RAW and a JPG in the same folder, with
/// the same stem (case-insensitively), whose capture dates are within 1 s; a file without a capture date never pairs
/// (a missed pair costs a render, a wrong pair would copy another photo). When more than one JPG qualifies, the
/// closest in time wins, then the first in the listing; each JPG pairs with one RAW at most. Only a JPG pair counts
/// here, as the 8 Nov decision says: the rule is run over the RAWs and JPGs alone, so a RAW whose partner is a HIF is
/// rendered from the RAW (an open point for Shamil).
public struct JPEGSourceRule: Sendable {
    /// How far apart a RAW's and a JPG's capture dates may be: `RawPairingRule`'s default.
    public static let pairTolerance: TimeInterval = RawPairingRule().tolerance

    /// A camera item as the pairing rule sees it.
    private struct Candidate: PairableFile {
        let item: CameraItem
        var pairingFolder: String { item.folder }
        var pairingFilename: String { item.name }
        var pairingCaptureDate: Date? { item.captureDate }
    }

    /// Each paired RAW's JPG.
    private let pairs: [CameraItem.ID: CameraItem]

    public init(listing: [CameraItem]) {
        let candidates = listing.filter { $0.format == .raw || $0.format == .jpeg }.map(Candidate.init)
        var pairs: [CameraItem.ID: CameraItem] = [:]
        for unit in RawPairingRule().units(candidates) {
            guard case let .pair(raw, processed) = unit, raw.item.format == .raw, processed.item.format == .jpeg
            else { continue }
            pairs[raw.item.id] = processed.item
        }
        self.pairs = pairs
    }

    /// The source for `item`, or nil when it can't be copied as a JPEG (video, sidecars, anything not a still).
    public func source(for item: CameraItem) -> JPEGSource? {
        switch item.format {
        case .jpeg:
            return JPEGSource(pressed: item, fetched: item, kind: .jpegAsIs)
        case .heif:
            return JPEGSource(pressed: item, fetched: item, kind: .heifReencode)
        case .raw:
            if let jpeg = pairedJPEG(of: item) {
                return JPEGSource(pressed: item, fetched: jpeg, kind: .pairedJPEG)
            }
            return JPEGSource(pressed: item, fetched: item, kind: .rawRender)
        case .video, .sidecar, .folder, .other:
            return nil
        }
    }

    /// The JPG that pairs with a RAW, if one is on the card.
    public func pairedJPEG(of raw: CameraItem) -> CameraItem? {
        guard raw.format == .raw else { return nil }
        return pairs[raw.id]
    }

    /// The name without its last extension: "DSC00001.ARW" → "DSC00001". A name with no extension, or one that starts
    /// with its only dot, is its own stem (`RawPairingRule.stem(ofFilename:)`).
    public static func stem(of name: String) -> String {
        RawPairingRule.stem(ofFilename: name)
    }
}
