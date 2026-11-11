import Foundation

/// The Staging screen and the loupe (backlog section 7.3), in British English. Titles in title case, descriptions and
/// announcements in sentence case, as the other screens' wording (HIG Writing). Plain Swift, tested on Linux; the
/// SwiftUI views only show these.
public enum CullWording {
    // MARK: The Staging screen

    public static let title = "Staging"
    /// The Cameras screen's button that opens Staging, until the tab bar gives it a tab (I10).
    public static let openStaging = "Staging"
    public static let openStagingHint = "Shows the staged files, to keep or reject them with no camera connected."
    public static let close = "Close"

    public static let loading = "Reading Staging"
    public static let emptyTitle = "Nothing Staged"
    public static let emptyDetail = "Files you stage from a camera's card appear here by camera and day, to keep or "
        + "reject with no camera connected."
    public static let loadFailedTitle = "Couldn't Read Staging"
    public static let loadFailedDetail = "Shutter Bridge couldn't read its list of staged files."
    public static let tryAgain = "Try Again"

    /// A day's row opens the loupe at its first photo with no mark.
    public static let dayHint = "Opens the photos of this day, at the first one with no mark."

    /// A day's title: "Today", "Yesterday", or the date written out ("Thursday 5 November 2026" in British English).
    /// `day` is `YYYYMMDD`, the camera's wall-clock day, compared with `now`'s day in `calendar`.
    public static func dayTitle(_ day: String, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                locale: Locale = .autoupdatingCurrent) -> String {
        guard let date = date(ofDay: day, calendar: calendar) else { return day }
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(date, inSameDayAs: today) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
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
        var parts = ["\(counts.units) staged"]
        if counts.kept > 0 { parts.append("\(counts.kept) kept") }
        if counts.rejected > 0 { parts.append("\(counts.rejected) rejected") }
        return parts.joined(separator: ", ")
    }

    /// The day's row as one sentence, for VoiceOver: "Today: 120 staged, 34 kept, 60 rejected".
    public static func dayLabel(title: String, counts: CullCounts) -> String {
        "\(title): \(countsLine(counts))"
    }

    /// Lines under the list for staged files that can't be shown; empty when every one can.
    public static func unavailableLines(_ unavailable: StagedUnavailable) -> [String] {
        var lines: [String] = []
        if unavailable.inICloudDrive > 0 {
            lines.append("\(fileCount(unavailable.inICloudDrive)) \(verb(unavailable.inICloudDrive)) in iCloud "
                + "Drive, which isn't available to Shutter Bridge now.")
        }
        if unavailable.gone > 0 {
            lines.append("\(fileCount(unavailable.gone)) \(verb(unavailable.gone)) no longer in Staging as "
                + "\(unavailable.gone == 1 ? "it was" : "they were") staged.")
        }
        if unavailable.unknownPlace > 0 {
            lines.append("\(fileCount(unavailable.unknownPlace)) can't be shown: Shutter Bridge doesn't know where "
                + "\(unavailable.unknownPlace == 1 ? "its copy is" : "their copies are").")
        }
        return lines
    }

    private static func fileCount(_ n: Int) -> String { n == 1 ? "1 staged file" : "\(n) staged files" }
    private static func verb(_ n: Int) -> String { n == 1 ? "is" : "are" }

    // MARK: The loupe

    public static let keep = "Keep"
    public static let reject = "Reject"
    public static let clearMark = "Clear Mark"
    public static let undo = "Undo"
    public static let nextPhoto = "Next Photo"
    public static let previousPhoto = "Previous Photo"
    public static let ratingTitle = "Stars"
    /// The VoiceOver actions for the pinch and the double tap.
    public static let zoomIn = "Zoom to Actual Size"
    public static let zoomOut = "Fit to Screen"
    public static let previewFailedTitle = "Couldn't Show This Photo"
    public static let previewFailedDetail = "The staged file couldn't be read."
    public static let noPreview = "There's no preview for this file."
    public static let downloading = "Downloading from iCloud Drive…"
    /// Shown under a RAW whose own decode isn't possible on this iPhone, as *Copy as JPEG* says it.
    public static let embeddedOnly = "Showing the camera's preview: this RAW couldn't be decoded on this iPhone."
    public static let writeFailed = "Couldn't save the mark, so it's back as it was."

    /// What VoiceOver says the loupe's gestures and actions are.
    public static let loupeHint = "Swipe up or down with one finger for the next or previous photo. Keep, Reject, "
        + "the stars, Undo and zoom are in the actions."

    /// "12 of 120", from a zero-based index.
    public static func position(_ index: Int, of count: Int) -> String {
        count == 0 ? "None" : "\(index + 1) of \(count)"
    }

    /// The decision as a badge and in the photo's VoiceOver value.
    public static func decisionWord(_ decision: CullDecision?) -> String {
        switch decision {
        case .keep?: "Kept"
        case .reject?: "Rejected"
        case nil: "No mark"
        }
    }

    /// "No stars", "1 star", "4 stars".
    public static func stars(_ rating: Int) -> String {
        switch rating {
        case ...0: "No stars"
        case 1: "1 star"
        default: "\(rating) stars"
        }
    }

    /// The name of the VoiceOver action, and the button, that gives `rating` stars: "No Stars", "1 Star", "4 Stars".
    public static func rateAction(_ rating: Int) -> String {
        switch rating {
        case ...0: "No Stars"
        case 1: "1 Star"
        default: "\(rating) Stars"
        }
    }

    /// The pair's badge: "RAW+JPEG", "RAW+HEIF"; nil for a lone file.
    public static func pairBadge(_ unit: CullUnit) -> String? {
        guard case let .pair(_, processed) = unit.pairing else { return nil }
        let name = processed.identity.filename
        let ext = name.contains(".") ? String(name.split(separator: ".").last ?? "").uppercased() : ""
        switch ext {
        case "JPG", "JPEG": return "RAW+JPEG"
        case "HIF", "HEIF", "HEIC": return "RAW+HEIF"
        default: return "RAW+\(ext)"
        }
    }

    /// The photo's VoiceOver label: its name, and for a pair the name it is shown by with "and its RAW".
    public static func unitLabel(_ unit: CullUnit) -> String {
        switch unit.pairing {
        case let .pair(_, processed): "\(processed.identity.filename) and its RAW"
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

    public static let firstPhoto = "First photo of the day."
    public static let lastPhoto = "Last photo of the day."
    public static let nothingToUndo = "Nothing to undo."

    /// After Keep, Reject or Clear Mark: "Kept.", and where the loupe moved on to, if it did ("Kept. 13 of 120.").
    public static func marked(_ decision: CullDecision?, movedTo position: String?) -> String {
        let said: String
        switch decision {
        case .keep?: said = "Kept."
        case .reject?: said = "Rejected."
        case nil: said = "Mark cleared."
        }
        guard let position else { return said }
        return "\(said) \(position)."
    }

    /// After a rating: "3 stars.", "No stars."
    public static func rated(_ rating: Int) -> String { stars(rating) + "." }

    /// After Undo, with where it went back to: "Mark undone. 12 of 120, No mark."
    public static func undone(index: Int, count: Int, mark: CullMark) -> String {
        "Mark undone. \(unitValue(index: index, count: count, mark: mark))."
    }
}
