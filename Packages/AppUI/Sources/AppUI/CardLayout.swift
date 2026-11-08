import CameraTransport
import Foundation

/// One day of the card in Browse's grid, newest first.
public struct CardSection: Sendable, Hashable, Identifiable {
    /// "2026-11-08", or "undated".
    public var id: String
    /// The start of the day in the phone's calendar; nil for files without a capture date.
    public var day: Date?
    public var items: [CameraItem]

    public init(id: String, day: Date?, items: [CameraItem]) {
        self.id = id
        self.day = day
        self.items = items
    }
}

/// How a file shows in the grid.
public enum CardCellKind: Sendable, Hashable {
    /// A still that can be copied or shared as a JPEG, with its badge ("RAW", "HEIF") or none for a JPG.
    case photo(badge: String?)
    /// Greyed out with "Video: from 1.1" and no actions (Shamil, 8 Nov).
    case video
    /// Anything else (a sidecar, an unknown file): greyed out with "Not a photo" and no actions.
    case other

    public var offersJPEGActions: Bool {
        if case .photo = self { true } else { false }
    }
}

/// The grid's layout rules, pure so they are tested on Linux.
public enum CardLayout {
    /// The listing grouped by day of capture, newest day first and newest first within a day; files without a date
    /// last. The link already lists newest first; this sorts again so the grid never depends on it.
    public static func sections(_ items: [CameraItem], calendar: Calendar = .current) -> [CardSection] {
        var sections: [CardSection] = []
        var undated: [CameraItem] = []
        for item in items.newestFirst() {
            guard let date = item.captureDate else {
                undated.append(item)
                continue
            }
            let day = calendar.startOfDay(for: date)
            if let last = sections.last, last.day == day {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(CardSection(id: dayID(day, calendar: calendar), day: day, items: [item]))
            }
        }
        if !undated.isEmpty { sections.append(CardSection(id: "undated", day: nil, items: undated)) }
        return sections
    }

    public static func kind(of item: CameraItem) -> CardCellKind {
        switch item.format {
        case .raw: .photo(badge: BrowseWording.rawBadge)
        case .heif: .photo(badge: BrowseWording.heifBadge)
        case .jpeg: .photo(badge: nil)
        case .video: .video
        case .sidecar, .folder, .other: .other
        }
    }

    static func dayID(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let (y, m, d) = (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "\(y)-\(m < 10 ? "0" : "")\(m)-\(d < 10 ? "0" : "")\(d)"
    }
}
