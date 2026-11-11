import Foundation
import ImportEngine
import Observation
import PhotosBridge

/// The Settings screen's model (backlog section 6, *Settings, destination*; decision 9, 8 Nov): the destination,
/// Photos or Files, app-wide, default Photos, saved as soon as it changes. A job already running keeps its route;
/// the next import follows the setting (`ImportModel` reads the store at each start).
///
/// The screen binds a picker to `destination` and shows `SettingsWording.destinationFooter` under it. It also shows
/// what the app will actually do when Photos access overrides the setting (`forcedFilesLine`, with Open Settings when
/// `offersPhotosSettingsLink`), reading the access in `refreshPhotosAccess()` when it appears and when the app comes
/// back to the foreground (the person may have changed it in Settings). The rule itself is the import's
/// (`DestinationDecision.resolve(choice:authorisation:staging:)`); nothing here changes it. It is reached from the
/// Cameras screen's toolbar.
@MainActor
@Observable
public final class SettingsModel {
    /// Where imports go when Photos access allows it. Saved on every change.
    public var destination: DestinationKind {
        didSet {
            guard destination != oldValue else { return }
            store.save(DestinationSetting(preferred: destination))
        }
    }

    /// Photos access as last read; nil before the first read, or without a way to read it.
    public private(set) var photosAccess: PhotosAuthorisation?

    @ObservationIgnored private let store: any DestinationSettingStore
    @ObservationIgnored private let photos: (any PhotosAuthorising)?

    /// - Parameter photos: Reads Photos access (never asks); without it the screen says nothing about access.
    public init(store: any DestinationSettingStore, photos: (any PhotosAuthorising)? = nil) {
        self.store = store
        self.photos = photos
        destination = store.load().preferred
    }

    /// Reads Photos access again. Never asks for it: that happens at the first Import.
    public func refreshPhotosAccess() async {
        guard let photos else { return }
        let read = await photos.authorisation()
        if read != photosAccess { photosAccess = read }
    }

    /// Why the next import goes to Files although the setting says Photos: access denied or restricted; nil when the
    /// setting is followed (or says Files, or access isn't read yet).
    public var forcedFilesReason: StagingReason? {
        guard let photosAccess else { return nil }
        let reason = DestinationDecision.resolve(choice: destination, authorisation: photosAccess,
                                                 staging: ImportRoute.defaultStagingPlace).stagingReason
        return reason?.isForced == true ? reason : nil
    }

    /// "Photos access is off, so imports go to Files." when access overrides the setting.
    public var forcedFilesLine: String? { forcedFilesReason.flatMap(SettingsWording.forcedFiles) }

    /// Open Settings beside that line: for a denial only (a restriction can't be changed there).
    public var offersPhotosSettingsLink: Bool { forcedFilesReason?.offersSettingsLink == true }

    /// The choices, in the order the picker shows them.
    public static let choices: [DestinationKind] = [.photos, .staging]

    /// The picker's label for a choice.
    public static func label(for kind: DestinationKind) -> String {
        SettingsWording.destinationLabel(kind)
    }
}
