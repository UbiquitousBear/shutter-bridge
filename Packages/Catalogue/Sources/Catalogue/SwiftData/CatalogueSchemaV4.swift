#if canImport(SwiftData)
import Foundation
import SwiftData

// Version 4 of the catalogue's schema (Iteration 2: culling, History and pending commits; Shamil, 11 Nov). The current
// version: `SwiftDataCatalogue` uses these models through the typealiases in `CatalogueSchema.swift`.
//
// What changed from version 3, and nothing else:
// - `ImportJob` gains optional attributes for History (backlog section 4): the camera's key, the job's purpose,
//   destination, carrier and album, the selection's parameters (the date range's bounds, the picked files' content
//   keys as an encoded list) and the last progress's counts with the failed files' content keys. All optional, so the
//   stage from version 3 is lightweight; a job written before reads as an import of every new file with no counts.
// - `CullMark`, a new model: one row per file, keyed by content key (section 7.4; D4).
// - `PendingCommitFile`, a new model: the pending-commit marker, one row per file, grouped by commit (section 3.1).
//   No relationship: forgetting a camera removes its markers by `cameraKey`, explicitly. Device-local in meaning (it
//   names this iPhone's Photos library and Staging root), so a later synced configuration leaves it out.
// `Camera` and `CameraObject` are version 3's, copied unchanged, because each version owns its model classes. The new
// models have no relationship, so `Camera`'s relationships are version 3's too. No column holds the network password,
// and none may.
//
// The same rules as versions 1 to 3 hold: CloudKit-compatible (nothing unique, every attribute optional or defaulted,
// every relationship optional with an inverse), and the models are internal.

/// Version 4 of the catalogue's schema: version 3, History's job fields, cull marks and pending-commit markers.
public enum CatalogueSchemaV4: VersionedSchema, Sendable {
    public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [Camera.self, CameraObject.self, ImportJob.self, CullMark.self, PendingCommitFile.self]
    }
}

extension CatalogueSchemaV4 {
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

    /// One file on one camera's card, identified by `(camera, folder, filename, captureDate, size)`: version 3's,
    /// unchanged. "Already imported" and "already staged" match rows on `filename`, `captureDate` and `size` alone.
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

    /// One job (`JobRecord`, column for column through `JobColumns`): version 1's columns, unchanged, and History's,
    /// new in version 4 and all optional.
    @Model
    final class ImportJob {
        var camera: Camera?
        var jobID: UUID = UUID()
        var startedAt: Date = Date.distantPast
        var finishedAt: Date?
        /// "all-new", "range", "picked" or (new in version 4) "picked-new" (`JobRecord.Selection`).
        var selection: String = ""
        var bytesTotal: Int64 = 0
        var bytesDone: Int64 = 0
        /// "completed", "cancelled", "catalogueUnavailable" or "stopped:<reason>" (`JobRecord.Outcome`).
        var outcome: String?
        /// New in version 4: the camera's key, repeated from the relationship. Nil on every row migrated from
        /// version 3.
        var cameraKey: String?
        /// New in version 4: `JobRecord.Purpose`'s raw value ("import", "stage" or "keepers").
        var purpose: String?
        /// New in version 4: `JobRecord.Destination`'s raw value ("photos" or "staging").
        var destination: String?
        /// New in version 4: `JobRecord.Carrier`'s raw value ("usb", "wifi" or "staging").
        var carrier: String?
        /// New in version 4: the Photos album's local identifier.
        var albumIdentifier: String?
        /// New in version 4: a date-range selection's lower bound.
        var rangeStart: Date?
        /// New in version 4: a date-range selection's upper bound.
        var rangeEnd: Date?
        /// New in version 4: the picked files' content keys (`StoredContentKeys`).
        var pickedKeys: Data?
        /// New in version 4: the failed files' content keys (`StoredContentKeys`).
        var failedKeys: Data?
        /// New in version 4: the last progress's counts.
        var filesTotal: Int?
        var filesImported: Int?
        var filesStaged: Int?
        var filesSkipped: Int?
        var filesFailed: Int?

        init(startedAt: Date) {
            self.startedAt = startedAt
        }
    }

    /// New in version 4: the person's mark on one file (`MarkRecord`), keyed by content key. Unique per content key by
    /// the store's rule, not the schema's.
    @Model
    final class CullMark {
        /// `ObjectIdentity.ContentKey.storageKey`.
        var contentKey: String = ""
        /// The name with ASCII letters upper-cased, as the content key holds it.
        var filename: String = ""
        /// `YYYYMMDDThhmmss`, the camera's wall clock.
        var captureDate: String = ""
        var size: Int64 = 0
        /// `MarkRecord.Decision`'s raw value ("keep" or "reject"); nil when only rated.
        var mark: String?
        /// 0 to 5, 0 being no stars; nil reads as 0.
        var rating: Int?
        var markedAt: Date?

        init(columns: CullMarkColumns) {
            contentKey = columns.contentKey
            filename = columns.filename
            captureDate = columns.captureDate
            size = columns.size
            mark = columns.mark
            rating = columns.rating
            markedAt = columns.markedAt
        }
    }

    /// New in version 4: one file of a pending commit (`PendingCommit`, section 3.1), grouped by `commitID`.
    @Model
    final class PendingCommitFile {
        /// The commit's token; every file of one commit has the same.
        var commitID: UUID?
        var jobID: UUID?
        var writtenAt: Date?
        /// "photos" or "staging".
        var destination: String = "photos"
        /// `StagingRoot`'s raw value, for a staging commit.
        var stagingRoot: String?
        /// The day folder relative to the root, "Staging/<camera>/<YYYY-MM-DD>", for a staging commit.
        var stagingFolder: String?
        /// The camera's key, as `CameraObject.cameraKey`.
        var cameraKey: String = ""
        /// `ObjectIdentity.storageKey`, as `CameraObject.identityKey`.
        var identityKey: String = ""
        var folder: String = ""
        var filename: String = ""
        /// `YYYYMMDDThhmmss`, the camera's wall clock.
        var captureDate: String = ""
        var size: Int64 = 0
        /// `PTPMediaKind`'s raw value.
        var format: String = "other"
        /// `PendingCommit.Role`'s raw value: "single", "raw" or "processed".
        var role: String = "single"
        /// The exact date the asset or the placed file was given.
        var assetDate: Date?

        init(columns: PendingCommitColumns) {
            commitID = columns.commitID
            jobID = columns.jobID
            writtenAt = columns.writtenAt
            destination = columns.destination
            stagingRoot = columns.stagingRoot
            stagingFolder = columns.stagingFolder
            cameraKey = columns.cameraKey
            identityKey = columns.identityKey
            folder = columns.folder
            filename = columns.filename
            captureDate = columns.captureDate
            size = columns.size
            format = columns.format
            role = columns.role
            assetDate = columns.assetDate
        }
    }
}

extension CatalogueSchemaV4.CameraObject {
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

extension CatalogueSchemaV4.Camera {
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
extension CatalogueSchemaV4.ImportJob {
    /// The row's columns as plain values; the relationship isn't among them.
    var columns: JobColumns {
        JobColumns(jobID: jobID, startedAt: startedAt, finishedAt: finishedAt, selection: selection,
                   bytesTotal: bytesTotal, bytesDone: bytesDone, outcome: outcome, cameraKey: cameraKey,
                   purpose: purpose, destination: destination, carrier: carrier, albumIdentifier: albumIdentifier,
                   rangeStart: rangeStart, rangeEnd: rangeEnd, pickedKeys: pickedKeys, failedKeys: failedKeys,
                   filesTotal: filesTotal, filesImported: filesImported, filesStaged: filesStaged,
                   filesSkipped: filesSkipped, filesFailed: filesFailed)
    }

    /// Overwrites every column `JobColumns` carries; the relationship to the camera is the store's to set.
    func apply(_ columns: JobColumns) {
        jobID = columns.jobID
        startedAt = columns.startedAt
        finishedAt = columns.finishedAt
        selection = columns.selection
        bytesTotal = columns.bytesTotal
        bytesDone = columns.bytesDone
        outcome = columns.outcome
        cameraKey = columns.cameraKey
        purpose = columns.purpose
        destination = columns.destination
        carrier = columns.carrier
        albumIdentifier = columns.albumIdentifier
        rangeStart = columns.rangeStart
        rangeEnd = columns.rangeEnd
        pickedKeys = columns.pickedKeys
        failedKeys = columns.failedKeys
        filesTotal = columns.filesTotal
        filesImported = columns.filesImported
        filesStaged = columns.filesStaged
        filesSkipped = columns.filesSkipped
        filesFailed = columns.filesFailed
    }
}

extension CatalogueSchemaV4.CullMark {
    /// The row's columns as plain values.
    var columns: CullMarkColumns {
        CullMarkColumns(contentKey: contentKey, filename: filename, captureDate: captureDate, size: size, mark: mark,
                        rating: rating, markedAt: markedAt)
    }

    /// Overwrites every column.
    func apply(_ columns: CullMarkColumns) {
        contentKey = columns.contentKey
        filename = columns.filename
        captureDate = columns.captureDate
        size = columns.size
        mark = columns.mark
        rating = columns.rating
        markedAt = columns.markedAt
    }
}

extension CatalogueSchemaV4.PendingCommitFile {
    /// The row's columns as plain values.
    var columns: PendingCommitColumns {
        PendingCommitColumns(commitID: commitID, jobID: jobID, writtenAt: writtenAt, destination: destination,
                             stagingRoot: stagingRoot, stagingFolder: stagingFolder, cameraKey: cameraKey,
                             identityKey: identityKey, folder: folder, filename: filename, captureDate: captureDate,
                             size: size, format: format, role: role, assetDate: assetDate)
    }
}
#endif
