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
    /// Bytes of a `.partial` file already on the phone, to resume from. Always 0 over USB in Iteration 1, where an
    /// interrupted file is copied again from its start (decision 7); it is for Wi-Fi.
    public var resumeOffset: UInt64

    public init(identity: ObjectIdentity, format: PTPMediaKind, state: ObjectState, location: ImportedLocation? = nil,
                resumeOffset: UInt64 = 0) {
        self.identity = identity
        self.format = format
        self.state = state
        self.location = location
        self.resumeOffset = resumeOffset
    }

    private enum CodingKeys: String, CodingKey {
        case identity, format, state, location, resumeOffset
    }

    // Written by hand so a record encoded before `resumeOffset` existed still decodes (as 0).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(ObjectIdentity.self, forKey: .identity)
        format = try c.decode(PTPMediaKind.self, forKey: .format)
        state = try c.decode(ObjectState.self, forKey: .state)
        location = try c.decodeIfPresent(ImportedLocation.self, forKey: .location)
        resumeOffset = try c.decodeIfPresent(UInt64.self, forKey: .resumeOffset) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(format, forKey: .format)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(resumeOffset, forKey: .resumeOffset)
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
/// (where SwiftData exists). Both pass the same contract tests (`CatalogueContractTests`).
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
}
