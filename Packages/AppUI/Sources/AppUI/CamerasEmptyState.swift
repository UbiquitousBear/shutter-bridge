import CameraTransport

/// What the Cameras screen says when no camera is connected (backlog section 6): the cable, the USB mode in the
/// camera's own wording, MSC recommended (decision 7), and that Remote Shoot (PC Remote) shares no files over USB
/// (decision 1). The empty state itself is short, with the key step in it (HIG Writing: be concise, lead with what
/// matters); the modes in detail are behind *Which USB Mode?*, in a sheet. Plain strings for now; they move into a
/// String Catalog with the full screens.
public struct CamerasEmptyState: Sendable, Hashable {
    public var title: String
    /// The empty state's description: the cable and the mode to choose.
    public var connect: String
    /// The button under it that opens the modes in detail, and that sheet's title.
    public var modeHelpButton: String
    // The sheet's lines.
    public var modeAdvice: String
    public var remoteShootNote: String
    public var menuNote: String

    public static let standard = CamerasEmptyState(
        title: "No Camera Connected",
        connect: "Connect the camera with a USB-C data cable and switch it on. When it asks, choose "
            + "\(USBMode.recommended.cameraWording).",
        modeHelpButton: "Which USB Mode?",
        modeAdvice: "When the camera asks you to Select USB Connect Mode, choose \(USBMode.recommended.cameraWording): "
            + "it shows your photos soonest. \(USBMode.mtp.cameraWording) works too, but reads the card more slowly.",
        remoteShootNote: "In \(USBMode.remoteShoot.cameraWording) the camera shares no photos over USB, so choose one "
            + "of the Image Transfer modes.",
        menuNote: "If the camera doesn't ask, unplug the cable and plug it in again, or change the USB connection mode "
            + "in the camera's menu."
    )

    /// Under the empty state while the app is looking, so a camera that doesn't appear isn't mistaken for a build
    /// that doesn't look.
    public static let lookingNotice = "Looking for a camera on the USB-C port."

    /// The sheet's lines, in reading order.
    public var modeHelpLines: [String] { [modeAdvice, remoteShootNote, menuNote] }

    /// Every line, in reading order: the empty state's title and description, then the sheet's.
    public var lines: [String] { [title, connect] + modeHelpLines }
}
