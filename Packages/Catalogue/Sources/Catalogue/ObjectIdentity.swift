import PTPKit

/// `(camera, folder, filename, capture date, size)`: what identifies one file on one camera (backlog section 4).
/// Handles aren't stable across sessions and filenames alone collide after the camera's counter wraps. The folder
/// is decision 7's addition for MSC, and the pairing rule needs it; the proposal's key has none.
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
