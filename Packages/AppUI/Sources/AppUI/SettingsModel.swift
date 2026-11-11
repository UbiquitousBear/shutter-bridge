import Foundation
import Observation
import PhotosBridge

/// The Settings screen's model (backlog section 6; Shamil, 11 Nov). There is no destination choice: since 11 Nov the
/// Import button offers *Import to Photos* and *Stage* at each import and remembers the last one used (`ImportModel`),
/// which replaced the app-wide Photos-or-Files setting decided on 8 Nov.
///
/// The screen shows where staging goes (`stagingLocation`: iCloud Drive › Shutter Bridge › Staging, or On My iPhone ›
/// Shutter Bridge › Staging) and, when it is on this iPhone, why (`stagingFallbackLine`). It also says what *Import to
/// Photos* will do when Photos access is off or restricted (`forcedStagingLine`, with Open Settings when
/// `offersPhotosSettingsLink`). Both are read in `refresh()`, when the screen appears and when the app comes back to
/// the foreground (the person may have changed them in Settings). The rules are the import's
/// (`DestinationDecision.resolve(choice:authorisation:staging:)`); nothing here changes them. It is reached from the
/// Cameras screen's toolbar.
@MainActor
@Observable
public final class SettingsModel {
    /// Photos access as last read; nil before the first read, or without a way to read it.
    public private(set) var photosAccess: PhotosAuthorisation?
    /// Where staging goes, as last read; nil before the first read, or without a staging locator.
    public private(set) var stagingPlace: StagingPlace?

    @ObservationIgnored private let photos: (any PhotosAuthorising)?
    @ObservationIgnored private let staging: (any StagingLocator)?

    /// - Parameters:
    ///   - photos: Reads Photos access (never asks); without it the screen says nothing about access.
    ///   - staging: Finds where staging goes (the app's `ImportDestinationMaking`); without it the screen says
    ///     nothing about staging.
    public init(photos: (any PhotosAuthorising)? = nil, staging: (any StagingLocator)? = nil) {
        self.photos = photos
        self.staging = staging
    }

    /// Reads Photos access and where staging goes again. Never asks for Photos access: that happens at the first
    /// *Import to Photos*.
    public func refresh() async {
        if let photos {
            let read = await photos.authorisation()
            if read != photosAccess { photosAccess = read }
        }
        if let staging {
            let place = await staging.locate().place
            if place != stagingPlace { stagingPlace = place }
        }
    }

    /// Where staging goes, as Files names it; nil before it is read.
    public var stagingLocation: String? { stagingPlace.map(SettingsWording.stagingLocation) }

    /// Why staging is on this iPhone rather than in iCloud Drive; nil when it is in iCloud Drive or not read yet.
    public var stagingFallbackLine: String? { stagingPlace.flatMap(SettingsWording.stagingFallback) }

    /// Why *Import to Photos* stages instead: access denied or restricted; nil when it imports to Photos (or access
    /// isn't read yet).
    public var forcedStagingReason: StagingReason? {
        guard let photosAccess else { return nil }
        let reason = DestinationDecision.resolve(choice: .photos, authorisation: photosAccess,
                                                 staging: stagingPlace ?? .iCloudDrive).stagingReason
        return reason?.isForced == true ? reason : nil
    }

    /// "Photos access is off, so Import to Photos stages the photos instead." when access overrides it.
    public var forcedStagingLine: String? { forcedStagingReason.flatMap(SettingsWording.forcedStaging) }

    /// Open Settings beside that line: for a denial only (a restriction can't be changed there).
    public var offersPhotosSettingsLink: Bool { forcedStagingReason?.offersSettingsLink == true }
}
