// What the Wi-Fi route did, as values for the bench log (W20): the join's steps and their times, the hand-off's CC09 status
// changes and CC08 writes, the Bluetooth RSSI, and the Wi-Fi link's open, poll, keep-alive, resume and close. CameraTransport
// has no logger: the app passes a `TransportTrace` that turns each event into a line (AppUI's `TransportTraceWording`), and
// everything else gets `.none`, which records nothing and makes no extra call.
//
// No event carries a network name, password, serial, peripheral or device identifier, GUID, address or manufacturer data:
// only times, counts, sizes, CC09 statuses and failure kinds. Recording an event never changes what the route does or when.

import Foundation

/// Where trace events go: a closure the app supplies, or nothing (`.none`).
public struct TransportTrace: Sendable {
    private let sink: (@Sendable (TransportTraceEvent) -> Void)?

    /// Calls `sink` with each event, on whichever task recorded it. It must return quickly and never block.
    public init(_ sink: @escaping @Sendable (TransportTraceEvent) -> Void) {
        self.sink = sink
    }

    private init() {
        sink = nil
    }

    /// Records nothing.
    public static let none = TransportTrace()

    /// Whether events go anywhere. Work done only for the trace (the RSSI read, the keep-alive's marks) is skipped when not.
    public var isOn: Bool { sink != nil }

    /// Records an event.
    public func record(_ event: TransportTraceEvent) {
        sink?(event)
    }

    /// Records an event; the event isn't even built when the trace is off.
    func callAsFunction(_ event: @autoclosure () -> TransportTraceEvent) {
        guard let sink else { return }
        sink(event())
    }
}

/// How long each step of one preparation (`WirelessSession.prepareImport`) took, summed over the times it was in each phase.
public struct WirelessStepTimes: Sendable, Equatable {
    /// From the start of the preparation to its end.
    public var total: Duration
    /// Bluetooth: the connect, the hand-off and any rewrite.
    public var handingOff: Duration
    /// From the network's details to the camera's gateway (iOS's prompt included).
    public var joining: Duration
    /// From the gateway (or, inside the stay, the start) to the camera's session open: the port, PTP/IP and the card's
    /// listing poll.
    public var openingSession: Duration

    public init(total: Duration = .zero, handingOff: Duration = .zero, joining: Duration = .zero,
                openingSession: Duration = .zero) {
        self.total = total
        self.handingOff = handingOff
        self.joining = joining
        self.openingSession = openingSession
    }
}

/// What the camera's CC09 said when the session looked after a join that didn't reach the gateway.
public enum CameraWiFiCheck: Sendable, Equatable {
    /// CC09 was read: its Wi-Fi status, 0 to 3 as the camera sends it (nil when the value didn't give one).
    case read(UInt8?)
    /// The Bluetooth link is down; the camera's 50 s from status 2 decide.
    case linkDown
    /// The read failed with the link up; the camera's 50 s from status 2 decide.
    case readFailed
    /// No Bluetooth link is held; the camera's 50 s from status 2 decide.
    case noLink
}

/// One thing the Wi-Fi route did. Times are `Duration`s since the start of the step named in each case's notes.
public enum TransportTraceEvent: Sendable, Equatable {
    // MARK: The session (`WirelessSession`)

    /// A preparation began. `joined`: the phone is still on the camera's network (inside the stay, or a recovery), so the
    /// session reopens without a join first; `bluetoothFirst`: but the camera's Wi-Fi is presumed off, so it goes to Bluetooth.
    case preparationStarted(joined: Bool, bluetoothFirst: Bool)
    /// Inside the stay, reopening on Wi-Fi gave up after `after` (since the reopen began); the session goes to Bluetooth.
    case stayReopenGaveUp(after: Duration)
    /// The Bluetooth connect returned a link, `after` since it was asked for.
    case bluetoothConnected(after: Duration)
    /// The link's signal strength in dBm (nil when iOS gave none), read `after` since this hand-off began, before its first
    /// connect, like `handoffFinished` (the `handoffStatus` times count from the run after the connect). Read beside the
    /// hand-off, never in its way.
    case bluetoothSignal(dBm: Int?, after: Duration)
    /// The hand-off's Bluetooth link dropped (`afterWrite`: CC08 had been written, or may have been); the session connects
    /// again, try `reconnect`.
    case bluetoothDropped(afterWrite: Bool, reconnect: Int)
    /// A hand-off (connect included) gave the network's details, `after` since it began. `rewrite`: it was a rewrite after
    /// the camera's Wi-Fi went off during the join. `windowLeft`: what is left of the camera's 50 s from status 2 (an upper
    /// bound when `statusTwoAlready`: the status read 2 before the hand-off looked).
    case handoffFinished(after: Duration, rewrite: Bool, wroteWiFiOn: Bool, statusTwoAlready: Bool, windowLeft: Duration)
    /// The join's `apply` number `attempt` returned `after` since it was called (iOS's prompt included), or threw `failure`.
    case joinApplied(attempt: Int, after: Duration, failure: JoinFailure?)
    /// The camera's gateway appeared (or not) `after` since the wait for it began.
    case gateway(found: Bool, after: Duration)
    /// After a join that didn't reach the gateway (or one that returned after the camera's 50 s), the session looked at the
    /// camera: what it found, whether the camera's 50 s from status 2 had passed, and what it decided (`off`: switch the
    /// camera's Wi-Fi on again).
    case cameraWiFiChecked(CameraWiFiCheck, windowPassed: Bool, off: Bool)
    /// Rewriting CC08 after the camera's Wi-Fi went off during the join: rewrite `number` of `limit`.
    case rewriteStarted(number: Int, limit: Int)
    /// With the app away (recovery), iOS rejoined the camera's network by itself (or not) `after` since the wait began.
    case rejoinedWhileAway(found: Bool, after: Duration)
    /// The camera's session opened on try `tries`, `after` since the first try. `reopening`: the link may reopen with what
    /// it knows (no CC08 since the last session).
    case sessionOpened(after: Duration, tries: Int, reopening: Bool)
    /// The camera's session didn't open: `refused` (a failure trying again won't fix) or every try failed in the time given.
    case sessionNotOpened(after: Duration, tries: Int, refused: Bool)
    /// The preparation ended, ready (`succeeded`) or not, with the time in each step.
    case preparationEnded(succeeded: Bool, times: WirelessStepTimes)

    // MARK: The hand-off (`WiFiHandoff`), times since that hand-off run began (after the connect; from 0 again after a
    // reconnect and on each rewrite)

    /// CC09's Wi-Fi status changed (the first reading included): 0 off, 1 starting, 2 on, 3 stopping, as the camera sends
    /// it; nil when a value didn't give one.
    case handoffStatus(UInt8?, after: Duration)
    /// CC08 = 0x01 (switch the camera's Wi-Fi on) was written and acknowledged.
    case handoffWroteWiFiOn(after: Duration)
    /// The network's details (CC06 and CC07) were read, on try `tries`. Nothing of them is carried.
    case handoffDetailsRead(after: Duration, tries: Int)

    // MARK: The Wi-Fi link (`IPLink`), times since that open began

    /// The camera answered on its port and the PTP/IP handshake finished. `reopening`, here and in `linkOpened`: the open
    /// used the reopening plan, on this link's earlier session or on a new link configured as reopening.
    case linkConnected(after: Duration, reopening: Bool)
    /// The session opened. `wholeCard`: Sony's whole-card session, which polls until the card lists; `polls` and
    /// `listedAfter` (from the first poll) are that poll's; `pollTimedOut`: it reached its limit first.
    case linkOpened(after: Duration, reopening: Bool, wholeCard: Bool, polls: Int, listedAfter: Duration?, pollTimedOut: Bool)
    /// A keep-alive (GetDeviceInfo) went out: `number` this session, answered OK or not; `idle` since the last command ended;
    /// `sincePrevious` since this session's previous keep-alive went out (nil for the first).
    case keepAlive(number: Int, answered: Bool, idle: Duration, sincePrevious: Duration?)
    /// A partial file's continuation with 0x9211 began at `offset` bytes of `size`.
    case resumeStarted(offset: UInt64, size: UInt64)
    /// The camera refused the first 0x9211 read at `offset`; the file is copied again from 0 with GetObject.
    case resumeRefused(offset: UInt64)
    /// A continuation with 0x9211 finished the file, with `reads` 0x9211 reads.
    case resumeFinished(reads: Int)
    /// The open session ended under the link: the connection's failure, or nil when the camera answered SessionNotOpen.
    case linkLost(PTPIPConnectionFailure?)
    /// The link was closed; what it saw over its life.
    case linkClosed(IPLinkDiagnostics)
}
