import CameraTransport
import Foundation

/// The type filter's groups (backlog section 6, *Browse*: filters for new only, date range and type).
public enum BrowseFileType: String, Sendable, Hashable, CaseIterable {
    case raw
    case jpeg
    case heif
    case video
    /// Sidecars, folders and unknown files.
    case other

    public static func of(_ item: CameraItem) -> BrowseFileType {
        switch item.format {
        case .raw: .raw
        case .jpeg: .jpeg
        case .heif: .heif
        case .video: .video
        case .sidecar, .folder, .other: .other
        }
    }
}

/// What Browse shows of the card. Pure, so the rules are tested on Linux.
public struct BrowseFilter: Sendable, Hashable {
    /// Hide files the catalogue has as imported.
    public var newOnly: Bool
    /// The types shown; every type by default.
    public var types: Set<BrowseFileType>
    /// Only files taken in this range (inclusive). A file without a capture date is hidden while a range is set.
    public var dateRange: ClosedRange<Date>?

    public init(newOnly: Bool = false, types: Set<BrowseFileType> = Set(BrowseFileType.allCases),
                dateRange: ClosedRange<Date>? = nil) {
        self.newOnly = newOnly
        self.types = types
        self.dateRange = dateRange
    }

    /// Everything shown.
    public static let none = BrowseFilter()

    /// Whether anything is filtered out.
    public var isActive: Bool { self != .none }

    public func admits(_ item: CameraItem, isImported: Bool) -> Bool {
        if newOnly && isImported { return false }
        if !types.contains(BrowseFileType.of(item)) { return false }
        if let dateRange {
            guard let date = item.captureDate, dateRange.contains(date) else { return false }
        }
        return true
    }

    /// Shows or hides one type.
    public mutating func toggle(_ type: BrowseFileType) {
        if types.contains(type) { types.remove(type) } else { types.insert(type) }
    }

    /// The whole days from `first`'s through `last`'s, in `calendar`: from the start of the first day to the last
    /// instant before the day after the last one. The days are swapped if `last` is before `first`, so the date
    /// filter's From and To pickers can never make an invalid range.
    public static func days(from first: Date, through last: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let (a, b) = first <= last ? (first, last) : (last, first)
        let start = calendar.startOfDay(for: a)
        let lastDay = calendar.startOfDay(for: b)
        let next = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        return start ... max(start, next.addingTimeInterval(-0.001))
    }

    /// Limits the dates to whole days from `from` through `to` (`days(from:through:calendar:)`).
    public mutating func limitDates(from: Date, to: Date, calendar: Calendar = .current) {
        dateRange = Self.days(from: from, through: to, calendar: calendar)
    }

    /// Moves the range's first day to `day`'s, keeping its last day unless that would come first.
    public mutating func setFirstDay(_ day: Date, bounds: ClosedRange<Date>, calendar: Calendar = .current) {
        let last = dateRange?.upperBound ?? bounds.upperBound
        limitDates(from: day, to: max(day, last), calendar: calendar)
    }

    /// Moves the range's last day to `day`'s, keeping its first day unless that would come after.
    public mutating func setLastDay(_ day: Date, bounds: ClosedRange<Date>, calendar: Calendar = .current) {
        let first = dateRange?.lowerBound ?? bounds.lowerBound
        limitDates(from: min(day, first), to: day, calendar: calendar)
    }
}

/// The sticky bar's numbers: how many files are selected and their total size.
public struct SelectionSummary: Sendable, Hashable {
    public var count: Int
    public var bytes: UInt64

    public init(count: Int, bytes: UInt64) {
        self.count = count
        self.bytes = bytes
    }

    public static let empty = SelectionSummary(count: 0, bytes: 0)
}

/// Who holds a camera link open: Browse while its screen is up, the import while its job uses the link. The link
/// closes when the last holder lets go, so leaving Browse never closes the link under a running import, and a
/// finished import never closes it under Browse (USB links are shared: `USBCameraBrowser.link(for:)` hands out the
/// same link while it is usable). One per app, shared by every `BrowseModel` and the `ImportModel`.
@MainActor
public final class LinkLeases {
    private var holders: [ObjectIdentifier: (link: any CameraLink, count: Int)] = [:]

    /// Called after a link has been closed because its last holder let go. The Wi-Fi cameras use it to end the stay
    /// (`WiFiCameraSource.linkClosed(_:)`): a camera's import has finished when no one holds its link any more. Nil by
    /// default.
    public var onClosed: (@MainActor (any CameraLink) async -> Void)?
    /// Called after a holder let go of a link that another still holds. Nil by default. The Wi-Fi cameras use it in the
    /// background (`WiFiCameraSource.linkReleased(_:activeImport:)`), where Browse being open must not keep the phone on
    /// the camera's network once the import is over.
    public var onReleased: (@MainActor (any CameraLink) async -> Void)?
    /// Called when a link gets its first holder. Nil by default. The reminder's connection hold uses it (W16,
    /// `ConnectionHolds`): a camera is connected while someone holds its link.
    public var onAcquired: (@MainActor (any CameraLink) -> Void)?

    public init() {}

    public func acquire(_ link: any CameraLink) {
        let key = ObjectIdentifier(link)
        let count = (holders[key]?.count ?? 0) + 1
        holders[key] = (link, count)
        if count == 1 { onAcquired?(link) }
    }

    /// Lets go of `link`; closes it when no one else holds it. Releasing a link that isn't held closes it.
    public func release(_ link: any CameraLink) async {
        let key = ObjectIdentifier(link)
        let remaining = (holders[key]?.count ?? 1) - 1
        if remaining > 0 {
            holders[key] = (link, remaining)
            await onReleased?(link)
            return
        }
        holders[key] = nil
        await link.close()
        await onClosed?(link)
    }

    /// How many hold `link`.
    public func holders(of link: any CameraLink) -> Int { holders[ObjectIdentifier(link)]?.count ?? 0 }
}
