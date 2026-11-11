#if canImport(Photos)
import CoreLocation
import Foundation
import Photos
import UniformTypeIdentifiers

/// The real Photos library, for `PhotosLibraryDestination` and `PhotosAccessGate`. Compiled only where Photos exists
/// (GitHub Actions builds it for iOS 27 with Xcode 27.1); its behaviour is checked on the bench iPhone, in the hardware
/// plan. The calls are the ones the spike's `PhotosProbe` used on iOS 27.2 and 27.3, except `originalResourceChoice`
/// (new in iOS 27, not run in the spike).
public struct SystemPhotoLibrary: PhotoLibraryClient {
    public init() {}

    public func authorisation() async -> PhotosAuthorisation {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestReadWriteAuthorisation() async -> PhotosAuthorisation {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    public func album(withIdentifier identifier: String) async -> AlbumLookup {
        let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
        guard let album = result.firstObject else { return .missing }
        return .found(canAddContent: album.canPerform(.addContent))
    }

    public func createAlbum(titled title: String) async throws(PhotoLibraryFailure) -> String {
        let created = Box()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                created.set(request.placeholderForCreatedAssetCollection.localIdentifier)
            }
        } catch {
            throw PhotoLibraryFailure(error)
        }
        guard let identifier = created.get() else {
            throw PhotoLibraryFailure(domain: "ShutterBridge.PhotosBridge", code: 1, detail: "no album placeholder")
        }
        return identifier
    }

    public func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) async throws(PhotoLibraryFailure) -> String {
        let created = Box()
        do {
            // Only Sendable values cross into the change block; Photos objects are fetched inside it.
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                for resource in asset.resources {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = resource.originalFilename
                    // The staged file's own name may not carry the camera's extension, so give the type explicitly:
                    // the camera's extensions by name, others only when the system declares them (an undeclared
                    // extension gives a dynamic `dyn.` type, which tells Photos nothing).
                    if let known = resource.knownTypeIdentifier {
                        options.uniformTypeIdentifier = known
                    } else {
                        let ext = (resource.originalFilename as NSString).pathExtension
                        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic {
                            options.uniformTypeIdentifier = type.identifier
                        }
                    }
                    // Photos copies the file; the destination deletes the staged file after a successful save, so a
                    // refused save leaves it for the staging fallback. Moving (`shouldMoveFile`) is untested.
                    options.shouldMoveFile = false
                    request.addResource(with: Self.map(resource.role), fileURL: resource.fileURL, options: options)
                }
                if let choice = asset.originalChoice, asset.resources.count > 1 {
                    // iOS 27; RAW+JPEG assets only (an error on a single original, Apple's documentation says).
                    if #available(iOS 27.0, macOS 27.0, *) {
                        request.originalResourceChoice = choice == .raw ? .raw : .compressed
                    }
                }
                if let date = asset.creationDate { request.creationDate = date }
                if let gps = asset.location {
                    let coordinate = CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude)
                    request.location = CLLocation(coordinate: coordinate,
                                                  altitude: gps.altitude ?? 0,
                                                  horizontalAccuracy: 0,
                                                  verticalAccuracy: gps.altitude == nil ? -1 : 0,
                                                  timestamp: gps.timestamp ?? asset.creationDate ?? Date())
                }
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                created.set(placeholder.localIdentifier)
                if !albumIdentifiers.isEmpty {
                    let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIdentifiers, options: nil)
                    for index in 0 ..< albums.count {
                        let album = albums.object(at: index)
                        // Checked again here: adding to an album that refuses content raises an exception.
                        guard album.canPerform(.addContent),
                              let change = PHAssetCollectionChangeRequest(for: album) else { continue }
                        change.addAssets([placeholder] as NSArray)
                    }
                }
            }
        } catch {
            throw PhotoLibraryFailure(error)
        }
        guard let identifier = created.get() else {
            throw PhotoLibraryFailure(domain: "ShutterBridge.PhotosBridge", code: 2, detail: "no asset placeholder")
        }
        return identifier
    }

    static func map(_ status: PHAuthorizationStatus) -> PhotosAuthorisation {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorised
        case .limited: .limited
        // A status this build doesn't know: staging is the side that can't lose a photo.
        @unknown default: .denied
        }
    }

    static func map(_ role: AssetCreation.Role) -> PHAssetResourceType {
        switch role {
        case .photo: .photo
        case .alternatePhoto: .alternatePhoto
        }
    }

    /// Carries an identifier out of a change block, which runs on another queue.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func set(_ v: String) { lock.withLock { value = v } }
        func get() -> String? { lock.withLock { value } }
    }
}

extension PhotosLibraryDestination {
    /// The Photos destination on the real library, reading positions with ImageIO.
    public init(albumStore: any AlbumIdentifierStore, options: PhotosImportOptions = PhotosImportOptions(),
                albumPlan: AlbumPlan) {
        self.init(library: SystemPhotoLibrary(), albumStore: albumStore, metadata: ImageIOMetadataReader(),
                  options: options, albumPlan: albumPlan)
    }
}

extension PhotosAccessGate {
    /// The gate on the real library.
    public init() {
        self.init(library: SystemPhotoLibrary())
    }
}
#endif

#if canImport(ImageIO)
import Foundation
import ImageIO

/// Reads the GPS block of a staged file's metadata with ImageIO, without decoding the image. Whether ImageIO reads
/// the α7C II's ARW metadata is unverified; the Photos destination tries the JPEG or HEIF of a pair first.
public struct ImageIOMetadataReader: PhotoMetadataReader {
    public init() {}

    public func gpsLocation(ofFileAt url: URL) async -> GPSLocation? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any],
              let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] else { return nil }
        // Re-keyed by the names `GPSLocation(exifGPS:)` reads, from ImageIO's own constants.
        let keys: [(CFString, String)] = [
            (kCGImagePropertyGPSLatitude, "Latitude"), (kCGImagePropertyGPSLatitudeRef, "LatitudeRef"),
            (kCGImagePropertyGPSLongitude, "Longitude"), (kCGImagePropertyGPSLongitudeRef, "LongitudeRef"),
            (kCGImagePropertyGPSAltitude, "Altitude"), (kCGImagePropertyGPSAltitudeRef, "AltitudeRef"),
            (kCGImagePropertyGPSDateStamp, "DateStamp"), (kCGImagePropertyGPSTimeStamp, "TimeStamp"),
            (kCGImagePropertyGPSStatus, "Status"),
        ]
        var block: [String: Any] = [:]
        for (key, name) in keys {
            if let value = gps[key as String] { block[name] = value }
        }
        return GPSLocation(exifGPS: block)
    }
}
#endif
