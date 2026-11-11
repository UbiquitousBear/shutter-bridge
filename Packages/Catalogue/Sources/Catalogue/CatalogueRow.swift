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
    /// How far along a file is, to pick one state when several rows hold one file: two rows for an identity (which
    /// the store never writes itself, but a sync or a second store on the same file could), or rows of the same
    /// content under several cameras or folders (Shamil's rule of 8 Nov). Imported, then partial, skipped, new.
    var progressRank: Int {
        switch self {
        case .new: 0
        case .skipped: 1
        case .partial: 2
        case .imported: 3
        }
    }

    /// The further along of two states; `self` when they are equal.
    func furthestAlong(_ other: ObjectState) -> ObjectState {
        other.progressRank > progressRank ? other : self
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
    /// The `.partial` file of a resumable download (`CatalogueRecord.tempURL`); nil on every other row.
    var tempURL: URL? = nil
    var assetLocalID: String?
    /// Where an import to Files put the file, relative to the app's Documents folder (builds before 11 Nov).
    var fileRelativePath: String?
    var pairStem: String
    /// New in `CatalogueSchemaV3`: the staged copy's path under its root (`StagedLocation.relativePath`); nil when the
    /// file isn't staged.
    var stagedRelativePath: String? = nil
    /// New in `CatalogueSchemaV3`: `StagingRoot`'s raw value, so a root a later version adds reads as not staged
    /// rather than failing.
    var stagedRoot: String? = nil
    /// New in `CatalogueSchemaV3`: when the file was staged.
    var stagedAt: Date? = nil
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
                  resumeOffset: Int64(bitPattern: record.resumeOffset), tempURL: record.tempURL,
                  assetLocalID: assetLocalID, fileRelativePath: fileRelativePath, pairStem: id.pairStem,
                  stagedRelativePath: record.staged?.relativePath, stagedRoot: record.staged?.root.rawValue,
                  stagedAt: record.staged?.stagedAt)
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
                               resumeOffset: UInt64(bitPattern: resumeOffset), tempURL: tempURL, staged: staged)
    }

    var objectState: ObjectState { ObjectState(rawValue: state) ?? .new }

    /// The staged copy; nil when there is no path, or the root is one this build doesn't know.
    var staged: StagedLocation? {
        guard let stagedRelativePath, let stagedRoot, let root = StagingRoot(rawValue: stagedRoot) else { return nil }
        return StagedLocation(root: root, relativePath: stagedRelativePath, stagedAt: stagedAt)
    }

    /// What "already imported" matches this row on (`ObjectIdentity.ContentKey`), from the columns every row has had
    /// since build 17.1, so rows written before the rule match with nothing recomputed. Nil when the stored date
    /// isn't one (a row no version of this code writes).
    var contentKey: ObjectIdentity.ContentKey? {
        guard let date = CaptureDate(rawValue: captureDate) else { return nil }
        return ObjectIdentity.ContentKey(filename: filename, captureDate: date, size: UInt64(bitPattern: size))
    }
}

/// Shamil's rule of 8 Nov in one place, for both stores: a file is as far along as the furthest-along row with the
/// same content (file name ignoring ASCII case, capture time to the second, size), whatever the row's camera key or
/// folder. Rows don't have to be unique by content: two rows of one file under two cameras (build 17.1 wrote them
/// for a file imported in MSC and again in MTP) both count, and neither is lost.
enum ContentMatch {
    /// The state of each identity among `rows`, which must include every row that could match (more is fine);
    /// `.new` for identities no row matches. Rows whose date doesn't parse match nothing.
    static func states(of identities: [ObjectIdentity], among rows: some Sequence<CatalogueRow>)
        -> [ObjectIdentity: ObjectState] {
        var known: [ObjectIdentity.ContentKey: ObjectState] = [:]
        for row in rows {
            guard let key = row.contentKey else { continue }
            known[key] = known[key].map { $0.furthestAlong(row.objectState) } ?? row.objectState
        }
        var out: [ObjectIdentity: ObjectState] = [:]
        for identity in identities {
            out[identity] = known[identity.contentKey] ?? .new
        }
        return out
    }

    /// The identities among `identities` that some row of `rows` with the same content has a staged copy for
    /// (`CatalogueStore.stagedStates(of:)`). `rows` must include every row that could match (more is fine).
    static func staged(of identities: [ObjectIdentity], among rows: some Sequence<CatalogueRow>)
        -> Set<ObjectIdentity> {
        var stagedKeys: Set<ObjectIdentity.ContentKey> = []
        for row in rows where row.staged != nil {
            if let key = row.contentKey { stagedKeys.insert(key) }
        }
        return Set(identities.filter { stagedKeys.contains($0.contentKey) })
    }
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

/// One `Camera` row's columns as plain values (the counterpart of `CatalogueRow` for `CameraRecord`), so the mapping
/// is unit-tested on Linux; the SwiftData model only copies these. The carrier is its raw string, so a value a later
/// version adds reads back as `.usb` (the column's default since build 17.1), not a failure.
struct CameraColumns: Sendable, Hashable {
    /// The `CameraKey`'s value (`CameraRecord.key`); the column has had this name since build 17.1.
    var serial: String
    var model: String
    var friendlyName: String
    var lastSeen: Date
    var preferredCarrier: String
    var autoImport: Bool
    var wifiSSID: String?
    var lastIP: String?
    var ptpipGUID: UUID?
    /// New in `CatalogueSchemaV2`.
    var bluetoothPeripheralID: UUID?
}

extension CameraColumns {
    init(_ record: CameraRecord) {
        self.init(serial: record.key.rawValue, model: record.model, friendlyName: record.friendlyName,
                  lastSeen: record.lastSeen, preferredCarrier: record.preferredCarrier.rawValue,
                  autoImport: record.autoImport, wifiSSID: record.wifiSSID, lastIP: record.lastIP,
                  ptpipGUID: record.ptpipGUID, bluetoothPeripheralID: record.bluetoothPeripheralID)
    }

    var record: CameraRecord {
        CameraRecord(key: CameraKey(rawValue: serial), model: model, friendlyName: friendlyName, lastSeen: lastSeen,
                     preferredCarrier: CameraRecord.Carrier(rawValue: preferredCarrier) ?? .usb,
                     autoImport: autoImport, wifiSSID: wifiSSID, lastIP: lastIP, ptpipGUID: ptpipGUID,
                     bluetoothPeripheralID: bluetoothPeripheralID)
    }
}

/// The order `cameras()` answers in, for both stores: the most recently seen first, then by key, one per key.
///
/// A store should hold one row per key, by its own rule, but a second store on the same file or a later sync could
/// leave two. Every read then answers with the same one (`preferred(_:)`), whatever order the rows were fetched in.
enum CameraOrder {
    static func sorted(_ cameras: some Sequence<CameraRecord>) -> [CameraRecord] {
        var best: [CameraKey: CameraRecord] = [:]
        for camera in cameras {
            if let kept = best[camera.key], !prefers(camera, over: kept) { continue }
            best[camera.key] = camera
        }
        return best.values.sorted {
            $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.key.rawValue < $1.key.rawValue
        }
    }

    /// The index of the row to answer with among rows of one key: the most recently seen, then one with a Bluetooth
    /// peripheral, then the first of equals. `SwiftDataCatalogue.upsertCamera` writes the same fields to every row
    /// of the key, so rows that tie hold the same fields once any camera write has run. Nil when there are none.
    static func preferred(_ rows: [CameraRecord]) -> Int? {
        guard var best = rows.indices.first else { return nil }
        for index in rows.indices.dropFirst() where prefers(rows[index], over: rows[best]) {
            best = index
        }
        return best
    }

    /// Whether `a` is to be answered with rather than `b`, two rows of the same key.
    static func prefers(_ a: CameraRecord, over b: CameraRecord) -> Bool {
        if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
        return a.bluetoothPeripheralID != nil && b.bluetoothPeripheralID == nil
    }
}
