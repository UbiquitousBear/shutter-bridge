import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge

/// The camera a job imports from: what discovery saw, and the catalogue's key for it (`CameraKeys`).
public struct ImportCamera: Sendable, Hashable {
    public var descriptor: CameraDescriptor
    public var key: CameraKey

    public init(descriptor: CameraDescriptor, key: CameraKey) {
        self.descriptor = descriptor
        self.key = key
    }

    /// What the camera calls itself (in MSC, the card's volume name); it names the Files folder and the album.
    public var name: String { descriptor.name }
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

/// One job's destinations: Photos and the camera's Files folder (the route picks one; the Files folder is also where
/// the rest goes if Photos refuses a save mid-import).
public struct ImportDestinations: Sendable {
    public var photos: any ImportDestination
    public var filesFolder: any ImportDestination
    /// The camera's folder in Files, for the Import screen: On My iPhone › Shutter Bridge › this.
    public var filesFolderName: String

    public init(photos: any ImportDestination, filesFolder: any ImportDestination, filesFolderName: String) {
        self.photos = photos
        self.filesFolder = filesFolder
        self.filesFolderName = filesFolderName
    }
}

/// Makes a job's destinations. Called once per job, so a continued job keeps its own album.
public protocol ImportDestinationMaking: Sendable {
    func destinations(for camera: ImportCamera, startedAt: Date) -> ImportDestinations
}

/// The app's destinations (backlog section 5): Photos through PhotosBridge's `PhotosLibraryDestination`, with the
/// person's album and original choices (defaults: one album per camera, RAW as the original), and the Files folder
/// in Documents, one folder per camera, named for the camera (`FilesFolderDestination`). Pure Foundation; the app
/// passes the real library (`SystemPhotoLibrary`), `ImageIOMetadataReader` and its Documents folder.
public struct StandardImportDestinations: ImportDestinationMaking {
    private let library: any PhotoLibraryClient
    private let albumStore: any AlbumIdentifierStore
    private let metadata: any PhotoMetadataReader
    private let options: PhotosImportOptions
    private let documentsDirectory: URL

    public init(library: any PhotoLibraryClient, albumStore: any AlbumIdentifierStore,
                metadata: any PhotoMetadataReader = NoMetadataReader(),
                options: PhotosImportOptions = PhotosImportOptions(), documentsDirectory: URL) {
        self.library = library
        self.albumStore = albumStore
        self.metadata = metadata
        self.options = options
        self.documentsDirectory = documentsDirectory
    }

    public func destinations(for camera: ImportCamera, startedAt: Date) -> ImportDestinations {
        let plan = AlbumPlan(choice: options.albums, cameraKey: camera.key.rawValue, cameraName: camera.name,
                             importID: UUID().uuidString, importDate: startedAt)
        let photos = PhotosLibraryDestination(library: library, albumStore: albumStore, metadata: metadata,
                                              options: options, albumPlan: plan)
        let files = FilesFolderDestination(documentsDirectory: documentsDirectory, cameraName: camera.name)
        return ImportDestinations(photos: photos, filesFolder: files, filesFolderName: files.folderName)
    }
}

/// What Browse asks of the Import screen's model: when the person taps Import, start a job with the picked files,
/// or add them to the running one (they land at the end); and while Browse is shown, say when more files have been
/// imported, so its badges follow.
@MainActor
public protocol BrowseImporting: AnyObject {
    func importItems(_ items: [CameraItem], from camera: ImportCamera, link: any CameraLink) async
        -> ImportRequestOutcome

    /// The import's revision each time more files have been imported, from now on, for as long as the caller reads
    /// (`ImportModel.importedUpdates()`).
    func importedUpdates() -> AsyncStream<Int>
}

/// What came of an Import tap in Browse.
public enum ImportRequestOutcome: Sendable, Hashable {
    /// A job started with this many picked files.
    case started(Int)
    /// Added to the running job's end.
    case appended(Int)
    /// Everything picked is already imported or already in the job.
    case nothingNew
    /// A job from another camera is running; one job at a time.
    case busyWithAnotherCamera
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
}

/// The scene's phase as the Import screen's model needs it (SwiftUI's `ScenePhase`, mapped by the app).
public enum AppScenePhase: Sendable, Hashable {
    case active
    case inactive
    case background
}
