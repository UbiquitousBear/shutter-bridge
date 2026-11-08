import Foundation

/// When a photo was taken, as the camera's own clock reads: wall-clock time to the second with no time zone, kept as
/// PTP's `YYYYMMDDThhmmss` (the α7C II's ObjectInfo dates have no zone and no tenths; fixtures, 8 Nov).
///
/// Why wall-clock and not a `Date`: ImageCaptureCore hands over a `Date` it made from the camera's zone-less time
/// in the phone's current zone. Keyed on that `Date`, every file would change identity when the phone changes time
/// zone, and be imported again. Converted back to wall-clock in the same zone at listing time, the key stays put.
/// Backlog section 4 leaves this to a week-1 decision; this is the proposal for it, and the type keeps the choice in
/// one place if the decision goes the other way.
public struct CaptureDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// `YYYYMMDDThhmmss`, always 15 characters.
    public let rawValue: String

    /// Accepts exactly `YYYYMMDDThhmmss` with plausible fields (month 1–12, day 1–31, hour < 24, minute < 60,
    /// second ≤ 60); anything else is nil.
    public init?(rawValue: String) {
        guard let f = Self.fields(rawValue) else { return nil }
        guard (1 ... 12).contains(f.month), (1 ... 31).contains(f.day), f.hour < 24, f.minute < 60, f.second <= 60
        else { return nil }
        self.rawValue = rawValue
    }

    /// From a PTP DateTime string as a camera sends it. Tenths (`.s`) are dropped. A zone suffix (`Z`, `±hhmm`) is
    /// dropped too: the wall-clock part is what the camera's clock read, and the α7C II sends no zone.
    public init?(ptpDateTime: String) {
        self.init(rawValue: String(ptpDateTime.prefix(15)))
        let rest = ptpDateTime.dropFirst(15)
        guard rest.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.Z".contains($0)) }) else { return nil }
    }

    /// From a `Date`, read as wall-clock time in `timeZone` (the phone's current zone at listing time, so the camera's
    /// own reading comes back out). Nil for years outside 0001–9999.
    public init?(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = c.year, let mo = c.month, let d = c.day, let h = c.hour, let mi = c.minute, let s = c.second,
              (1 ... 9999).contains(y) else { return nil }
        func pad(_ v: Int, _ width: Int) -> String {
            let digits = String(v)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        self.init(rawValue: pad(y, 4) + pad(mo, 2) + pad(d, 2) + "T" + pad(h, 2) + pad(mi, 2) + pad(s, 2))
    }

    /// The instant this wall-clock time names in `timeZone`.
    public func date(in timeZone: TimeZone) -> Date? {
        guard let f = Self.fields(rawValue) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: f.year, month: f.month, day: f.day,
                                                  hour: f.hour, minute: f.minute, second: f.second))
    }

    /// Fixed width, so the strings order as the times do.
    public static func < (a: CaptureDate, b: CaptureDate) -> Bool { a.rawValue < b.rawValue }

    public var description: String { rawValue }

    // Decoding goes through the same check as `init(rawValue:)`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = CaptureDate(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not a YYYYMMDDThhmmss capture date"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    private static func fields(_ s: String)
        -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)? {
        let u = Array(s.utf8)
        guard u.count == 15, u[8] == UInt8(ascii: "T") else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                guard (48 ... 57).contains(u[i]) else { return nil }
                v = v * 10 + Int(u[i] - 48)
            }
            return v
        }
        guard let y = num(0 ..< 4), let mo = num(4 ..< 6), let d = num(6 ..< 8),
              let h = num(9 ..< 11), let mi = num(11 ..< 13), let se = num(13 ..< 15) else { return nil }
        return (y, mo, d, h, mi, se)
    }
}
