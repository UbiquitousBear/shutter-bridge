/// The order thumbnails are asked for: at most `limit` in flight (two, decision 7: 73.0 ms each in MTP against
/// 80.8 ms one at a time and 87.6 ms four at a time), and when a slot frees, the newest waiting file goes next.
/// Rank 0 is the newest file in the listing; ties go first come, first served. Pure, so it is unit-tested on Linux.
struct ThumbnailQueue: Sendable {
    let limit: Int
    private(set) var inFlight = 0
    private var waiting: [(ticket: UInt64, rank: Int, arrival: UInt64)] = []
    private var arrivals: UInt64 = 0

    init(limit: Int = 2) {
        precondition(limit > 0, "a thumbnail queue needs at least one slot")
        self.limit = limit
    }

    var waitingCount: Int { waiting.count }

    /// A request arrives: true if it may start now (a slot was free and is now taken), false if it waits.
    mutating func arrive(ticket: UInt64, rank: Int) -> Bool {
        if inFlight < limit && waiting.isEmpty {
            inFlight += 1
            return true
        }
        arrivals += 1
        waiting.append((ticket, rank, arrivals))
        return false
    }

    /// A request in flight finished: the ticket that takes its slot (the newest waiting), or nil if none waits.
    mutating func finish() -> UInt64? {
        precondition(inFlight > 0, "finish without a request in flight")
        guard let next = waiting.indices.min(by: { (waiting[$0].rank, waiting[$0].arrival) < (waiting[$1].rank, waiting[$1].arrival) })
        else {
            inFlight -= 1
            return nil
        }
        return waiting.remove(at: next).ticket   // the slot passes straight to it
    }

    /// A waiting request was cancelled: true if it was still waiting (and is now gone).
    mutating func withdraw(ticket: UInt64) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.ticket == ticket }) else { return false }
        waiting.remove(at: index)
        return true
    }
}

/// `ThumbnailQueue` with real waiting: `enter` suspends until the request may start, `leave` frees its slot. One
/// per link. A cancelled waiter leaves the queue and `enter` throws the link's "cancelled" failure.
actor ThumbnailGate {
    private var queue: ThumbnailQueue
    private var parked: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    /// Decided before the waiter parked (true: admitted, false: withdrawn), should a hop ever come in between.
    private var decidedEarly: [UInt64: Bool] = [:]
    private var tickets: UInt64 = 0

    init(limit: Int = 2) { queue = ThumbnailQueue(limit: limit) }

    var inFlight: Int { queue.inFlight }
    var waitingCount: Int { queue.waitingCount }

    /// Waits for a slot. `rank` 0 is the newest file. Call `leave()` exactly once after a successful `enter`.
    func enter(rank: Int) async throws(CameraLinkFailure) {
        tickets += 1
        let ticket = tickets
        if queue.arrive(ticket: ticket, rank: rank) { return }
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if let decided = decidedEarly.removeValue(forKey: ticket) {
                    continuation.resume(returning: decided)
                    return
                }
                parked[ticket] = continuation
                if Task.isCancelled { withdraw(ticket) }
            }
        } onCancel: {
            Task { await self.withdraw(ticket) }
        }
        if !admitted { throw USBFailureMapping.cancelled(.thumbnail) }
    }

    func leave() {
        guard let next = queue.finish() else { return }
        decide(next, admitted: true)
    }

    private func withdraw(_ ticket: UInt64) {
        guard queue.withdraw(ticket: ticket) else { return }   // already admitted: it goes ahead and leaves later
        decide(ticket, admitted: false)
    }

    private func decide(_ ticket: UInt64, admitted: Bool) {
        if let continuation = parked.removeValue(forKey: ticket) {
            continuation.resume(returning: admitted)
        } else {
            decidedEarly[ticket] = admitted
        }
    }
}
