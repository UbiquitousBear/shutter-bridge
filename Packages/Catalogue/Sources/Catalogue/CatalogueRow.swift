import Foundation
import PTPKit

// The storage side of the catalogue in plain values: the columns a `CameraObject` row holds, the key that makes an
// identity unique in the store, and the stored form of a card listing. Pure Foundation, so the mapping between the
// public values and what SwiftData stores is unit-tested on Linux too; the SwiftData models only copy these columns.

extension ObjectIdentity {
    /// One string per identity, for the store's uniqueness check and lookups: every component length-prefixed (in
    /// UTF-8 bytes), so no two identities share a key whatever their names contain. Versioned, so a later change of
    /// form is a planned migration rather than a silent mismatch.
    ///
    /// Strings are compared byte for byte here, while `==` on `String` treats canonically equivalent forms as equal.
    /// The card's names are DCF's (upper-case ASCII letters, digits and `_`), where the two agree.
    var storageKey: String {
        var key = "v1"
        for part in [camera.rawValue, folder, filename, captureDate.rawValue, String(size)] {
            key += "|\(part.utf8.count):\(part)"
        }
        return key
    }
}

extension ObjectState {
    /// How far along a file is, to pick one row when a store holds two for an identity (which the store never writes
    /// itself, but a sync or a second store on the same file could): imported, then partial, skipped, new.
    var progressRank: Int {
        switch self {
        case .new: 0
        case .skipped: 1
        case .partial: 2
        case .imported: 3
        }
    }
}

/// One `CameraObject` row's columns. Sizes and offsets are `Int64` by bit pattern, because the store has no unsigned
/// integers; enums are their raw strings, so a value a later version adds reads back as a fallback, not a failure.
struct CatalogueRow: Sendable, Hashable {
    /// The camera's key again, beside the relationship to its `Camera` row, so lookups by camera need no join and a
    /// row whose relationship hasn't arrived (a later CloudKit sync) still knows its camera.
    var cameraKey: String
    var identityKey: String
    var folder: String
    var filename: String
    /// `YYYYMMDDThhmmss`, the camera's wall clock (`CaptureDate`).
    var captureDate: String
    var size: Int64
    var format: String
    var state: String
    var resumeOffset: Int64
    var assetLocalID: String?
    /// Where an import to Files put the file, relative to the app's Documents folder (PhotosBridge's `FileLocation`).
    var fileRelativePath: String?
    var pairStem: String
}

extension CatalogueRow {
    init(_ record: CatalogueRecord) {
        let id = record.identity
        var assetLocalID: String?
        var fileRelativePath: String?
        switch record.location {
        case let .photosAsset(localIdentifier): assetLocalID = localIdentifier
        case let .file(relativePath): fileRelativePath = relativePath
        case nil: break
        }
        self.init(cameraKey: id.camera.rawValue, identityKey: id.storageKey, folder: id.folder, filename: id.filename,
                  captureDate: id.captureDate.rawValue, size: Int64(bitPattern: id.size),
                  format: record.format.rawValue, state: record.state.rawValue,
                  resumeOffset: Int64(bitPattern: record.resumeOffset), assetLocalID: assetLocalID,
                  fileRelativePath: fileRelativePath, pairStem: id.pairStem)
    }

    /// The record this row holds; nil when its capture date isn't one (a row no version of this code writes).
    var record: CatalogueRecord? {
        guard let date = CaptureDate(rawValue: captureDate) else { return nil }
        let identity = ObjectIdentity(camera: CameraKey(rawValue: cameraKey), folder: folder, filename: filename,
                                      captureDate: date, size: UInt64(bitPattern: size))
        let location: ImportedLocation? = if let assetLocalID {
            .photosAsset(localIdentifier: assetLocalID)
        } else if let fileRelativePath {
            .file(relativePath: fileRelativePath)
        } else {
            nil
        }
        return CatalogueRecord(identity: identity, format: PTPMediaKind(rawValue: format) ?? .other,
                               state: objectState, location: location,
                               resumeOffset: UInt64(bitPattern: resumeOffset))
    }

    var objectState: ObjectState { ObjectState(rawValue: state) ?? .new }
}

/// A card listing as the store keeps it: one blob per camera (the entries without the camera key each would repeat),
/// beside the listing's date. One write per listing, however many files the card holds.
enum StoredListing {
    struct Blob: Codable {
        var version: Int
        var entries: [Entry]
    }

    struct Entry: Codable {
        var folder: String
        var filename: String
        var captureDate: CaptureDate
        var size: UInt64
        var format: String
    }

    enum Failure: Error, Sendable, Hashable {
        /// Not a listing this version can read.
        case unreadable
    }

    static let version = 1

    static func encode(_ listing: CardListing) throws -> Data {
        let entries = listing.entries.map {
            Entry(folder: $0.identity.folder, filename: $0.identity.filename, captureDate: $0.identity.captureDate,
                  size: $0.identity.size, format: $0.format.rawValue)
        }
        return try JSONEncoder().encode(Blob(version: version, entries: entries))
    }

    /// Throws `Failure.unreadable` for anything but a version-1 blob.
    static func decode(_ data: Data, camera: CameraKey, listedAt: Date) throws -> CardListing {
        let blob: Blob
        do {
            blob = try JSONDecoder().decode(Blob.self, from: data)
        } catch {
            throw Failure.unreadable
        }
        guard blob.version == version else { throw Failure.unreadable }
        let entries = blob.entries.map {
            CardListing.Entry(identity: ObjectIdentity(camera: camera, folder: $0.folder, filename: $0.filename,
                                                       captureDate: $0.captureDate, size: $0.size),
                              format: PTPMediaKind(rawValue: $0.format) ?? .other)
        }
        return CardListing(camera: camera, listedAt: listedAt, entries: entries)
    }
}
