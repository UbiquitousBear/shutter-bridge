/// The engine's view of time: a `Duration` since the engine was made, on whatever clock it was given. Production
/// passes `ContinuousClock`; tests pass a manual clock, so the 4-a-second limit, the rate, stall timing and retry
/// backoff are deterministic and no test sleeps on the wall clock.
struct EngineClock: Sendable {
    private let readNow: @Sendable () -> Duration
    private let sleepUntil: @Sendable (Duration) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        readNow = { origin.duration(to: clock.now) }
        sleepUntil = { offset in try await clock.sleep(until: origin.advanced(by: offset), tolerance: nil) }
    }

    /// Time since the origin.
    var now: Duration { readNow() }

    /// Sleeps until `deadline` (time since the origin); returns at once when it has passed. Throws
    /// `CancellationError` when the task is cancelled.
    func sleep(until deadline: Duration) async throws { try await sleepUntil(deadline) }
}

extension Duration {
    /// Seconds as a `Double`, for rates.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
