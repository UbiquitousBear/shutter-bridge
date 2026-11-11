import Catalogue
import Foundation

/// The loupe's one small line of facts about the photo: capture time, shutter, aperture, ISO and focal length (backlog
/// section 7.3). Parsing is pure (from ImageIO's property dictionary, or any dictionary with the same keys), so it runs
/// on Linux; reading a file with ImageIO is `read(from:)`, compiled by CI only.
public struct EXIFSummary: Sendable, Hashable {
    /// The camera's wall-clock capture time.
    public var captureDate: CaptureDate?
    public var shutterSeconds: Double?
    /// The f-number: 2.8 for f/2.8.
    public var aperture: Double?
    public var iso: Int?
    public var focalLengthMM: Double?

    public init(captureDate: CaptureDate? = nil, shutterSeconds: Double? = nil, aperture: Double? = nil,
                iso: Int? = nil, focalLengthMM: Double? = nil) {
        self.captureDate = captureDate
        self.shutterSeconds = shutterSeconds
        self.aperture = aperture
        self.iso = iso
        self.focalLengthMM = focalLengthMM
    }

    /// From ImageIO's properties of an image (`{Exif}` inside), or a bare Exif dictionary. A value that is missing,
    /// not a number or not positive is left out.
    public init(imageProperties: [String: Any]) {
        let exif = imageProperties["{Exif}"] as? [String: Any] ?? imageProperties
        self.init(
            captureDate: (exif["DateTimeOriginal"] as? String).flatMap(Self.captureDate(fromExif:)),
            shutterSeconds: Self.number(exif["ExposureTime"]).flatMap { $0 > 0 ? $0 : nil },
            aperture: Self.number(exif["FNumber"]).flatMap { $0 > 0 ? $0 : nil },
            iso: Self.integer(exif["ISOSpeedRatings"]) ?? Self.integer(exif["PhotographicSensitivity"]),
            focalLengthMM: Self.number(exif["FocalLength"]).flatMap { $0 > 0 ? $0 : nil })
    }

    /// "14:03:22 · 1/250 s · f/2.8 · ISO 400 · 35 mm", leaving out what isn't known; empty when nothing is.
    public var line: String {
        var parts: [String] = []
        if let captureDate { parts.append(Self.timeOfDay(captureDate)) }
        if let shutterSeconds { parts.append(Self.shutterText(shutterSeconds)) }
        if let aperture { parts.append("f/" + Self.decimalText(aperture)) }
        if let iso { parts.append("ISO \(iso)") }
        if let focalLengthMM { parts.append(Self.decimalText(focalLengthMM) + " mm") }
        return parts.joined(separator: " · ")
    }

    public var isEmpty: Bool { line.isEmpty }

    // MARK: Text

    /// "1/250 s" for a fast shutter, "0.4 s" or "2 s" for a slow one.
    static func shutterText(_ seconds: Double) -> String {
        if seconds >= 0.3 { return decimalText(seconds) + " s" }
        return "1/\(max(1, Int((1 / seconds).rounded()))) s"
    }

    /// One decimal place at most, none when it is zero: 2.8, 4, 35, 1.3.
    static func decimalText(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }

    private static func timeOfDay(_ date: CaptureDate) -> String {
        let raw = Array(date.rawValue)   // YYYYMMDDThhmmss
        return String(raw[9 ... 10]) + ":" + String(raw[11 ... 12]) + ":" + String(raw[13 ... 14])
    }

    // MARK: Parsing

    /// "2026:11:05 14:03:22" → 20261105T140322.
    static func captureDate(fromExif text: String) -> CaptureDate? {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 14 else { return nil }
        return CaptureDate(rawValue: String(digits.prefix(8)) + "T" + String(digits.dropFirst(8)))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: v.isFinite ? v : nil
        case let v as Float: v.isFinite ? Double(v) : nil
        case let v as Int: Double(v)
        case let v as NSNumber: v.doubleValue.isFinite ? v.doubleValue : nil
        default: nil
        }
    }

    /// An integer, or the first of an array of them (ImageIO's ISOSpeedRatings is an array).
    private static func integer(_ value: Any?) -> Int? {
        if let list = value as? [Any] { return integer(list.first) }
        guard let n = number(value), n > 0, n < 10_000_000 else { return nil }
        return Int(n)
    }
}

#if canImport(ImageIO)
import ImageIO

extension EXIFSummary {
    /// Reads the file's EXIF with ImageIO (the primary image's properties; no pixels are decoded). Nil if the file
    /// can't be read. Compiled only by CI's Xcode job.
    public static func read(from url: URL) -> EXIFSummary? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
                as? [String: Any]
        else { return nil }
        return EXIFSummary(imageProperties: properties)
    }
}
#endif
