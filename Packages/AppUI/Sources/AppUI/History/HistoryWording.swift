import Catalogue
import CameraTransport
import Foundation

/// The History screen (backlog section 4; D6), in British English. Titles in title case, lines in sentence case (HIG
/// Writing). Every line names the camera by its display name, never its key or serial. `locale`, `calendar` and
/// `timeZone` are for tests; the app passes nothing.
public enum HistoryWording {
    public static let title = AppText.string("History")
    public static let allCameras = AppText.string("All Cameras")
    public static let filterMenu = AppText.string("Camera")
    public static let loading = AppText.string("Reading History…")
    public static let emptyTitle = AppText.string("No Imports Yet")
    public static let emptyDetail = AppText.string("Imports and staging from your cameras are listed here, newest "
        + "first.")
    public static let loadFailedTitle = AppText.string("Couldn't Read History")
    public static let loadFailedDetail = AppText.string("Shutter Bridge couldn't read its catalogue. Try again in a "
        + "moment.")
    public static let tryAgain = AppText.string("Try Again")
    public static let resume = AppText.string("Resume")
    public static let resumeHint = AppText.string("Opens Import with the files this job didn't finish, when the camera "
        + "is connected.")
    public static let rerun = AppText.string("Re-run Failed Files")
    public static let rerunHint = AppText.string("Opens Import with this job's failed files that still aren't "
        + "imported, when the camera "
        + "is connected.")
    public static let openStagingHint = AppText.string("Shows this job's folder in Staging.")
    public static let forgetImportsAction = AppText.string("Forget Imports")
    public static let showInStaging = AppText.string("Show in Staging")

    // MARK: - A job's row

    /// What the job was, with the camera's name: "Import from ILCE-7CM2", "Stage from ILCE-7CM2", or *Import keepers*
    /// from Staging (D6).
    public static func title(_ purpose: JobRecord.Purpose, camera: String) -> String {
        switch purpose {
        case .import: AppText.format("Import from %@", camera)
        case .stage: AppText.format("Stage from %@", camera)
        case .keepers: AppText.format("Keepers from %@ to Photos", camera)
        }
    }

    /// "48 imported, 2 skipped", "12 staged", "10 imported, 28 staged, 1 failed", as the Import screen counts them
    /// (`ImportWording.counts`) without its "files" and full stop, so a list row stays short. A job that did nothing:
    /// "Nothing imported" or "Nothing staged".
    public static func counts(_ job: JobRecord) -> String {
        var parts: [String] = []
        if job.filesImported > 0 {
            parts.append(AppText.counted(job.filesImported, one: "%lld imported", other: "%lld imported"))
        }
        if job.filesStaged > 0 {
            parts.append(AppText.counted(job.filesStaged, one: "%lld staged", other: "%lld staged"))
        }
        if parts.isEmpty {
            parts.append(job.purpose == .stage ? AppText.string("Nothing staged") : AppText.string("Nothing imported"))
        }
        if job.filesSkipped > 0 {
            parts.append(AppText.counted(job.filesSkipped, one: "%lld skipped", other: "%lld skipped"))
        }
        if job.filesFailed > 0 {
            parts.append(AppText.counted(job.filesFailed, one: "%lld failed", other: "%lld failed"))
        }
        return parts.joined(separator: ", ")
    }

    /// The bytes copied, in decimal units ("1.24 GB"), or "1.2 GB of 4.5 GB" for a job that copied less than it set
    /// out to.
    public static func bytes(_ job: JobRecord, locale: Locale = .autoupdatingCurrent) -> String {
        if job.bytesTotal > job.bytesDone {
            return ByteWording.progress(job.bytesDone, of: job.bytesTotal, locale: locale)
        }
        return ByteWording.size(job.bytesDone, locale: locale)
    }

    /// How long the job ran, start to end: "40 sec", "12 min", "1 hr, 5 min" (abbreviated units, as the system writes
    /// them); nil for a job with no end. Whole seconds under a minute (at least one), whole minutes above.
    public static func duration(_ job: JobRecord, locale: Locale = .autoupdatingCurrent) -> String? {
        rounded(job).map { $0.formatted(durationStyle(.abbreviated, locale: locale)) }
    }

    /// The same as VoiceOver says it, in whole words: "12 minutes".
    public static func durationSpoken(_ job: JobRecord, locale: Locale = .autoupdatingCurrent) -> String? {
        rounded(job).map { $0.formatted(durationStyle(.wide, locale: locale)) }
    }

    private static func rounded(_ job: JobRecord) -> Duration? {
        guard let end = job.finishedAt else { return nil }
        let seconds = max(0, end.timeIntervalSince(job.startedAt))
        guard seconds.isFinite else { return nil }
        let whole = max(1, Int64(min(seconds, 1e9).rounded()))
        if whole < 60 { return .seconds(whole) }
        return .seconds((whole + 30) / 60 * 60)
    }

    private static func durationStyle(_ width: Duration.UnitsFormatStyle.UnitWidth,
                                      locale: Locale) -> Duration.UnitsFormatStyle {
        Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: width, maximumUnitCount: 2)
            .locale(locale)
    }

    /// How the job ended, as the Import screen words its end (`ImportWording.finished`) without the "Import" the row's
    /// title already says: "Finished", "Cancelled", "Stopped: this iPhone is out of space". A job with no end is
    /// "In progress" while it runs and "Stopped early" once it doesn't (the app's end interrupted it, section 4).
    public static func outcome(_ outcome: JobRecord.Outcome?, running: Bool) -> String {
        switch outcome {
        case nil: running ? AppText.string("In progress") : AppText.string("Stopped early")
        case .completed: AppText.string("Finished")
        case .cancelled: AppText.string("Cancelled")
        case let .stopped(reason):
            if let kind = CameraLinkFailure.Kind(rawValue: reason) {
                AppText.format("Stopped: %@", withoutFullStop(ImportWording.stopReason(kind)))
            } else if reason == JobRecord.Outcome.photosAccessReason {
                // A keepers job Photos refused (I12): the Import screen's "Photos access needed".
                AppText.string("Stopped: Photos access needed")
            } else {
                AppText.string("Stopped")
            }
        case .catalogueUnavailable: AppText.string("Stopped: Shutter Bridge couldn't read or update its catalogue")
        }
    }

    private static func withoutFullStop(_ line: String) -> String {
        line.hasSuffix(".") ? String(line.dropLast()) : line
    }

    /// Where the files went (D6): "Photos", "Photos, album “ILCE-7CM2”" when the job kept its album's identifier (the
    /// album is named after the camera, D11), "Staging" for a stage job, "Staging instead of Photos" for an import
    /// Photos refused; nil when the job never got that far.
    public static func place(_ job: JobRecord, camera: String) -> String? {
        switch job.destination {
        case nil: nil
        case .photos:
            job.albumIdentifier == nil ? AppText.string("Photos") : AppText.format("Photos, album “%@”", camera)
        case .staging: job.purpose == .stage ? AppText.string("Staging") : AppText.string("Staging instead of Photos")
        }
    }

    /// "14:05": when the job started, in the person's clock style.
    public static func time(_ date: Date, locale: Locale = .autoupdatingCurrent,
                            calendar: Calendar = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// A day's header: "Today", "Yesterday", or the date written out, as the Staging screen heads its days
    /// (`CullWording.dayTitle`).
    public static func dayTitle(_ day: String, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                locale: Locale = .autoupdatingCurrent) -> String {
        CullWording.dayTitle(day, now: now, calendar: calendar, locale: locale)
    }

    /// The *Resumable* line: "Resumable: 12 files left", or "Resumable" when how many isn't known (the card was never
    /// listed).
    public static func resumable(filesLeft: Int?) -> String {
        guard let filesLeft else { return AppText.string("Resumable") }
        return AppText.format("Resumable: %@ left", ByteWording.files(filesLeft))
    }

    /// The re-run line: "2 failed files not imported yet" ("not staged yet" for a stage job).
    public static func failedLeft(_ count: Int, purpose: JobRecord.Purpose) -> String {
        purpose == .stage
            ? AppText.counted(count, one: "%lld failed file not staged yet", other: "%lld failed files not staged yet")
            : AppText.counted(count, one: "%lld failed file not imported yet", other: "%lld failed files not imported "
                + "yet")
    }

    /// The row as VoiceOver reads it, one line per job (section 4): its title and time, how it ended, the counts, the
    /// bytes and how long it took, where the files went and, when it applies, *Resumable* or the failures left.
    public static func rowAccessibility(title: String, time: String, outcome: String, counts: String, bytes: String,
                                        durationSpoken: String?, place: String?, action: String?) -> String {
        var line = AppText.format("%@, %@. %@. %@. %@", title, time, outcome, counts, bytes)
        if let durationSpoken { line += " " + AppText.format("in %@", durationSpoken) }
        line += "."
        if let place { line += " \(place)." }
        if let action { line += " \(action)." }
        return line
    }

    // MARK: - After a tap

    /// The camera isn't connected (or, over Wi-Fi, isn't open in Browse): History never starts a join by itself.
    public static func connectCamera(_ name: String, carrier: JobRecord.Carrier?) -> String {
        switch carrier {
        case .wifi: AppText.format("Open %@ in Cameras to connect over Wi-Fi, then tap here again.", name)
        case .usb, .staging, nil: AppText.format("Connect %@ with its USB-C cable, then tap here again.", name)
        }
    }

    /// Everything the job would queue is done already.
    public static func nothingLeft(purpose: JobRecord.Purpose) -> String {
        purpose == .stage ? AppText.string("Nothing left to stage: those files are staged already.")
            : AppText.string("Nothing left to import: those files are imported already.")
    }

    public static func listingFailed(_ name: String) -> String {
        AppText.format("Shutter Bridge couldn't read the card in %@. Try again.", name)
    }

    /// Failed files of a re-run that the card no longer has: "2 failed files are no longer on the card."
    public static func missing(_ count: Int) -> String {
        AppText.counted(count, one: "%lld failed file is no longer on the card.",
                        other: "%lld failed files are no longer on the card.")
    }

    public static let catalogueFailed = AppText.string("Shutter Bridge couldn't read its catalogue. Try again in a "
        + "moment.")

    // MARK: - Forget imports (D6)

    /// The confirmation before *Forget imports* for one camera (section 4): what it does, that the photos stay in
    /// Photos and could be imported again, and, as a footer, that a photo also imported from another camera stays
    /// imported ("already imported" ignores the camera key).
    public struct ForgetConfirmation: Sendable, Hashable {
        public var title: String
        public var message: String
        public var footer: String
        public var confirm: String
        public var cancel: String

        /// The message and the footer as one text, for a confirmation dialog, which has no footer of its own.
        public var dialogMessage: String { message + "\n\n" + footer }
    }

    public static func forgetConfirmation(camera: String) -> ForgetConfirmation {
        ForgetConfirmation(
            title: AppText.format("Forget Imports from %@?", camera),
            message: AppText.format("Shutter Bridge will forget which photos it imported from %@, so they show as new "
                + "on "
                + "its card and could be imported again. The photos stay in Photos, staged copies stay in Staging, and "
                + "nothing on the camera changes.", camera),
            footer: AppText.string("A photo also imported from another camera stays imported."),
            confirm: AppText.string("Forget Imports"),
            cancel: AppText.string("Cancel"))
    }

    /// *Forget imports* asked for while that camera's import is running or paused.
    public static func forgetWhileImporting(_ camera: String) -> String {
        AppText.format("Wait for the import from %@ to finish, then forget its imports.", camera)
    }

    /// After *Forget imports*: "Forgot 48 imports from ILCE-7CM2.", or that there was nothing to forget.
    public static func forgot(_ count: Int, camera: String) -> String {
        count == 0 ? AppText.format("There were no imports from %@ to forget.", camera)
            : AppText.format("Forgot %@ from %@.", AppText.counted(count, one: "%lld import", other: "%lld imports"),
                             camera)
    }

    // MARK: - The camera's name

    /// A camera's name from its catalogue row (D11: albums and Staging folders by display name): its friendly name,
    /// else its model, else "Camera"; a card's volume name ("Untitled", from Image Transfer) reads as "Camera", as
    /// `CamerasWording.displayName(for:)` has it. Never the key.
    public static func cameraName(_ record: CameraRecord?) -> String {
        guard let record else { return CamerasWording.genericName }
        let friendly = record.friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !friendly.isEmpty, !CamerasWording.volumeDefaultNames.contains(friendly.lowercased()) { return friendly }
        let model = record.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { return model }
        return CamerasWording.genericName
    }

    // MARK: - The running import, as the tab bar's accessory

    public static let accessoryHint = AppText.string("Opens the import.")
}
