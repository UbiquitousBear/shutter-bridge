import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge

// The app's copy (backlog section 6), in British English and in the camera's own wording for its modes. No maker's
// marks: "works with" wording only. Numbers are the bench's measurements, never promises. Sizes and times go through
// the system's formatters for the person's region (`ByteWording`); the rest are plain strings until the String
// Catalog arrives.

/// The Cameras screen.
public enum CamerasWording {
    public static let title = "Cameras"
    public static let usbBadge = "USB-C"
    /// The toolbar button that opens Settings.
    public static let settingsButton = "Settings"

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

    /// When discovery couldn't start for a reason other than access (`CamerasModel.Access.failed`): the camera would
    /// never appear, so the screen says so with Try Again rather than show "No Camera Connected".
    public static let discoveryFailedTitle = "Can't Look for Cameras"
    public static let discoveryFailedDetail = "Shutter Bridge couldn't start looking for a camera on the USB-C port. "
        + "Tap Try Again."

    /// When ImageCaptureCore's access is denied or restricted (`USBCameraBrowser.start()` throws `notAuthorised`).
    /// `unverified`: which Settings switch governs it. ImageCaptureCore reuses the camera privacy string, and iOS 27.2
    /// never asked on the bench, so the copy names the Camera setting and allows for a restriction.
    public static let notAllowedTitle = "Camera Access Is Off"
    public static let notAllowedDetail = "Shutter Bridge isn't allowed to read from a connected camera. Check "
        + "Shutter Bridge's Camera setting in Settings. If Screen Time or a profile restricts it on this iPhone, it "
        + "can't be changed here."
    public static let openSettings = "Open Settings"

    /// What the app calls a camera whose own name isn't known: in Image Transfer (MSC) discovery gives the card's
    /// volume name, not the camera's.
    public static let genericName = "Camera"

    /// Volume names a card is given when nobody named it, compared ignoring case (the α7C II's card is "Untitled";
    /// FAT cards formatted elsewhere read "NO NAME").
    static let volumeDefaultNames: Set<String> = ["untitled", "no name"]

    /// The one name the app shows and files under for a camera: the Browse title, the Cameras row, the disconnect
    /// message, and the album and Files folder made for a new import. In Image Transfer (MSC) ImageCaptureCore names
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
        let subject = name == genericName ? "The camera" : name
        return "\(subject) was disconnected. Connect it again to see its card."
    }
}

/// The Browse screen.
public enum BrowseWording {
    // Titles are in title case, as system empty states are ("No Results"); descriptions in sentence case (HIG
    // Writing).
    public static let readingTitle = "Reading the Card"

    /// What to expect while ImageCaptureCore reads the card, from the bench's measurements (decision 7). The times
    /// were measured on cards of 391–549 (MSC) and 391–825 (MTP) files; the copy keeps the times only (HIG Writing).
    public static func readingDetail(_ mode: CameraMode) -> String {
        switch mode {
        case .usb(.massStorage):
            "In \(USBMode.massStorage.cameraWording) this takes about 7–12 seconds."
        case .usb(.mtp), .usb(.remoteShoot):
            "In \(USBMode.mtp.cameraWording) it takes longer, about 65–123 seconds, and the photos all appear at the "
                + "end. \(USBMode.massStorage.cameraWording) reads the card much sooner."
        case .wifi:
            "This can take a while on a full card."
        }
    }

    /// After the time the card has been read for, which the screen shows as a system timer ("0:12 so far",
    /// `Text(timerInterval:)`), so it counts in the person's own notation.
    public static let elapsedSuffix = "so far"

    /// The catalogue completed at once with no files: Remote Shoot (PC Remote), or an empty card in MTP, which looks
    /// the same, so the copy doesn't claim either (`USBModeClassifier`).
    public static let noFilesTitle = "No Files over USB"
    /// Short, as it is also the one-line failure of *Copy as JPEG* (HIG Writing: lead with what matters). The modes
    /// in detail are behind the Cameras empty state's *Which USB Mode?*.
    public static let noFilesDetail = "The camera is sharing no files over USB. Reconnect it and choose "
        + "\(USBMode.massStorage.cameraWording) or \(USBMode.mtp.cameraWording)."

    public static let emptyCardTitle = "No Photos on the Card"
    public static let emptyCardDetail = "There are no files on the card."

    public static let goneTitle = "Camera Disconnected"
    public static let goneDetail = "Connect the camera again to see its card."

    public static let listingFailedTitle = "Couldn't Read the Card"
    public static let tryAgain = "Try Again"
    public static let undatedHeader = "No Date"

    /// On a greyed-out video (Shamil, 8 Nov).
    public static let videoLabel = "Video: from 1.1"
    /// On anything else that isn't a still, greyed out too.
    public static let otherLabel = "Not a photo"

    /// The close button on a message strip (iOS calls this control Close).
    public static let close = "Close"

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
        case .cardUnavailable:
            "The camera isn't offering its card right now. Check that the card is in the camera, then try again."
        case .refused:
            "The camera refused the connection. Check its network settings, then try again."
        case .identityChanged:
            "This isn't the camera that was connected before. Connect to the same camera, then try again."
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
            case .disconnected: "The camera was disconnected. Connect it again, then try again."
            case .busy, .noAnswer: "The camera didn't answer. Try again."
            case .itemNotFound: "This file is no longer on the card. Go back to Cameras and open the camera again."
            case .unreadableItem: "The camera couldn't read this file. Check the card in the camera, then try again."
            case .unsupportedFormat: "This file can't be made into a JPEG. Import it to keep the original."
            case .phoneStorageFull: "This iPhone is out of space. Free some space, then try again."
            case .notAuthorised: CamerasWording.notAllowedDetail
            case .modeListsNoFiles: BrowseWording.noFilesDetail
            case .cardUnavailable: "The camera isn't offering its card right now. Try again in a moment."
            case .refused: "The camera refused the connection. Close any other app connected to it, then try again."
            case .identityChanged: "This isn't the camera that was connected before. Connect that camera again, then try again."
            }
        case .conversion:
            "This photo couldn't be made into a JPEG on this iPhone. Import it to keep the original."
        case .storage:
            "The JPEG couldn't be prepared. Check that this iPhone has free space, then try again."
        case .clipboard:
            "The JPEG couldn't be copied. Try again, or use Share as JPEG."
        case .shareUnavailable:
            "The share sheet couldn't be shown. Try again."
        }
    }
}

/// Sizes, rates and times through the system's formatters (HIG Writing; Apple's localisation guidance), so the
/// decimal separator, the units and their spacing follow the person's region, as everywhere else in iOS. Sizes are
/// the file style's decimal units (1 MB = 10^6 bytes), as the bench measured them. `locale` is for tests; the app
/// passes nothing. Counted words ("1 file", "3 files") stay plain until the String Catalog's plural variants.
public enum ByteWording {
    /// "512 bytes", "640 kB", "42.3 MB", "1.24 GB" (in en-GB; "42,3 MB" in de-DE). Zero is "0 bytes"-style digits, not
    /// "Zero KB".
    public static func size(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    /// "1.2 GB of 4.5 GB".
    public static func progress(_ done: UInt64, of total: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        "\(size(done, locale: locale)) of \(size(total, locale: locale))"
    }

    /// "41.8 MB/s": the size the bench measures each second, with "/s" as the system writes data rates.
    public static func rate(megabytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\(size(bytesPerSecond(megabytesPerSecond), locale: locale))/s"
    }

    /// The rate as VoiceOver says it: "41.8 MB per second", so "/s" isn't read as a letter.
    public static func rateSpoken(megabytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\(size(bytesPerSecond(megabytesPerSecond), locale: locale)) per second"
    }

    /// "About 40 secs left", "About 3 min left", "About 1 hr, 5 min left" (abbreviated units, as the system writes
    /// them). Rounded up, so it never reads 0: to the second under a minute, then to the minute.
    public static func timeLeft(_ duration: Duration, locale: Locale = .autoupdatingCurrent) -> String {
        "About \(roundedTimeLeft(duration).formatted(timeLeftStyle(.abbreviated, locale: locale))) left"
    }

    /// The same as VoiceOver says it, in whole words: "About 3 minutes left".
    public static func timeLeftSpoken(_ duration: Duration, locale: Locale = .autoupdatingCurrent) -> String {
        "About \(roundedTimeLeft(duration).formatted(timeLeftStyle(.wide, locale: locale))) left"
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
    public static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
}

/// Browse beyond the thin slice: selection, the sticky bar, filters, the already-imported badge and the last-known
/// card (backlog section 6, *Browse* and *Browse, while the card is read*).
extension BrowseWording {
    public static let select = "Select"
    public static let doneSelecting = "Done"
    public static let selectAllNew = "Select All New"
    public static let deselectAll = "Deselect All"
    public static let importAction = "Import"
    public static let importedBadge = "Imported"
    public static let new = "New"

    /// The title while selecting, as Photos and Files report the selection: "Select Items", then "3 Selected".
    public static func selectingTitle(_ summary: SelectionSummary) -> String {
        summary.count == 0 ? selectItems : "\(summary.count) Selected"
    }

    public static let selectItems = "Select Items"

    /// The bottom bar's status while selecting: "3 files · 142.5 MB".
    public static func selectionSummary(_ summary: SelectionSummary) -> String {
        summary.count == 0 ? noSelection : "\(ByteWording.files(summary.count)) · \(ByteWording.size(summary.bytes))"
    }

    public static let noSelection = "No files selected"

    /// Why a file can't be selected, as a sentence. The cell's VoiceOver value says it, not a hint (people can turn
    /// hints off, and they are read last); `cellAccessibilityValue(_:)` leaves out what the label already says.
    public static func notSelectable(_ reason: BrowseModel.SelectionBlock) -> String {
        switch reason {
        case .video: videosNotYet
        case .notAPhoto: "This kind of file can't be imported."
        case .imported: "Already imported."
        case .noCaptureDate: "No capture date, so it can't be imported yet."
        case .cardNotRead: "Wait until the card has been read."
        }
    }

    /// What VoiceOver hears for a video, in place of the on-screen "Video: from 1.1" (Shamil, 9 Nov).
    public static let videosNotYet = "Videos can't be imported yet."

    // Filters.
    public static let filters = "Filters"
    public static let newOnly = "New Only"
    public static let type = "Type"
    public static let dateRange = "Date"
    public static let anyDate = "Any Date"
    public static let from = "From"
    public static let to = "To"
    public static let clearFilters = "Clear Filters"
    public static let noMatchesTitle = "No Matching Files"
    public static let noMatchesDetail = "No files on the card match these filters."
    /// The Filters button's VoiceOver value, so hidden files aren't taken for missing ones.
    public static let filtersOn = "On"
    public static let filtersOff = "Off"

    public static func filtersValue(isActive: Bool) -> String { isActive ? filtersOn : filtersOff }

    public static func typeLabel(_ type: BrowseFileType) -> String {
        switch type {
        case .raw: "RAW"
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        case .video: "Video"
        case .other: "Other"
        }
    }

    /// While ImageCaptureCore reads the card, the catalogue's last listing shows at once (decision 7), with one
    /// line above the grid: "Showing the card as it was on 8 Nov 2026 at 14:05." `date` is when it was listed
    /// (`BrowseModel.lastKnownListedAt`), formatted by the screen for the locale.
    public static func lastKnownLine(_ date: String) -> String { "Showing the card as it was on \(date)." }

    /// The bar's subtitle while the last-known card is shown and the live one is read.
    public static let readingSubtitle = "Reading the card…"

    /// The button by the last-known line that shows the measured reading times (backlog section 6).
    public static let readingTimesButton = "Reading Times"

    /// The date filter's switch, and what it says when no file on the card has a capture date.
    public static let limitDates = "Only These Dates"
    public static let noDatedFiles = "No file on the card has a capture date."
    /// The import status strip's VoiceOver hint (on Cameras and Browse); tapping it opens the Import screen. A hint
    /// describes the result (HIG Accessibility).
    public static let importStripHint = "Opens the import."

    /// The grid cell's VoiceOver label: name, date, type and, for a still, Imported or New. Selection is the
    /// `.isSelected` trait, not words, so it isn't said twice. `date` is formatted by the screen for the locale; nil
    /// for a file without one.
    public static func cellAccessibility(name: String, date: String?, kind: CardCellKind, isImported: Bool) -> String {
        var parts = [name]
        parts.append(date ?? undatedHeader)
        switch kind {
        case let .photo(badge): parts.append(badge ?? "JPEG")
        case .video: parts.append(typeLabel(.video))
        case .other: parts.append(otherLabel)
        }
        if kind.offersJPEGActions { parts.append(isImported ? importedBadge : new) }
        return parts.joined(separator: ", ")
    }

    /// The grid cell's VoiceOver value: why it can't be selected, unless the label says so already (Imported, Not a
    /// photo); nil when it can be.
    public static func cellAccessibilityValue(_ block: BrowseModel.SelectionBlock?) -> String? {
        switch block {
        case nil, .imported?, .notAPhoto?: nil
        case let block?: notSelectable(block)
        }
    }

    /// After Import is tapped in Browse.
    public static func importRequested(_ outcome: ImportRequestOutcome) -> String? {
        switch outcome {
        case let .started(n): "Importing \(ByteWording.files(n))."
        case let .appended(n): "Added \(ByteWording.files(n)) to the import."
        case .nothingNew: "These files are already imported or in the import."
        case .busyWithAnotherCamera:
            "Another camera's import is still running. Let it finish, or cancel it, then import from this camera."
        case .stillStarting: "The import is starting. Try again in a moment."
        case let .failed(message): message
        }
    }
}

/// The Settings screen (backlog section 6, *Settings, destination*; decision 9, 8 Nov).
public enum SettingsWording {
    public static let title = "Settings"
    public static let destinationHeader = "Import To"

    public static func destinationLabel(_ kind: DestinationKind) -> String {
        switch kind {
        case .photos: "Photos"
        case .filesFolder: "Files"
        }
    }

    /// Under the control: where files go in Files, and when a change applies. What Photos access does to the
    /// setting is said in its own row when it applies (`forcedFiles(_:)`).
    public static let destinationFooter = "In Files, imports are in On My iPhone › Shutter Bridge, in a folder for "
        + "each camera. The next import follows this setting."

    /// What the app will do when Photos access overrides the setting (HIG Settings: show what will happen); nil when
    /// it doesn't. A denial comes with Open Settings; a restriction can't be changed there.
    public static func forcedFiles(_ reason: FilesReason) -> String? {
        switch reason {
        case .chosen: nil
        case .photosDenied: "Photos access is off, so imports go to Files."
        case .photosRestricted: "Photos is restricted on this iPhone, so imports go to Files."
        }
    }

}

/// The Import screen (backlog section 6, *Import*; decisions 1, 4 and 9).
public enum ImportWording {
    public static let title = "Import"
    public static let pause = "Pause"
    public static let resume = "Continue"
    public static let cancel = "Cancel Import"
    public static let openSettings = "Open Settings"
    public static let askingForPhotos = "Waiting for your answer about Photos access…"
    public static let couldNotStart = "The import couldn't start. Check the camera is still connected, then try again."
    public static let couldNotAdd = "These files couldn't be added to the import. Try again."
    public static let filesHeader = "In This Import"
    public static let noJobTitle = "Nothing to Import"
    public static let noJobDetail = "Select photos on a camera's card and tap Import."
    public static let cancelConfirmTitle = "Cancel this import?"
    public static let cancelConfirmDetail = "Files already imported are kept. The rest stay on the card."
    public static let keepImporting = "Keep Importing"

    /// The ask to keep the app in front, and why the screen stays on (decision 1: the import asks to stay in front
    /// and keeps the screen on): a wired import stopped within about 2 s of the app leaving the foreground on the
    /// bench (2 Nov); the app pauses the job then and carries on when it is back.
    public static let screenOnNote = "Keep Shutter Bridge open while it imports over USB: the import pauses within "
        + "a couple of seconds of leaving the app, and carries on when you come back. The screen stays on meanwhile."

    /// The job's state in the person's words. `mode` is the USB mode the job was started in, named when the camera
    /// was disconnected (it has to come back in the same mode).
    public static func status(_ progress: ImportProgress, mode: USBMode? = nil) -> String {
        switch progress.state {
        case .idle:
            return "Getting ready…"
        case .running:
            if progress.filesTotal == 0 { return "Reading the card…" }
            return "\(progress.filesDone) of \(ByteWording.files(progress.filesTotal)) done"
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
            "Paused: open Shutter Bridge to continue."
        case .cameraRemoved:
            if let mode {
                "Paused: the camera was disconnected. Connect it again in \(mode.cameraWording) and the import "
                    + "carries on."
            } else {
                "Paused: the camera was disconnected. Connect it again and the import carries on."
            }
        case .stalled:
            stallWaitsForPerson
                ? "Paused: the camera stopped sending. Check the cable and the camera, then tap Continue."
                : "The camera stopped sending, so the file is being copied again."
        case .byPerson:
            "Paused. Tap Continue to resume."
        // Wi-Fi's reasons (W7). Placeholder copy until the wireless screens (W15) word them.
        case .taskExpired:
            "Paused while Shutter Bridge was in the background. Tap Continue to resume."
        case .cardUnavailable:
            "Paused: the camera isn't offering its card. The import resumes when the card is back."
        case .cameraUnreachable:
            "Paused: the camera can't be reached. The import resumes when it's back in reach."
        case .needsJoin:
            "Paused: open Shutter Bridge to join the camera's network and resume."
        }
    }

    public static func finished(_ outcome: JobOutcome) -> String {
        switch outcome {
        case .completed: "Import finished."
        case .cancelled: "Import cancelled."
        case let .stopped(kind): "Import stopped: \(stopReason(kind))"
        case .catalogueUnavailable:
            "Import stopped: Shutter Bridge couldn't read or update its catalogue of imported files, so it stopped "
                + "rather than import files twice."
        }
    }

    static func stopReason(_ kind: CameraLinkFailure.Kind) -> String {
        switch kind {
        case .phoneStorageFull: "this iPhone is out of space."
        case .notAuthorised: "Shutter Bridge isn't allowed to read from the camera."
        case .modeListsNoFiles: "the camera is in \(USBMode.remoteShoot.cameraWording), which shares no files over USB."
        case .disconnected: "the camera was disconnected."
        case .busy, .noAnswer: "the camera stopped answering."
        case .itemNotFound, .unreadableItem, .unsupportedFormat: "the camera couldn't read its card."
        case .refused: "the camera refused the connection."
        case .identityChanged: "a different camera answered."
        case .cardUnavailable: "the camera stopped offering its card."
        }
    }

    /// Files imported so far: done, less skipped and failed.
    public static func importedCount(_ progress: ImportProgress) -> Int {
        max(0, progress.filesDone - progress.filesSkipped - progress.filesFailed)
    }

    /// "38 files imported." or "38 files imported, 2 skipped, 1 failed."
    public static func counts(_ progress: ImportProgress) -> String {
        let imported = importedCount(progress)
        var line = "\(ByteWording.files(imported)) imported"
        if progress.filesSkipped > 0 { line += ", \(progress.filesSkipped) skipped" }
        if progress.filesFailed > 0 { line += ", \(progress.filesFailed) failed" }
        return line + "."
    }

    /// Where the files go, named from the first file (backlog section 5, *It says so*): Photos, or Files with the
    /// folder. `imported` is how many files the job has imported (as `counts` works it out); a finished job that
    /// imported none has no destination line, rather than claim "Imported to Photos.".
    public static func destination(_ decision: DestinationDecision?, folder: String?, finished: Bool,
                                   imported: Int) -> String? {
        guard let kind = decision?.kind else { return nil }
        if finished && imported <= 0 { return nil }
        let verb = finished ? "Imported to" : "Importing to"
        switch kind {
        case .photos:
            return "\(verb) Photos."
        case .filesFolder:
            let path = ["On My iPhone", "Shutter Bridge", folder].compactMap { $0 }.joined(separator: " › ")
            return "\(verb) Files: \(path)."
        }
    }

    /// Why the files go to Files. Forced: Photos access is off (with the Settings button) or restricted (no button,
    /// the person can't change it there). Chosen: it says so, with no button.
    public static func filesReason(_ reason: FilesReason) -> String {
        switch reason {
        case .chosen:
            "You chose Files in Settings."
        case .photosDenied:
            "Photos access is off, so photos are going to Files. Allow access in Settings to import to Photos next "
                + "time."
        case .photosRestricted:
            "Photos is restricted on this iPhone, by Screen Time or device management, so photos are going to Files."
        }
    }

    // Rows.

    public static func row(_ phase: ImportFileStatus.Phase, item: CameraItem, going kind: DestinationKind?) -> String {
        switch phase {
        case .queued: "Waiting"
        case .downloading: "Copying from the camera"
        case .waitingToRetry: "Trying again"
        // One word per idea (HIG Writing): "Saving to", then "Imported to", as the summary says.
        case .committing: kind == .filesFolder ? "Saving to Files" : "Saving to Photos"
        case let .imported(location):
            switch location {
            case .photosAsset?: "Imported to Photos"
            case .file?: "Imported to Files"
            case nil: "Imported"
            }
        case let .skipped(reason): "Skipped: \(skipped(reason, item: item))"
        case let .failed(reason): "Failed: \(failed(reason))"
        case .notImported: "Not imported: still on the card"
        }
    }

    static func skipped(_ reason: ImportSkipReason, item: CameraItem) -> String {
        switch reason {
        // The row says it plainly; the thumbnail's "Video: from 1.1" is Shamil's on-screen label (9 Nov).
        case .notAStill: item.format == .video ? "videos can't be imported yet" : "not a photo"
        case .noCaptureDate: "no capture date"
        case let .link(kind):
            switch kind {
            case .itemNotFound: "no longer on the card"
            case .unreadableItem: "the camera couldn't read it"
            case .unsupportedFormat: "this kind of file can't be imported"
            case .busy, .noAnswer, .disconnected, .phoneStorageFull, .notAuthorised, .modeListsNoFiles,
                 .identityChanged, .refused, .cardUnavailable:
                "the camera couldn't send it"
            }
        }
    }

    static func failed(_ reason: ImportFailureReason) -> String {
        switch reason {
        case let .link(kind):
            switch kind {
            case .phoneStorageFull: "this iPhone is out of space"
            case .unreadableItem: "the camera couldn't read it"
            case .itemNotFound: "no longer on the card"
            case .busy, .noAnswer, .disconnected, .notAuthorised, .modeListsNoFiles, .unsupportedFormat,
                 .identityChanged, .refused, .cardUnavailable:
                "the camera couldn't send it"
            }
        case .sizeMismatch: "the copy didn't match the size the camera gave"
        case let .destination(failure):
            switch failure {
            case .notEnoughSpace: "this iPhone is out of space"
            case .stagedFileMissing: "the copy went missing before it was saved"
            case .photosAccessDenied: "Photos access is off"
            case .rejected: "it couldn't be saved"
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
        case .committing, .imported, .skipped, .failed, .notImported:
            ByteWording.size(status.item.size)
        }
    }

    /// A row's VoiceOver label: name, state, size and how far along.
    public static func rowAccessibility(name: String, state: String, size: String, fraction: Double?) -> String {
        var parts = [name, state, size]
        if let fraction { parts.append("\(Int((fraction * 100).rounded(.down))) percent") }
        return parts.joined(separator: ", ")
    }
}
