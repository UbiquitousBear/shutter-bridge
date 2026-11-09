import Foundation
import PTPKit

/// Where a file is in the catalogue's eyes (proposal, "Data model and storage").
public enum ObjectState: String, Sendable, Hashable, Codable, CaseIterable {
    /// Not imported. Also the answer for an identity the catalogue has never seen.
    case new
    /// A download was started and not finished.
    case partial
    case imported
    /// The person or a failure took it out of the import.
    case skipped
}

/// Where an imported file went: one Photos asset (both files of a RAW+JPEG pair share it), or a file in the app's
/// Files folder when Photos access is denied (decision 9).
public enum ImportedLocation: Sendable, Hashable, Codable {
    case photosAsset(localIdentifier: String)
    /// Relative to the app's Documents folder, because the container's absolute path changes between installs.
    case file(relativePath: String)
}

/// One row of the ledger.
public struct CatalogueRecord: Sendable, Hashable, Codable {
    public var identity: ObjectIdentity
    public var format: PTPMediaKind
    public var state: ObjectState
    public var location: ImportedLocation?
    /// Bytes of a `.partial` file already on the phone, to resume from. Always 0 over USB, where an interrupted file
    /// is copied again from its start (decision 7, and USB links don't resume); written by `markPartial` for Wi-Fi.
    public var resumeOffset: UInt64
    /// The `.partial` file holding the first `resumeOffset` bytes, while the row is `.partial` (Wi-Fi, Iteration 3;
    /// written by `markPartial`). **Relative to the engine's staging folder**, with no base URL, because iOS moves the
    /// app's data container to a new path when the app is updated or reinstalled, so a stored absolute path would no
    /// longer exist after a TestFlight update (as `ImportedLocation.file` is relative to Documents). Resolve it with
    /// `partialFile(in:)`. A reader still checks that the file is there and holds at least `resumeOffset` bytes
    /// before resuming from it, and restarts the file when it doesn't. Nil on every other row.
    public var tempURL: URL?

    public init(identity: ObjectIdentity, format: PTPMediaKind, state: ObjectState, location: ImportedLocation? = nil,
                resumeOffset: UInt64 = 0, tempURL: URL? = nil) {
        self.identity = identity
        self.format = format
        self.state = state
        self.location = location
        self.resumeOffset = resumeOffset
        self.tempURL = tempURL
    }

    /// The partial file's location now: `tempURL` resolved against `stagingDirectory` (the folder it was relative to
    /// when the checkpoint was written, at the container's current path). Nil when the row has no partial file.
    public func partialFile(in stagingDirectory: URL) -> URL? {
        guard let tempURL else { return nil }
        return stagingDirectory.appendingPathComponent(tempURL.relativePath, isDirectory: false)
    }

    private enum CodingKeys: String, CodingKey {
        case identity, format, state, location, resumeOffset, tempURL
    }

    // Written by hand so a record encoded before `resumeOffset` or `tempURL` existed still decodes (as 0 and nil).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(ObjectIdentity.self, forKey: .identity)
        format = try c.decode(PTPMediaKind.self, forKey: .format)
        state = try c.decode(ObjectState.self, forKey: .state)
        location = try c.decodeIfPresent(ImportedLocation.self, forKey: .location)
        resumeOffset = try c.decodeIfPresent(UInt64.self, forKey: .resumeOffset) ?? 0
        tempURL = try c.decodeIfPresent(URL.self, forKey: .tempURL)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(format, forKey: .format)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(resumeOffset, forKey: .resumeOffset)
        try c.encodeIfPresent(tempURL, forKey: .tempURL)
    }
}

/// The last listing of one camera's card, so Browse can show the last-known card at once while ImageCaptureCore
/// lists (decision 7). Names, dates and sizes only; thumbnails stay in memory unless week 1 adds a disk cache.
public struct CardListing: Sendable, Hashable, Codable {
    public struct Entry: Sendable, Hashable, Codable {
        public var identity: ObjectIdentity
        public var format: PTPMediaKind

        public init(identity: ObjectIdentity, format: PTPMediaKind) {
            self.identity = identity
            self.format = format
        }
    }

    public var camera: CameraKey
    public var listedAt: Date
    public var entries: [Entry]

    public init(camera: CameraKey, listedAt: Date, entries: [Entry]) {
        self.camera = camera
        self.listedAt = listedAt
        self.entries = entries
    }
}

/// The catalogue as the engine sees it. An actor, so no write ever runs on the main actor (backlog section 4). Two
/// implementations: `InMemoryCatalogue` (tests and previews, any platform) and `SwiftDataCatalogue`, a `ModelActor`
/// (where SwiftData exists). Both pass the same contract tests (`CatalogueContractTests`, `CameraRowContractTests`).
///
/// Besides file rows and listings, a store keeps one `CameraRecord` per camera (the `Camera` row, Iteration 3) and
/// download checkpoints for resumable Wi-Fi downloads (`markPartial`). It never stores a network password.
///
/// Rows are unique per store by their full identity (camera, folder, name, capture date, size): the store, not the
/// schema, enforces it (a SwiftData schema with a unique attribute can't sync through CloudKit, which the proposal
/// keeps open for a later opt-in; backlog section 4).
///
/// **"Already imported" is answered by content** (Shamil, 8 Nov): `states(of:)` matches rows by file name (ignoring
/// ASCII case), capture time to the second and size (`ObjectIdentity.ContentKey`), ignoring the camera key and the
/// folder, so a file imported in MSC reads as imported in MTP. Rows of the same content under several cameras or
/// folders are allowed, and all count; nothing asserts that content is unique.
public protocol CatalogueStore: Actor {
    /// The row for exactly this identity (camera and folder included), if there is one: where that copy went.
    func record(for identity: ObjectIdentity) throws -> CatalogueRecord?

    /// The state of each identity: the furthest along (imported, partial, skipped, new) of every row with the same
    /// content, whatever its camera key or folder; `.new` when no row matches. This is the diff the engine runs
    /// (stage 3), and Browse's Imported badge.
    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState]

    /// Inserts the row, or updates the one with the same full identity: a second insert never duplicates. A row of
    /// the same content under another camera or folder is a row of its own and is left alone.
    func upsert(_ record: CatalogueRecord) throws

    /// Replaces the stored listing for the listing's camera.
    func saveListing(_ listing: CardListing) throws

    /// The last listing stored for a camera, if any.
    func lastListing(for camera: CameraKey) throws -> CardListing?

    // MARK: Partial files (Iteration 3)

    /// Records a download checkpoint (the engine writes one every 16 MiB, `PTPPartialRead.crossesCheckpoint`, and
    /// on a pause): the row for exactly this identity becomes `.partial`, with `resumeOffset` = `offset` and
    /// `tempURL`, and is inserted when there is none. Any location the row had is kept. A row that is already
    /// `.imported` is left as it is, so a checkpoint flushed after the file was committed never undoes the commit.
    /// Throws `CatalogueFailure.resumeOffsetPastEnd` when `offset` is larger than the identity's size.
    ///
    /// `tempURL` is relative to the engine's staging folder: a relative URL (`URL(string: "<job>/<file>.partial")`)
    /// or one made relative to the staging folder (`URL(fileURLWithPath: "<job>/<file>.partial", relativeTo:
    /// staging)`). Only its relative part is stored. Throws `CatalogueFailure.partialFileNotRelative` for an absolute
    /// URL, which would point nowhere once an app update moves the container.
    ///
    /// Committing the file is an ordinary `upsert` of an `.imported` record, which clears the offset and the
    /// temporary file; restarting a file from 0 is a `markPartial` with offset 0 (or an `upsert`).
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws

    // MARK: The Camera row (Iteration 3)

    /// The stored camera with this key, if the catalogue has one. A camera gets a row as soon as it has a file row
    /// or a listing (with empty names and `lastSeen` from the listing), not only through `upsertCamera(_:)`.
    func camera(_ key: CameraKey) throws -> CameraRecord?

    /// Every stored camera, the most recently seen first (ties by key), one per key. For the proximity scan's list
    /// of known peripherals (Iteration 4) and the Cameras screen.
    func cameras() throws -> [CameraRecord]

    /// Inserts the camera, or updates the one with the same key: every field is written as given, except
    /// `lastSeen`, which never moves backwards. The camera's file rows and last listing are left alone.
    ///
    /// To change some fields, use `updateCamera(_:_:)` instead: an upsert built from an earlier `camera(_:)` read,
    /// with an `await` in between, writes back that read's value of every other field and loses a write made in the
    /// meantime (the Bluetooth link storing the peripheral while the Wi-Fi link stores the GUID).
    func upsertCamera(_ record: CameraRecord) throws
}

extension CatalogueStore {
    /// Changes the stored camera in one actor call, so concurrent changes to different fields never lose each other:
    /// reads the key's camera (`CameraRecord(key:)` when there is none), applies `change`, and writes the result with
    /// `upsertCamera(_:)`, with no suspension in between. `change` can't move the record to another key. Returns the
    /// camera as stored (`lastSeen` never moves backwards). Every partial write of the Camera row (the onboarding's
    /// peripheral, the Wi-Fi link's GUID and address, the join's network name) goes through here.
    @discardableResult
    public func updateCamera(_ key: CameraKey, _ change: @Sendable (inout CameraRecord) -> Void) throws
        -> CameraRecord {
        let stored = try camera(key)
        var record = stored ?? CameraRecord(key: key)
        change(&record)
        record.key = key
        try upsertCamera(record)
        return record.written(over: stored)
    }
}
