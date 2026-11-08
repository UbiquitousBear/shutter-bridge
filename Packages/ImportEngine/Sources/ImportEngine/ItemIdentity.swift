import CameraTransport
import Catalogue
import Foundation

extension CameraItem {
    /// The catalogue identity of this file on `camera`: folder, name, capture date and size (backlog section 4,
    /// decision 7). The capture date is read as wall-clock time in `timeZone`, the zone the link turned the camera's
    /// zone-less time into a `Date` with, so the camera's own reading comes back out (`CaptureDate`). Nil when the
    /// link gave no date: such a file can't be told apart from a later one of the same name and size, so the engine
    /// doesn't import it until section 4 decides what to do with it.
    ///
    /// Whether the file is already imported, or already in a job, is decided on the identity's `contentKey` alone
    /// (name, capture time, size; Shamil, 8 Nov), so neither the camera key nor the folder changes the answer; the
    /// whole identity is what the file's row is written under.
    ///
    /// Public so Browse badges files by the same rule the engine imports by.
    public func identity(camera: CameraKey, timeZone: TimeZone) -> ObjectIdentity? {
        guard let captureDate, let date = CaptureDate(captureDate, in: timeZone) else { return nil }
        return ObjectIdentity(camera: camera, folder: folder, filename: name, captureDate: date, size: size)
    }
}
