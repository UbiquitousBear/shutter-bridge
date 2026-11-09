// When the proximity scan is started and restarted (backlog section 11, "Restart the scan from a wake, not a timer"; wireless
// plan, W17). Pure: the rules take the time as an input, so they are tested on Linux with fixed dates, and nothing here sleeps.
//
// Why restarts matter: without duplicates, iOS reports each peripheral once per scan (mostly, while it stays in range; spike,
// 2 to 5 Nov). After the camera has been reported, the scan has to be restarted for its next arrival to be reported. The spike
// restarted on a 60 s timer, which doesn't run while the app is suspended, so every restart in the 2 Nov run happened when the
// app came back to the front. Here a restart happens only at a wake: a report, Bluetooth coming back on, the app coming to the
// front, or the app-refresh task. And a camera that sits in range mustn't wake the app over and over, so after it has been
// reported, the scan waits `ProximityTiming.rearmAfterReport` before a wake restarts it.

import Foundation

/// The proximity scan's one timing, with what it rests on (wireless plan, section 0, item 8).
public enum ProximityTiming {
    /// How long after a known camera was reported the scan waits before a wake restarts it, so the camera can be reported
    /// again. A restart while the camera is still in range reports it at once (1 to 2 s: the advertising gaps measured, about
    /// 1,024 ms on, 2,037 ms asleep, 1,529 ms off), which wakes the app for nothing, so a camera that stays in range wakes it at
    /// most about once per this interval, and only when something else wakes the app (the app-refresh task is asked for this
    /// time).
    ///
    /// `unverified`, a choice: the proposal's 30 minutes, which the backlog keeps as the floor for the reminder's hold
    /// (section 12). The reminder's own 4-hour hold per camera (decided 9 Nov, W18) decides whether a report becomes a
    /// reminder; this only decides how often the scan is re-armed.
    public static let rearmAfterReport: Duration = .seconds(30 * 60)
}

/// What the app does to the scan after an event.
public enum ProximityScanAction: Sendable, Equatable {
    /// Nothing: the scan keeps running as it is.
    case none
    /// Make sure the scan is running, and keep it if it is (the scan iOS handed back after a relaunch included: restarting it
    /// could lose the discovery that woke the app).
    case start
    /// Stop the scan and start it again, so every camera in range is reported afresh.
    case restart
}

/// The rules' answer to one event.
public struct ProximityScanDecision: Sendable, Equatable {
    public var action: ProximityScanAction
    /// When to ask iOS to run the app-refresh task, so a scan waiting to be re-armed gets a wake (nil: none is needed, and any
    /// earlier ask is cancelled). iOS runs it no earlier than this, at a time of its choosing, or not at all.
    public var refreshAt: Date?

    public init(action: ProximityScanAction, refreshAt: Date?) {
        self.action = action
        self.refreshAt = refreshAt
    }
}

/// The restart rules, as a value the app keeps for as long as it runs (the state is one date; a relaunched app starts afresh,
/// which the refresh rule allows for).
///
/// | Event | Action | Why |
/// |---|---|---|
/// | `enabled` | start | The reminder was switched on, or the app launched with it on. |
/// | `cameraReported` | none; re-arm due `rearmAfter` later | The scan has just reported this camera; restarting now would report it again at once. The scan keeps running, so other cameras still get their first report. |
/// | `otherReported` | restart if the re-arm is due | A report the confirmation ignored is still a wake. Each peripheral is reported once per scan, so it doesn't hide the camera. |
/// | `bluetoothPoweredOn` | start | iOS ends the scan with the power; the new scan reports every camera afresh (measured 5 Nov 02:17: the camera reported 0.03 s after the restart). |
/// | `foreground` | restart | The app is awake anyway, so a report costs no wake, and the nearby state comes up to date. |
/// | `refreshTask` | restart, unless a re-arm is waiting and not yet due | The refresh is asked for when the re-arm is due. With nothing waiting, the app has been relaunched and lost its state, so it restarts to be safe. |
///
/// Never from a timer: no rule produces a restart without an event, and nothing here sleeps.
public struct ProximityRestartRules: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The proximity reminder was switched on, or the app launched with it on.
        case enabled
        /// A report confirmed as one of the app's cameras has been handled.
        case cameraReported
        /// A report the confirmation ignored has been handled.
        case otherReported
        /// The phone's Bluetooth came (back) on.
        case bluetoothPoweredOn
        /// The app came to the front.
        case foreground
        /// The app-refresh task ran.
        case refreshTask
    }

    /// How long after a camera's report the scan waits before a wake restarts it.
    public let rearmAfter: Duration
    /// When the scan may be restarted to report a camera again; nil when no camera has been reported since the last
    /// (re)start.
    public private(set) var rearmAt: Date?

    public init(rearmAfter: Duration = ProximityTiming.rearmAfterReport) {
        self.rearmAfter = rearmAfter
    }

    /// Applies one event that happened at `now`.
    public mutating func handle(_ event: Event, at now: Date) -> ProximityScanDecision {
        let action: ProximityScanAction
        switch event {
        case .enabled:
            action = .start
        case .cameraReported:
            let next = now.addingTimeInterval(Self.seconds(rearmAfter))
            rearmAt = max(rearmAt ?? next, next)
            action = .none
        case .otherReported:
            action = isDue(at: now) ? .restart : .none
        case .bluetoothPoweredOn:
            action = .start
        case .foreground:
            action = .restart
        case .refreshTask:
            let waiting = rearmAt.map { $0 > now } ?? false
            action = waiting ? .none : .restart
        }
        // A start after the power came back is a new scan too: Core Bluetooth ends the scan with the power.
        if action == .restart || event == .bluetoothPoweredOn { rearmAt = nil }
        return ProximityScanDecision(action: action, refreshAt: rearmAt)
    }

    /// Forgets the waiting re-arm: the reminder was switched off and the scan stopped.
    public mutating func reset() {
        rearmAt = nil
    }

    private func isDue(at now: Date) -> Bool {
        guard let rearmAt else { return false }
        return rearmAt <= now
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// The proximity scan, as the app's proximity model drives it. `BluetoothCentral` implements it (Apple-only); tests use a fake.
public protocol ProximityScanning: Sendable {
    /// Makes sure the scan for service 1800 is running, without duplicates, with connection events registered (never relied
    /// on). Keeps a running scan, including the one iOS handed back after a relaunch. Returns at once: while Bluetooth isn't
    /// on, the scan starts when it comes on.
    func startProximityScan() async
    /// Stops the scan and starts it again, so every camera in range is reported afresh.
    func restartProximityScan() async
    /// Stops the scan, and the connection events with it.
    func stopProximityScan() async
    /// Every report while the scan runs, unconfirmed. One reader (the proximity model). Reports that arrive before the first
    /// reader are held for it, so the discovery that woke a relaunched app isn't lost.
    var proximityReports: AsyncStream<ProximityReport> { get }
    /// The phone's Bluetooth: a new stream on every access, starting with the state now.
    var powerState: AsyncStream<BluetoothPower> { get }
}
