import CameraTransport
import Catalogue
import Foundation

extension CameraItem {
    /// The catalogue identity of this file on `camera`: folder, name, capture date and size (backlog section 4,
    /// decision 7). The capture date is read as wall-clock time in the zone the link turned the camera's zone-less
    /// time into a `Date` with, so the camera's own reading comes back out (`CaptureDate`): the item's own
    /// `captureTimeZone` when the link recorded it, so a relisting after the phone has changed zone still finds the
    /// file's row to the second (Iteration 2, section 1), and otherwise `timeZone`, the reader's zone (the job's, or
    /// Browse's at listing time), as before. Either way the row's key is the camera's reading, so rows written before
    /// items carried their zone still match. Nil when the link gave no date: such a file can't be told apart from a
    /// later one of the same name and size, so it is left out of every import and counted (D10).
    ///
    /// Whether the file is already imported, or already in a job, is decided on the identity's `contentKey` alone
    /// (name, capture time, size; Shamil, 8 Nov), so neither the camera key nor the folder changes the answer; the
    /// whole identity is what the file's row is written under.
    ///
    /// Public so Browse badges files by the same rule the engine imports by.
    public func identity(camera: CameraKey, timeZone: TimeZone) -> ObjectIdentity? {
        guard let captureDate, let date = CaptureDate(captureDate, in: captureTimeZone ?? timeZone) else { return nil }
        return ObjectIdentity(camera: camera, folder: folder, filename: name, captureDate: date, size: size)
    }
}
