import Foundation
import PTPKit

/// The card a simulated camera serves: objects with sizes, capture dates and formats, RAW+JPEG pairs among them
/// (backlog section 7). Pure values: the same script always gives the same card, so tests can name what they expect.
public struct ScriptedCard: Sendable, Hashable {
    /// One file on the card.
    public struct Object: Sendable, Hashable {
        public var handle: PTPObjectHandle
        /// "DCIM/100MSDCF" and so on, as a Sony body names its folders.
        public var folder: String
        public var filename: String
        public var size: UInt64
        /// A PTP DateTime as the α7C II sends it: `YYYYMMDDThhmmss`, no zone, no tenths (fixtures, 8 Nov).
        public var captureDateRaw: String
        public var format: PTPObjectFormat

        public init(handle: PTPObjectHandle, folder: String, filename: String, size: UInt64, captureDateRaw: String,
                    format: PTPObjectFormat) {
            self.handle = handle
            self.folder = folder
            self.filename = filename
            self.size = size
            self.captureDateRaw = captureDateRaw
            self.format = format
        }
    }

    /// What each frame of a scripted shoot writes.
    public enum Frame: String, Sendable, Hashable, CaseIterable {
        case raw, jpeg, heif, rawPlusJPEG, rawPlusHEIF

        var files: [(ext: String, format: PTPObjectFormat)] {
            switch self {
            case .raw: [("ARW", .sonyARW)]
            case .jpeg: [("JPG", .exifJPEG)]
            case .heif: [("HIF", .sonyHEIF)]
            case .rawPlusJPEG: [("ARW", .sonyARW), ("JPG", .exifJPEG)]
            case .rawPlusHEIF: [("ARW", .sonyARW), ("HIF", .sonyHEIF)]
            }
        }
    }

    public var storageID: PTPStorageID
    public var objects: [Object]

    /// 0x00010001, the store the α7C II's StoreAdded event names (fixture `event-4004.bin`).
    public static let defaultStorageID = PTPStorageID(rawValue: 0x0001_0001)

    public init(storageID: PTPStorageID = ScriptedCard.defaultStorageID, objects: [Object]) {
        self.storageID = storageID
        self.objects = objects
    }

    /// A shoot of `frames.count` frames, one every `interval` seconds from `start` (a PTP DateTime). Frame numbers
    /// count up from `firstNumber` as DSCnnnnn; after 9999 the camera starts a new folder and goes back to 1, so a
    /// long enough shoot reuses file names, as a real card does. Sizes are fixed per format and frame, around the
    /// spike's measured averages (20 ARW were 839 MB and 20 JPG 440 MB, so about 42 and 22 MB). The HIF size is a
    /// placeholder: no HIF has been measured. Nil if `start` isn't a PTP DateTime.
    public static func shoot(
        _ frames: [Frame],
        start: String = "20261101T090000",
        interval: Int = 2,
        firstNumber: Int = 1,
        firstFolder: Int = 100,
        storageID: PTPStorageID = ScriptedCard.defaultStorageID
    ) -> ScriptedCard? {
        guard let utc = TimeZone(secondsFromGMT: 0), (1 ... 9999).contains(firstNumber), (100 ... 999).contains(firstFolder),
              let t0 = PTPDateTime.parse(start, defaultTimeZone: utc) else { return nil }
        var objects: [Object] = []
        var number = firstNumber
        var folder = firstFolder
        var handle: UInt32 = 1
        for (i, frame) in frames.enumerated() {
            let date = format(t0.addingTimeInterval(TimeInterval(i * interval)), utc)
            let stem = "DSC" + pad(number, 5)
            for file in frame.files {
                objects.append(Object(
                    handle: PTPObjectHandle(rawValue: handle), folder: "DCIM/\(folder)MSDCF",
                    filename: "\(stem).\(file.ext)", size: size(of: file.format, frame: number),
                    captureDateRaw: date, format: file.format))
                handle += 1
            }
            number += 1
            if number > 9999 {
                number = 1
                folder += 1
            }
        }
        return ScriptedCard(storageID: storageID, objects: objects)
    }

    /// `pairs` RAW+JPEG frames: the shape of the exit criteria's 100 files.
    public static func rawPlusJPEG(pairs: Int, start: String = "20261101T090000") -> ScriptedCard? {
        shoot(Array(repeating: .rawPlusJPEG, count: max(0, pairs)), start: start)
    }

    public var handles: [PTPObjectHandle] { objects.map(\.handle) }

    public func object(_ handle: PTPObjectHandle) -> Object? { objects.first { $0.handle == handle } }

    /// The ObjectInfo the simulator answers `GetObjectInfo` with, built with PTPKit's initialiser. Thumbnail and
    /// pixel fields are zero for now; v1 seeds them from the captured α7C II fixtures (section 7).
    public func objectInfo(for handle: PTPObjectHandle) -> PTPObjectInfo? {
        guard let o = object(handle) else { return nil }
        return PTPObjectInfo(
            storageID: storageID, objectFormat: o.format, protectionStatus: 0,
            // ISO 15740: 0xFFFFFFFF for an object of 4 GiB or more.
            objectCompressedSize: o.size >= 0x1_0000_0000 ? UInt32.max : UInt32(o.size),
            thumbFormat: .undefined, thumbCompressedSize: 0, thumbPixWidth: 0, thumbPixHeight: 0,
            imagePixWidth: 0, imagePixHeight: 0, imageBitDepth: 0,
            parentObject: PTPObjectHandle(rawValue: 0), associationType: 0, associationDescription: 0,
            sequenceNumber: 0, filename: o.filename, captureDateRaw: o.captureDateRaw, modificationDateRaw: "",
            keywords: "")
    }

    private static func size(of format: PTPObjectFormat, frame: Int) -> UInt64 {
        // A deterministic 0–4 MB on top of each format's base: ARW 40–44 MB, JPG 20–24 MB, HIF 10–14 MB.
        let spread = UInt64((frame &* 7919) % 4_000_000)
        switch format {
        case .sonyARW: return 40_000_000 + spread
        case .exifJPEG: return 20_000_000 + spread
        default: return 10_000_000 + spread
        }
    }

    private static func format(_ date: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return pad(c.year ?? 0, 4) + pad(c.month ?? 0, 2) + pad(c.day ?? 0, 2) + "T"
            + pad(c.hour ?? 0, 2) + pad(c.minute ?? 0, 2) + pad(c.second ?? 0, 2)
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let digits = String(v)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
