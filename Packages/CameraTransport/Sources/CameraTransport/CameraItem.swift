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
    /// The zone the link made `captureDate` in from the camera's zone-less wall-clock time: the phone's zone when the
    /// card was listed, or the zone a PTP date string named itself. Read back in this zone, `captureDate` gives the
    /// camera's own reading again, so a file listed in London and listed again after a flight 9 hours east keeps its
    /// catalogue identity (backlog Iteration 2, section 1). Nil when the link didn't say; whoever reads the date then
    /// supplies the zone (`identity(camera:timeZone:)` in ImportEngine). Always a fixed zone, never the
    /// autoupdating one, so it stays the zone the date was made in.
    public var captureTimeZone: TimeZone? {
        didSet { if let zone = captureTimeZone, zone == .autoupdatingCurrent { captureTimeZone = Self.fixed(zone) } }
    }
    public var format: PTPMediaKind

    public init(id: ID, folder: String, name: String, size: UInt64, captureDate: Date?, format: PTPMediaKind,
                captureTimeZone: TimeZone? = nil) {
        self.id = id
        self.folder = folder
        self.name = name
        self.size = size
        self.captureDate = captureDate
        self.captureTimeZone = captureTimeZone.map(Self.fixed)
        self.format = format
    }

    /// An item whose format follows from its file name.
    public init(id: ID, folder: String, name: String, size: UInt64, captureDate: Date?,
                captureTimeZone: TimeZone? = nil) {
        self.init(id: id, folder: folder, name: name, size: size, captureDate: captureDate,
                  format: Self.format(ofFilename: name), captureTimeZone: captureTimeZone)
    }

    /// A PTP DateTime string (`YYYYMMDDThhmmss`, optionally `.s` tenths, optionally `Z` or `±hhmm`) as a capture date
    /// and the zone it was made in: the zone the string names, or `defaultTimeZone` (the phone's, at listing time)
    /// when it names none, as the α7C II's don't. Nil when PTPKit can't read the string. The IP link and the
    /// simulator list their items through this, so `captureTimeZone` is always the zone `PTPDateTime` used.
    public static func captureTime(ptpDateTime raw: String, defaultTimeZone: TimeZone)
        -> (date: Date, zone: TimeZone)? {
        guard let date = PTPDateTime.parse(raw, defaultTimeZone: defaultTimeZone) else { return nil }
        return (date, namedZone(ptpDateTime: raw) ?? fixed(defaultTimeZone))
    }

    /// The zone a PTP DateTime string names after its 15 characters and optional tenths, read as `PTPDateTime` reads
    /// it; nil when it names none.
    private static func namedZone(ptpDateTime raw: String) -> TimeZone? {
        var rest = Array(raw.utf8.dropFirst(15))
        if rest.first == UInt8(ascii: ".") {
            rest.removeFirst()
            if let digit = rest.first, (48 ... 57).contains(digit) { rest.removeFirst() }
        }
        guard let mark = rest.first else { return nil }
        if mark == UInt8(ascii: "Z") { return TimeZone(secondsFromGMT: 0) }
        guard mark == UInt8(ascii: "+") || mark == UInt8(ascii: "-"), rest.count >= 5,
              rest[1 ... 4].allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
        let hours = Int(rest[1] - 48) * 10 + Int(rest[2] - 48)
        let minutes = Int(rest[3] - 48) * 10 + Int(rest[4] - 48)
        let sign = mark == UInt8(ascii: "+") ? 1 : -1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    /// `zone` as a fixed zone: the autoupdating zone becomes the zone it stands for now; any other is kept as it is.
    private static func fixed(_ zone: TimeZone) -> TimeZone {
        zone == .autoupdatingCurrent ? TimeZone(identifier: zone.identifier) ?? zone : zone
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
