import Foundation

/// How many bytes a slow link may carry, on the simulator's own clock (backlog Iteration 2, section 3, *Slow link*).
///
/// Every `tick` of simulated time grants `bytesPerTick` bytes; a download takes what it needs from `available` and
/// waits for the next tick when none is left. Time passes only through `advance(by:)`, as everywhere in the
/// simulators, so a test says exactly how many bytes the link has carried and a loaded runner can't change it. Pure
/// and `Sendable`: the in-process link (`SimulatedCameraLink`), the in-memory camera and the loopback server each hold
/// one and wake what is waiting when it grows.
///
/// Whole ticks only: time short of a tick is carried over, never rounded up, so `advance(by: tick / 2)` twice grants
/// one tick. Bytes nobody has taken stay in `available` (a test may advance the clock before the download starts);
/// a link's bandwidth can't really be saved up, so a test that wants none carried over sets a new budget.
public struct ThroughputBudget: Sendable, Equatable {
    public let bytesPerTick: UInt64
    public let tick: Duration
    /// Bytes granted by ticks that have passed and not yet taken.
    public private(set) var available: UInt64 = 0
    /// Attoseconds of the tick in progress.
    private var carried: Int128 = 0

    /// Nil unless `bytesPerTick` is at least 1 and `tick` is positive: a budget that never grants would hang a
    /// download rather than slow it.
    public init?(bytesPerTick: UInt64, every tick: Duration) {
        guard bytesPerTick > 0, Self.attoseconds(of: tick) > 0 else { return nil }
        self.bytesPerTick = bytesPerTick
        self.tick = tick
    }

    /// Lets `elapsed` simulated time go by (a negative duration is ignored).
    public mutating func advance(by elapsed: Duration) {
        let size = Self.attoseconds(of: tick)
        carried += max(0, Self.attoseconds(of: elapsed))
        let ticks = carried / size
        carried %= size
        guard ticks > 0 else { return }
        let granted = UInt64(clamping: ticks).multipliedReportingOverflow(by: bytesPerTick)
        let add = granted.overflow ? UInt64.max : granted.partialValue
        let sum = available.addingReportingOverflow(add)
        available = sum.overflow ? UInt64.max : sum.partialValue
    }

    /// Takes up to `wanted` bytes of what is available and returns how many it took (0 when none is left).
    public mutating func take(upTo wanted: UInt64) -> UInt64 {
        let taken = min(wanted, available)
        available -= taken
        return taken
    }

    private static func attoseconds(of duration: Duration) -> Int128 {
        let c = duration.components
        return Int128(c.seconds) * 1_000_000_000_000_000_000 + Int128(c.attoseconds)
    }
}
