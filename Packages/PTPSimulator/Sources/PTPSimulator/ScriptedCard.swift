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
    /// What every new object's size is divided by: 1 for a full-size card, the product of every `scaled(down:)`
    /// divisor for a scaled one, so frames `shootMore` adds are scaled as the rest of the card is.
    public private(set) var sizeDivisor: UInt64 = 1

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
        guard (1 ... 9999).contains(firstNumber), (100 ... 999).contains(firstFolder),
              let t0 = PTPDateTime.parse(start, defaultTimeZone: utc) else { return nil }
        let objects = makeObjects(frames, t0: t0, interval: interval, number: firstNumber, folder: firstFolder,
                                  handle: 1)
        return ScriptedCard(storageID: storageID, objects: objects)
    }

    /// Frames shot after the last object on the card, `interval` seconds apart from its capture date, continuing its
    /// numbering, folder and handles (a card not made by `shoot` starts at DSC00001 in 100MSDCF). Returns the objects
    /// added, for the simulator's ObjectAdded events and for tests.
    @discardableResult
    public mutating func shootMore(_ frames: [Frame], interval: Int = 2) -> [Object] {
        let last = objects.last
        var number = last.flatMap { Self.number(inFilename: $0.filename) }.map { $0 + 1 } ?? 1
        var folder = last.flatMap { Self.number(inFolder: $0.folder) } ?? 100
        if number > 9999 {
            number = 1
            folder += 1
        }
        let t0 = last.flatMap { PTPDateTime.parse($0.captureDateRaw, defaultTimeZone: Self.utc) }
            .map { $0.addingTimeInterval(TimeInterval(interval)) }
            ?? PTPDateTime.parse("20261101T090000", defaultTimeZone: Self.utc)!
        let handle = (objects.map(\.handle.rawValue).max() ?? 0) + 1
        let added = Self.makeObjects(frames, t0: t0, interval: interval, number: number, folder: folder,
                                     handle: handle, sizeDivisor: sizeDivisor)
        objects += added
        return added
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!

    private static func makeObjects(_ frames: [Frame], t0: Date, interval: Int, number firstNumber: Int,
                                    folder firstFolder: Int, handle firstHandle: UInt32,
                                    sizeDivisor: UInt64 = 1) -> [Object] {
        var objects: [Object] = []
        var number = firstNumber
        var folder = firstFolder
        var handle = firstHandle
        for (i, frame) in frames.enumerated() {
            let date = format(t0.addingTimeInterval(TimeInterval(i * interval)), utc)
            let stem = "DSC" + pad(number, 5)
            for file in frame.files {
                objects.append(Object(
                    handle: PTPObjectHandle(rawValue: handle), folder: "DCIM/\(folder)MSDCF",
                    filename: "\(stem).\(file.ext)",
                    size: max(1, size(of: file.format, frame: number) / max(1, sizeDivisor)),
                    captureDateRaw: date, format: file.format))
                handle += 1
            }
            number += 1
            if number > 9999 {
                number = 1
                folder += 1
            }
        }
        return objects
    }

    /// 1234 from "DSC01234.ARW".
    private static func number(inFilename name: String) -> Int? {
        guard name.hasPrefix("DSC"), name.count >= 8 else { return nil }
        return Int(name.dropFirst(3).prefix(5))
    }

    /// 100 from "DCIM/100MSDCF".
    private static func number(inFolder folder: String) -> Int? {
        guard let last = folder.split(separator: "/").last, last.hasSuffix("MSDCF") else { return nil }
        return Int(last.prefix(3))
    }

    /// `pairs` RAW+JPEG frames: the shape of the exit criteria's 100 files.
    public static func rawPlusJPEG(pairs: Int, start: String = "20261101T090000") -> ScriptedCard? {
        shoot(Array(repeating: .rawPlusJPEG, count: max(0, pairs)), start: start)
    }

    public var handles: [PTPObjectHandle] { objects.map(\.handle) }

    public func object(_ handle: PTPObjectHandle) -> Object? { objects.first { $0.handle == handle } }

    /// A copy whose every size is divided by `divisor` (at least 1 byte each), keeping handles, names, dates and
    /// formats: a card shaped like the real one whose bytes tests can afford to write. The exit criteria's 50 pairs
    /// are about 3.1 GB; scaled down by 1,000 they are about 3.1 MB. The divisor is kept (`sizeDivisor`), so frames
    /// shot onto the copy later are scaled too.
    public func scaled(down divisor: UInt64) -> ScriptedCard {
        var copy = self
        let d = max(1, divisor)
        for i in copy.objects.indices { copy.objects[i].size = max(1, copy.objects[i].size / d) }
        let (product, overflow) = sizeDivisor.multipliedReportingOverflow(by: d)
        copy.sizeDivisor = overflow ? .max : product
        return copy
    }

    /// The ObjectInfo the simulator answers `GetObjectInfo` with, built with PTPKit's initialiser. The thumbnail and
    /// pixel fields are the captured α7C II ObjectInfo's (`CapturedA7C2.objectInfoTemplate(raw:)`): an ARW gets the
    /// captured ARW's (a 160 × 120 JFIF thumbnail of 6,584 B, 7008 × 4672), a JPG the captured JPG's (7,376 B), a HIF
    /// the JPG's as a placeholder (no HIF ObjectInfo is captured), anything else none. The parent is 0: the
    /// simulator serves no folder objects (the camera's are the handles that are multiples of 0x80000).
    public func objectInfo(for handle: PTPObjectHandle) -> PTPObjectInfo? {
        guard let o = object(handle) else { return nil }
        let template = Self.template(for: o.format)
        return PTPObjectInfo(
            storageID: storageID, objectFormat: o.format, protectionStatus: 0,
            // ISO 15740: 0xFFFFFFFF for an object of 4 GiB or more.
            objectCompressedSize: o.size >= 0x1_0000_0000 ? UInt32.max : UInt32(o.size),
            thumbFormat: template?.thumbFormat ?? .undefined,
            thumbCompressedSize: template?.thumbCompressedSize ?? 0,
            thumbPixWidth: template?.thumbPixWidth ?? 0, thumbPixHeight: template?.thumbPixHeight ?? 0,
            imagePixWidth: template?.imagePixWidth ?? 0, imagePixHeight: template?.imagePixHeight ?? 0,
            imageBitDepth: template?.imageBitDepth ?? 0,
            parentObject: PTPObjectHandle(rawValue: 0), associationType: 0, associationDescription: 0,
            sequenceNumber: 0, filename: o.filename, captureDateRaw: o.captureDateRaw, modificationDateRaw: "",
            keywords: "")
    }

    /// The thumbnail the simulator answers `GetThumb` with: as many bytes as its ObjectInfo's thumbnail size, the
    /// JPEG start and end markers around deterministic filler. Not a decodable image. Nil when the object has no
    /// thumbnail (a format without a captured template) or isn't on the card.
    public func thumbnail(for handle: PTPObjectHandle) -> Data? {
        guard let info = objectInfo(for: handle), info.thumbCompressedSize >= 4 else { return nil }
        let count = Int(info.thumbCompressedSize)
        var data = Self.content(of: handle, in: 0 ..< UInt64(count))
        data[data.startIndex] = 0xFF
        data[data.startIndex + 1] = 0xD8
        data[data.endIndex - 2] = 0xFF
        data[data.endIndex - 1] = 0xD9
        return data
    }

    /// The bytes of an object in `range`, or nil if the object isn't on the card or the range runs past its end.
    public func content(of handle: PTPObjectHandle, in range: Range<UInt64>) -> Data? {
        guard let o = object(handle), range.upperBound <= o.size else { return nil }
        return Self.content(of: handle, in: range)
    }

    /// The scripted bytes of the object with `handle`: byte *i* is ((i + 7919 × handle) mod 251) XOR
    /// ((handle ÷ 251) × 37 mod 256), so any range can be produced without the rest and a test can check a copy
    /// without keeping one. The phase alone repeats every 251 handles; the XOR term separates those, so two objects
    /// whose handles differ by less than 64,256 (251 × 256) differ over any span of 251 bytes or more at the same
    /// offsets (shorter spans can match). Built a period at a time, so producing megabytes is cheap.
    public static func content(of handle: PTPObjectHandle, in range: Range<UInt64>) -> Data {
        let count = Int(range.upperBound - range.lowerBound)
        guard count > 0 else { return Data() }
        let period = 251
        let phase = Int((range.lowerBound % 251 + UInt64(handle.rawValue) % 251 * 7919) % 251)
        let mask = UInt8(truncatingIfNeeded: (handle.rawValue / 251) &* 37)
        let cycle = (0 ..< period).map { UInt8((phase + $0) % period) ^ mask }
        var out = Data(capacity: count)
        var left = count
        while left > 0 {
            let n = min(period, left)
            out.append(contentsOf: cycle[0 ..< n])
            left -= n
        }
        return out
    }

    /// The captured ObjectInfo whose thumbnail and pixel fields a format borrows; nil for none.
    private static func template(for format: PTPObjectFormat) -> PTPObjectInfo? {
        switch format {
        case .sonyARW: templates.raw
        case .exifJPEG, .jfif, .sonyHEIF: templates.jpeg
        default: nil
        }
    }

    private static let templates: (raw: PTPObjectInfo?, jpeg: PTPObjectInfo?) = (
        try? CapturedA7C2.objectInfoTemplate(raw: true), try? CapturedA7C2.objectInfoTemplate(raw: false)
    )

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
