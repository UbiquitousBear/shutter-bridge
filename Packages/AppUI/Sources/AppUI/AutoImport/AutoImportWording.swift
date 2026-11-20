import CameraTransport
import Foundation

/// Settings › *Import When Connected* and Browse's notices for an auto-import (backlog section 14). British English; no
/// camera maker's marks: the cameras are named from the catalogue, the USB modes by their own wording
/// (`USBMode.cameraWording`). The camera's menu isn't named, since its name hasn't been read off the camera yet: the
/// footer says "USB connection mode", as `CamerasEmptyState.menuNote` does.
public enum AutoImportWording: Sendable {
    public static let header = AppText.string("Import When Connected")

    public static let footer = AppText.string("When a camera turned on here connects while Shutter Bridge is open, "
        + "Browse opens and the camera's new photos are imported to Photos or staged, whichever you chose last time. "
        + "Over Wi-Fi it starts once you've tapped the camera to connect and its card has been read; a reminder never "
        + "starts an import by itself. To stop the camera asking for a USB mode each time you plug it in, set its USB "
        + "connection mode in the camera's menu.")

    /// Under the footer while more than one camera is listed: MSC can't tell them apart (D11), so it follows none.
    public static let mscNote = AppText.format("%@ can't tell cameras apart, so while more than one camera is listed "
        + "here, a camera in that mode isn't imported automatically.", USBMode.massStorage.cameraWording)

    /// In place of the switches while the catalogue knows no camera of its own (a one-body row).
    public static let noCameras = AppText.format("A camera is listed here once its card has been read in %@ or over "
        + "Wi-Fi.", USBMode.mtp.cameraWording)

    public static let toggleHint = AppText.string("Imports this camera's new photos when it connects.")

    public static let saveFailed = AppText.string("The setting wasn't saved. Try again.")

    /// Browse's notice when an auto-import started a job.
    public static func started(_ n: Int, staging: Bool) -> String {
        staging ? AppText.format("Staging %@ automatically.", ByteWording.files(n))
            : AppText.format("Importing %@ automatically.", ByteWording.files(n))
    }

    /// Browse's notice when an auto-import added files to the running job.
    public static func appended(_ n: Int, staging: Bool) -> String {
        staging ? AppText.format("Added %@ to staging automatically.", ByteWording.files(n))
            : AppText.format("Added %@ to the import automatically.", ByteWording.files(n))
    }

    /// Browse's notice when an auto-import found nothing new on the card.
    public static func nothingNew(staged: Bool) -> String {
        staged ? AppText.string("No new photos to stage.") : AppText.string("No new photos to import.")
    }
}
