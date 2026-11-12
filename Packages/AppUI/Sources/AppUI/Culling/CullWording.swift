import Foundation

/// The Staging screen and the loupe (backlog section 7.3), in British English. Titles in title case, descriptions and
/// announcements in sentence case, as the other screens' wording (HIG Writing). Plain Swift, tested on Linux; the
/// SwiftUI views only show these.
public enum CullWording {
    // MARK: The Staging screen

    public static let title = AppText.string("Staging")

    public static let loading = AppText.string("Reading Staging")
    public static let emptyTitle = AppText.string("Nothing Staged")
    public static let emptyDetail = AppText.string("Files you stage from a camera's card appear here by camera and "
        + "day, to keep or "
        + "reject with no camera connected.")
    public static let loadFailedTitle = AppText.string("Couldn't Read Staging")
    public static let loadFailedDetail = AppText.string("Shutter Bridge couldn't read its list of staged files.")
    public static let tryAgain = AppText.string("Try Again")
    /// A pull to refresh that failed over a list already shown, which stays as it was.
    public static let refreshFailed = AppText.string("Couldn't read Staging again, so this list may be out of date.")

    /// A day's row opens the loupe at its first photo with no mark.
    public static let dayHint = AppText.string("Opens the photos of this day, at the first one with no mark.")

    /// A day's title: "Today", "Yesterday", or the date written out ("Thursday 5 November 2026" in British English).
    /// `day` is `YYYYMMDD`, the camera's wall-clock day, compared with `now`'s day in `calendar`.
    public static func dayTitle(_ day: String, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                locale: Locale = .autoupdatingCurrent) -> String {
        guard let date = date(ofDay: day, calendar: calendar) else { return day }
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(date, inSameDayAs: today) { return AppText.string("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return AppText.string("Yesterday")
        }
        var style = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Midday of `YYYYMMDD` in `calendar`, so a daylight-saving change can't move it to another day.
    static func date(ofDay day: String, calendar: Calendar) -> Date? {
        guard day.count == 8, day.allSatisfy({ $0.isASCII && $0.isNumber }),
              let year = Int(day.prefix(4)), let month = Int(day.dropFirst(4).prefix(2)),
              let dayOfMonth = Int(day.suffix(2))
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12))
    }

    /// "120 staged, 34 kept, 60 rejected", counted in units (a RAW+JPEG pair is one); a part that is 0 is left out,
    /// except the staged count.
    public static func countsLine(_ counts: CullCounts) -> String {
        var parts = [AppText.counted(counts.units, one: "%lld staged", other: "%lld staged")]
        if counts.kept > 0 { parts.append(AppText.counted(counts.kept, one: "%lld kept", other: "%lld kept")) }
        if counts.rejected > 0 {
            parts.append(AppText.counted(counts.rejected, one: "%lld rejected", other: "%lld rejected"))
        }
        return parts.joined(separator: ", ")
    }

    /// The day's row as one sentence, for VoiceOver: "Today: 120 staged, 34 kept, 60 rejected".
    public static func dayLabel(title: String, counts: CullCounts) -> String {
        AppText.format("%@: %@", title, countsLine(counts))
    }

    /// Lines under the list for staged files that can't be shown; empty when every one can.
    public static func unavailableLines(_ unavailable: StagedUnavailable) -> [String] {
        var lines: [String] = []
        if unavailable.inICloudDrive > 0 {
            lines.append(AppText.counted(
                unavailable.inICloudDrive,
                one: "%lld staged file is in iCloud Drive, which isn't available to Shutter Bridge now.",
                other: "%lld staged files are in iCloud Drive, which isn't available to Shutter Bridge now."))
        }
        if unavailable.gone > 0 {
            lines.append(AppText.counted(
                unavailable.gone,
                one: "%lld staged file is no longer in Staging as it was staged.",
                other: "%lld staged files are no longer in Staging as they were staged."))
        }
        if unavailable.unknownPlace > 0 {
            lines.append(AppText.counted(
                unavailable.unknownPlace,
                one: "%lld staged file can't be shown: Shutter Bridge doesn't know where its copy is.",
                other: "%lld staged files can't be shown: Shutter Bridge doesn't know where their copies are."))
        }
        return lines
    }

    // MARK: The loupe

    public static let keep = AppText.string("Keep")
    public static let reject = AppText.string("Reject")
    public static let clearMark = AppText.string("Clear Mark")
    public static let undo = AppText.string("Undo")
    public static let nextPhoto = AppText.string("Next Photo")
    public static let previousPhoto = AppText.string("Previous Photo")
    public static let ratingTitle = AppText.string("Stars")
    /// The VoiceOver actions for the pinch and the double tap: to the original's 100 %, or, for a RAW shown by its
    /// embedded preview (no original's pixels to decode), as far as the preview goes.
    public static let zoomIn = AppText.string("Zoom to Actual Size")
    public static let zoomInPreview = AppText.string("Zoom In")
    public static let zoomOut = AppText.string("Fit to Screen")
    public static let previewFailedTitle = AppText.string("Couldn't Show This Photo")
    public static let previewFailedDetail = AppText.string("The staged file couldn't be read.")
    public static let noPreview = AppText.string("There's no preview for this file.")
    public static let downloading = AppText.string("Downloading from iCloud Drive…")
    /// Shown under a RAW whose own decode isn't possible on this iPhone, as *Copy as JPEG* says it.
    public static let embeddedOnly = AppText.string("Showing the camera's preview: this RAW couldn't be decoded on "
        + "this iPhone.")
    public static let writeFailed = AppText.string("Couldn't save the mark, so it's back as it was.")

    /// What VoiceOver says the loupe's gestures and actions are.
    public static let loupeHint = AppText.string("Swipe up or down with one finger for the next or previous photo. "
        + "Keep, Reject, "
        + "the stars, Undo and zoom are in the actions.")

    /// "12 of 120", from a zero-based index.
    public static func position(_ index: Int, of count: Int) -> String {
        count == 0 ? AppText.string("None") : AppText.format("%@ of %@", String(index + 1), String(count))
    }

    /// The decision as a badge and in the photo's VoiceOver value.
    public static func decisionWord(_ decision: CullDecision?) -> String {
        switch decision {
        case .keep?: AppText.string("Kept")
        case .reject?: AppText.string("Rejected")
        case nil: AppText.string("No mark")
        }
    }

    /// "No stars", "1 star", "4 stars".
    public static func stars(_ rating: Int) -> String {
        switch rating {
        case ...0: AppText.string("No stars")
        default: AppText.counted(rating, one: "%lld star", other: "%lld stars")
        }
    }

    /// The name of the VoiceOver action, and the button, that gives `rating` stars: "No Stars", "1 Star", "4 Stars".
    public static func rateAction(_ rating: Int) -> String {
        switch rating {
        case ...0: AppText.string("No Stars")
        default: AppText.counted(rating, one: "%lld Star", other: "%lld Stars")
        }
    }

    /// The pair's badge: "RAW+JPEG", "RAW+HEIF"; nil for a lone file.
    public static func pairBadge(_ unit: CullUnit) -> String? {
        guard case let .pair(_, processed) = unit.pairing else { return nil }
        let name = processed.identity.filename
        let ext = name.contains(".") ? String(name.split(separator: ".").last ?? "").uppercased() : ""
        switch ext {
        case "JPG", "JPEG": return AppText.string("RAW+JPEG")
        case "HIF", "HEIF", "HEIC": return AppText.string("RAW+HEIF")
        default: return AppText.format("RAW+%@", ext)
        }
    }

    /// The photo's VoiceOver label: its name, and for a pair the name it is shown by with "and its RAW".
    public static func unitLabel(_ unit: CullUnit) -> String {
        switch unit.pairing {
        case let .pair(_, processed): AppText.format("%@ and its RAW", processed.identity.filename)
        case let .single(file): file.identity.filename
        }
    }

    /// The photo's VoiceOver value: "12 of 120, Kept, 3 stars".
    public static func unitValue(index: Int, count: Int, mark: CullMark) -> String {
        var parts = [position(index, of: count), decisionWord(mark.decision)]
        if mark.rating > 0 { parts.append(stars(mark.rating)) }
        return parts.joined(separator: ", ")
    }

    // MARK: Announcements

    public static let firstPhoto = AppText.string("First photo of the day.")
    public static let lastPhoto = AppText.string("Last photo of the day.")
    public static let nothingToUndo = AppText.string("Nothing to undo.")

    /// After Keep, Reject or Clear Mark: "Kept.", and where the loupe moved on to, if it did ("Kept. 13 of 120.").
    public static func marked(_ decision: CullDecision?, movedTo position: String?) -> String {
        let said: String
        switch decision {
        case .keep?: said = AppText.string("Kept.")
        case .reject?: said = AppText.string("Rejected.")
        case nil: said = AppText.string("Mark cleared.")
        }
        guard let position else { return said }
        return AppText.format("%@ %@.", said, position)
    }

    /// After a rating: "3 stars.", "No stars."
    public static func rated(_ rating: Int) -> String { stars(rating) + "." }

    /// After Undo, with where it went back to: "Mark undone. 12 of 120, No mark."
    public static func undone(index: Int, count: Int, mark: CullMark) -> String {
        AppText.format("Mark undone. %@.", unitValue(index: index, count: count, mark: mark))
    }
}
