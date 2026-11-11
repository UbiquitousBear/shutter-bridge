/// The app's Photos access, mirroring `PHAuthorizationStatus` for `.readWrite` so the rule below can be tested
/// without the Photos framework.
public enum PhotosAuthorisation: String, Sendable, Hashable, CaseIterable {
    case notDetermined
    /// Parental controls or a profile forbid access.
    case restricted
    /// *Don't Allow* at the prompt, or *None* in Settings.
    case denied
    /// *Limit Access*, with or without photos selected: enough to import (decision 9).
    case limited
    case authorised

    /// Where *Import to Photos* goes with this access alone. Nil means ask first: iOS shows the prompt once, at the
    /// first import to Photos. Denied and restricted are staged instead (decision 9, 8 Nov; Shamil, 11 Nov). With the
    /// choice, use `DestinationDecision.resolve(choice:authorisation:staging:)`, which also gives the reason.
    public var destination: DestinationKind? {
        switch self {
        case .notDetermined: nil
        case .limited, .authorised: .photos
        case .denied, .restricted: .staging
        }
    }
}

/// How imports are filed in Photos (Shamil, 1 Nov): the person chooses, with these defaults.
public struct PhotosImportOptions: Sendable, Hashable, Codable {
    public enum Albums: String, Sendable, Hashable, Codable, CaseIterable {
        case perCamera
        case perImport
        case both
    }

    /// For a RAW+JPEG pair, which file is the asset's original (iOS 27's `originalResourceChoice`).
    public enum PairOriginal: String, Sendable, Hashable, Codable, CaseIterable {
        case raw
        case processed
    }

    public var albums: Albums
    public var pairOriginal: PairOriginal

    public init(albums: Albums = .perCamera, pairOriginal: PairOriginal = .raw) {
        self.albums = albums
        self.pairOriginal = pairOriginal
    }
}
