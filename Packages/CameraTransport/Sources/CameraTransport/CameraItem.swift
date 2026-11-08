import Foundation
import PTPKit

/// One file on the camera's card, as a link lists it: folder, name, size, capture date and format.
public struct CameraItem: Sendable, Hashable, Identifiable {
    /// The link's handle for the file in this session. Not stable across sessions or replugs; the engine finds a
    /// file again by its catalogue identity (folder, name, capture date, size), never by this.
    public struct ID: Sendable, Hashable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public var description: String { rawValue }
    }

    public var id: ID
    /// The folder on the card, such as "DCIM/100MSDCF"; empty when the link can't tell. Whether ImageCaptureCore's
    /// items carry their folder in MTP is a week-1 check (backlog section 4).
    public var folder: String
    /// The camera's file name, such as "DSC04512.ARW".
    public var name: String
    /// Size in bytes, as the link reports it.
    public var size: UInt64
    /// When the photo was taken, as the link reports it (ImageCaptureCore's item over USB). Nil when it has none.
    public var captureDate: Date?
    public var format: PTPMediaKind

    public init(id: ID, folder: String, name: String, size: UInt64, captureDate: Date?, format: PTPMediaKind) {
        self.id = id
        self.folder = folder
        self.name = name
        self.size = size
        self.captureDate = captureDate
        self.format = format
    }

    /// An item whose format follows from its file name.
    public init(id: ID, folder: String, name: String, size: UInt64, captureDate: Date?) {
        self.init(id: id, folder: folder, name: name, size: size, captureDate: captureDate,
                  format: Self.format(ofFilename: name))
    }

    /// The format a file name implies, by PTPKit's own table (`PTPObjectInfo.mediaKind`), so the link and the codec
    /// can never disagree. The format code is left undefined, so the extension alone decides.
    public static func format(ofFilename name: String) -> PTPMediaKind {
        PTPObjectInfo(
            storageID: PTPStorageID(rawValue: 0), objectFormat: .undefined, protectionStatus: 0,
            objectCompressedSize: 0, thumbFormat: .undefined, thumbCompressedSize: 0, thumbPixWidth: 0,
            thumbPixHeight: 0, imagePixWidth: 0, imagePixHeight: 0, imageBitDepth: 0,
            parentObject: PTPObjectHandle(rawValue: 0), associationType: 0, associationDescription: 0,
            sequenceNumber: 0, filename: name, captureDateRaw: "", modificationDateRaw: "", keywords: ""
        ).mediaKind
    }
}

extension Sequence where Element == CameraItem {
    /// Newest first on the capture date, as Browse and the thumbnail queue want them (backlog section 2). Items
    /// without a date go last; ties keep a stable order by folder and name.
    public func newestFirst() -> [CameraItem] {
        sorted { a, b in
            switch (a.captureDate, b.captureDate) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.folder, a.name) < (b.folder, b.name)
            }
        }
    }
}
