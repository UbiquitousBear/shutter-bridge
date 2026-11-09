#if canImport(SwiftData)
import Foundation
import SwiftData

// The catalogue's SwiftData schema (backlog section 4; proposal, "Data model and storage"). Compiled only where
// SwiftData exists: CI builds it for iOS 27 with Xcode 27.1 and runs the contract tests against it in the iOS
// Simulator; Linux builds the rest of the package without it.
//
// Versioned from the first release, so every later change is a planned migration (`CatalogueMigrationPlan`), never an
// inferred one. Version 1 (this file) is what every build before Catalogue V2 (17.1 and 18.1) shipped, and is frozen:
// its models' stored properties must never change, or a store written by those builds stops opening ("Shutter Bridge
// couldn't start"). Version 2 (`CatalogueSchemaV2.swift`, Iteration 3) adds the Camera row's Bluetooth peripheral
// identifier through a lightweight stage. Iteration 2's cull marks and the like arrive as a further version and stage.
//
// Kept CloudKit-compatible for a later opt-in (proposal): no `@Attribute(.unique)` (the store enforces identity, see
// `SwiftDataCatalogue`), every attribute optional or defaulted, every relationship optional with an inverse.
//
// The models are internal: `@Model` classes aren't `Sendable`, and every write goes through `SwiftDataCatalogue`,
// off the main actor. Callers see `CatalogueRecord` and `CardListing`.

/// Version 1 of the catalogue's schema: `Camera`, `CameraObject` and `ImportJob`.
public enum CatalogueSchemaV1: VersionedSchema, Sendable {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [Camera.self, CameraObject.self, ImportJob.self]
    }
}

/// Every version of the schema, oldest first, and the stages between them.
///
/// - V1 → V2 (Iteration 3): lightweight. V2 adds one optional attribute, `Camera.bluetoothPeripheralID`, which reads
///   nil on every migrated row; nothing else changes, so every V1 row, listing and camera field is carried as it is.
public enum CatalogueMigrationPlan: SchemaMigrationPlan, Sendable {
    public static var schemas: [any VersionedSchema.Type] { [CatalogueSchemaV1.self, CatalogueSchemaV2.self] }

    public static var stages: [MigrationStage] { [v1ToV2] }

    /// V1 → V2: the peripheral identifier, optional, so no row needs a value and no custom stage is needed.
    static var v1ToV2: MigrationStage {
        MigrationStage.lightweight(fromVersion: CatalogueSchemaV1.self, toVersion: CatalogueSchemaV2.self)
    }
}

// The current version's models, so the store's code names no version.
typealias CatalogueCurrentSchema = CatalogueSchemaV2
typealias Camera = CatalogueCurrentSchema.Camera
typealias CameraObject = CatalogueCurrentSchema.CameraObject
typealias ImportJob = CatalogueCurrentSchema.ImportJob

// Frozen: what every build before Catalogue V2 (17.1 and 18.1) shipped. Change nothing stored here; add a version
// instead.
extension CatalogueSchemaV1 {
    /// One camera body.
    @Model
    final class Camera {
        /// The `CameraKey`'s value. Unique, by the store's rule rather than the schema's. What fills it in MSC is
        /// still open (section 2).
        var serial: String = ""
        var model: String = ""
        var friendlyName: String = ""
        var lastSeen: Date = Date.distantPast
        /// "usb" or "wifi".
        var preferredCarrier: String = "usb"
        var autoImport: Bool = false
        var wifiSSID: String?
        var lastIP: String?
        /// The PTP/IP initiator GUID the app uses with this camera (Iteration 3; `CameraRecord.ptpipGUID`).
        var ptpipGUID: UUID?
        /// When `lastListing` was listed.
        var lastListedAt: Date?
        /// The last listing of the card (`StoredListing`), for the last-known card (decision 7).
        var lastListing: Data?

        @Relationship(deleteRule: .cascade, inverse: \CameraObject.camera)
        var objects: [CameraObject]? = []

        @Relationship(deleteRule: .cascade, inverse: \ImportJob.camera)
        var jobs: [ImportJob]? = []

        init(serial: String) {
            self.serial = serial
        }
    }

    /// One file on one camera's card, identified by `(camera, folder, filename, captureDate, size)`. "Already
    /// imported" matches rows on `filename`, `captureDate` and `size` alone (Shamil, 8 Nov), which every row has had
    /// since build 17.1: don't change these columns without a new schema version and a stage.
    @Model
    final class CameraObject {
        var camera: Camera?
        /// The camera's key, repeated from the relationship (`CatalogueRow.cameraKey`).
        var cameraKey: String = ""
        /// `ObjectIdentity.storageKey`: unique, by the store's rule.
        var identityKey: String = ""
        var folder: String = ""
        var filename: String = ""
        /// `YYYYMMDDThhmmss`, the camera's wall clock.
        var captureDate: String = ""
        var size: Int64 = 0
        /// `PTPMediaKind`'s raw value.
        var format: String = "other"
        /// `ObjectState`'s raw value: new, partial, imported or skipped.
        var state: String = "new"
        /// 0 over USB in Iteration 1 (decision 7: a file restarts); for Wi-Fi.
        var resumeOffset: Int64 = 0
        /// The partial file of a resumable download (Wi-Fi, Iteration 3). No build before Catalogue V2 wrote it.
        var tempURL: URL?
        /// The Photos asset, for an import to Photos.
        var assetLocalID: String?
        /// Where an import to Files put the file, relative to the app's Documents folder (decision 9; PhotosBridge's
        /// `FileLocation`). Kept when Photos access is granted later: the file stays in Files, still imported.
        var fileRelativePath: String?
        /// The filename without its extension, for the RAW+JPEG pairing rule.
        var pairStem: String = ""

        init(row: CatalogueRow) {
            cameraKey = row.cameraKey
            identityKey = row.identityKey
            folder = row.folder
            filename = row.filename
            captureDate = row.captureDate
            size = row.size
            format = row.format
            state = row.state
            resumeOffset = row.resumeOffset
            assetLocalID = row.assetLocalID
            fileRelativePath = row.fileRelativePath
            pairStem = row.pairStem
        }
    }

    /// One import job. Nothing writes these yet: the engine's job history arrives with the screen that shows it.
    @Model
    final class ImportJob {
        var camera: Camera?
        var jobID: UUID = UUID()
        var startedAt: Date = Date.distantPast
        var finishedAt: Date?
        /// "all-new", "range" or "picked" (`ImportSelection`).
        var selection: String = ""
        var bytesTotal: Int64 = 0
        var bytesDone: Int64 = 0
        var outcome: String?

        init(startedAt: Date) {
            self.startedAt = startedAt
        }
    }
}

#endif
