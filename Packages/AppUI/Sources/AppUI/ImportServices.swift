import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge

/// The camera a job imports from: what discovery saw, and the catalogue's key for it (`CameraKeys`).
public struct ImportCamera: Sendable, Hashable {
    public var descriptor: CameraDescriptor
    public var key: CameraKey
    /// The camera's name (D11, one name per body: `CameraNaming`): its staging folder's name, and its Photos album's
    /// title and key (`camera-name:<name>`), so every mode of one body shares them. An album an earlier build stored
    /// under the camera's key (`camera:<key>`) is found by its stored identifier and adopted the first time, keeping its
    /// title; a folder made before stays where it is. By default discovery's name (`CamerasWording.displayName(for:)`:
    /// "Camera" in Image Transfer (MSC), where discovery gives the card's volume name); the Import screen's model names
    /// a job's camera from the catalogue as the job starts (`CameraNaming.name(for:key:catalogue:)`).
    public var name: String

    public init(descriptor: CameraDescriptor, key: CameraKey, name: String? = nil) {
        self.descriptor = descriptor
        self.key = key
        self.name = name ?? CamerasWording.displayName(for: descriptor)
    }
}

/// Reading and asking for Photos access (`.readWrite`), behind a protocol so the Import screen's model is tested on
/// Linux. The app passes `LibraryPhotosAuthorisation(library: SystemPhotoLibrary())`.
public protocol PhotosAuthorising: Sendable {
    /// Reads the authorisation without asking.
    func authorisation() async -> PhotosAuthorisation
    /// Asks for `.readWrite`. iOS shows the prompt once; afterwards this answers at once with the status.
    func requestReadWriteAuthorisation() async -> PhotosAuthorisation
}

/// Photos access through PhotosBridge's library client (the real `SystemPhotoLibrary` in the app).
public struct LibraryPhotosAuthorisation: PhotosAuthorising {
    private let library: any PhotoLibraryClient

    public init(library: any PhotoLibraryClient) {
        self.library = library
    }

    public func authorisation() async -> PhotosAuthorisation { await library.authorisation() }
    public func requestReadWriteAuthorisation() async -> PhotosAuthorisation {
        await library.requestReadWriteAuthorisation()
    }
}

/// One job's destinations: Photos, and the camera's staging folder where staging goes now and on this iPhone (the
/// route picks one; staging is also where the rest goes if Photos refuses a save mid-import, and the folder on this
/// iPhone where it goes if iCloud Drive is lost mid-job).
public struct ImportDestinations: Sendable {
    public var photos: any ImportDestination
    /// The camera's staging folder in `stagingPlace`: iCloud Drive, or this iPhone.
    public var staging: any ImportDestination
    /// The camera's staging folder on this iPhone (the same folder as `staging` when that is on this iPhone).
    public var stagingOnThisIPhone: any ImportDestination
    /// Where `staging` stages, as the staging locator found it just before the job.
    public var stagingPlace: StagingPlace
    /// The camera's folder under Staging, for the Import screen: `stagingPlace.folderPath` › this.
    public var stagingFolderName: String

    public init(photos: any ImportDestination, staging: any ImportDestination,
                stagingOnThisIPhone: any ImportDestination, stagingPlace: StagingPlace, stagingFolderName: String) {
        self.photos = photos
        self.staging = staging
        self.stagingOnThisIPhone = stagingOnThisIPhone
        self.stagingPlace = stagingPlace
        self.stagingFolderName = stagingFolderName
    }

    /// The staging folder for `place`: the one in iCloud Drive for `.iCloudDrive` when there is one, otherwise the one
    /// on this iPhone.
    public func staging(in place: StagingPlace) -> any ImportDestination {
        place == .iCloudDrive && stagingPlace == .iCloudDrive ? staging : stagingOnThisIPhone
    }
}

/// Makes a job's destinations. Called once per job, so a continued job keeps its own album. It is also the app's
/// staging locator (`locate()`): the Import screen's model reads it before each job and before a continue, Settings
/// to show where staging goes, and Browse for the Import menu's wording.
public protocol ImportDestinationMaking: StagingLocator {
    /// - Parameter staging: Where staging can go, read with `locate()` just before.
    func destinations(for camera: ImportCamera, startedAt: Date, staging: StagingAvailability) -> ImportDestinations
}

/// The app's destinations (backlog section 5; Shamil, 11 Nov): Photos through PhotosBridge's
/// `PhotosLibraryDestination`, with the person's album and original choices (defaults: one album per camera, RAW as
/// the original), and the staging folder, one folder per camera and capture day (`ImportCamera.name`,
/// `StagingFolderDestination`): in the app's iCloud Drive folder (iCloud Drive › Shutter Bridge › Staging) when the
/// staging locator finds it, otherwise in the app's Documents folder (On My iPhone › Shutter Bridge › Staging). Pure
/// Foundation; the app passes the real library (`SystemPhotoLibrary`), `ImageIOMetadataReader`, its Documents folder,
/// `UbiquityStagingLocator` and `UbiquitousFileMover`.
public struct StandardImportDestinations: ImportDestinationMaking {
    private let library: any PhotoLibraryClient
    private let albumStore: any AlbumIdentifierStore
    private let metadata: any PhotoMetadataReader
    private let options: PhotosImportOptions
    private let documentsDirectory: URL
    private let stagingLocator: any StagingLocator
    private let iCloudDriveMover: any StagedFileMover

    /// - Parameters:
    ///   - documentsDirectory: The app's Documents folder: the staging root when iCloud Drive isn't available.
    ///   - stagingLocator: Finds the app's iCloud Drive folder (`UbiquityStagingLocator` on iPhone).
    ///   - iCloudDriveMover: Moves staged files into iCloud Drive (`UbiquitousFileMover` on iPhone). Files staged on
    ///     this iPhone are moved with `PlainFileMover`.
    public init(library: any PhotoLibraryClient, albumStore: any AlbumIdentifierStore,
                metadata: any PhotoMetadataReader = NoMetadataReader(),
                options: PhotosImportOptions = PhotosImportOptions(), documentsDirectory: URL,
                stagingLocator: any StagingLocator, iCloudDriveMover: any StagedFileMover) {
        self.library = library
        self.albumStore = albumStore
        self.metadata = metadata
        self.options = options
        self.documentsDirectory = documentsDirectory
        self.stagingLocator = stagingLocator
        self.iCloudDriveMover = iCloudDriveMover
    }

    public func locate() async -> StagingAvailability { await stagingLocator.locate() }

    public func destinations(for camera: ImportCamera, startedAt: Date,
                             staging availability: StagingAvailability) -> ImportDestinations {
        let plan = AlbumPlan(choice: options.albums, cameraKey: camera.key.rawValue, cameraName: camera.name,
                             importID: UUID().uuidString, importDate: startedAt)
        let photos = PhotosLibraryDestination(library: library, albumStore: albumStore, metadata: metadata,
                                              options: options, albumPlan: plan)
        // On this iPhone: On My iPhone › Shutter Bridge › Staging › camera › day, beside the Files folders earlier
        // builds made (Documents/camera), which are left alone. Its place says why it isn't iCloud Drive; when iCloud
        // Drive is available it is only the fallback for losing it mid-job.
        let localPlace = availability.place.fallbackReason.map(StagingPlace.onThisIPhone)
            ?? .onThisIPhone(.lostDuringImport)
        let local = StagingFolderDestination(root: documentsDirectory, place: localPlace, cameraName: camera.name,
                                             timeZone: .current)
        let staging: StagingFolderDestination
        if let iCloud = availability.iCloudDocuments {
            staging = StagingFolderDestination(root: iCloud, place: .iCloudDrive, cameraName: camera.name,
                                               timeZone: .current, mover: iCloudDriveMover)
        } else {
            staging = local
        }
        return ImportDestinations(photos: photos, staging: staging, stagingOnThisIPhone: local,
                                  stagingPlace: availability.place, stagingFolderName: staging.cameraFolderName)
    }
}

/// What Browse asks of the Import screen's model: when the person taps Import (or picks *Import to Photos* or *Stage*
/// from its menu), start a job with the picked files, or add them to the running one (they land at the end); what the
/// Import button does by default (the last choice used, remembered app-wide) and where staging goes, for its menu; and
/// while Browse is shown, say when more files have been imported or staged, so its badges follow.
@MainActor
public protocol BrowseImporting: AnyObject {
    /// - Parameters:
    ///   - choice: *Import to Photos* (`.photos`) or *Stage* (`.staging`); it becomes the remembered choice.
    ///   - newOnly: The picks came from *Select All New*, so a stage job also leaves out files already imported
    ///     (Shamil, 11 Nov); false for an explicit pick.
    func importItems(_ items: [CameraItem], from camera: ImportCamera, link: any CameraLink, as choice: DestinationKind,
                     newOnly: Bool) async -> ImportRequestOutcome

    /// The remembered choice: what the Import button does by default (Shamil, 11 Nov).
    var importChoice: DestinationKind { get }

    /// Where staging goes, as last read (`refreshStagingPlace()`); nil before the first read.
    var stagingPlace: StagingPlace? { get }

    /// Reads where staging goes again, for the Import menu's wording.
    func refreshStagingPlace() async

    /// The import's revision each time more files have been imported, from now on, for as long as the caller reads
    /// (`ImportModel.importedUpdates()`).
    func importedUpdates() -> AsyncStream<Int>
}

/// What came of an Import tap in Browse.
public enum ImportRequestOutcome: Sendable, Hashable {
    /// A job started with this many of the picked files: those it doesn't leave out as done already.
    case started(Int)
    /// Added to the running job's end.
    case appended(Int)
    /// Everything picked is already done or already in the job: imported, for an import to Photos; staged, when the
    /// import stages (`staging`: a *Stage*, or an *Import to Photos* staged because Photos access is off).
    case nothingNew(staging: Bool)
    /// A job from another camera is running; one job at a time.
    case busyWithAnotherCamera
    /// A job of the other kind is running from this camera: an import while these were to be staged, or staging while
    /// these were to be imported (`DestinationKind` is the running job's). One job at a time; try again once it ends.
    case busyWithAnotherMode(DestinationKind)
    /// *Import keepers* is running (I12): one job at a time, and nothing from a camera joins a keepers job.
    case busyWithKeepers
    /// A job is being started (Photos access may be being asked for); try again once it has.
    case stillStarting
    /// The engine refused, with a line for the person.
    case failed(String)
}

/// Finds a connected camera by its catalogue key, so an import paused by a removed cable can carry on once the
/// camera is back and listed (decision 7). `CamerasModel` is the app's.
@MainActor
public protocol CameraFinding: AnyObject {
    /// A link to the connected camera whose key is `key`, if one is connected.
    func link(forCameraWith key: CameraKey) async -> (any CameraLink)?

    /// The attached USB cameras that list files (Image Transfer, MSC or MTP) whose key isn't `key`, each with its key and
    /// an unopened link, in Cameras' order; never a Wi-Fi camera, whose link could start a join, nor Remote Shoot, which
    /// lists nothing. For continuing a paused USB job on the same body in the other mode, by content (D11).
    func otherUSBCameras(than key: CameraKey) async -> [AttachedCamera]
}

extension CameraFinding {
    /// A finder that only finds by key (History's, test doubles): no other camera to continue on.
    public func otherUSBCameras(than key: CameraKey) async -> [AttachedCamera] { [] }
}

/// An attached camera, its catalogue key and its link (not opened), as `CameraFinding.otherUSBCameras(than:)` gives
/// them. A camera link is an actor, so it is `Sendable`.
public struct AttachedCamera: Sendable {
    public var descriptor: CameraDescriptor
    public var key: CameraKey
    public var link: any CameraLink

    public init(descriptor: CameraDescriptor, key: CameraKey, link: any CameraLink) {
        self.descriptor = descriptor
        self.key = key
        self.link = link
    }
}

/// The scene's phase as the Import screen's model needs it (SwiftUI's `ScenePhase`, mapped by the app).
public enum AppScenePhase: Sendable, Hashable {
    case active
    case inactive
    case background
}
