import Foundation

/// The staged files of one capture day, as the cull screen groups them (section 7.1).
public struct StagedDay: Sendable, Hashable {
    /// "YYYY-MM-DD", the camera's wall-clock day, as Staging's day folders are named.
    public var day: String
    /// In capture order.
    public var records: [CatalogueRecord]

    public init(day: String, records: [CatalogueRecord]) {
        self.day = day
        self.records = records
    }
}

/// Grouping `CatalogueStore.stagedRecords(camera:)` by capture day.
public enum StagedDays {
    /// `records` by capture day, the earliest day first, each day's files in capture order (then by file name, camera
    /// key and folder), whatever order `records` came in.
    public static func grouped(_ records: [CatalogueRecord]) -> [StagedDay] {
        var days: [StagedDay] = []
        for record in StagedOrder.sorted(records) {
            let day = Self.day(of: record.identity.captureDate)
            if days.last?.day == day {
                days[days.count - 1].records.append(record)
            } else {
                days.append(StagedDay(day: day, records: [record]))
            }
        }
        return days
    }

    /// "YYYY-MM-DD" from the camera's `YYYYMMDDThhmmss`.
    static func day(of date: CaptureDate) -> String {
        let raw = Array(date.rawValue)
        return String(raw[0 ..< 4]) + "-" + String(raw[4 ..< 6]) + "-" + String(raw[6 ..< 8])
    }
}

/// The order `stagedRecords(camera:)` answers in, for both stores.
enum StagedOrder {
    static func sorted(_ records: some Sequence<CatalogueRecord>) -> [CatalogueRecord] {
        records.sorted { a, b in
            let x = a.identity
            let y = b.identity
            if x.captureDate != y.captureDate { return x.captureDate < y.captureDate }
            if x.filename != y.filename { return x.filename < y.filename }
            if x.camera.rawValue != y.camera.rawValue { return x.camera.rawValue < y.camera.rawValue }
            return x.folder < y.folder
        }
    }
}

/// *Forget imports* (D6), for both stores: what becomes of one row of the camera being forgotten.
enum ForgetRule {
    enum Change: Equatable {
        /// Not an imported or skipped row: left as it is.
        case keep
        /// No staged copy: the row goes.
        case delete
        /// A staged copy: the row goes back to new with no location, keeping the copy.
        case rewrite(CatalogueRow)
    }

    static func change(for row: CatalogueRow) -> Change {
        guard row.objectState == .imported || row.objectState == .skipped else { return .keep }
        // The raw column, not `row.staged`: a copy under a root a later version adds is still a staged copy to keep.
        guard row.stagedRelativePath != nil else { return .delete }
        var forgotten = row
        forgotten.state = ObjectState.new.rawValue
        forgotten.assetLocalID = nil
        forgotten.fileRelativePath = nil
        forgotten.resumeOffset = 0
        forgotten.tempURL = nil
        return .rewrite(forgotten)
    }
}
