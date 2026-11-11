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

    /// True only for an explicit pick of nothing.
    public var isEmpty: Bool {
        switch self {
        case let .items(items), let .newItems(items): items.isEmpty
        case .allNew, .dateRange: false
        }
    }

    /// Whether only new files were asked for, rather than an explicit pick: a stage job then leaves out imported
    /// files too.
    var newOnly: Bool {
        if case .items = self { false } else { true }
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
