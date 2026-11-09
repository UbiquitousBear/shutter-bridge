// Where an `any Clock<Duration>` is opened into a concrete clock.
//
// Swift 6.4.2 on Linux (checked 9 Nov 2026) refuses to open an `any Clock<Duration>` into a generic `C: Clock<Duration>`
// ("type 'any Clock<Duration>' cannot conform to 'Clock'") when the value is a stored property passed straight to the
// generic function, as `performHandoffOnConcrete(clock: clock, ...)` inside `WiFiHandoff.run` would. A parameter or a local
// opens fine, with or without `import Foundation` here; the likely culprit is the C `clock()` function that Glibc and
// Darwin export. So open the clock from a parameter or a local, here, and never pass a stored `clock` property directly.

extension ClockMark {
    /// A mark at the clock's current time.
    public static func now(on clock: any Clock<Duration>) -> ClockMark {
        func mark<C: Clock<Duration>>(_ clock: C) -> ClockMark { ClockMark(clock, at: clock.now) }
        return mark(clock)
    }
}

/// The public sequencer entry: runs a hand-off on whatever clock it was given.
func performHandoff(
    clock: any Clock<Duration>, link: any GATTLink, subscribe: Bool, trace: TransportTrace
) async throws(HandoffFailure) -> HandoffResult {
    try await performHandoffOnConcrete(clock: clock, link: link, subscribe: subscribe, trace: trace)
}
