import Foundation
import Testing
@testable import CameraTransport

/// A join the person keeps leaving during iOS's prompt: each lapse that follows time away switches the camera's Wi-Fi on
/// again without counting against `WirelessTiming.rewritesPerJoin`, so `WirelessTiming.switchOnsAfterAway` bounds them.
@Suite("Wireless session: leaving during every prompt", .timeLimit(.minutes(1)))
struct WirelessJoinBounceTests {
    /// `trips` joins, each left 1 s into iOS's prompt and returned from 100 s apart; the camera's Wi-Fi is off whenever
    /// the session looks (it lapsed while the app was away), and the gateway appears only after the last join.
    private func bouncing(_ trips: Int) -> Rig {
        let rig = Rig()
        rig.link.schedule(status: 0, after: .seconds(1), notify: false)
        rig.joiner.script(Array(repeating: FakeJoiner.Step(delay: .seconds(10), during: rig.away(after: .seconds(1))),
                                count: trips))
        rig.path.script(Array(repeating: .never, count: trips) + [.after(.seconds(1))])
        for trip in 1...trips { rig.comeBack(at: .seconds(100 * trip)) }
        return rig
    }

    @Test func upToTheLimitTheJoinStillCompletes() async {
        let rig = bouncing(WirelessTiming.switchOnsAfterAway)
        let result = await rig.prepare()
        #expect(opened(result) != nil)
        // The first join and one after each switch-on, every one made in front.
        #expect(rig.joiner.applyTimes.count == WirelessTiming.switchOnsAfterAway + 1)
    }

    @Test func oneTripMoreThanTheLimitPausesForTheApp() async {
        let rig = bouncing(WirelessTiming.switchOnsAfterAway + 1)
        let result = await rig.prepare()
        #expect(failure(result) == .paused(.needsJoin))
        // No switch-on and no join after the limit.
        #expect(rig.joiner.applyTimes.count == WirelessTiming.switchOnsAfterAway + 1)
    }
}
