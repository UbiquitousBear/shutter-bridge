import Foundation

/// What PhotosBridge needs from the Photos library, so the Photos path's logic (album lookup by stored identifier,
/// the error mapping, the resources of a pair) is tested on Linux with a fake. `SystemPhotoLibrary` is the real one,
/// behind `#if canImport(Photos)`, and is tested in the hardware plan.
public protocol PhotoLibraryClient: Sendable {
    /// The `.readWrite` authorisation, read without asking (`PHPhotoLibrary.authorizationStatus(for: .readWrite)`).
    func authorisation() async -> PhotosAuthorisation
    /// Asks for `.readWrite` access. iOS shows the prompt once; afterwards this returns at once with the status.
    func requestReadWriteAuthorisation() async -> PhotosAuthorisation
    /// Looks an album up by its `localIdentifier`.
    func album(withIdentifier identifier: String) async -> AlbumLookup
    /// Creates an album with this title and returns its `localIdentifier`.
    func createAlbum(titled title: String) async throws(PhotoLibraryFailure) -> String
    /// Saves one asset in one change block, adds it to the albums given by identifier that accept new content, and
    /// returns the asset's `localIdentifier`.
    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) async throws(PhotoLibraryFailure) -> String
    /// Looks for an asset the app saved (backlog section 3.1, I15): library-wide by the date it was given, then by its
    /// original file names, role for role (`AssetQuery.matches(_:)`); the album is never consulted. Reads access,
    /// never asks for it. The default answers `.cannotSearch`, so a library that can't look leaves markers waiting.
    func findAsset(_ query: AssetQuery) async -> AssetSearch
}

/// The result of looking an album up by identifier.
public enum AlbumLookup: Sendable, Hashable {
    /// No album has this identifier (the person deleted it, or it was never made in this library).
    case missing
    /// Found; `canAddContent` is `canPerform(.addContent)`. Adding to an album that says no raises an exception, so
    /// it is checked first.
    case found(canAddContent: Bool)
}

/// An error from the Photos library, by domain and code, so the mapping can be tested without the framework.
public struct PhotoLibraryFailure: Error, Sendable, Hashable, CustomStringConvertible {
    public var domain: String
    public var code: Int
    public var detail: String

    public init(domain: String, code: Int, detail: String = "") {
        self.domain = domain
        self.code = code
        self.detail = detail
    }

    public init(_ error: any Error) {
        let ns = error as NSError
        self.init(domain: ns.domain, code: ns.code, detail: ns.localizedDescription)
    }

    /// `PHPhotosErrorDomain`, as the spike logged it.
    public static let photosErrorDomain = "PHPhotosErrorDomain"

    /// `PHPhotosError.Code` values this package acts on (Photos' public header values).
    public enum PhotosCode {
        /// `invalidResource`: what a `complete`-protected file gave while locked (spike, K1).
        public static let invalidResource = 3302
        /// `missingResource`.
        public static let missingResource = 3303
        /// `notEnoughSpace`.
        public static let notEnoughSpace = 3305
        /// `accessRestricted`.
        public static let accessRestricted = 3310
        /// `accessUserDenied`: every save on the *Don't Allow* run (8 Nov).
        public static let accessUserDenied = 3311
    }

    public var description: String { "\(domain) \(code)\(detail.isEmpty ? "" : ": \(detail)")" }
}

extension ImportDestinationFailure {
    /// The mapping from a Photos error to a commit failure (backlog section 5):
    /// - 3311 (`accessUserDenied`) and 3310 (`accessRestricted`) are a denial, not a failed file: the engine sends
    ///   this file and the rest to staging (`DestinationDecision.afterDeniedSave(authorisation:staging:)` picks the
    ///   reason);
    /// - 3305 is no room; 3303, or a Cocoa "no such file", is a staged file gone;
    /// - anything else is rejected, with the domain and code for the log. A 3302 lands here: staged files are
    ///   complete-until-first-unlock, so it means something else is wrong with the file.
    public init(photoLibraryFailure f: PhotoLibraryFailure) {
        switch (f.domain, f.code) {
        case (PhotoLibraryFailure.photosErrorDomain, PhotoLibraryFailure.PhotosCode.accessUserDenied),
             (PhotoLibraryFailure.photosErrorDomain, PhotoLibraryFailure.PhotosCode.accessRestricted):
            self = .photosAccessDenied
        case (PhotoLibraryFailure.photosErrorDomain, PhotoLibraryFailure.PhotosCode.notEnoughSpace):
            self = .notEnoughSpace
        case (PhotoLibraryFailure.photosErrorDomain, PhotoLibraryFailure.PhotosCode.missingResource):
            self = .stagedFileMissing
        case (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue),
             (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue):
            self = .stagedFileMissing
        case (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue):
            self = .notEnoughSpace
        default:
            self = .rejected(detail: f.description)
        }
    }
}

/// One asset to create, built from a commit unit (`AssetCreation.init(unit:options:)`), resources from file URLs only.
public struct AssetCreation: Sendable, Hashable {
    /// `PHAssetResourceType`'s two still roles used here.
    public enum Role: String, Sendable, Hashable {
        case photo
        case alternatePhoto
    }

    public struct Resource: Sendable, Hashable {
        public var role: Role
        /// The staged file; added with `addResource(with:fileURL:options:)`, never read into memory.
        public var fileURL: URL
        /// The camera's file name, kept as the resource's original file name; its extension gives the type.
        public var originalFilename: String

        public init(role: Role, fileURL: URL, originalFilename: String) {
            self.role = role
            self.fileURL = fileURL
            self.originalFilename = originalFilename
        }

        /// The uniform type identifier for the camera's own extensions, from `originalFilename`, case-insensitive;
        /// nil for any other. `SystemPhotoLibrary` gives Photos this type, because the staged file's own name may not
        /// carry the extension. Explicit rather than `UTType(filenameExtension:)` alone, which returns a dynamic
        /// `dyn.` type for an extension the system doesn't declare (whether iOS 27 declares Sony's `hif` is
        /// unverified). The ARW identifier is Apple's for Sony RAW; that Photos takes it for the α7C II's ARW is
        /// unverified (bench iPhone).
        public var knownTypeIdentifier: String? {
            switch (originalFilename as NSString).pathExtension.lowercased() {
            case "arw": "com.sony.arw-raw-image"
            case "jpg", "jpeg": "public.jpeg"
            case "hif", "heif": "public.heif"
            case "heic": "public.heic"
            default: nil
            }
        }
    }

    public var resources: [Resource]
    /// For a RAW+JPEG pair only: iOS 27's `PHAssetCreationRequest.originalResourceChoice` (setting it on an asset
    /// with one original is an error, Apple's documentation says). Nil for a lone file.
    public var originalChoice: PhotosImportOptions.PairOriginal?
    /// The camera's capture date, set as the asset's creation date.
    public var creationDate: Date?
    /// From the file's EXIF, if present.
    public var location: GPSLocation?

    public init(resources: [Resource], originalChoice: PhotosImportOptions.PairOriginal?, creationDate: Date?,
                location: GPSLocation?) {
        self.resources = resources
        self.originalChoice = originalChoice
        self.creationDate = creationDate
        self.location = location
    }

    /// The asset for a unit. A lone file is the `.photo`. A pair keeps the layout the proposal and Photos' own import
    /// use, the JPEG or HEIF as `.photo` and the ARW as `.alternatePhoto`, and says which is the original with
    /// `originalChoice` (default RAW, Shamil, 1 Nov).
    ///
    /// **Unverified (bench iPhone):** that `originalResourceChoice = .raw` with this layout makes the ARW the base
    /// for renders, and doesn't need the ARW added as `.photo` instead. Apple documents the property as choosing
    /// "whether the RAW or the compressed resource serves as the original" of a RAW+JPEG asset, which reads as
    /// independent of the roles; the hardware plan reads `PHAsset.originalResourceChoice` and the asset's resource
    /// types back after a save.
    public init(unit: CommitUnit, options: PhotosImportOptions, location: GPSLocation? = nil) {
        switch unit {
        case let .single(f):
            self.init(resources: [Resource(role: .photo, fileURL: f.url, originalFilename: f.filename)],
                      originalChoice: nil, creationDate: f.captureDate, location: location)
        case let .pair(raw, processed):
            self.init(resources: [
                Resource(role: .photo, fileURL: processed.url, originalFilename: processed.filename),
                Resource(role: .alternatePhoto, fileURL: raw.url, originalFilename: raw.filename),
            ], originalChoice: options.pairOriginal, creationDate: raw.captureDate ?? processed.captureDate,
            location: location)
        }
    }
}

/// A position from a file's EXIF GPS block.
public struct GPSLocation: Sendable, Hashable, Codable {
    /// Degrees, north positive.
    public var latitude: Double
    /// Degrees, east positive.
    public var longitude: Double
    /// Metres above sea level, negative below.
    public var altitude: Double?
    /// The GPS fix's time (UTC), when the block has one.
    public var timestamp: Date?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, timestamp: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
    }

    /// Reads ImageIO's GPS dictionary (`kCGImagePropertyGPSDictionary`), keyed by its string values: "Latitude",
    /// "LatitudeRef", "Longitude", "LongitudeRef", "Altitude", "AltitudeRef", "DateStamp", "TimeStamp", "Status".
    /// Nil when there is no usable position: missing or out-of-range coordinates, or a void fix ("Status" "V").
    /// Whether the α7C II writes a GPS block (from the phone, over Bluetooth) is unverified: the card's fixtures have
    /// none.
    public init?(exifGPS gps: [String: Any]) {
        if let status = gps["Status"] as? String, status.uppercased() == "V" { return nil }
        guard var lat = Self.number(gps["Latitude"]), var lon = Self.number(gps["Longitude"]),
              lat.isFinite, lon.isFinite else { return nil }
        lat = abs(lat)
        lon = abs(lon)
        if let ref = gps["LatitudeRef"] as? String, ref.uppercased().hasPrefix("S") { lat = -lat }
        if let ref = gps["LongitudeRef"] as? String, ref.uppercased().hasPrefix("W") { lon = -lon }
        guard lat <= 90, lon <= 180 else { return nil }
        var altitude: Double?
        if let alt = Self.number(gps["Altitude"]), alt.isFinite {
            let below = Self.number(gps["AltitudeRef"]) == 1
            altitude = below ? -abs(alt) : abs(alt)
        }
        self.init(latitude: lat, longitude: lon, altitude: altitude,
                  timestamp: Self.timestamp(date: gps["DateStamp"] as? String, time: gps["TimeStamp"] as? String))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let f as Float: Double(f)
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// "2026:11:05" and "09:41:07.25" (UTC) → a date.
    private static func timestamp(date: String?, time: String?) -> Date? {
        guard let date, let time else { return nil }
        let d = date.split(separator: ":").compactMap { Int($0) }
        let t = time.split(separator: ":")
        guard d.count == 3, t.count == 3, let h = Int(t[0]), let m = Int(t[1]), let s = Double(t[2]) else { return nil }
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")
        (c.year, c.month, c.day, c.hour, c.minute) = (d[0], d[1], d[2], h, m)
        c.second = Int(s)
        guard c.isValidDate, let whole = c.date else { return nil }
        return whole.addingTimeInterval(s - Double(Int(s)))
    }
}

/// Reads a position from a staged file's metadata. `ImageIOMetadataReader` on Apple platforms; tests pass a fake.
public protocol PhotoMetadataReader: Sendable {
    func gpsLocation(ofFileAt url: URL) async -> GPSLocation?
}

/// Reads nothing: the default where ImageIO isn't available.
public struct NoMetadataReader: PhotoMetadataReader {
    public init() {}
    public func gpsLocation(ofFileAt url: URL) async -> GPSLocation? { nil }
}

/// Where the albums' `localIdentifier`s are kept between launches. The app layer persists them; the identifier, not
/// the title, finds an album (two albums can share a title).
public protocol AlbumIdentifierStore: Sendable {
    func albumIdentifier(forKey key: String) async -> String?
    func setAlbumIdentifier(_ identifier: String?, forKey key: String) async
}

/// An album store that lives in memory: for tests, and until the app layer stores them.
public actor InMemoryAlbumIdentifierStore: AlbumIdentifierStore {
    private var identifiers: [String: String]

    public init(_ identifiers: [String: String] = [:]) {
        self.identifiers = identifiers
    }

    public func albumIdentifier(forKey key: String) -> String? { identifiers[key] }
    public func setAlbumIdentifier(_ identifier: String?, forKey key: String) { identifiers[key] = identifier }
    public var all: [String: String] { identifiers }
}

/// The albums one import's assets go into, from the person's album choice (Shamil, 1 Nov: one per camera by
/// default; one per import, dated; or both).
public struct AlbumPlan: Sendable, Hashable {
    public struct Album: Sendable, Hashable {
        /// The store key: "camera-name:<camera name>" (`AlbumPlan.cameraAlbumKey(named:)`) or "import:<import id>".
        public var key: String
        /// The title used when the album has to be created.
        public var title: String
        /// Store keys earlier builds kept this album under, tried in order only when `key` has no entry or its album
        /// is gone: the first that names an album still in the library that accepts photos, and that no other key has
        /// adopted (`AlbumPlan.adoptionKey(forLegacy:)`), is adopted (stored under `key` too) rather than a new album
        /// made. A legacy entry is only ever read, never written or removed.
        public var legacyKeys: [String]

        public init(key: String, title: String, legacyKeys: [String] = []) {
            self.key = key
            self.title = title
            self.legacyKeys = legacyKeys
        }
    }

    public var albums: [Album]

    public init(albums: [Album]) {
        self.albums = albums
    }

    /// The per-camera album's store key (D11, Shamil 12 Nov: one name per body): the camera's name, so every key the
    /// one body has (MSC, MTP, Wi-Fi) shares one album, and so do two bodies with one name (the risk accepted in D11 (a)).
    public static func cameraAlbumKey(named name: String) -> String { "camera-name:" + name }

    /// The store key builds before D11 kept a per-camera album under: the catalogue's camera key. Read only, to adopt
    /// that album (`Album.legacyKeys`).
    public static func legacyCameraAlbumKey(forCamera cameraKey: String) -> String { "camera:" + cameraKey }

    /// The store key recording which album key adopted a legacy key's album: its value is that album's key, not an
    /// album identifier. A legacy album is adopted by one key only, so a camera key seen under two names doesn't give
    /// its old album to both.
    public static func adoptionKey(forLegacy legacyKey: String) -> String { "adopted:" + legacyKey }

    /// - Parameters:
    ///   - cameraKey: the catalogue's camera key. It only finds the album an earlier build stored per key
    ///     (`legacyCameraAlbumKey(forCamera:)`), which is adopted the first time.
    ///   - cameraName: the camera's name: the per-camera album's title and its key (`cameraAlbumKey(named:)`), used
    ///     exactly as given.
    ///   - importID: what identifies this import, so a continued import finds its own album.
    ///   - importTitle: the per-import album's title; by default the camera's name and the import's date and time in
    ///     the phone's locale.
    public init(choice: PhotosImportOptions.Albums, cameraKey: String, cameraName: String, importID: String,
                importDate: Date, importTitle: String? = nil) {
        let perCamera = Album(key: Self.cameraAlbumKey(named: cameraName), title: cameraName,
                              legacyKeys: [Self.legacyCameraAlbumKey(forCamera: cameraKey)])
        let perImport = Album(key: "import:" + importID,
                              title: importTitle ?? "\(cameraName), \(importDate.formatted(date: .abbreviated, time: .shortened))")
        switch choice {
        case .perCamera: albums = [perCamera]
        case .perImport: albums = [perImport]
        case .both: albums = [perCamera, perImport]
        }
    }
}
