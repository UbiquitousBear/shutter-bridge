import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge

// The app's copy (backlog section 6), in British English and in the camera's own wording for its modes. No maker's
// marks: "works with" wording only. Numbers are the bench's measurements, never promises. Sizes and times go through
// the system's formatters for the person's region (`ByteWording`); the words come from AppUI's String Catalog through
// `AppText` (I17), keyed by their English, with plural variants for counted words.

/// The Cameras screen.
public enum CamerasWording {
    public static let title = AppText.string("Cameras")
    public static let usbBadge = AppText.string("USB-C")
    /// The toolbar button that opens Settings.
    public static let settingsButton = AppText.string("Settings")

    /// The mode line under a camera's name. `ICTransportTypeUSB` is MTP or Remote Shoot (PC Remote), and nothing
    /// tells them apart before the card is read (`USBModeClassifier`), so the line says both until Browse finds out.
    public static func modeLine(_ mode: CameraMode) -> String {
        switch mode {
        case .usb(.massStorage): USBMode.massStorage.cameraWording
        case .usb(.mtp): AppText.format("%@ or %@", USBMode.mtp.cameraWording, USBMode.remoteShoot.cameraWording)
        case .usb(.remoteShoot): USBMode.remoteShoot.cameraWording
        case .wifi: AppText.string("Wi-Fi")
        case .staging: stagingBadge
        }
    }

    /// The badge on a camera's row: how it is connected.
    public static func badge(for mode: CameraMode) -> String {
        switch mode.carrier {
        case .usb: usbBadge
        case .wifi: wifiBadge
        case .staging: stagingBadge
        }
    }

    public static let wifiBadge = AppText.string("Wi-Fi")
    /// Staging read as a camera for *Import keepers* (`CameraMode.staging`): never a row on Cameras, but every switch
    /// over the carrier names it.
    public static let stagingBadge = AppText.string("Staging")

    /// The lines about the device on a camera's row: its battery level and the card's free space. Only a link that can read
    /// them has any (`CameraLinkCapabilities.reportsBatteryAndFreeSpace`: Wi-Fi's can't, the whole-card session lists no
    /// device properties and its storage reports no capacity, B:70), and a value nobody has read (`nil`) is left out, never
    /// shown as 0.
    public static func deviceStatus(carrier: CameraCarrier, batteryPercent: Int?, freeBytes: UInt64?,
                                    locale: Locale = .autoupdatingCurrent) -> [String] {
        guard CameraLinkCapabilities.defaults(for: carrier).reportsBatteryAndFreeSpace else { return [] }
        var lines: [String] = []
        if let batteryPercent { lines.append(AppText.format("Battery %@%%", String(min(max(batteryPercent, 0), 100)))) }
        if let freeBytes { lines.append(AppText.format("%@ free", ByteWording.size(freeBytes, locale: locale))) }
        return lines
    }

    /// When discovery couldn't start for a reason other than access (`CamerasModel.Access.failed`): the camera would
    /// never appear, so the screen says so with Try Again rather than show "No Camera Connected".
    public static let discoveryFailedTitle = AppText.string("Can't Look for Cameras")
    public static let discoveryFailedDetail = AppText.string("Shutter Bridge couldn't start looking for a camera on "
        + "the USB-C port. "
        + "Tap Try Again.")

    /// When ImageCaptureCore's access is denied or restricted (`USBCameraBrowser.start()` throws `notAuthorised`).
    /// `unverified`: which Settings switch governs it. ImageCaptureCore reuses the camera privacy string, and iOS 27.2
    /// never asked on the bench, so the copy names the Camera setting and allows for a restriction.
    public static let notAllowedTitle = AppText.string("Camera Access Is Off")
    public static let notAllowedDetail = AppText.string("Shutter Bridge isn't allowed to read from a connected camera. "
        + "Check "
        + "Shutter Bridge's Camera setting in Settings. If Screen Time or a profile restricts it on this iPhone, it "
        + "can't be changed here.")
    public static let openSettings = AppText.string("Open Settings")

    /// What the app calls a camera whose own name isn't known: in Image Transfer (MSC) discovery gives the card's
    /// volume name, not the camera's.
    public static let genericName = AppText.string("Camera")

    /// Volume names a card is given when nobody named it, compared ignoring case (the α7C II's card is "Untitled";
    /// FAT cards formatted elsewhere read "NO NAME").
    static let volumeDefaultNames: Set<String> = ["untitled", "no name"]

    /// The one name the app shows and files under for a camera: the Browse title, the Cameras row, the disconnect
    /// message, and the album and staging folder made for a new import. In Image Transfer (MSC) ImageCaptureCore names
    /// the device after the card's volume ("Untitled"), which reads like a placeholder, so the app says "Camera"
    /// there, and for a volume default or an empty name in any mode; otherwise the camera's own name.
    public static func displayName(for camera: CameraDescriptor) -> String {
        if camera.mode == .usb(.massStorage) { return genericName }
        let name = camera.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || volumeDefaultNames.contains(name.lowercased()) { return genericName }
        return name
    }

    /// After Browse closes because the camera went away.
    public static func disconnected(_ camera: CameraDescriptor) -> String {
        let name = displayName(for: camera)
        let subject = name == genericName ? AppText.string("The camera") : name
        return AppText.format("%@ was disconnected. Connect it again to see its card.", subject)
    }
}

/// The Browse screen.
public enum BrowseWording {
    // Titles are in title case, as system empty states are ("No Results"); descriptions in sentence case (HIG
    // Writing).
    public static let readingTitle = AppText.string("Reading the Card")

    /// While a Wi-Fi camera is reached (Bluetooth, the join, the session) and no last-known card is shown: the card
    /// isn't being read yet, so the screen doesn't say it is (bench 19.1). The detail is always `connectingDetail`: the
    /// connection's step is in the status strip above (`WiFiImportModel.activityLine`).
    public static let connectingTitle = AppText.string("Connecting to the Camera")
    public static let connectingDetail = AppText.string("Shutter Bridge is reaching the camera over Bluetooth and its "
        + "Wi-Fi.")
    /// The bar's subtitle while a Wi-Fi camera is reached under its last-known card.
    public static let connectingSubtitle = AppText.string("Connecting to the camera…")

    // The link going away under a shown card (Wi-Fi; bench 19.1).

    /// The strip over the card while the link is let go or lost.
    public static let disconnectedLine = AppText.string("Disconnected from the camera's Wi-Fi.")
    /// The strip while it comes back.
    public static let reconnectingLine = AppText.string("Reconnecting to the camera…")
    public static let reconnect = AppText.string("Reconnect")
    public static let reconnectHint = AppText.string("Joins the camera's Wi-Fi again and reads its card.")

    /// The strip's line for an interruption.
    public static func interruptionLine(_ interruption: BrowseModel.Interruption) -> String {
        switch interruption {
        case .reconnecting: reconnectingLine
        case .disconnected: disconnectedLine
        }
    }

    /// What to expect while ImageCaptureCore reads the card, from the bench's measurements (decision 7). The times
    /// were measured on cards of 391–549 (MSC) and 391–825 (MTP) files; the copy keeps the times only (HIG Writing).
    public static func readingDetail(_ mode: CameraMode) -> String {
        switch mode {
        case .usb(.massStorage):
            AppText.format("In %@ this takes about 7–12 seconds.", USBMode.massStorage.cameraWording)
        case .usb(.mtp), .usb(.remoteShoot):
            AppText.format("In %@ it takes longer, about 65–123 seconds, and the photos all appear at the end. %@ "
                + "reads the card much sooner.", USBMode.mtp.cameraWording, USBMode.massStorage.cameraWording)
        case .wifi:
            AppText.string("This can take a while on a full card.")
        case .staging:
            AppText.string("Reading the staged files.")
        }
    }

    /// After the time the card has been read for, which the screen shows as a system timer ("0:12 so far",
    /// `Text(timerInterval:)`), so it counts in the person's own notation.
    public static let elapsedSuffix = AppText.string("so far")

    /// The catalogue completed at once with no files: Remote Shoot (PC Remote), or an empty card in MTP, which looks
    /// the same, so the copy doesn't claim either (`USBModeClassifier`).
    public static let noFilesTitle = AppText.string("No Files over USB")
    /// Short, as it is also the one-line failure of *Copy as JPEG* (HIG Writing: lead with what matters). The modes
    /// in detail are behind the Cameras empty state's *Which USB Mode?*.
    public static let noFilesDetail = AppText.format("The camera is sharing no files over USB. Reconnect it and "
        + "choose %@ or %@.", USBMode.massStorage.cameraWording, USBMode.mtp.cameraWording)

    public static let emptyCardTitle = AppText.string("No Photos on the Card")
    public static let emptyCardDetail = AppText.string("There are no files on the card.")

    public static let goneTitle = AppText.string("Camera Disconnected")
    public static let goneDetail = AppText.string("Connect the camera again to see its card.")

    public static let listingFailedTitle = AppText.string("Couldn't Read the Card")
    public static let tryAgain = AppText.string("Try Again")
    public static let undatedHeader = AppText.string("No Date")

    /// On a greyed-out video (Shamil, 8 Nov).
    public static let videoLabel = AppText.string("Video: from 1.1")
    /// On anything else that isn't a still, greyed out too.
    public static let otherLabel = AppText.string("Not a photo")

    /// The close button on a message strip (iOS calls this control Close).
    public static let close = AppText.string("Close")

    public static let rawBadge = AppText.string("RAW")
    public static let heifBadge = AppText.string("HEIF")

    /// Why listing failed, by the link's failure. A removal isn't here: it returns to Cameras.
    public static func listingFailed(_ kind: CameraLinkFailure.Kind) -> String {
        switch kind {
        case .busy, .noAnswer:
            AppText.string("The camera didn't answer. Check the cable and that the camera is on, then try again.")
        case .notAuthorised:
            CamerasWording.notAllowedDetail
        case .modeListsNoFiles:
            noFilesDetail
        case .disconnected:
            goneDetail
        case .phoneStorageFull:
            AppText.string("This iPhone is out of space. Free some space, then try again.")
        case .itemNotFound, .unreadableItem, .unsupportedFormat:
            AppText.string("The camera couldn't read its card. Check the card in the camera, then try again.")
        case .cardUnavailable:
            AppText.string("The camera isn't offering its card right now. Check that the card is in the camera, then "
                + "try again.")
        case .refused:
            AppText.string("The camera refused the connection. Check its network settings, then try again.")
        case .identityChanged:
            AppText.string("This isn't the camera that was connected before. Connect to the same camera, then try "
                + "again.")
        }
    }
}

/// *Copy as JPEG* and *Share as JPEG…* (Shamil, 8 Nov).
public enum JPEGWording {
    public static let copyAction = AppText.string("Copy as JPEG")
    public static let shareAction = AppText.string("Share as JPEG…")
    public static let cancel = AppText.string("Cancel")
    public static let cancelling = AppText.string("Cancelling…")
    /// When the app left the foreground during an action, which cancels it.
    public static let keepOpen = AppText.string("Keep Shutter Bridge open until the JPEG is ready.")

    /// The progress line.
    public static func working(name: String, stage: JPEGStage) -> String {
        switch stage {
        case .fetching: AppText.format("Fetching %@ from the camera…", name)
        case .converting(.renderRAW): AppText.string("Making a JPEG from the RAW…")
        case .converting(.reencodeHEIF): AppText.string("Making a JPEG from the HEIF…")
        case .converting(.asIs): AppText.string("Preparing the JPEG…")
        }
    }

    /// The confirmation after a copy.
    public static func copied(pressedName: String, embeddedPreview: Bool) -> String {
        embeddedPreview ? copiedPreview : AppText.format("Copied %@ as a JPEG.", JPEGSourceRule.stem(of: pressedName))
    }

    /// The fallback, said whenever the camera's preview stands in for a render.
    public static let copiedPreview = AppText.string("Copied the camera's preview: this RAW couldn't be decoded on "
        + "this iPhone.")
    public static let sharingPreview = AppText.string("Sharing the camera's preview: this RAW couldn't be decoded on "
        + "this iPhone.")

    /// Why an action didn't finish; nil for a cancel, which needs no message.
    public static func failed(_ failure: JPEGActionFailure) -> String? {
        switch failure {
        case .cancelled:
            nil
        case let .link(linkFailure):
            switch linkFailure.kind {
            case .disconnected: AppText.string("The camera was disconnected. Connect it again, then try again.")
            case .busy, .noAnswer: AppText.string("The camera didn't answer. Try again.")
            case .itemNotFound: AppText.string("This file is no longer on the card. Go back to Cameras and open the "
                + "camera again.")
            case .unreadableItem: AppText.string("The camera couldn't read this file. Check the card in the camera, "
                + "then try again.")
            case .unsupportedFormat: AppText.string("This file can't be made into a JPEG. Import it to keep the "
                + "original.")
            case .phoneStorageFull: AppText.string("This iPhone is out of space. Free some space, then try again.")
            case .notAuthorised: CamerasWording.notAllowedDetail
            case .modeListsNoFiles: BrowseWording.noFilesDetail
            case .cardUnavailable: AppText.string("The camera isn't offering its card right now. Try again in a moment.")
            case .refused: AppText.string("The camera refused the connection. Close any other app connected to it, "
                + "then try again.")
            case .identityChanged: AppText.string("This isn't the camera that was connected before. Connect that "
                + "camera again, then try again.")
            }
        case .conversion:
            AppText.string("This photo couldn't be made into a JPEG on this iPhone. Import it to keep the original.")
        case .storage:
            AppText.string("The JPEG couldn't be prepared. Check that this iPhone has free space, then try again.")
        case .clipboard:
            AppText.string("The JPEG couldn't be copied. Try again, or use Share as JPEG.")
        case .shareUnavailable:
            AppText.string("The share sheet couldn't be shown. Try again.")
        }
    }
}

/// Sizes, rates and times through the system's formatters (HIG Writing; Apple's localisation guidance), so the
/// decimal separator, the units and their spacing follow the person's region, as everywhere else in iOS. Sizes are
/// the file style's decimal units (1 MB = 10^6 bytes), as the bench measured them. `locale` is for tests; the app
/// passes nothing. Counted words ("1 file", "3 files") are the String Catalog's plural variants (`AppText.counted`).
public enum ByteWording {
    /// "512 bytes", "640 kB", "42.3 MB", "1.24 GB" (in en-GB; "42,3 MB" in de-DE). Zero is "0 bytes"-style digits, not
    /// "Zero KB".
    public static func size(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    /// "1.2 GB of 4.5 GB".
    public static func progress(_ done: UInt64, of total: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        AppText.format("%@ of %@", size(done, locale: locale), size(total, locale: locale))
    }

    /// "41.8 MB/s": the size the bench measures each second, with "/s" as the system writes data rates.
    public static func rate(megabytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        AppText.format("%@/s", size(bytesPerSecond(megabytesPerSecond), locale: locale))
    }

    /// The rate as VoiceOver says it: "41.8 MB per second", so "/s" isn't read as a letter.
    public static func rateSpoken(megabytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        AppText.format("%@ per second", size(bytesPerSecond(megabytesPerSecond), locale: locale))
    }

    /// "About 40 secs left", "About 3 min left", "About 1 hr, 5 min left" (abbreviated units, as the system writes
    /// them). Rounded up, so it never reads 0: to the second under a minute, then to the minute.
    public static func timeLeft(_ duration: Duration, locale: Locale = .autoupdatingCurrent) -> String {
        AppText.format("About %@ left", roundedTimeLeft(duration).formatted(timeLeftStyle(.abbreviated, locale: locale)))
    }

    /// The same as VoiceOver says it, in whole words: "About 3 minutes left".
    public static func timeLeftSpoken(_ duration: Duration, locale: Locale = .autoupdatingCurrent) -> String {
        AppText.format("About %@ left", roundedTimeLeft(duration).formatted(timeLeftStyle(.wide, locale: locale)))
    }

    /// The time left as shown: at least a second, whole seconds under a minute, whole minutes above.
    static func roundedTimeLeft(_ duration: Duration) -> Duration {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let total = seconds.isFinite ? max(1, Int64(min(seconds, 1e9).rounded(.up))) : 1
        if total < 60 { return .seconds(total) }
        return .seconds((total + 59) / 60 * 60)
    }

    private static func timeLeftStyle(_ width: Duration.UnitsFormatStyle.UnitWidth,
                                      locale: Locale) -> Duration.UnitsFormatStyle {
        Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: width, maximumUnitCount: 2)
            .locale(locale)
    }

    private static func bytesPerSecond(_ megabytesPerSecond: Double) -> UInt64 {
        guard megabytesPerSecond.isFinite, megabytesPerSecond > 0 else { return 0 }
        return UInt64(min(megabytesPerSecond, 1e9) * 1_000_000)
    }

    /// "1 file", "3 files".
    public static func files(_ n: Int) -> String { AppText.counted(n, one: "%lld file", other: "%lld files") }
}

/// Browse beyond the thin slice: selection, the sticky bar, filters, the already-imported badge and the last-known
/// card (backlog section 6, *Browse* and *Browse, while the card is read*).
extension BrowseWording {
    public static let select = AppText.string("Select")
    public static let doneSelecting = AppText.string("Done")
    public static let selectAllNew = AppText.string("Select All New")
    public static let deselectAll = AppText.string("Deselect All")
    public static let importAction = AppText.string("Import")
    public static let importedBadge = AppText.string("Imported")
    /// A photo with a staged copy (Shamil, 11 Nov). Imported takes its place on the cell when both apply.
    public static let stagedBadge = AppText.string("Staged")
    public static let new = AppText.string("New")
    /// A photo rejected in Staging (D3, Shamil, 11 Nov): *Select All New* and New Only leave it out, even once its
    /// staged copy has gone. Imported takes its place on the cell when both apply; it takes Staged's.
    public static let rejectedBadge = AppText.string("Rejected")
    /// The Rejected badge's action (a tap on it, the press-and-hold menu, the badge as a VoiceOver button): clears the
    /// mark, so the photo is new again.
    public static let liftReject = AppText.string("Lift Reject")
    /// What lifting does, for the badge's VoiceOver hint.
    public static let liftRejectHint = AppText.string("Makes this photo new again, so Select All New picks it.")
    /// When the catalogue couldn't clear the mark.
    public static let liftRejectFailed = AppText.string("The reject couldn't be lifted. Try again.")

    // The Import button (Shamil, 11 Nov): its primary action is the remembered choice, and its menu offers both.
    /// The primary action when the remembered choice is *Stage*.
    public static let stageAction = AppText.string("Stage")
    public static let importToPhotos = AppText.string("Import to Photos")
    public static let stageInICloudDrive = AppText.string("Stage in iCloud Drive")
    public static let stageOnIPhone = AppText.string("Stage on iPhone")
    /// The Import button's VoiceOver hint: what it does, not the gesture (VoiceOver reaches the menu its own way;
    /// how it announces a menu with a primary action is to be confirmed on the iPhone).
    public static let importButtonHint = AppText.string("Uses the last choice. Import to Photos and Stage are in its "
        + "menu.")

    /// The Import button's title: "Import", or "Stage" when the remembered choice is *Stage*.
    public static func importButtonTitle(_ choice: DestinationKind) -> String {
        switch choice {
        case .photos: importAction
        case .staging: stageAction
        }
    }

    /// The menu's *Stage* item: "Stage in iCloud Drive", or "Stage on iPhone" when staging is on this iPhone (or
    /// where it goes isn't read yet).
    public static func stageMenuTitle(_ place: StagingPlace?) -> String {
        place == .iCloudDrive ? stageInICloudDrive : stageOnIPhone
    }

    /// The title while selecting, as Photos and Files report the selection: "Select Items", then "3 Selected".
    public static func selectingTitle(_ summary: SelectionSummary) -> String {
        summary.count == 0 ? selectItems : AppText.counted(summary.count, one: "%lld Selected", other: "%lld Selected")
    }

    public static let selectItems = AppText.string("Select Items")

    /// The bottom bar's status while selecting: "3 files · 142.5 MB".
    public static func selectionSummary(_ summary: SelectionSummary) -> String {
        summary.count == 0 ? noSelection
            : AppText.format("%@ · %@", ByteWording.files(summary.count), ByteWording.size(summary.bytes))
    }

    public static let noSelection = AppText.string("No files selected")

    /// Why a file can't be selected, as a sentence. The cell's VoiceOver value says it, not a hint (people can turn
    /// hints off, and they are read last); `cellAccessibilityValue(_:)` leaves out what the label already says.
    public static func notSelectable(_ reason: BrowseModel.SelectionBlock) -> String {
        switch reason {
        case .video: videosNotYet
        case .notAPhoto: AppText.string("This kind of file can't be imported.")
        case .noCaptureDate: AppText.string("No capture date, so it can't be imported yet.")
        case .cardNotRead: AppText.string("Wait until the card has been read.")
        case .cameraNotConnected: AppText.string("Connect the camera to select this file.")
        }
    }

    /// What VoiceOver hears for a video, in place of the on-screen "Video: from 1.1" (Shamil, 9 Nov).
    public static let videosNotYet = AppText.string("Videos can't be imported yet.")

    // Filters.
    public static let filters = AppText.string("Filters")
    public static let newOnly = AppText.string("New Only")
    public static let type = AppText.string("Type")
    public static let dateRange = AppText.string("Date")
    public static let anyDate = AppText.string("Any Date")
    public static let from = AppText.string("From")
    public static let to = AppText.string("To")
    public static let clearFilters = AppText.string("Clear Filters")
    public static let noMatchesTitle = AppText.string("No Matching Files")
    public static let noMatchesDetail = AppText.string("No files on the card match these filters.")
    /// The Filters button's VoiceOver value, so hidden files aren't taken for missing ones.
    public static let filtersOn = AppText.string("On")
    public static let filtersOff = AppText.string("Off")

    public static func filtersValue(isActive: Bool) -> String { isActive ? filtersOn : filtersOff }

    public static func typeLabel(_ type: BrowseFileType) -> String {
        switch type {
        case .raw: AppText.string("RAW")
        case .jpeg: AppText.string("JPEG")
        case .heif: AppText.string("HEIF")
        case .video: AppText.string("Video")
        case .other: AppText.string("Other")
        }
    }

    /// While ImageCaptureCore reads the card, the catalogue's last listing shows at once (decision 7), with one
    /// line above the grid: "Showing the card as it was on 8 Nov 2026 at 14:05." `date` is when it was listed
    /// (`BrowseModel.lastKnownListedAt`), formatted by the screen for the locale.
    public static func lastKnownLine(_ date: String) -> String {
        AppText.format("Showing the card as it was on %@.", date)
    }

    /// The bar's subtitle while the last-known card is shown and the live one is read.
    public static let readingSubtitle = AppText.string("Reading the card…")

    // The camera isn't connected (W6-absent): an offline Browse, opened by "Import new photos" with the camera away.

    /// The bar's subtitle on an offline Browse.
    public static let notConnectedSubtitle = AppText.string("Not connected")
    /// The offline Browse's empty state's title, when the catalogue has no card to show.
    public static let notConnectedTitle = AppText.string("Camera Not Connected")
    /// The line above an offline Browse's last-known card, after `lastKnownLine(_:)`.
    public static let notConnectedLine = AppText.string("The camera isn't connected.")
    /// The offline Browse's empty state when the camera's card has never been read.
    public static let neverReadDetail = AppText.string("Shutter Bridge hasn't read this camera's card yet.")
    /// The offline Browse's empty state when the card was empty the last time it was read; `date` as in
    /// `lastKnownLine(_:)`.
    public static func emptyLastKnownDetail(_ date: String) -> String {
        AppText.format("The card had no files when it was last read, on %@.", date)
    }
    /// The offline Browse's next step: connect the camera, or, for a Wi-Fi camera Shutter Bridge can try to reach now,
    /// tap Connect (`canConnect`).
    public static func notConnectedNextStep(carrier: CameraCarrier, canConnect: Bool) -> String {
        switch carrier {
        case .wifi:
            canConnect ? AppText.string("Tap Connect to reach it over Wi-Fi and read its card.")
                : AppText.string("Its card will be read once Shutter Bridge can reach it.")
        case .usb, .staging:
            AppText.string("Connect it with its cable to read its card and import new photos.")
        }
    }
    /// The offline Browse's button for a Wi-Fi camera that is listed: it opens the camera, which starts the join.
    public static let connect = AppText.string("Connect")

    /// The button by the last-known line that shows the measured reading times (backlog section 6).
    public static let readingTimesButton = AppText.string("Reading Times")

    /// The date filter's switch, and what it says when no file on the card has a capture date.
    public static let limitDates = AppText.string("Only These Dates")
    public static let noDatedFiles = AppText.string("No file on the card has a capture date.")

    /// The grid cell's VoiceOver label: name, date, type and, for a still, Imported, Staged, both ("Imported,
    /// staged": the cell shows only Imported) or New; a rejected still that isn't imported says Rejected (and staged,
    /// when it is) in place of New (D3). Selection is the `.isSelected` trait, not words, so it isn't said twice.
    /// `date` is formatted by the screen for the locale; nil for a file without one.
    public static func cellAccessibility(name: String, date: String?, kind: CardCellKind, isImported: Bool,
                                         isStaged: Bool = false, isRejected: Bool = false) -> String {
        var parts = [name]
        parts.append(date ?? undatedHeader)
        switch kind {
        case let .photo(badge): parts.append(badge ?? AppText.string("JPEG"))
        case .video: parts.append(typeLabel(.video))
        case .other: parts.append(otherLabel)
        }
        if kind.offersJPEGActions, isRejected, !isImported {
            parts.append(isStaged ? rejectedBadge + ", " + stagedBadge.lowercased() : rejectedBadge)
        } else if kind.offersJPEGActions {
            switch (isImported, isStaged) {
            case (true, true): parts.append(importedBadge + ", " + stagedBadge.lowercased())
            case (true, false): parts.append(importedBadge)
            case (false, true): parts.append(stagedBadge)
            case (false, false): parts.append(new)
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The grid cell's VoiceOver value: why it can't be selected, unless the label says so already (Not a photo); nil
    /// when it can be.
    public static func cellAccessibilityValue(_ block: BrowseModel.SelectionBlock?) -> String? {
        switch block {
        case nil, .notAPhoto?: nil
        case let block?: notSelectable(block)
        }
    }

    /// After Import (or *Import to Photos* or *Stage*) is tapped in Browse. `choice` is what was asked for; nothing new
    /// is worded by what the import does instead, so an *Import to Photos* staged because Photos access is off says
    /// the files are already staged.
    public static func importRequested(_ outcome: ImportRequestOutcome, choice: DestinationKind = .photos) -> String? {
        let staging = choice == .staging
        switch outcome {
        case let .started(n):
            return staging ? AppText.format("Staging %@.", ByteWording.files(n))
                : AppText.format("Importing %@.", ByteWording.files(n))
        case let .appended(n):
            return staging ? AppText.format("Added %@ to staging.", ByteWording.files(n))
                : AppText.format("Added %@ to the import.", ByteWording.files(n))
        case let .nothingNew(staged):
            return staged ? AppText.string("These files are already staged or being staged.")
                : AppText.string("These files are already imported or in the import.")
        case .busyWithAnotherCamera:
            return AppText.string("Another camera's import is still running. Let it finish, or cancel it, then import "
                + "from this camera.")
        case .busyWithAnotherMode(.photos): return AppText.string("An import is running. Stage these when it's done.")
        case .busyWithAnotherMode(.staging): return AppText.string("Staging is running. Import these when it's done.")
        case .busyWithKeepers: return AppText.string("Keepers are being imported from Staging. Import these when it's "
            + "done.")
        case .stillStarting: return AppText.string("The import is starting. Try again in a moment.")
        case let .failed(message): return message
        }
    }
}

/// The Settings screen (backlog section 6; Shamil, 11 Nov). There is no destination choice any more: the Import
/// button offers *Import to Photos* and *Stage* at each import. Settings says where staging goes, and why it is on
/// this iPhone when it is.
public enum SettingsWording {
    public static let title = AppText.string("Settings")
    public static let stagingHeader = AppText.string("Staging")

    /// Under the staging section: what *Stage* does, and where the choice is made. It promises nothing about culling,
    /// which isn't built yet.
    public static let stagingFooter = AppText.string("Stage copies the camera's originals into this folder, in a "
        + "folder for each "
        + "camera and capture day, and leaves Photos alone. Choose Import to Photos or Stage from the Import button "
        + "each time you import.")

    /// Where staging goes, as Files names it.
    public static func stagingLocation(_ place: StagingPlace) -> String { place.folderPath }

    /// The VoiceOver label of the location row: "Staging folder, iCloud Drive › Shutter Bridge › Staging".
    public static func stagingLocationAccessibility(_ place: StagingPlace) -> String {
        AppText.format("Staging folder, %@", place.folderPath)
    }

    /// Why staging is on this iPhone; nil when it is in iCloud Drive. No Settings button: the app's page in Settings
    /// has no iCloud switch.
    public static func stagingFallback(_ place: StagingPlace) -> String? {
        switch place.fallbackReason {
        case nil: nil
        case .iCloudDriveOff?:
            AppText.string("iCloud Drive is off or you're not signed in to iCloud, so staging is on this iPhone.")
        case .containerUnavailable?:
            AppText.string("iCloud Drive isn't available to Shutter Bridge, so staging is on this iPhone.")
        case .lostDuringImport?: AppText.string("iCloud Drive became unavailable, so staging is on this iPhone.")
        }
    }

    /// What *Import to Photos* will do when Photos access is off or restricted (HIG Settings: show what will happen);
    /// nil when it isn't. A denial comes with Open Settings; a restriction can't be changed there.
    public static func forcedStaging(_ reason: StagingReason) -> String? {
        switch reason {
        case .chosen: nil
        case .photosDenied: AppText.string("Photos access is off, so Import to Photos stages the photos instead.")
        case .photosRestricted: AppText.string("Photos is restricted on this iPhone, so Import to Photos stages the "
            + "photos instead.")
        }
    }
}

/// The Import screen (backlog section 6, *Import*; decisions 1, 4 and 9).
public enum ImportWording {
    public static let title = AppText.string("Import")
    public static let pause = AppText.string("Pause")
    public static let resume = AppText.string("Continue")
    public static let cancel = AppText.string("Cancel Import")
    public static let openSettings = AppText.string("Open Settings")
    public static let askingForPhotos = AppText.string("Waiting for your answer about Photos access…")
    public static let couldNotStart = AppText.string("The import couldn't start. Check the camera is still connected, "
        + "then try again.")
    public static let couldNotAdd = AppText.string("These files couldn't be added to the import. Try again.")
    public static let filesHeader = AppText.string("In This Import")
    public static let noJobTitle = AppText.string("Nothing to Import")
    public static let noJobDetail = AppText.string("Select photos on a camera's card and tap Import.")
    public static let cancelConfirmTitle = AppText.string("Cancel this import?")
    public static let cancelConfirmDetail = AppText.string("Files already imported are kept. The rest stay on the card.")
    public static let keepImporting = AppText.string("Keep Importing")

    /// The ask to keep the app in front, and why the screen stays on (decision 1: the import asks to stay in front
    /// and keeps the screen on): a wired import stopped within about 2 s of the app leaving the foreground on the
    /// bench (2 Nov); the app pauses the job then and carries on when it is back.
    public static let screenOnNote = AppText.string("Keep Shutter Bridge open while it imports over USB: the import "
        + "pauses within "
        + "a couple of seconds of leaving the app, and carries on when you come back. The screen stays on meanwhile.")

    /// The job's state in the person's words. `mode` is the USB mode the job was started in, named when the camera
    /// was disconnected (it has to come back in the same mode).
    public static func status(_ progress: ImportProgress, mode: USBMode? = nil) -> String {
        switch progress.state {
        case .idle:
            return AppText.string("Getting ready…")
        case .running:
            if progress.filesTotal == 0 { return AppText.string("Reading the card…") }
            return AppText.format("%@ of %@ done", String(progress.filesDone), ByteWording.files(progress.filesTotal))
        case let .paused(reason):
            return paused(reason, stallWaitsForPerson: progress.stallWaitsForPerson, mode: mode)
        case let .finished(outcome):
            return finished(outcome)
        }
    }

    /// A pause is normal, not a failure (decision 4). After a removal the camera has to come back in the job's USB
    /// mode (the catalogue keys a camera differently in each, and the camera asks for a mode at every plug-in), so the
    /// line names it when `mode` is given.
    public static func paused(_ reason: PauseReason, stallWaitsForPerson: Bool = false,
                              mode: USBMode? = nil) -> String {
        switch reason {
        case .appInBackground:
            AppText.string("Paused: open Shutter Bridge to continue.")
        case .cameraRemoved:
            if let mode {
                AppText.format("Paused: the camera was disconnected. Connect it again in %@ and the import carries "
                    + "on.", mode.cameraWording)
            } else {
                AppText.string("Paused: the camera was disconnected. Connect it again and the import carries on.")
            }
        case .stalled:
            stallWaitsForPerson
                ? AppText.string("Paused: the camera stopped sending. Check the cable and the camera, then tap "
                    + "Continue.")
                : AppText.string("The camera stopped sending, so the file is being copied again.")
        case .byPerson:
            AppText.string("Paused. Tap Continue to resume.")
        // Wi-Fi's reasons (W7, worded in W15): each says what to do next. The two the app lifts by itself on a
        // reconnect say so, the others have a Continue button.
        case .taskExpired:
            AppText.string("Paused while Shutter Bridge was in the background. Tap Continue to resume.")
        case .cardUnavailable:
            AppText.string("Paused: the camera isn't offering its card. Check that the card is in the camera; the "
                + "import resumes by itself.")
        case .cameraUnreachable:
            AppText.string("Paused: the camera can't be reached. Move closer and check its Wi-Fi is on; the import "
                + "resumes when it's "
                + "back in reach.")
        case .needsJoin:
            AppText.string("Paused: open Shutter Bridge to join the camera's Wi-Fi, then the import carries on.")
        }
    }

    public static func finished(_ outcome: JobOutcome) -> String {
        switch outcome {
        case .completed: AppText.string("Import finished.")
        case .cancelled: AppText.string("Import cancelled.")
        case let .stopped(kind): AppText.format("Import stopped: %@", stopReason(kind))
        case .catalogueUnavailable:
            AppText.string("Import stopped: Shutter Bridge couldn't read or update its catalogue of imported files, so "
                + "it stopped "
                + "rather than import files twice.")
        case let .photosAccessNeeded(authorisation): photosAccessNeeded(authorisation)
        }
    }

    /// A keepers job Photos refused (3311; backlog section 7.5): the rest stay in Staging, never staged again, and
    /// nothing is removed from Staging. A denial comes with Open Settings (`ImportModel.offersPhotosSettingsLink`); a
    /// restriction can't be changed there.
    public static func photosAccessNeeded(_ authorisation: PhotosAuthorisation) -> String {
        authorisation == .restricted
            ? AppText.string("Photos access needed: Photos is restricted on this iPhone, so the keepers not yet "
                + "imported stay in "
                + "Staging.")
            : AppText.string("Photos access needed: Photos access is off, so the keepers not yet imported stay in "
                + "Staging. Allow "
                + "access in Settings, then import the keepers again.")
    }

    static func stopReason(_ kind: CameraLinkFailure.Kind) -> String {
        switch kind {
        case .phoneStorageFull: AppText.string("this iPhone is out of space.")
        case .notAuthorised: AppText.string("Shutter Bridge isn't allowed to read from the camera.")
        case .modeListsNoFiles:
            AppText.format("the camera is in %@, which shares no files over USB.", USBMode.remoteShoot.cameraWording)
        case .disconnected: AppText.string("the camera was disconnected.")
        case .busy, .noAnswer: AppText.string("the camera stopped answering.")
        case .itemNotFound, .unreadableItem, .unsupportedFormat: AppText.string("the camera couldn't read its card.")
        case .refused: AppText.string("the camera refused the connection.")
        case .identityChanged: AppText.string("a different camera answered.")
        case .cardUnavailable: AppText.string("the camera stopped offering its card.")
        }
    }

    /// Files imported or staged so far: done, less skipped and failed.
    public static func importedCount(_ progress: ImportProgress) -> Int {
        max(0, progress.filesDone - progress.filesSkipped - progress.filesFailed)
    }

    /// How many rejected files the job left out (D3: `ImportProgress.rejectsLeftOut`), for the outcome: "3 rejected
    /// files left out. Pick them in Browse to import them anyway."; nil when none were.
    public static func rejectsLeftOut(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return AppText.counted(count, one: "%lld rejected file left out. Pick it in Browse to import it anyway.",
                               other: "%lld rejected files left out. Pick them in Browse to import them anyway.")
    }

    /// "38 files imported.", "38 files imported, 2 skipped, 1 failed.", "38 files staged." or, when Photos refused
    /// a save part-way, "10 files imported, 28 staged."
    public static func counts(_ progress: ImportProgress) -> String {
        let imported = progress.filesImported
        let staged = progress.filesStaged
        var line: String
        if staged == 0 {
            line = AppText.format("%@ imported", ByteWording.files(imported))
        } else if imported == 0 {
            line = AppText.format("%@ staged", ByteWording.files(staged))
        } else {
            line = AppText.format("%@ imported, %@ staged", ByteWording.files(imported), String(staged))
        }
        if progress.filesSkipped > 0 {
            line += ", " + AppText.counted(progress.filesSkipped, one: "%lld skipped", other: "%lld skipped")
        }
        if progress.filesFailed > 0 {
            line += ", " + AppText.counted(progress.filesFailed, one: "%lld failed", other: "%lld failed")
        }
        return line + "."
    }

    /// Photos an interrupted import may have saved twice (backlog section 3.1's fallback, I15: a pending commit not found
    /// under Limited Access, `ImportProgress.possibleDuplicates`): "1 photo from an interrupted import may now be in
    /// Photos twice."; nil for none.
    public static func possibleDuplicates(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return AppText.counted(count, one: "%lld photo from an interrupted import may now be in Photos twice.",
                               other: "%lld photos from an interrupted import may now be in Photos twice.")
    }

    /// Why files were left out for having no capture date (D10: skip them and say how many): "1 file was left out
    /// because it has no capture date, so Shutter Bridge can't tell whether it was imported before."; nil for none.
    public static func undatedLeftOut(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return AppText.counted(
            count,
            one: "%lld file was left out because it has no capture date, so Shutter Bridge can't tell whether it was "
                + "imported before.",
            other: "%lld files were left out because they have no capture date, so Shutter Bridge can't tell whether "
                + "they were imported before.")
    }

    /// Where the files go (backlog section 5, *It says so*): Photos, or the staging folder with the camera's folder
    /// ("Staging to iCloud Drive › Shutter Bridge › Staging › ILCE-7CM2."). `imported` is how many files the job has
    /// imported or staged (as `importedCount` works it out); a finished job that did neither has no destination line,
    /// rather than claim "Imported to Photos.".
    public static func destination(_ decision: DestinationDecision?, folder: String?, finished: Bool,
                                   imported: Int) -> String? {
        guard let decision, decision.kind != nil else { return nil }
        if finished && imported <= 0 { return nil }
        switch decision {
        case .photos, .askForPhotosAccess:
            return finished ? AppText.string("Imported to Photos.") : AppText.string("Importing to Photos.")
        case let .staging(_, place):
            let path = [place.folderPath, folder].compactMap { $0 }.joined(separator: " › ")
            return finished ? AppText.format("Staged in %@.", path) : AppText.format("Staging to %@.", path)
        }
    }

    /// Why the files are staged, and why on this iPhone when they are. Chosen: nothing goes to Photos (no button).
    /// Forced: Photos access is off (with the Settings button) or restricted (no button, the person can't change it
    /// there). It promises nothing about culling, which isn't built yet.
    public static func stagingReason(_ reason: StagingReason, place: StagingPlace) -> String {
        let why = switch reason {
        case .chosen:
            place == .iCloudDrive
                ? AppText.string("Not added to Photos. iCloud Drive uploads the files in the background.")
                : AppText.string("Not added to Photos.")
        case .photosDenied:
            AppText.string("Photos access is off, so photos are being staged instead. Allow access in Settings to "
                + "import to Photos "
                + "next time.")
        case .photosRestricted:
            AppText.string("Photos is restricted on this iPhone, by Screen Time or device management, so photos are "
                + "being staged "
                + "instead.")
        }
        guard let fallback = place.fallbackReason else { return why }
        return why + " " + stagingFallback(fallback)
    }

    /// Why the files are staged on this iPhone rather than in iCloud Drive.
    public static func stagingFallback(_ reason: StagingFallbackReason) -> String {
        switch reason {
        case .iCloudDriveOff:
            AppText.string("iCloud Drive is off or you're not signed in to iCloud, so they stay on this iPhone.")
        case .containerUnavailable:
            AppText.string("iCloud Drive isn't available to Shutter Bridge, so they stay on this iPhone.")
        case .lostDuringImport: AppText.string("iCloud Drive became unavailable, so the rest are staged on this iPhone.")
        }
    }

    // Rows.

    public static func row(_ phase: ImportFileStatus.Phase, item: CameraItem, going kind: DestinationKind?) -> String {
        switch phase {
        case .queued: AppText.string("Waiting")
        case .downloading: AppText.string("Copying from the camera")
        case .waitingToRetry: AppText.string("Trying again")
        // One word per idea (HIG Writing): "Saving to", then "Imported to", as the summary says.
        case .committing: kind == .staging ? AppText.string("Saving to Staging") : AppText.string("Saving to Photos")
        case let .imported(location):
            switch location {
            case .photosAsset?: AppText.string("Imported to Photos")
            case .file?: AppText.string("Imported to Files")
            case nil: AppText.string("Imported")
            }
        case let .staged(location):
            switch location?.root {
            case .iCloudDrive?: AppText.string("Staged in iCloud Drive")
            case .onThisIPhone?: AppText.string("Staged on this iPhone")
            case nil: AppText.string("Staged")
            }
        case let .skipped(reason): AppText.format("Skipped: %@", skipped(reason, item: item))
        case let .failed(reason): AppText.format("Failed: %@", failed(reason))
        case .notImported: AppText.string("Not imported: still on the card")
        }
    }

    static func skipped(_ reason: ImportSkipReason, item: CameraItem) -> String {
        switch reason {
        // The row says it plainly; the thumbnail's "Video: from 1.1" is Shamil's on-screen label (9 Nov).
        case .notAStill:
            item.format == .video ? AppText.string("videos can't be imported yet") : AppText.string("not a photo")
        case .noCaptureDate: AppText.string("no capture date")
        case .alreadyStaged: AppText.string("already staged")
        case let .link(kind):
            switch kind {
            case .itemNotFound: AppText.string("no longer on the card")
            case .unreadableItem: AppText.string("the camera couldn't read it")
            case .unsupportedFormat: AppText.string("this kind of file can't be imported")
            case .busy, .noAnswer, .disconnected, .phoneStorageFull, .notAuthorised, .modeListsNoFiles,
                 .identityChanged, .refused, .cardUnavailable:
                AppText.string("the camera couldn't send it")
            }
        }
    }

    static func failed(_ reason: ImportFailureReason) -> String {
        switch reason {
        case let .link(kind):
            switch kind {
            case .phoneStorageFull: AppText.string("this iPhone is out of space")
            case .unreadableItem: AppText.string("the camera couldn't read it")
            case .itemNotFound: AppText.string("no longer on the card")
            case .busy, .noAnswer, .disconnected, .notAuthorised, .modeListsNoFiles, .unsupportedFormat,
                 .identityChanged, .refused, .cardUnavailable:
                AppText.string("the camera couldn't send it")
            }
        case .sizeMismatch: AppText.string("the copy didn't match the size the camera gave")
        case let .destination(failure):
            switch failure {
            case .notEnoughSpace: AppText.string("this iPhone is out of space")
            case .stagedFileMissing: AppText.string("the copy went missing before it was saved")
            case .photosAccessDenied: AppText.string("Photos access is off")
            case .stagingUnavailable: AppText.string("iCloud Drive isn't available")
            case .rejected: AppText.string("it couldn't be saved")
            }
        }
    }

    /// "12.3 MB of 45.6 MB" while a file is copied, its size otherwise.
    public static func rowSize(_ status: ImportFileStatus) -> String {
        switch status.phase {
        case .downloading, .waitingToRetry:
            ByteWording.progress(status.bytesDone, of: status.item.size)
        case .queued:
            status.bytesDone > 0 ? ByteWording.progress(status.bytesDone, of: status.item.size)
                : ByteWording.size(status.item.size)
        case .committing, .imported, .staged, .skipped, .failed, .notImported:
            ByteWording.size(status.item.size)
        }
    }

    /// A row's VoiceOver label: name, state, size and how far along.
    public static func rowAccessibility(name: String, state: String, size: String, fraction: Double?) -> String {
        var parts = [name, state, size]
        if let fraction { parts.append(AppText.format("%@ percent", String(Int((fraction * 100).rounded(.down))))) }
        return parts.joined(separator: ", ")
    }
}


// MARK: - Wi-Fi cameras (wireless plan W15)
//
// Titles in title case, descriptions in sentence case, a next step in every failure, "Tap Continue to resume" for a
// pause the person lifts (the house style of the HIG pass, #94). The camera's own wording is used for its menus and
// settings; where the camera's wording isn't confirmed, a comment says `unverified`. No serial, network name or
// address is ever put in copy.

/// Pairing the camera over Bluetooth, the Wi-Fi onboarding (backlog Iteration 3, section 6).
public enum OnboardingWording {
    public static let title = AppText.string("Pair Your Camera")

    /// What the camera menu path and its two settings are. Both settings are named until it is known whether the
    /// hand-off needs *Bluetooth Rmt Ctrl* (backlog section 6: *Bluetooth Function* was on in every run, *Bluetooth
    /// Rmt Ctrl* in the runs that record their settings).
    ///
    /// `unverified`: the path is the one the spike's runs recorded; Shamil reads it off the camera before 1.0 (B:144).
    public static let cameraPath = AppText.string("MENU › Network › Bluetooth › Pairing")
    public static let settingsToCheck = AppText.string("Bluetooth Function and Bluetooth Rmt Ctrl")

    /// PLACEHOLDER, `unverified` (B:144): the words the camera shows when it asks to confirm the pairing, to be read off
    /// the camera by Shamil and put here word for word. Until then it is nil and the copy says only that the camera asks
    /// you to confirm: a quoted prompt the camera doesn't show would be worse than none. Whether either prompt shows a
    /// code to compare isn't recorded either.
    public static let cameraConfirmationWording: String? = nil

    public static let explainTitle = AppText.string("Pair Over Bluetooth")
    /// The steps, in order: the camera's Pairing screen, its two Bluetooth settings, and the two prompts that follow
    /// (iOS's Bluetooth pairing request first, then the camera's confirmation).
    public static let explainSteps: [String] = steps(cameraConfirmation: cameraConfirmationWording)

    /// The steps with the camera's confirmation quoted when its wording is known (`cameraConfirmationWording`).
    public static func steps(cameraConfirmation wording: String?) -> [String] {
        let cameraAsks = wording.map { AppText.format("the camera asks \u{2018}%@\u{2019}", $0) }
            ?? AppText.string("the camera asks you to confirm")
        return [
            AppText.format("On the camera, open %@ and leave that screen open.", cameraPath),
            AppText.format("Check that %@ are on.", settingsToCheck),
            AppText.format("Tap Start Pairing. Two prompts follow: first iOS asks to pair this iPhone with the camera "
                + "over Bluetooth, then %@. Accept both.", cameraAsks),
        ]
    }
    /// iOS asks for Bluetooth access at this step, with its own wording.
    public static let bluetoothPrompt = AppText.string("iOS also asks whether Shutter Bridge may use Bluetooth.")

    public static let start = AppText.string("Start Pairing")
    public static let cancel = AppText.string("Cancel")
    public static let tryAgain = AppText.string("Try Again")
    public static let done = AppText.string("Done")
    public static let openSettings = AppText.string("Open Settings")

    public static let waitingTitle = AppText.string("Waiting for You")
    public static let waitingDetail = AppText.string("Accept the pairing request on this iPhone, then confirm on the "
        + "camera. Keep the "
        + "camera's Pairing screen open. This can take about 15 seconds.")

    public static let pairedTitle = AppText.string("Camera Paired")
    public static let pairedDetail = AppText.string("Shutter Bridge can now switch on the camera's Wi-Fi and join it "
        + "for you.")
    public static let alreadyPairedTitle = AppText.string("Already Paired")
    public static let alreadyPairedDetail = AppText.string("This iPhone is already paired with the camera, so there "
        + "was nothing to "
        + "confirm. Shutter Bridge can switch on the camera's Wi-Fi and join it for you.")

    public static let notPairedTitle = AppText.string("Not Paired Yet")
    public static let notPairedDetail = AppText.format("The camera didn't accept the pairing. On the camera, open %@ "
        + "and leave that screen open, then tap Try Again.", cameraPath)

    public static let bluetoothOffTitle = AppText.string("Bluetooth Is Off")
    public static let bluetoothOffDetail = AppText.string("Turn on Bluetooth in Control Centre or Settings, then tap "
        + "Try Again.")
    public static let bluetoothNotAllowedTitle = AppText.string("Bluetooth Access Is Off")
    public static let bluetoothNotAllowedDetail = AppText.string("Allow Shutter Bridge to use Bluetooth in Settings, "
        + "then tap Try Again.")
    public static let droppedTitle = AppText.string("Connection Lost")
    /// The pairing check already tried a second connection (`PairingCheck`), so this is after two drops.
    public static let droppedDetail = AppText.format("The Bluetooth connection to the camera dropped twice. Open %@ on "
        + "the camera again and move closer, then tap Try Again.", cameraPath)
    public static let notFoundTitle = AppText.string("Couldn't Find the Camera")
    public static let notFoundDetail = AppText.string("Check that the camera is on and close to this iPhone with "
        + "Bluetooth Function on, "
        + "then tap Try Again.")
    public static let unsupportedTitle = AppText.string("Can't Pair With This Camera")
    public static let unsupportedDetail = AppText.string("The camera doesn't offer the Bluetooth service Shutter "
        + "Bridge needs. Check "
        + "that its firmware is up to date, or import over USB-C instead.")

    /// The title and detail for a pairing that couldn't finish for `failure` (never for a refusal: that is
    /// `notPairedTitle`).
    public static func unavailable(_ failure: GATTFailure) -> (title: String, detail: String) {
        switch failure {
        case .bluetoothOff: (bluetoothOffTitle, bluetoothOffDetail)
        case .unauthorised: (bluetoothNotAllowedTitle, bluetoothNotAllowedDetail)
        case .linkDropped: (droppedTitle, droppedDetail)
        case .serviceMissing: (unsupportedTitle, unsupportedDetail)
        case .notPaired: (notPairedTitle, notPairedDetail)
        case .wifiOff, .timedOut, .cancelled, .other: (notFoundTitle, notFoundDetail)
        }
    }
}

/// Typing the camera's address, for a camera on the same network as the phone (backlog Iteration 3, section 5).
public enum TypedAddressWording {
    public static let title = AppText.string("Camera Address")
    public static let explanation = AppText.string("Use this when the camera and this iPhone are on the same Wi-Fi "
        + "network. Find the "
        + "camera's IP address in its network settings and type it here.")
    public static let fieldLabel = AppText.string("Address")
    public static let fieldHint = AppText.string("Four numbers with dots, such as 10.0.0.12, or a name. Add :port only "
        + "if the camera "
        + "uses a port other than 15740.")
    public static let connect = AppText.string("Add Camera")
    public static let cancel = AppText.string("Cancel")

    /// Why the text can't be used, and what to type instead.
    public static func problem(_ problem: TypedAddressModel.Problem) -> String {
        switch problem {
        case .url: AppText.string("Leave out http:// and anything after the address.")
        case .ipv6: AppText.string("Use an IPv4 address (four numbers with dots) or a name. IPv6 isn't supported.")
        case .port: AppText.string("The port must be a number from 1 to 65535. Leave it out to use 15740.")
        case .numbers: AppText.string("An address has four numbers from 0 to 255 with dots between them, such as "
            + "10.0.0.12.")
        case .unusable: AppText.string("That address can't be a camera. Check the numbers, then try again.")
        case .name: AppText.string("A name can only have letters, numbers, hyphens and dots.")
        case .cameraNetwork:
            AppText.string("That is the camera's own network. Set the camera up with Bluetooth instead: Shutter Bridge "
                + "joins that "
                + "network for you.")
        case .other: AppText.string("That isn't an address Shutter Bridge can use. Check it, then try again.")
        }
    }
}

/// Connecting to a camera over Wi-Fi: the steps of the join and the stay, the Local Network prompt, and why a
/// connection failed (backlog Iteration 3, sections 1, 8 and 9).
public enum WiFiWording {
    // MARK: The Local Network prompt

    /// Before the first connection, so iOS's prompt isn't a surprise (backlog section 1, *Local Network permission*).
    public static let localNetworkTitle = AppText.string("Allow Local Network Access")
    public static let localNetworkDetail = AppText.string("To talk to the camera over Wi-Fi, iOS asks whether Shutter "
        + "Bridge may find "
        + "devices on your local network. Tap Allow. Without it the camera can't be reached over Wi-Fi.")
    public static let localNetworkContinue = AppText.string("Continue")
    public static let localNetworkNotNow = AppText.string("Not Now")
    /// While iOS's prompt is up.
    public static let waitingForLocalNetwork = AppText.string("Waiting for Local Network access. Tap Allow in the iOS "
        + "prompt.")
    /// When the prompt has been up a while, or never showed (it shows once; after Don't Allow it never comes back).
    public static let stillWaitingForLocalNetwork = AppText.string("Still waiting. If you didn't see a prompt, turn on "
        + "Local Network "
        + "for Shutter Bridge in Settings, then try again.")

    // MARK: Steps

    /// What the connection is doing, for the line under a camera's name. Nil when there is nothing to say (idle, and
    /// connected: the screen shows the card or the import).
    public static func step(_ phase: WirelessPhase) -> String? {
        switch phase {
        case .idle, .ready: nil
        case .handingOff: AppText.string("Switching on the camera's Wi-Fi…")
        case .joining: AppText.string("Joining the camera's Wi-Fi. Tap Join if iOS asks.")
        case .awaitingFront: AppText.string("Come back to Shutter Bridge to finish joining the camera's Wi-Fi.")
        case .openingSession: AppText.string("Opening the camera…")
        case .staying: stay
        case .leaving: AppText.string("Leaving the camera's Wi-Fi…")
        case let .paused(pause): paused(pause)
        }
    }

    /// While the phone stays on the camera's network after an import (decided 8 Nov: one 3-minute timer, from the end
    /// of the import, while the app is in front).
    public static let stay = AppText.string("Still joined to the camera's Wi-Fi, so a second import starts at once.")

    /// The camera's network takes the phone's internet while it is joined (backlog section 8, measured 2 Nov).
    public static let mobileDataNote = AppText.string("While this iPhone is joined to the camera's Wi-Fi, its internet "
        + "uses mobile data.")

    /// After leaving: 1.0 writes nothing to switch the camera's Wi-Fi off (backlog section 8; the camera's went off
    /// 51 to 53 s later in two runs and stayed on for the 59 s watched in a third).
    public static let wifiMayStayOn = AppText.string("The camera's Wi-Fi may stay on for a while. Switching the camera "
        + "off ends it.")

    // MARK: Waiting for the person

    /// A pause the connection can't lift by itself, with the next step (`WirelessPause`).
    public static func paused(_ pause: WirelessPause) -> String {
        switch pause {
        case .needsJoin: AppText.string("Open Shutter Bridge to join the camera's Wi-Fi.")
        case .notPaired:
            AppText.format("The camera isn't paired with this iPhone. Open %@ on the camera, then open the camera "
                + "here again.", OnboardingWording.cameraPath)
        case .bluetoothOff: AppText.string("Bluetooth is off. Turn it on to reach the camera, then open it again.")
        case .bluetoothNotAllowed:
            AppText.string("Bluetooth access is off for Shutter Bridge. Allow it in Settings, then open the camera "
                + "again.")
        case .joinDeclined:
            AppText.string("Shutter Bridge wasn't allowed to join the camera's Wi-Fi. Open the camera again and choose "
                + "Join when "
                + "iOS asks.")
        }
    }

    // MARK: Failures

    public static let failedTitle = AppText.string("Couldn't Connect to the Camera")

    /// A connection that ended because the join needed the app in front (`.paused(.needsJoin)` as an open failure; bench
    /// 19.1: the session holds the join while the app is away, then lets go). Worded for both places it shows: Browse's
    /// failed state, with Try Again, and the Import screen. Wording confirmed by Shamil (10 Nov).
    public static let needsAppToJoin = AppText.string("Shutter Bridge has to be open to join the camera's Wi-Fi. Try "
        + "again, and stay in "
        + "Shutter Bridge until iOS asks to join.")

    /// Why the connection failed, with a next step in every line; nil for a cancel the person asked for.
    public static func failure(_ failure: WirelessFailure) -> String? {
        switch failure {
        case .paused(.needsJoin):
            return needsAppToJoin
        case let .paused(pause):
            return paused(pause)
        case .cameraNotFound:
            return AppText.string("Shutter Bridge couldn't find the camera. Check that it is on and close to this "
                + "iPhone with "
                + "Bluetooth on, then try again.")
        case let .bluetooth(gatt):
            switch gatt {
            case .bluetoothOff: return paused(.bluetoothOff)
            case .unauthorised: return paused(.bluetoothNotAllowed)
            case .notPaired: return paused(.notPaired)
            case .serviceMissing:
                return AppText.string("The camera doesn't offer the Bluetooth service Shutter Bridge needs. Import "
                    + "over USB-C "
                    + "instead.")
            case .cancelled: return nil
            case .wifiOff, .linkDropped, .timedOut, .other:
                return AppText.string("The Bluetooth connection to the camera failed. Move closer to the camera, then "
                    + "try again.")
            }
        case let .handoff(handoff):
            // The join's first hand-off, which failed with the app in front (one that overlapped time away is run again
            // from the front by the session, and a lapse while away pauses with `.needsJoin`).
            switch handoff {
            case .notPaired: return paused(.notPaired)
            case .cancelled: return nil
            case .gatt, .linkDropped, .statusUnreadable, .unexpectedStatus, .wifiDidNotStart, .timedOut, .wifiLapsed,
                 .credentialsInvalid:
                return AppText.string("The camera didn't switch its Wi-Fi on. Check that it is on with Bluetooth "
                    + "Function on, then "
                    + "try again.")
            }
        case let .rewriteFailed(handoff):
            // Switching the camera's Wi-Fi on again after it lapsed before iOS joined it.
            switch handoff {
            case .notPaired: return paused(.notPaired)
            case .cancelled: return nil
            case .gatt, .linkDropped, .statusUnreadable, .unexpectedStatus, .wifiDidNotStart, .timedOut, .wifiLapsed,
                 .credentialsInvalid:
                return AppText.string("The camera's Wi-Fi switched itself off before iOS joined it. Try again, and tap "
                    + "Join as soon "
                    + "as iOS asks.")
            }
        case let .join(join):
            switch join {
            case .userDenied: return paused(.joinDeclined)
            case .notInForeground: return needsAppToJoin
            case .cancelled: return nil
            case .invalidCredentials:
                return AppText.string("iOS couldn't use the camera's network details. Try again; if it keeps "
                    + "happening, "
                    + "switch the camera off and on.")
            case .pending, .systemConfiguration, .other:
                return AppText.string("iOS couldn't join the camera's Wi-Fi. Move closer to the camera, then try again.")
            }
        case .noGateway:
            return AppText.string("The camera's Wi-Fi didn't answer after joining. Move closer to the camera, then try "
                + "again.")
        case .cameraWiFiLapsed:
            return AppText.string("The camera's Wi-Fi switched itself off while joining. Try again, and tap Join as "
                + "soon as iOS "
                + "asks.")
        case let .link(link):
            return listingFailed(link.kind)
        case .cancelled:
            return nil
        }
    }

    /// `BrowseWording.listingFailed(_:)` for a Wi-Fi camera: the same, except where it mentions the cable.
    public static func listingFailed(_ kind: CameraLinkFailure.Kind) -> String {
        switch kind {
        case .busy, .noAnswer:
            AppText.string("The camera didn't answer. Check that it is on and its Wi-Fi is on, then try again.")
        default:
            BrowseWording.listingFailed(kind)
        }
    }
}

// MARK: - Wireless screens (W16)
//
// The copy the wireless screens add over the W15 models: the Cameras screen's way in to Wi-Fi, the Import screen's Try
// Again for a Wi-Fi job that needs the person, and the Settings row for the reminder. Same house style as above.

extension CamerasWording {
    /// The toolbar menu that sets a Wi-Fi camera up, and its two choices.
    public static let addWiFiCamera = AppText.string("Add Wi-Fi Camera")
    public static let addWiFiCameraHint = AppText.string("Pair a camera over Bluetooth, or add one on this iPhone's "
        + "Wi-Fi network by "
        + "its address.")
    /// The menu's hint when the app can't pair (no Bluetooth pairing in this build): Type an Address is the only choice.
    public static let addWiFiCameraByAddressHint = AppText.string("Add a camera on this iPhone's Wi-Fi network by its "
        + "address.")
    public static let pairOverBluetooth = AppText.string("Pair Over Bluetooth")
    public static let typeAddress = AppText.string("Type an Address")

    /// The badge on a camera's row when the proximity scan has reported it lately (`ReminderModel.isNearby(_:)`).
    public static let nearbyBadge = AppText.string("Nearby")

    /// The line under a camera's name. A USB camera's mode in the camera's wording (`modeLine(_:)`); a Wi-Fi camera's
    /// route, as its badge already says Wi-Fi.
    public static func detailLine(_ mode: CameraMode) -> String {
        switch mode {
        case .usb: modeLine(mode)
        case .wifi(.cameraNetwork): AppText.string("Joins the camera's Wi-Fi when opened")
        case .wifi(.otherNetwork): AppText.string("On this iPhone's Wi-Fi network")
        case .staging: AppText.string("Staged files on this iPhone or in iCloud Drive")
        }
    }

    /// A camera row's VoiceOver hint: what opening it does. A Wi-Fi camera is joined first, which takes a while.
    public static func rowHint(_ mode: CameraMode) -> String {
        switch mode {
        case .usb: AppText.string("Opens the camera's card.")
        case .wifi(.cameraNetwork): AppText.string("Switches on the camera's Wi-Fi, joins it and opens the camera's "
            + "card.")
        case .wifi(.otherNetwork): AppText.string("Connects to the camera and opens its card.")
        case .staging: AppText.string("Opens the staged files.")
        }
    }

    /// Under the empty state, when the app can set up a Wi-Fi camera.
    public static let wifiEmptyHint = AppText.string("Or set up a camera over Wi-Fi.")

    /// Said once a camera has been added, by pairing or by address.
    public static func added(_ camera: CameraDescriptor) -> String {
        let name = displayName(for: camera)
        return name == genericName ? AppText.string("Camera added. Tap it to open its card.")
            : AppText.format("%@ added. Tap it to open its card.", name)
    }
}

extension ImportWording {
    /// A Wi-Fi job paused for a join with the app in front: the session couldn't join from where it was, so the person
    /// tries again (W14's `.needsJoin`, which with the app away says "open Shutter Bridge").
    public static let needsJoinInFront = AppText.string("Paused: Shutter Bridge couldn't join the camera's Wi-Fi. Tap "
        + "Try Again, then "
        + "tap Join if iOS asks.")
    /// The button that runs the Wi-Fi recovery again (`ImportModel.tryAgainWiFi()`).
    public static let tryAgain = AppText.string("Try Again")
    public static let tryAgainHint = AppText.string("Switches on the camera's Wi-Fi over Bluetooth if needed, joins it "
        + "and carries on "
        + "with the import.")
    /// While the recovery reaches the camera again by itself, for a job paused for a join (whose own line, with the app
    /// away, says to open Shutter Bridge).
    public static let reconnecting = AppText.string("Reaching the camera again…")

    /// A Wi-Fi job paused for its camera, its card or a join once the recovery has given up or waits for the person, in
    /// front: only Try Again carries it on now, so the line ends with it rather than "resumes by itself".
    public static func pausedTryAgain(_ reason: PauseReason) -> String {
        switch reason {
        case .needsJoin: needsJoinInFront
        case .cameraUnreachable:
            AppText.string("Paused: the camera can't be reached. Move closer and check its Wi-Fi is on, then tap Try "
                + "Again.")
        case .cardUnavailable:
            AppText.string("Paused: the camera isn't offering its card. Check that the card is in the camera, then tap "
                + "Try Again.")
        case .appInBackground, .cameraRemoved, .stalled, .byPerson, .taskExpired: paused(reason)
        }
    }
    /// The Wi-Fi section's header on the Import screen.
    public static let wifiHeader = AppText.string("Wi-Fi")
}

extension WiFiWording {
    /// The countdown's label while the phone stays on the camera's network after an import.
    public static let stayCountdownPrefix = AppText.string("Leaves the camera's Wi-Fi in")
    /// The close button on the notes, for VoiceOver.
    public static let dismissNotes = AppText.string("Close")
    public static let dismissNotesHint = AppText.string("Hides these notes.")
    public static let localNetworkContinueHint = AppText.string("Shows iOS's Local Network prompt next.")
    public static let localNetworkNotNowHint = AppText.string("Doesn't connect to the camera now.")

    /// The join's line on the screens, which show only with the app in front (`WiFiImportModel.activityLine`): a pause
    /// for a join says nothing (the Import summary says to tap Try Again, and a connection from Browse says why it failed
    /// in Browse), a declined join says to try again rather than to open the camera, and the others are as in `step(_:)`.
    public static func stepInFront(_ phase: WirelessPhase) -> String? {
        switch phase {
        case .paused(.needsJoin): nil
        case .paused(.joinDeclined):
            AppText.string("Shutter Bridge wasn't allowed to join the camera's Wi-Fi. Try again, and choose Join when "
                + "iOS asks.")
        default: step(phase)
        }
    }
}

extension SettingsWording {
    /// The row that opens the reminder's settings (`ReminderSettingsView`), with whether it is on.
    public static func remindersValue(on: Bool) -> String { on ? AppText.string("On") : AppText.string("Off") }
    public static let remindersHint = AppText.string("Opens the settings for the reminder when your camera is nearby.")
}

extension OnboardingWording {
    public static let startHint = AppText.string("Starts looking for the camera over Bluetooth.")
    public static let cancelHint = AppText.string("Stops pairing and goes back to the steps.")
    public static let tryAgainHint = AppText.string("Looks for the camera over Bluetooth again.")
    public static let openSettingsHint = AppText.string("Opens Shutter Bridge's page in Settings.")
    public static let doneHint = AppText.string("Closes pairing. The camera is in the list.")

    /// A numbered step as VoiceOver reads it: "Step 1 of 3. On the camera, open …".
    public static func stepLabel(_ number: Int, of count: Int, _ step: String) -> String {
        AppText.format("Step %@ of %@. %@", String(number), String(count), step)
    }
}

extension TypedAddressWording {
    /// The field's placeholder: an example of the usual kind of address.
    public static let fieldPrompt = "10.0.0.12"
    public static let connectHint = AppText.string("Adds the camera to the list. Tap it there to connect.")
}
