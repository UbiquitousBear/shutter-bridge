import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge

// The app's copy (backlog section 6), in British English and in the camera's own wording for its modes. No maker's
// marks: "works with" wording only. Numbers are the bench's measurements, never promises. Plain strings until the
// String Catalog arrives.

/// The Cameras screen.
public enum CamerasWording {
    public static let title = "Cameras"
    public static let usbBadge = "USB-C"
    /// The toolbar button that opens Settings.
    public static let settingsButton = "Settings"
    /// The toolbar button that opens the Import screen while a job exists.
    public static let importButton = "Import"

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

/// Sizes, rates and times, in decimal units as the bench measured them (1 MB = 10^6 bytes). Fixed formatting, so the
/// copy reads the same on every locale until the String Catalog takes over.
public enum ByteWording {
    /// "512 bytes", "640 KB", "42.3 MB", "1.24 GB".
    public static func size(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if bytes < 1_000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        if bytes < 1_000_000 { return "\(Int((b / 1_000).rounded())) KB" }
        if bytes < 1_000_000_000 { return "\(decimal(b / 1_000_000, places: 1)) MB" }
        return "\(decimal(b / 1_000_000_000, places: 2)) GB"
    }

    /// "1.2 GB of 4.5 GB".
    public static func progress(_ done: UInt64, of total: UInt64) -> String {
        "\(size(done)) of \(size(total))"
    }

    /// "41.8 MB/s".
    public static func rate(megabytesPerSecond: Double) -> String {
        "\(decimal(megabytesPerSecond, places: 1)) MB/s"
    }

    /// "About 40 s left", "About 3 min left", "About 1 h 5 min left". Rounded up, so it never reads 0.
    public static func timeLeft(_ duration: Duration) -> String {
        let total = max(1, Int((Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18).rounded(.up)))
        if total < 60 { return "About \(total) s left" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "About \(minutes) min left" }
        return "About \(minutes / 60) h \(minutes % 60) min left"
    }

    /// `value` with `places` decimals, rounded half up, with a "." separator.
    static func decimal(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "?" }
        var scale = 1.0
        for _ in 0 ..< places { scale *= 10 }
        let scaled = Int((value * scale).rounded())
        let whole = scaled / Int(scale)
        guard places > 0 else { return "\(whole)" }
        let fraction = String(abs(scaled % Int(scale)))
        return "\(whole)." + String(repeating: "0", count: places - fraction.count) + fraction
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
    public static let selected = "Selected"
    public static let notSelected = "Not selected"
    public static let new = "New"

    /// The sticky bar: "3 files · 142.5 MB".
    public static func selectionSummary(_ summary: SelectionSummary) -> String {
        summary.count == 0 ? noSelection : "\(ByteWording.files(summary.count)) · \(ByteWording.size(summary.bytes))"
    }

    public static let noSelection = "No files selected"

    /// Why a file can't be selected, for VoiceOver's hint and the cell; nil when it can.
    public static func notSelectable(_ reason: BrowseModel.SelectionBlock) -> String {
        switch reason {
        case .video: videoLabel
        case .notAPhoto: otherLabel
        case .imported: "Already imported."
        case .noCaptureDate: "No capture date, so it can't be imported yet."
        case .cardNotRead: "Wait until the card has been read."
        }
    }

    // Filters.
    public static let filters = "Filters"
    public static let newOnly = "New Only"
    public static let type = "Type"
    public static let dateRange = "Date"
    public static let anyDate = "Any Date"
    public static let from = "From"
    public static let to = "To"
    public static let clearFilters = "Clear Filters"
    public static let noMatchesTitle = "No matching files"
    public static let noMatchesDetail = "No files on the card match these filters."

    public static func typeLabel(_ type: BrowseFileType) -> String {
        switch type {
        case .raw: "RAW"
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        case .video: "Video"
        case .other: "Other"
        }
    }

    /// While ImageCaptureCore reads the card, the catalogue's last listing shows at once (decision 7). The screen
    /// adds the date it was listed (`BrowseModel.lastKnownListedAt`), formatted for the locale.
    public static let lastKnownTitle = "Last-known card"

    /// "Listed 8 Nov 2026 at 14:05." under the last-known title; `date` is formatted by the screen for the locale.
    public static func lastKnownListed(_ date: String) -> String { "Listed \(date)." }

    /// The date filter's switch, and what it says when no file on the card has a capture date.
    public static let limitDates = "Only These Dates"
    public static let noDatedFiles = "No file on the card has a capture date."
    /// The strip at the top of Browse while a job exists; tapping it opens the Import screen.
    public static let showImport = "Show Import"
    public static let lastKnownDetail = "These are the files the card held last time. They're replaced when the "
        + "camera has read the card."

    /// The grid cell's VoiceOver label: name, date, type, imported and selected states. `date` is formatted by the
    /// screen for the locale; nil for a file without one.
    public static func cellAccessibility(name: String, date: String?, kind: CardCellKind, isImported: Bool,
                                         isSelected: Bool, selectable: Bool) -> String {
        var parts = [name]
        parts.append(date ?? undatedHeader)
        switch kind {
        case let .photo(badge): parts.append(badge ?? "JPEG")
        case .video: parts.append(videoLabel)
        case .other: parts.append(otherLabel)
        }
        if kind.offersJPEGActions { parts.append(isImported ? importedBadge : new) }
        if selectable || isSelected { parts.append(isSelected ? selected : notSelected) }
        return parts.joined(separator: ", ")
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

    /// Under the control: the forced-Files rule and where files go.
    public static let destinationFooter = "If Photos access is off, or Photos is restricted on this iPhone, imports "
        + "go to Files whatever this setting says. In Files they're in On My iPhone › Shutter Bridge, in a folder "
        + "for each camera. The next import follows this setting; files already imported stay where they are."

    public static let done = "Done"
}

/// The Import screen (backlog section 6, *Import*; decisions 1, 4 and 9).
public enum ImportWording {
    public static let title = "Import"
    public static let pause = "Pause"
    public static let resume = "Continue"
    public static let cancel = "Cancel Import"
    public static let done = "Done"
    public static let openSettings = "Open Settings"
    public static let askingForPhotos = "Waiting for your answer about Photos access…"
    public static let couldNotStart = "The import couldn't start. Check the camera is still connected, then try again."
    public static let couldNotAdd = "These files couldn't be added to the import. Try again."
    public static let filesHeader = "In This Import"
    public static let noJobTitle = "Nothing to import yet"
    public static let noJobDetail = "Select photos on a camera's card and tap Import."
    public static let cancelConfirmTitle = "Cancel this import?"
    public static let cancelConfirmDetail = "Files already imported stay where they went. The rest stay on the card."
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
            "Paused. Tap Continue to carry on."
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
        case .committing: kind == .filesFolder ? "Moving to Files" : "Saving to Photos"
        case let .imported(location):
            switch location {
            case .photosAsset?: "Imported to Photos"
            case .file?: "Saved to Files"
            case nil: "Imported"
            }
        case let .skipped(reason): "Skipped: \(skipped(reason, item: item))"
        case let .failed(reason): "Failed: \(failed(reason))"
        case .notImported: "Not imported: still on the card"
        }
    }

    static func skipped(_ reason: ImportSkipReason, item: CameraItem) -> String {
        switch reason {
        case .notAStill: item.format == .video ? "video (from 1.1)" : "not a photo"
        case .noCaptureDate: "no capture date"
        case let .link(kind):
            switch kind {
            case .itemNotFound: "no longer on the card"
            case .unreadableItem: "the camera couldn't read it"
            case .unsupportedFormat: "this kind of file can't be imported"
            case .busy, .noAnswer, .disconnected, .phoneStorageFull, .notAuthorised, .modeListsNoFiles:
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
            case .busy, .noAnswer, .disconnected, .notAuthorised, .modeListsNoFiles, .unsupportedFormat:
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
