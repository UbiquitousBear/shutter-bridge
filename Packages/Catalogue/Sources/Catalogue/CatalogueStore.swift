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
/// Files folder, where builds before 11 Nov imported when Files was chosen or Photos access was denied (decision 9).
/// Staging replaced the Files folder (Shamil, 11 Nov) and is recorded apart, in `CatalogueRecord.staged`; rows with a
/// `.file` location stay imported and keep reading as they are.
public enum ImportedLocation: Sendable, Hashable, Codable {
    case photosAsset(localIdentifier: String)
    /// Relative to the app's Documents folder, because the container's absolute path changes between installs.
    case file(relativePath: String)
}

/// Which staging root a staged file is under (PhotosBridge's `StagingPlace`, without the reason).
public enum StagingRoot: String, Sendable, Hashable, Codable, CaseIterable {
    /// iCloud Drive › Shutter Bridge: the Documents folder of the app's iCloud container.
    case iCloudDrive
    /// On My iPhone › Shutter Bridge: the app's own Documents folder.
    case onThisIPhone
}

/// Where a staged copy of a file is (Shamil, 11 Nov): the root and the path under it, for example
/// "Staging/ILCE-7CM2/2026-11-08/DSC00001.ARW", and when it was staged. Relative, because the container's absolute
/// path changes between installs and updates.
///
/// **Resolve it only with `fileURL(in:)`.** Anything that acts on a staged copy (culling, *Import keepers*, the
/// staging clean-up) gets its file from there, never by appending `relativePath` to a folder itself: the path may be
/// unknown, and the root's Documents folder also holds the Files folders of builds before 11 Nov, one of which may be
/// a camera's folder named "Staging" (`FilesFolderNaming.folderName(forCamera:)`).
public struct StagedLocation: Sendable, Hashable, Codable {
    public var root: StagingRoot
    /// The path under the root's Documents folder, starting "Staging/". **Empty means unknown**: the file was staged
    /// but its destination didn't say where (the engine's `unreportedStagedLocation(for:)`). The row still reads as
    /// staged, so the file isn't staged twice, but the path must never be resolved to a file: `fileURL(in:)` refuses
    /// it.
    public var relativePath: String
    /// When the file was staged; nil when not known.
    public var stagedAt: Date?

    /// The staging folder under each root's Documents folder: the first component of every path recorded.
    public static let stagingFolderName = "Staging"

    public init(root: StagingRoot, relativePath: String, stagedAt: Date? = nil) {
        self.root = root
        self.relativePath = relativePath
        self.stagedAt = stagedAt
    }

    /// Whether `relativePath` names a file inside the staging folder: "Staging/" and at least one more component,
    /// none of them empty, "." or "..", and no leading "/". False for an unknown (empty) path.
    public var isResolvable: Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components[0] == Self.stagingFolderName else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The staged copy's file under `documents`, the Documents folder of the location's root (`root`: the iCloud
    /// container's or the app's own); nil when the path is unknown (empty) or doesn't name a file inside the staging
    /// folder (`isResolvable`). The only way code may turn a staged copy into a file to read, move or remove.
    public func fileURL(in documents: URL) -> URL? {
        guard isResolvable else { return nil }
        var url = documents
        let components = relativePath.split(separator: "/")
        for (i, component) in components.enumerated() {
            url = url.appendingPathComponent(String(component), isDirectory: i < components.count - 1)
        }
        return url
    }
}

/// One row of the ledger.
///
/// Being staged is a fact of its own, beside the state rather than one of its values (Shamil, 11 Nov): a file can be
/// new and staged (waiting to be culled), imported and staged, or either and not staged. So *Import to Photos* still
/// offers staged files, *Stage* leaves them out, and Browse shows Staged beside Imported.
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
    /// Where the staged copy is, when the file has been staged (`markStaged`); nil otherwise. Written only by
    /// `markStaged` and `clearStaged`: `upsert` and `markPartial` keep what the row has.
    public var staged: StagedLocation?

    public init(identity: ObjectIdentity, format: PTPMediaKind, state: ObjectState, location: ImportedLocation? = nil,
                resumeOffset: UInt64 = 0, tempURL: URL? = nil, staged: StagedLocation? = nil) {
        self.identity = identity
        self.format = format
        self.state = state
        self.location = location
        self.resumeOffset = resumeOffset
        self.tempURL = tempURL
        self.staged = staged
    }

    /// The partial file's location now: `tempURL` resolved against `stagingDirectory` (the folder it was relative to
    /// when the checkpoint was written, at the container's current path). Nil when the row has no partial file.
    public func partialFile(in stagingDirectory: URL) -> URL? {
        guard let tempURL else { return nil }
        return stagingDirectory.appendingPathComponent(tempURL.relativePath, isDirectory: false)
    }

    private enum CodingKeys: String, CodingKey {
        case identity, format, state, location, resumeOffset, tempURL, staged
    }

    // Written by hand so a record encoded before `resumeOffset`, `tempURL` or `staged` existed still decodes (as 0
    // and nil), and a staged copy this build can't read (a root a later version adds) reads as nil, not a failure.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(ObjectIdentity.self, forKey: .identity)
        format = try c.decode(PTPMediaKind.self, forKey: .format)
        state = try c.decode(ObjectState.self, forKey: .state)
        location = try c.decodeIfPresent(ImportedLocation.self, forKey: .location)
        resumeOffset = try c.decodeIfPresent(UInt64.self, forKey: .resumeOffset) ?? 0
        tempURL = try c.decodeIfPresent(URL.self, forKey: .tempURL)
        staged = (try? c.decodeIfPresent(StagedLocation.self, forKey: .staged)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(format, forKey: .format)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(resumeOffset, forKey: .resumeOffset)
        try c.encodeIfPresent(tempURL, forKey: .tempURL)
        try c.encodeIfPresent(staged, forKey: .staged)
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
    ///
    /// The staged copy is not upsert's to change (Shamil, 11 Nov): an update keeps the row's `staged` whatever the
    /// record says, so an import to Photos never forgets a staged copy; a row it inserts takes the record's.
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
    /// temporary file; restarting a file from 0 is a `markPartial` with offset 0 (or an `upsert`). A staged copy is
    /// kept.
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws

    // MARK: Staging (Shamil, 11 Nov)

    /// Records that the file was staged, at `location`: the row for exactly this identity gets `staged` = `location`
    /// and is inserted (`.new`) when there is none. Its state and location are kept, so an imported file stays
    /// imported; a `.partial` row goes back to `.new` with its resume offset and temporary file cleared, because the
    /// partial file was consumed by the staging commit.
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws

    /// Forgets the staged copy of the row for exactly this identity (its file was removed from Staging); the state and
    /// location are kept. Nothing happens when there is no row.
    func clearStaged(_ identity: ObjectIdentity) throws

    /// The identities that have a staged copy, matched by content as `states(of:)` is (file name ignoring ASCII
    /// case, capture time to the second, size; whatever the camera key or folder), so a file staged in MSC reads as
    /// staged in MTP. For Browse's Staged badge and for *Stage* leaving out what is already staged.
    func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity>

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
