import CameraTransport
import Foundation

/// What to import from the card (proposal, `ImportJob.selection`: all-new, range or explicit).
public enum ImportSelection: Sendable, Hashable {
    /// Everything the catalogue doesn't have as imported: the default (Browse's *Select all new*).
    case allNew
    /// Files taken in this range that aren't imported yet.
    case dateRange(ClosedRange<Date>)
    /// Files picked in Browse. Kept as whole items, not link handles, because handles don't survive a replug and
    /// the engine finds the files left by identity (decision 7).
    case items([CameraItem])

    /// True only for an explicit pick of nothing.
    public var isEmpty: Bool {
        if case let .items(items) = self { return items.isEmpty }
        return false
    }
}

/// Settings the engine reads at the start of a job.
public struct ImportSettings: Sendable, Hashable, Codable {
    /// Downloads in flight on USB: 1 or 2. Two gained 2 % in MTP and 5 % in MSC (one run each), so the default is
    /// 1 (backlog section 3). Values outside 1...2 are clamped.
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
