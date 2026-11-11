#if canImport(SwiftData)
import Foundation
import SwiftData

// Version 3 of the catalogue's schema (staging; Shamil, 11 Nov). The current version: `SwiftDataCatalogue` uses these
// models through the `Camera`, `CameraObject` and `ImportJob` typealiases in `CatalogueSchema.swift`.
//
// What changed from version 2, and nothing else: `CameraObject` gains three optional attributes for the staged copy
// (`stagedRelativePath`, `stagedRoot` as `StagingRoot`'s raw string, `stagedAt`), so the stage from version 2 is
// lightweight (`CatalogueMigrationPlan.v2ToV3`). Being staged is a fact of its own beside the state, not a state. The
// other models are version 2's, copied unchanged, because each version owns its model classes. No column holds the
// network password, and none may.
//
// The same rules as versions 1 and 2 hold: CloudKit-compatible (nothing unique, every attribute optional or
// defaulted, every relationship optional with an inverse), and the models are internal.

/// Version 3 of the catalogue's schema: version 2 plus the file row's staged copy.
public enum CatalogueSchemaV3: VersionedSchema, Sendable {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [Camera.self, CameraObject.self, ImportJob.self]
    }
}

extension CatalogueSchemaV3 {
    /// One camera body: `CameraRecord`, column for column (`CameraColumns`).
    @Model
    final class Camera {
        /// The `CameraKey`'s value (`CameraRecord.key`). Unique, by the store's rule rather than the schema's.
        var serial: String = ""
        /// DeviceInfo's model name.
        var model: String = ""
        var friendlyName: String = ""
        /// Never moves backwards (`CameraRecord.lastSeen`).
        var lastSeen: Date = Date.distantPast
        /// "usb" or "wifi" (`CameraRecord.Carrier`).
        var preferredCarrier: String = "usb"
        var autoImport: Bool = false
        /// The camera's network name, to remove the hotspot configuration on leaving. Never the password.
        var wifiSSID: String?
        var lastIP: String?
        /// The PTP/IP initiator GUID the app uses with this camera (`CameraRecord.ptpipGUID`).
        var ptpipGUID: UUID?
        /// The Core Bluetooth peripheral identifier stored at onboarding (`CameraRecord.bluetoothPeripheralID`), new in
        /// version 2.
        var bluetoothPeripheralID: UUID?
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

    /// One file on one camera's card, identified by `(camera, folder, filename, captureDate, size)`: version 2's
    /// columns, unchanged, and the staged copy's. "Already imported" and "already staged" match rows on `filename`,
    /// `captureDate` and `size` alone.
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
        /// Bytes of the partial file to resume from: 0 over USB (a file restarts), written by `markPartial` for Wi-Fi.
        var resumeOffset: Int64 = 0
        /// The partial file of a resumable download (`CatalogueRecord.tempURL`), written by `markPartial`.
        var tempURL: URL?
        /// The Photos asset, for an import to Photos.
        var assetLocalID: String?
        /// Where an import to Files put the file, relative to the app's Documents folder (builds before 11 Nov).
        var fileRelativePath: String?
        /// The filename without its extension, for the RAW+JPEG pairing rule.
        var pairStem: String = ""
        /// New in version 3: the staged copy's path under its root (`StagedLocation.relativePath`). Nil when the file
        /// isn't staged, and on every row migrated from version 2.
        var stagedRelativePath: String?
        /// New in version 3: the staged copy's root, `StagingRoot`'s raw value ("iCloudDrive" or "onThisIPhone"), so
        /// a root a later version adds reads as not staged rather than failing.
        var stagedRoot: String?
        /// New in version 3: when the file was staged.
        var stagedAt: Date?

        // Assigned one by one, as version 1's initialiser does, rather than through `apply(_:)`.
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
            tempURL = row.tempURL
            assetLocalID = row.assetLocalID
            fileRelativePath = row.fileRelativePath
            pairStem = row.pairStem
            stagedRelativePath = row.stagedRelativePath
            stagedRoot = row.stagedRoot
            stagedAt = row.stagedAt
        }
    }

    /// One import job; version 1's, unchanged. Nothing writes these yet.
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

extension CatalogueSchemaV3.CameraObject {
    /// The row's columns as plain values.
    var row: CatalogueRow {
        CatalogueRow(cameraKey: cameraKey, identityKey: identityKey, folder: folder, filename: filename,
                     captureDate: captureDate, size: size, format: format, state: state,
                     resumeOffset: resumeOffset, tempURL: tempURL, assetLocalID: assetLocalID,
                     fileRelativePath: fileRelativePath, pairStem: pairStem,
                     stagedRelativePath: stagedRelativePath, stagedRoot: stagedRoot, stagedAt: stagedAt)
    }

    /// Overwrites every column the row carries; the relationship to the camera is the store's to set.
    func apply(_ row: CatalogueRow) {
        cameraKey = row.cameraKey
        identityKey = row.identityKey
        folder = row.folder
        filename = row.filename
        captureDate = row.captureDate
        size = row.size
        format = row.format
        state = row.state
        resumeOffset = row.resumeOffset
        tempURL = row.tempURL
        assetLocalID = row.assetLocalID
        fileRelativePath = row.fileRelativePath
        pairStem = row.pairStem
        stagedRelativePath = row.stagedRelativePath
        stagedRoot = row.stagedRoot
        stagedAt = row.stagedAt
    }
}

extension CatalogueSchemaV3.Camera {
    /// The row's columns as plain values; the listing and the relationships aren't among them.
    var columns: CameraColumns {
        CameraColumns(serial: serial, model: model, friendlyName: friendlyName, lastSeen: lastSeen,
                      preferredCarrier: preferredCarrier, autoImport: autoImport, wifiSSID: wifiSSID,
                      lastIP: lastIP, ptpipGUID: ptpipGUID, bluetoothPeripheralID: bluetoothPeripheralID)
    }

    /// Overwrites every column `CameraColumns` carries; the listing and the relationships are left alone.
    func apply(_ columns: CameraColumns) {
        serial = columns.serial
        model = columns.model
        friendlyName = columns.friendlyName
        lastSeen = columns.lastSeen
        preferredCarrier = columns.preferredCarrier
        autoImport = columns.autoImport
        wifiSSID = columns.wifiSSID
        lastIP = columns.lastIP
        ptpipGUID = columns.ptpipGUID
        bluetoothPeripheralID = columns.bluetoothPeripheralID
    }
}
#endif
