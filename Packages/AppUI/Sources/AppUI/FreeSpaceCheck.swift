import CameraTransport
import Catalogue
import Foundation

// The free-space check before a job starts (staging PR 7, bench S4): the job's bytes plus a spare against the space
// iOS says it can make available for important work. Linux-tested; the Darwin key is compiled only by CI.

/// How many bytes the phone has free for the import's files; nil when it can't say.
public protocol FreeSpaceReading: Sendable {
    func availableBytes() async -> UInt64?
}

/// No reading: the check never stops a job. The default, for tests and previews.
public struct UnknownFreeSpace: FreeSpaceReading {
    public init() {}
    public func availableBytes() async -> UInt64? { nil }
}

/// The free space of the volume `url` is on: on Apple platforms `volumeAvailableCapacityForImportantUsage`, which
/// counts space iOS would free (purgeable caches) for work the person asked for; elsewhere `volumeAvailableCapacity`
/// (Linux Foundation has no key for important usage). Read off the cooperative pool, since working out the purgeable
/// space can take a moment. The privacy manifest declares the disk-space reason for it (E174.1 and 85F4.1).
public struct VolumeFreeSpace: FreeSpaceReading {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func availableBytes() async -> UInt64? {
        let url = self.url
        return await StagedRemoval.offThePool { Self.read(url) }
    }

    private static func read(_ url: URL) -> UInt64? {
        #if canImport(Darwin)
        guard let bytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, bytes >= 0 else { return nil }
        return UInt64(bytes)
        #else
        guard let bytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
              bytes >= 0 else { return nil }
        return UInt64(bytes)
        #endif
    }
}

/// Whether a job fits in the free space, before it starts.
public enum FreeSpaceCheck {
    /// Kept spare beyond the job's own bytes: 1 GB, in decimal units as the app's sizes are. It covers the few work
    /// files in flight (Photos copies each file and its temporary file is deleted after each commit) and whatever else
    /// the phone writes meanwhile. `unverified`: bench S4 compares it with a 200-file stage job at about 2 GB free.
    public static let spare: UInt64 = 1_000_000_000

    public enum Verdict: Sendable, Hashable {
        /// `available` is at least `needed` (the job's bytes plus the spare).
        case fits(available: UInt64, needed: UInt64)
        /// `available` is less than `needed`: the job isn't started.
        case tooLittle(available: UInt64, needed: UInt64)
        /// The free space couldn't be read: the job isn't stopped.
        case unknown
    }

    /// The verdict for a job of `jobBytes` with `available` bytes free: it fits when `available` is at least
    /// `jobBytes` plus `spare` (saturating, never trapping).
    public static func verdict(jobBytes: UInt64, available: UInt64?, spare: UInt64 = spare) -> Verdict {
        let (sum, overflow) = jobBytes.addingReportingOverflow(spare)
        let needed = overflow ? UInt64.max : sum
        guard let available else { return .unknown }
        return available >= needed ? .fits(available: available, needed: needed)
            : .tooLittle(available: available, needed: needed)
    }

    /// The bytes a job of `items` would copy: the sizes of its stills with a capture date, as the engine copies them
    /// (it leaves out other files and files with no capture date). Saturating.
    public static func jobBytes(_ items: [CameraItem], camera: CameraKey, timeZone: TimeZone) -> UInt64 {
        var total: UInt64 = 0
        for item in items where item.format.isStill && item.identity(camera: camera, timeZone: timeZone) != nil {
            let (sum, overflow) = total.addingReportingOverflow(item.size)
            total = overflow ? .max : sum
        }
        return total
    }

    /// How much more space the job needs than there is (`needed - available`), rounded up to what `ByteWording.size`
    /// shows (whole kB under a megabyte, tenths of a MB under a gigabyte, hundredths of a GB above), so the number the
    /// person reads is never less than the space they must free.
    public static func shortfall(available: UInt64, needed: UInt64) -> UInt64 {
        guard needed > available else { return 0 }
        let short = needed - available
        let step: UInt64 = short < 1_000_000 ? 1_000 : short < 1_000_000_000 ? 100_000 : 10_000_000
        let steps = short / step + (short % step == 0 ? 0 : 1)
        let (rounded, overflow) = steps.multipliedReportingOverflow(by: step)
        return overflow ? short : rounded
    }
}
