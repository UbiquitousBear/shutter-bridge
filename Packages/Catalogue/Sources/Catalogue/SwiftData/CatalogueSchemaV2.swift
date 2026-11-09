#if canImport(SwiftData)
import Foundation
import SwiftData

// Version 2 of the catalogue's schema (Iteration 3; wireless plan W4; backlog section 0, "Catalogue fields"). The
// current version: `SwiftDataCatalogue` uses these models through the `Camera`, `CameraObject` and `ImportJob`
// typealiases in `CatalogueSchema.swift`.
//
// What changed from version 1, and nothing else: `Camera` gains `bluetoothPeripheralID`, optional, so the stage from
// version 1 is lightweight (`CatalogueMigrationPlan.v1ToV2`). The other models are version 1's, copied unchanged,
// because each version owns its model classes. The Camera row's fields that version 1 already had (`model`,
// `friendlyName`, `preferredCarrier`, `autoImport`, `wifiSSID`, `lastIP`, `ptpipGUID`) gain a reader and a writer in
// this version's store (`CameraRecord`), and `CameraObject.tempURL` is written by `markPartial`. No column holds the
// network password, and none may: it is read over Bluetooth for each join and never stored.
//
// The same rules as version 1 hold: CloudKit-compatible (nothing unique, every attribute optional or defaulted, every
// relationship optional with an inverse), and the models are internal.

/// Version 2 of the catalogue's schema: version 1 plus the Camera row's Bluetooth peripheral identifier.
public enum CatalogueSchemaV2: VersionedSchema, Sendable {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [Camera.self, CameraObject.self, ImportJob.self]
    }
}

extension CatalogueSchemaV2 {
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
        /// New in version 2: the Core Bluetooth peripheral identifier stored at onboarding
        /// (`CameraRecord.bluetoothPeripheralID`). Nil on every row migrated from version 1.
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

    /// One file on one camera's card, identified by `(camera, folder, filename, captureDate, size)`; version 1's
    /// columns, unchanged. "Already imported" matches rows on `filename`, `captureDate` and `size` alone.
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
        /// Where an import to Files put the file, relative to the app's Documents folder (decision 9).
        var fileRelativePath: String?
        /// The filename without its extension, for the RAW+JPEG pairing rule.
        var pairStem: String = ""

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

extension CatalogueSchemaV2.CameraObject {
    /// The row's columns as plain values.
    var row: CatalogueRow {
        CatalogueRow(cameraKey: cameraKey, identityKey: identityKey, folder: folder, filename: filename,
                     captureDate: captureDate, size: size, format: format, state: state,
                     resumeOffset: resumeOffset, tempURL: tempURL, assetLocalID: assetLocalID,
                     fileRelativePath: fileRelativePath, pairStem: pairStem)
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
    }
}

extension CatalogueSchemaV2.Camera {
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
