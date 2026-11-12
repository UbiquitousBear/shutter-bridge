import Foundation

/// The Photos destination's logic, over a `PhotoLibraryClient`: one asset per unit (a RAW+JPEG pair is one asset,
/// with the original the person chose), the capture date and EXIF position on it, into the albums the person chose,
/// each found by its stored `localIdentifier` and created once. Returns the asset's `localIdentifier`.
///
/// A save refused as a denial (`PHPhotosErrorDomain` 3311, or 3310) throws `.photosAccessDenied`: not a failed file;
/// the engine stages this unit and the rest instead. On a successful save the staged files are deleted (they are
/// consumed, as the protocol says); on a failure they stay, so the staging fallback can move them.
///
/// Read the authorisation with `PhotosAccessGate` before the import starts and before it continues; this type
/// doesn't ask for access.
public actor PhotosLibraryDestination: ImportDestination {
    public nonisolated let kind: DestinationKind = .photos

    private let library: any PhotoLibraryClient
    private let albumStore: any AlbumIdentifierStore
    private let metadata: any PhotoMetadataReader
    public nonisolated let options: PhotosImportOptions
    public nonisolated let albumPlan: AlbumPlan

    /// Albums that couldn't take this import's photos, for the log and the Import screen: the photo is saved
    /// without them rather than failed.
    public private(set) var albumIssues: [AlbumIssue] = []

    public enum AlbumIssue: Sendable, Hashable {
        /// The album exists but `canPerform(.addContent)` is false.
        case doesNotAcceptPhotos(key: String)
        /// Creating the album failed for a reason other than a denial.
        case couldNotCreate(key: String, detail: String)
    }

    public init(library: any PhotoLibraryClient, albumStore: any AlbumIdentifierStore,
                metadata: any PhotoMetadataReader = NoMetadataReader(),
                options: PhotosImportOptions = PhotosImportOptions(), albumPlan: AlbumPlan) {
        self.library = library
        self.albumStore = albumStore
        self.metadata = metadata
        self.options = options
        self.albumPlan = albumPlan
    }

    public func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        let files = unit.files
        for file in files where !FileManager.default.fileExists(atPath: file.url.path) {
            throw .stagedFileMissing
        }
        // A save shortly after the phone locks needs the file readable: never `complete` (decision 9).
        for file in files { StagingProtection.relaxIfComplete(file.url) }

        let albums = try await resolveAlbums()
        var asset = AssetCreation(unit: unit, options: options)
        asset.location = await location(for: unit)

        let identifier: String
        do {
            identifier = try await library.save(asset, toAlbums: albums)
        } catch {
            throw ImportDestinationFailure(photoLibraryFailure: error)
        }
        for file in files { try? FileManager.default.removeItem(at: file.url) }
        return .photosAsset(localIdentifier: identifier)
    }

    /// The library, whichever albums the plan names.
    public nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget { .photosLibrary }

    /// The identifiers of the plan's albums that accept photos: found by the stored identifier; else an album an
    /// earlier build stored under one of the album's legacy keys (`AlbumPlan.Album.legacyKeys`, D11), adopted under its
    /// key; else created (once) and stored when there is none or the stored one is gone. An album found by its key
    /// that refuses new content is skipped and noted, not recreated (it is still the person's album). A legacy album
    /// that refuses new content isn't adopted: the album's key is shared by every camera key with that name, so
    /// adopting it would leave all of them without an album; it is left as it is and the next legacy key is tried.
    ///
    /// Commits overlap (two downloads in flight, and the save runs off the download path), and this actor suspends
    /// while it reads the store and asks the library, so a second commit could otherwise find no identifier too and
    /// create a second album. Each key's resolution therefore runs once at a time: the task is registered before the
    /// first suspension point, and a commit that arrives meanwhile awaits the same task. The entry is dropped once
    /// it finishes, so the next commit looks again (an album deleted during the import is made again).
    private func resolveAlbums() async throws(ImportDestinationFailure) -> [String] {
        var identifiers: [String] = []
        for album in albumPlan.albums {
            let task: Task<AlbumResolution, Never>
            if let running = albumResolutions[album.key] {
                task = running
            } else {
                let library = self.library, store = self.albumStore
                task = Task { await Self.resolve(album, library: library, store: store) }
                albumResolutions[album.key] = task
            }
            let resolution = await task.value
            if albumResolutions[album.key] == task { albumResolutions[album.key] = nil }
            switch resolution {
            case let .identifier(id): identifiers.append(id)
            case let .issue(issue): note(issue)
            case .denied: throw .photosAccessDenied
            }
        }
        return identifiers
    }

    private enum AlbumResolution: Sendable {
        case identifier(String)
        case issue(AlbumIssue)
        /// Creating the album failed as a denial (3311 or 3310).
        case denied
    }

    /// Resolutions in progress, by album key (see `resolveAlbums()`).
    private var albumResolutions: [String: Task<AlbumResolution, Never>] = [:]

    private static func resolve(_ album: AlbumPlan.Album, library: any PhotoLibraryClient,
                                store: any AlbumIdentifierStore) async -> AlbumResolution {
        if let stored = await store.albumIdentifier(forKey: album.key) {
            switch await library.album(withIdentifier: stored) {
            case .found(canAddContent: true):
                return .identifier(stored)
            case .found(canAddContent: false):
                return .issue(.doesNotAcceptPhotos(key: album.key))
            case .missing:
                break // deleted: adopt or make a new one below
            }
        }
        if let adopted = await adoptLegacy(album, library: library, store: store) { return adopted }
        do {
            let created = try await library.createAlbum(titled: album.title)
            await store.setAlbumIdentifier(created, forKey: album.key)
            return .identifier(created)
        } catch {
            if ImportDestinationFailure(photoLibraryFailure: error) == .photosAccessDenied { return .denied }
            return .issue(.couldNotCreate(key: album.key, detail: error.description))
        }
    }

    /// The first legacy key's album still in the library that accepts photos, stored under `album.key` too; nil when
    /// there is none. A legacy entry is never written or removed. Each adoption is recorded under
    /// `adoptionKey(forLegacy:)`, naming the key that took it, and a legacy key another key has taken is passed over:
    /// one camera key's old album is adopted by one name only. Otherwise a key seen under two names (the MSC key's
    /// "ILCE-7CM2" and, once another body is attached, the shared "Camera") would give its old album to both, and a
    /// second body's photos would be filed into the first body's album.
    private static func adoptLegacy(_ album: AlbumPlan.Album, library: any PhotoLibraryClient,
                                    store: any AlbumIdentifierStore) async -> AlbumResolution? {
        for legacy in album.legacyKeys {
            let adoption = AlbumPlan.adoptionKey(forLegacy: legacy)
            if let takenBy = await store.albumIdentifier(forKey: adoption), takenBy != album.key { continue }
            guard let id = await store.albumIdentifier(forKey: legacy) else { continue }
            guard case .found(canAddContent: true) = await library.album(withIdentifier: id) else { continue }
            await store.setAlbumIdentifier(album.key, forKey: adoption)
            await store.setAlbumIdentifier(id, forKey: album.key)
            return .identifier(id)
        }
        return nil
    }

    /// The position from the JPEG or HEIF first (cheap to read), then the ARW.
    private func location(for unit: CommitUnit) async -> GPSLocation? {
        switch unit {
        case let .single(f):
            return await metadata.gpsLocation(ofFileAt: f.url)
        case let .pair(raw, processed):
            if let l = await metadata.gpsLocation(ofFileAt: processed.url) { return l }
            return await metadata.gpsLocation(ofFileAt: raw.url)
        }
    }

    private func note(_ issue: AlbumIssue) {
        if !albumIssues.contains(issue) { albumIssues.append(issue) }
    }
}

/// Reads the Photos authorisation and decides the destination: before an import starts and again before a paused
/// or interrupted import continues (access can change in Settings while the app is away). Asks for `.readWrite` only
/// while it is not determined and the choice is *Import to Photos*, so the prompt comes once, at the first import to
/// Photos, and never for *Stage*; Limited Access with nothing selected is enough (decision 9).
public struct PhotosAccessGate: Sendable {
    private let library: any PhotoLibraryClient

    public init(library: any PhotoLibraryClient) {
        self.library = library
    }

    /// Before an import, or before a continue: never returns `.askForPhotosAccess`.
    ///
    /// - Parameters:
    ///   - choice: *Import to Photos* or *Stage*.
    ///   - staging: where staging goes now, for a staged decision.
    public func decision(for choice: DestinationKind, staging: StagingPlace) async -> DestinationDecision {
        if choice == .staging { return .staging(.chosen, staging) } // never reads or asks for Photos access
        let first = DestinationDecision.resolve(choice: choice, authorisation: await library.authorisation(),
                                                staging: staging)
        guard first == .askForPhotosAccess else { return first }
        let answered = await library.requestReadWriteAuthorisation()
        let second = DestinationDecision.resolve(choice: choice, authorisation: answered, staging: staging)
        // Still not determined (the prompt couldn't be shown): treat as a denial for this import rather than loop.
        return second == .askForPhotosAccess ? .staging(.photosDenied, staging) : second
    }

    /// After a save failed as a denial: staging for the rest of the import, with the reason read from the
    /// authorisation now.
    public func decisionAfterDeniedSave(staging: StagingPlace) async -> DestinationDecision {
        DestinationDecision.afterDeniedSave(authorisation: await library.authorisation(), staging: staging)
    }
}
