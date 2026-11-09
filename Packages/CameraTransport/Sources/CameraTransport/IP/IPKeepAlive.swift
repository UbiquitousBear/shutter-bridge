/// The keep-alive timer of a PTP/IP session: GetDeviceInfo once the session has been idle for `interval`, never
/// during a transaction (backlog Iteration 3, section 4, *Keep-alive*). The Imagedge code reports that the camera drops
/// an idle session after about 30 s (ZV-E10; on the α7C II that drop hasn't been separated from iOS closing a
/// suspended app's sockets, `unverified`), and the spike's GetDeviceInfo every 10 s kept sessions up; it answered six
/// times on 5 Nov. GetDeviceInfo, never GetDevicePropValue, which this session never answers.
///
/// `IPSession` owns one and re-arms it whenever the last queued transaction ends, so the timer always counts from the
/// end of the latest command: a session in steady use sends no keep-alive at all, and an idle one sends one every
/// `interval`. The timer runs on the session's injected clock. Each arming has a generation, so a timer that fires as
/// a transaction begins is recognised as stale and does nothing.
struct IPKeepAlive: Sendable {
    /// Idle time before a keep-alive; nil turns the keep-alive off.
    let interval: Duration?
    private var timer: Task<Void, Never>?
    private(set) var generation = 0
    /// Keep-alives the camera answered, whatever the code, for diagnostics.
    private(set) var answered = 0
    /// Keep-alives that failed: a non-OK answer, or the connection failing under one.
    private(set) var failed = 0

    init(interval: Duration?) {
        self.interval = interval
    }

    /// Starts a new timer for `interval` from now (read from the clock at once), replacing any running one; `fire`
    /// gets the arming's generation. Does nothing when the keep-alive is off.
    mutating func arm(on clock: any Clock<Duration>, fire: @escaping @Sendable (_ generation: Int) async -> Void) {
        stop()
        guard let interval else { return }
        generation += 1
        timer = Self.timer(on: clock, after: interval, generation: generation, fire: fire)
    }

    /// The deadline is read from the clock here, as the timer is armed (the end of the latest transaction), not
    /// whenever the task first runs: a task that starts late, on a loaded phone or test runner, still fires on time.
    private static func timer<C: Clock<Duration>>(on clock: C, after interval: Duration, generation: Int,
                                                  fire: @escaping @Sendable (_ generation: Int) async -> Void)
        -> Task<Void, Never> {
        let deadline = clock.now.advanced(by: interval)
        return Task {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return  // re-armed or stopped
            }
            await fire(generation)
        }
    }

    /// Whether `generation` is the arming still current: a fire from an older one is stale.
    func isCurrent(_ generation: Int) -> Bool { timer != nil && generation == self.generation }

    /// The timer has fired and its keep-alive is about to be sent: forget the task without cancelling it (the
    /// keep-alive runs in it), so re-arming at the end of that transaction leaves it alone.
    mutating func firing() { timer = nil }

    /// Cancels the timer.
    mutating func stop() {
        timer?.cancel()
        timer = nil
    }

    mutating func recordAnswer(ok: Bool) {
        answered += 1
        if !ok { failed += 1 }
    }

    mutating func recordFailure() { failed += 1 }
}
