/// Calls waiting on a framework's completion handler, each finished exactly once: by its completion, its time limit,
/// a cancel, the camera going away or the link closing, whichever comes first; later ones are dropped. Kept by the
/// link's actor, so only the actor touches it. Pure, so the exactly-once rule is unit-tested on Linux.
struct PendingCalls<Outcome: Sendable> {
    private var parked: [UInt64: CheckedContinuation<Outcome, Never>] = [:]
    private var next: UInt64 = 0

    var count: Int { parked.count }

    /// A fresh id for a call about to park.
    mutating func reserve() -> UInt64 {
        next += 1
        return next
    }

    mutating func park(_ id: UInt64, _ continuation: CheckedContinuation<Outcome, Never>) {
        precondition(parked[id] == nil, "a call id parked twice")
        parked[id] = continuation
    }

    func isWaiting(_ id: UInt64) -> Bool { parked[id] != nil }

    /// Finishes one call; false if it had already finished (or never parked), in which case nothing happens.
    @discardableResult
    mutating func finish(_ id: UInt64, with outcome: Outcome) -> Bool {
        guard let continuation = parked.removeValue(forKey: id) else { return false }
        continuation.resume(returning: outcome)
        return true
    }

    /// Finishes every waiting call with the same outcome (removal, close) and returns how many there were.
    @discardableResult
    mutating func finishAll(with outcome: Outcome) -> Int {
        let all = parked
        parked.removeAll()
        for continuation in all.values { continuation.resume(returning: outcome) }
        return all.count
    }
}
