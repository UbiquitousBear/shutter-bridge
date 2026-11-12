import CameraTransport
import Catalogue
import Foundation
import PhotosBridge

/// What to import from the card (proposal, `ImportJob.selection`: all-new, range or explicit).
///
/// What counts as done depends on the job's purpose (`ImportRoute.purpose`; Shamil, 11 Nov): an import job leaves out
/// files already imported and ignores staging; a stage job leaves out files already staged and, where only new files
/// were asked for (`allNew`, `dateRange`, `newItems`), files already imported too. An explicit pick (`items`) of an
/// imported file may still be staged.
///
/// Files with a Reject mark in the catalogue (`CatalogueStore.marks(of:)`, by content key; D3, Shamil, 11 Nov) are
/// left out of every selection but an explicit pick (`leavesOutRejects`): a reject whose staged copy was removed isn't
/// offered again, and an explicit pick of it still imports it.
public enum ImportSelection: Sendable, Hashable {
    /// Everything that is new for the job's purpose: the default.
    case allNew
    /// Files taken in this range that are new for the job's purpose.
    case dateRange(ClosedRange<Date>)
    /// Files picked in Browse. Kept as whole items, not link handles, because handles don't survive a replug and
    /// the engine finds the files left by identity (decision 7).
    case items([CameraItem])
    /// Files picked by Browse's *Select all new*: matched like `items`, but only new ones are copied, so a stage
    /// job also leaves out those already imported.
    case newItems([CameraItem])
    /// Files a History row queues again (D6): a *Resumable* job's stored pick, or a *Re-run* of a job's failed
    /// files, matched against the card's listing (`init(requeueing:from:camera:timeZone:)`,
    /// `rerun(_:from:camera:timeZone:)`). Matched and done like `items` (an imported file may still be staged), but
    /// files with a Reject mark are left out (D3): the person picked them before, not now.
    case requeued([CameraItem])

    /// True only for an explicit pick of nothing.
    public var isEmpty: Bool {
        switch self {
        case let .items(items), let .newItems(items), let .requeued(items): items.isEmpty
        case .allNew, .dateRange: false
        }
    }

    /// Whether only new files were asked for, rather than an explicit pick: a stage job then leaves out imported
    /// files too.
    var newOnly: Bool {
        switch self {
        case .items, .requeued: false
        case .allNew, .dateRange, .newItems: true
        }
    }

    /// Whether files with a Reject mark are left out (D3): everything but an explicit pick, which still imports a
    /// rejected file.
    public var leavesOutRejects: Bool {
        if case .items = self { false } else { true }
    }
}

extension ImportSelection {
    /// A History row's stored selection, queued again (*Resumable*, D6): *all new* again, the stored date range, or the
    /// stored picks matched by content key against `listed` (in the stored order; a key not on the card is left out).
    /// A stored explicit pick comes back as `requeued`, so files rejected since are left out too (D3); a stored
    /// *Select all new* pick as `newItems`.
    ///
    /// - Parameters:
    ///   - listed: The card as the app listed it just now.
    ///   - camera: The catalogue's key for the camera, as `ImportEngine.start(_:from:camera:to:)` takes it.
    ///   - timeZone: The zone the capture times are read in (the engine's).
    public init(requeueing stored: JobRecord.Selection, from listed: [CameraItem], camera: CameraKey,
                timeZone: TimeZone) {
        switch stored {
        case .allNew: self = .allNew
        case let .dateRange(range): self = .dateRange(range)
        case let .picked(keys): self = .requeued(Self.matching(keys, in: listed, camera: camera, timeZone: timeZone))
        case let .pickedNew(keys):
            self = .newItems(Self.matching(keys, in: listed, camera: camera, timeZone: timeZone))
        }
    }

    /// A *Re-run* of a job's failed files (`JobRecord.failedFiles`, D6), matched by content key against `listed`; a
    /// file no longer on the card is left out. Files rejected since are left out of the job (D3).
    public static func rerun(_ failed: [ObjectIdentity.ContentKey], from listed: [CameraItem], camera: CameraKey,
                             timeZone: TimeZone) -> ImportSelection {
        .requeued(matching(failed, in: listed, camera: camera, timeZone: timeZone))
    }

    /// The files of `listed` whose content is one of `keys`, in the order of `keys`, each once.
    static func matching(_ keys: [ObjectIdentity.ContentKey], in listed: [CameraItem], camera: CameraKey,
                         timeZone: TimeZone) -> [CameraItem] {
        let onCard = ImportEngine.byContent(listed, camera: camera, timeZone: timeZone)
        var seen = Set<ObjectIdentity.ContentKey>()
        return keys.compactMap { key in
            guard seen.insert(key).inserted else { return nil }
            return onCard[key]
        }
    }
}

/// The Reject rule (D3, Shamil, 11 Nov): which files a selection leaves out because the catalogue holds a Reject mark
/// for their content. Public so History counts and queues a job again as the engine would run it (I10).
public enum RejectRule {
    /// The content keys whose mark in `marks` is a Reject.
    public static func rejected(in marks: [ObjectIdentity.ContentKey: MarkRecord]) -> Set<ObjectIdentity.ContentKey> {
        Set(marks.compactMap { $0.value.decision == .reject ? $0.key : nil })
    }
}

/// Settings the engine reads at the start of a job.
public struct ImportSettings: Sendable, Hashable, Codable {
    /// Downloads in flight: 1 or 2. Two gained 2 % in MTP and 5 % in MSC (one run each), so the default is 1
    /// (backlog section 3). Values outside 1...2 are clamped. A job runs at most
    /// `min(this, link.capabilities.maxDownloadsInFlight)`, so Wi-Fi's single transaction keeps it at 1 whatever
    /// this says (backlog Iteration 3, section 1, *One transaction at a time*).
    public var downloadsInFlight: Int {
        didSet { downloadsInFlight = Self.clamp(downloadsInFlight) }
    }

    public init(downloadsInFlight: Int = 1) {
        self.downloadsInFlight = Self.clamp(downloadsInFlight)
    }

    private enum CodingKeys: String, CodingKey { case downloadsInFlight }

    /// Decodes through the clamp, so a corrupt or old stored value can't put 0 or 5 downloads in flight.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(downloadsInFlight: try c.decodeIfPresent(Int.self, forKey: .downloadsInFlight) ?? 1)
    }

    private static func clamp(_ n: Int) -> Int { min(2, max(1, n)) }
}

/// What a job leaves out as done, by its purpose (Shamil, 11 Nov), for the first listing's diff and for `append`.
enum DoneRule {
    /// Whether a file is still to do.
    ///
    /// - Parameters:
    ///   - state: The catalogue's state for the file, matched by content (`CatalogueStore.states(of:)`).
    ///   - staged: Whether the catalogue has a staged copy of it, matched by content
    ///     (`CatalogueStore.stagedStates(of:)`). Read only for a stage job.
    ///   - purpose: The job's (`ImportRoute.purpose`).
    ///   - newOnly: Only new files were asked for (`ImportSelection.newOnly`), not an explicit pick.
    ///   - wholeCard: The card was listed for them (`allNew`, `dateRange`): only new and partial rows are wanted, so
    ///     a skipped file waits for an explicit pick, as before staging.
    static func isWanted(state: ObjectState, staged: Bool, purpose: DestinationKind, newOnly: Bool,
                         wholeCard: Bool) -> Bool {
        switch purpose {
        case .photos:
            // An import job ignores staging: a staged file is imported like any other.
            if state == .imported { return false }
        case .staging:
            if staged { return false }
            // An explicit pick of an imported file may still be staged.
            if newOnly && state == .imported { return false }
        }
        return wholeCard ? (state == .new || state == .partial) : true
    }
}
