import CameraTransport

/// What the Cameras screen says when no camera is connected (backlog section 6): the cable, the USB mode in the
/// camera's own wording, MSC recommended (decision 7), and that Remote Shoot (PC Remote) shares no files over USB
/// (decision 1). Plain strings for now; they move into a String Catalog with the screens.
public struct CamerasEmptyState: Sendable, Hashable {
    public var title: String
    public var connect: String
    public var modeAdvice: String
    public var remoteShootNote: String

    public static let standard = CamerasEmptyState(
        title: "No camera connected",
        connect: "Connect your camera to this iPhone with a USB-C cable that carries data, then switch the camera on.",
        modeAdvice: "When the camera asks you to Select USB Connect Mode, choose \(USBMode.recommended.cameraWording): "
            + "it shows your photos soonest. \(USBMode.mtp.cameraWording) works too, but reads the card more slowly.",
        remoteShootNote: "In \(USBMode.remoteShoot.cameraWording) the camera shares no photos over USB, so choose one "
            + "of the Image Transfer modes."
    )

    /// Shown under the empty state until `USBLink` lands: this build doesn't look for cameras, so a connected camera
    /// would otherwise sit behind "No camera connected" with no explanation.
    public static let notYetLookingNotice = "This early build doesn't look for cameras yet."

    /// Every line, in reading order.
    public var lines: [String] { [title, connect, modeAdvice, remoteShootNote] }
}
