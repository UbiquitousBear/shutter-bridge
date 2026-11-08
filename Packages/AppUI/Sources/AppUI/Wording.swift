import CameraTransport
import Foundation

// The thin Browse slice's copy (backlog section 6), in British English and in the camera's own wording for its
// modes. No maker's marks: "works with" wording only. Plain strings until the String Catalog arrives with the full
// screens.

/// The Cameras screen.
public enum CamerasWording {
    public static let title = "Cameras"
    public static let usbBadge = "USB-C"

    /// The mode line under a camera's name. `ICTransportTypeUSB` is MTP or Remote Shoot (PC Remote), and nothing
    /// tells them apart before the card is read (`USBModeClassifier`), so the line says both until Browse finds out.
    public static func modeLine(_ mode: CameraMode) -> String {
        switch mode {
        case .usb(.massStorage): USBMode.massStorage.cameraWording
        case .usb(.mtp): "\(USBMode.mtp.cameraWording) or \(USBMode.remoteShoot.cameraWording)"
        case .usb(.remoteShoot): USBMode.remoteShoot.cameraWording
        case .wifi: "Wi-Fi"
        }
    }

    /// When ImageCaptureCore's access is denied or restricted (`USBCameraBrowser.start()` throws `notAuthorised`).
    /// `unverified`: which Settings switch governs it. ImageCaptureCore reuses the camera privacy string, and iOS 27.2
    /// never asked on the bench, so the copy names the Camera setting and allows for a restriction.
    public static let notAllowedTitle = "Camera access is off"
    public static let notAllowedDetail = "Shutter Bridge isn't allowed to read from a connected camera. Check "
        + "Shutter Bridge's Camera setting in Settings. If Screen Time or a profile restricts it on this iPhone, it "
        + "can't be changed here."
    public static let openSettings = "Open Settings"

    /// After Browse closes because the camera went away.
    public static func disconnected(_ name: String) -> String {
        "\(name) was disconnected. Connect it again to see its card."
    }
}

/// The Browse screen.
public enum BrowseWording {
    public static let readingTitle = "Reading the card"

    /// What to expect while ImageCaptureCore reads the card, from the bench's measurements (decision 7).
    public static func readingDetail(_ mode: CameraMode) -> String {
        switch mode {
        case .usb(.massStorage):
            "In \(USBMode.massStorage.cameraWording) this takes about 7–12 seconds for a card of 391–549 files."
        case .usb(.mtp), .usb(.remoteShoot):
            "In \(USBMode.mtp.cameraWording) it takes longer: about 65–123 seconds for a card of 391–825 files, "
                + "and the photos all appear at the end. \(USBMode.massStorage.cameraWording) reads the card much "
                + "sooner."
        case .wifi:
            "This can take a while on a full card."
        }
    }

    /// "12 s so far", "2 min 5 s so far".
    public static func elapsed(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds) s so far" }
        return "\(seconds / 60) min \(seconds % 60) s so far"
    }

    /// The catalogue completed at once with no files: Remote Shoot (PC Remote), or an empty card in MTP, which looks
    /// the same, so the copy doesn't claim either (`USBModeClassifier`).
    public static let noFilesTitle = "No files over USB"
    public static let noFilesDetail = "The camera listed no files. In \(USBMode.remoteShoot.cameraWording) it shares "
        + "none over USB. Unplug the cable, plug it in again and choose \(USBMode.massStorage.cameraWording) or "
        + "\(USBMode.mtp.cameraWording) when the camera asks you to Select USB Connect Mode. If it doesn't ask, change "
        + "the USB connection mode in the camera's menu."

    public static let emptyCardTitle = "No photos on the card"
    public static let emptyCardDetail = "The camera listed no files on its card."

    public static let goneTitle = "Camera disconnected"
    public static let goneDetail = "Connect the camera again to see its card."

    public static let listingFailedTitle = "Couldn't read the card"
    public static let tryAgain = "Try Again"
    public static let undatedHeader = "No date"

    /// On a greyed-out video (Shamil, 8 Nov).
    public static let videoLabel = "Video: from 1.1"
    /// On anything else that isn't a still, greyed out too.
    public static let otherLabel = "Not a photo"

    public static let rawBadge = "RAW"
    public static let heifBadge = "HEIF"

    /// Why listing failed, by the link's failure. A removal isn't here: it returns to Cameras.
    public static func listingFailed(_ kind: CameraLinkFailure.Kind) -> String {
        switch kind {
        case .busy, .noAnswer:
            "The camera didn't answer. Check the cable and that the camera is on, then try again."
        case .notAuthorised:
            CamerasWording.notAllowedDetail
        case .modeListsNoFiles:
            noFilesDetail
        case .disconnected:
            goneDetail
        case .phoneStorageFull:
            "This iPhone is out of space. Free some space, then try again."
        case .itemNotFound, .unreadableItem, .unsupportedFormat:
            "The camera couldn't read its card. Check the card in the camera, then try again."
        }
    }
}

/// *Copy as JPEG* and *Share as JPEG…* (Shamil, 8 Nov).
public enum JPEGWording {
    public static let copyAction = "Copy as JPEG"
    public static let shareAction = "Share as JPEG…"
    public static let cancel = "Cancel"
    public static let cancelling = "Cancelling…"
    /// When the app left the foreground during an action, which cancels it.
    public static let keepOpen = "Keep Shutter Bridge open until the JPEG is ready."

    /// The progress line.
    public static func working(name: String, stage: JPEGStage) -> String {
        switch stage {
        case .fetching: "Fetching \(name) from the camera…"
        case .converting(.renderRAW): "Making a JPEG from the RAW…"
        case .converting(.reencodeHEIF): "Making a JPEG from the HEIF…"
        case .converting(.asIs): "Preparing the JPEG…"
        }
    }

    /// The confirmation after a copy.
    public static func copied(pressedName: String, embeddedPreview: Bool) -> String {
        embeddedPreview ? copiedPreview : "Copied \(JPEGSourceRule.stem(of: pressedName)) as a JPEG."
    }

    /// The fallback, said whenever the camera's preview stands in for a render.
    public static let copiedPreview = "Copied the camera's preview: this RAW couldn't be decoded on this iPhone."
    public static let sharingPreview = "Sharing the camera's preview: this RAW couldn't be decoded on this iPhone."

    /// Why an action didn't finish; nil for a cancel, which needs no message.
    public static func failed(_ failure: JPEGActionFailure) -> String? {
        switch failure {
        case .cancelled:
            nil
        case let .link(linkFailure):
            switch linkFailure.kind {
            case .disconnected: "The camera was disconnected."
            case .busy, .noAnswer: "The camera didn't answer. Try again."
            case .itemNotFound: "This file is no longer on the card."
            case .unreadableItem: "The camera couldn't read this file."
            case .unsupportedFormat: "This file can't be made into a JPEG."
            case .phoneStorageFull: "This iPhone is out of space. Free some space, then try again."
            case .notAuthorised: CamerasWording.notAllowedDetail
            case .modeListsNoFiles: BrowseWording.noFilesDetail
            }
        case .conversion:
            "This photo couldn't be made into a JPEG on this iPhone."
        case .storage:
            "The JPEG couldn't be prepared. Check that this iPhone has free space, then try again."
        case .clipboard:
            "The JPEG couldn't be put on the clipboard."
        case .shareUnavailable:
            "The share sheet couldn't be shown. Try again."
        }
    }
}
