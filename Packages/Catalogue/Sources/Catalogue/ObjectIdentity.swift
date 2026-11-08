import PTPKit

/// `(camera, folder, filename, capture date, size)`: one file on one camera as a row records it (backlog section 4).
/// Handles aren't stable across sessions and filenames alone collide after the camera's counter wraps. The folder
/// is decision 7's addition for MSC, and the pairing rule needs it; the proposal's key has none.
///
/// **Whether a file is already imported doesn't use all of it** (Shamil, 8 Nov, after the 17.1 bench run): the
/// catalogue recognises a file by its `contentKey`, its file name, capture time (to the second) and size, ignoring
/// the USB mode, the camera key and the folder. The camera and folder stay in each row, for grouping (albums, Files
/// folders, the Camera row, the last-known card) and for finding the camera again after a pulled cable.
public struct ObjectIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    public var camera: CameraKey
    /// The folder on the card, such as "DCIM/100MSDCF"; empty when the link can't tell.
    public var folder: String
    public var filename: String
    public var captureDate: CaptureDate
    public var size: UInt64

    public init(camera: CameraKey, folder: String, filename: String, captureDate: CaptureDate, size: UInt64) {
        self.camera = camera
        self.folder = folder
        self.filename = filename
        self.captureDate = captureDate
        self.size = size
    }

    /// From PTPKit's identity, which has no folder and keeps the camera's raw date string. Nil when that string
    /// isn't a PTP DateTime.
    public init?(_ ptp: PTPObjectIdentity, folder: String) {
        guard let date = CaptureDate(ptpDateTime: ptp.captureDateRaw) else { return nil }
        self.init(camera: CameraKey(rawValue: ptp.cameraSerial), folder: folder, filename: ptp.filename,
                  captureDate: date, size: ptp.size)
    }

    /// What "already imported" matches on (Shamil, 8 Nov): the file name, capture time and size.
    public var contentKey: ContentKey {
        ContentKey(filename: filename, captureDate: captureDate, size: size)
    }

    /// The filename without its extension, "DSC04512", which the RAW+JPEG pairing rule matches on.
    public var pairStem: String {
        guard let dot = filename.lastIndex(of: ".") else { return filename }
        return String(filename[..<dot])
    }

    /// Safe for logs: the camera key shows only its length.
    public var description: String {
        "\(folder.isEmpty ? "" : folder + "/")\(filename) \(captureDate) \(size)B @\(camera)"
    }
}

extension ObjectIdentity {
    /// What the catalogue recognises an imported file by (Shamil's decision of 8 Nov, superseding the per-camera
    /// matching of decision 7 for "already imported"): the **file name**, the **capture time to the second** and the
    /// **size**, whatever the USB mode, the camera key or the folder. A file imported in MSC is imported in MTP, and
    /// a file MTP lists without a folder is the one MSC listed in `DCIM/100MSDCF`.
    ///
    /// **Accepted risk:** two cameras writing the same file name in the same second at the same byte size count as
    /// one file, and the second isn't imported. Shamil accepted it. (Why the risk is small: DCF names carry a 4-digit
    /// counter, and a match also needs the same second and the same size to the byte.)
    ///
    /// **File names compare ignoring ASCII case** (`a`–`z` as `A`–`Z`; an implementation choice, not part of
    /// Shamil's rule, for Shamil to confirm), with no locale-dependent case folding, so the result never depends on
    /// the locale. The name is a Swift `String`, so names that are canonically equivalent in Unicode ("E\u{301}" and
    /// "\u{C9}") also match, as `String`'s `==` and hashing treat them. DCF names use only upper-case letters,
    /// digits and `_`, so no two real names differ by case or by Unicode form alone (and FAT and exFAT, which ignore
    /// case, couldn't hold both in one folder); folding protects against a transport that reports a name in another
    /// case. Any extra match would also need the same second and size, so it falls inside the accepted risk.
    ///
    /// The capture time is `CaptureDate`'s wall-clock time, already to the second. **Unverified:** that MSC and MTP
    /// report the same second and size for one file (the next bench run compares them in the listing's log line).
    public struct ContentKey: Sendable, Hashable, CustomStringConvertible {
        /// The name with ASCII letters upper-cased.
        public let filename: String
        public let captureDate: CaptureDate
        public let size: UInt64

        public init(filename: String, captureDate: CaptureDate, size: UInt64) {
            self.filename = Self.foldingASCIICase(filename)
            self.captureDate = captureDate
            self.size = size
        }

        public var description: String { "\(filename) \(captureDate) \(size)B" }

        /// `a`–`z` as `A`–`Z`; every other byte, non-ASCII ones included, unchanged.
        static func foldingASCIICase(_ name: String) -> String {
            guard name.utf8.contains(where: { (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains($0) }) else {
                return name
            }
            let bytes = name.utf8.map { byte in
                (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) ? byte - 32 : byte
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
