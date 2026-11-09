import CameraTransport
import Catalogue
import Foundation
import Observation

// The proximity scan's app side (Iteration 4, section 11; wireless plan, W17): it confirms each report against the catalogue's
// cameras, keeps when each camera was last nearby, hands every confirmed arrival on for the reminder rules (W18), and drives the
// scan's restarts from wakes (`ProximityRestartRules`). Plain Swift and Foundation, so it is tested on Linux against a fake
// scanner and fixed dates. The live scanner is `BluetoothCentral`; the app-refresh task is `BackgroundRefreshScheduler`
// (Apple-only, `ProximityRefreshTask.swift`). Wiring both into the app (launch, scene phase, the reminder setting) is W16/W18's.

/// Asks iOS for the app-refresh task that restarts the proximity scan (`BGAppRefreshTaskRequest`; decided 9 Nov: background
/// app refresh). The app's is `BackgroundRefreshScheduler`; tests record the asks.
public protocol ProximityRefreshScheduling: Sendable {
    /// Asks iOS to run the refresh task no earlier than `date`, replacing any earlier ask; nil cancels it. iOS decides when,
    /// or whether, it runs. It never waits: the ask may reach iOS later (`settle(within:)`).
    func scheduleRefresh(earliest date: Date?)

    /// Waits, for at most `limit`, until the asks made so far have reached iOS and iOS has accepted or refused them. The
    /// refresh task calls it before it ends: iOS may suspend the app once the task is complete, and the next ask mustn't be
    /// left on its way. Does nothing by default.
    func settle(within limit: Duration) async
}

extension ProximityRefreshScheduling {
    public func settle(within limit: Duration) async {}
}

/// A known camera reported nearby, for the reminder rules (W18). The time is the report's.
public struct ProximityArrival: Sendable, Equatable {
    public let camera: CameraKey
    public let report: ProximityReport
    public let match: ProximityConfirmer.Match

    public init(camera: CameraKey, report: ProximityReport, match: ProximityConfirmer.Match) {
        self.camera = camera
        self.report = report
        self.match = match
    }
}

/// The copy the reminder's settings show about the scan's limits (backlog section 11). British English; "nearby", never
/// "switched on" (decision 8).
public enum ProximityWording {
    /// iOS doesn't relaunch an app the person swipes away (per Apple; untested), so the scan stops with it.
    public static let swipeAwayStops =
        "If you swipe Shutter Bridge away in the app switcher, reminders stop until you next open it."
    /// Low Power Mode didn't stop background discovery in the two runs that had it on (3 and 4 to 5 Nov); the copy says "may
    /// stop" until it is tested on purpose (decision-pack.md, 3.12).
    public static let lowPowerMayStop = "Low Power Mode may stop reminders."
    /// The camera advertised while off with *Remote Power ON/OFF* On; with it Off it is untested, so the setup names it.
    public static let cameraSetting =
        "On the camera, turn on Bluetooth Function and Remote Power ON/OFF so it can be noticed nearby while it's off."
}

/// The proximity scan's model: off until the reminder is switched on (decided 9 Nov: off by default).
///
/// - **Confirm** each report (`ProximityConfirmer`, against `setKnownCameras(_:)`): a confirmed one updates `lastNearby` and
///   is sent on `arrivals`; anything else is ignored. Nothing logged names the camera, the peripheral or the manufacturer data.
/// - **Restart** from wakes only (`ProximityRestartRules`): reports, Bluetooth coming back on, `appBecameActive()` and
///   `refreshTaskRan()`. After a known camera is reported, the app-refresh task is asked for when the scan may be re-armed.
@MainActor
@Observable
public final class ProximityModel {
    /// The app-refresh task's identifier, as `BGTaskSchedulerPermittedIdentifiers` in App/Info.plist lists it.
    public nonisolated static let refreshTaskIdentifier = "net.shamil.shutter-bridge.proximity-refresh"

    /// Whether the scan is wanted (the reminder is on). False until `setEnabled(_:)` is first called, which always acts.
    public private(set) var isEnabled = false
    /// The phone's Bluetooth, as the scanner last reported it.
    public private(set) var power: BluetoothPower = .unknown
    /// When each known camera was last reported nearby, by this run of the app.
    public private(set) var lastNearby: [CameraKey: Date] = [:]

    /// Every confirmed report while the scan is wanted. One reader (the reminder rules, W18); the newest 32 are kept for it.
    @ObservationIgnored public let arrivals: AsyncStream<ProximityArrival>

    @ObservationIgnored private let arrivalSink: AsyncStream<ProximityArrival>.Continuation
    @ObservationIgnored private let scanner: any ProximityScanning
    @ObservationIgnored private let refresh: any ProximityRefreshScheduling
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private var rules: ProximityRestartRules
    @ObservationIgnored private var confirmer = ProximityConfirmer(known: [])
    /// What was last asked of the refresh scheduler: nil before the first ask, `.some(nil)` after a cancel.
    @ObservationIgnored private var askedRefresh: Date??
    /// Whether `setEnabled(_:)` has been called: until then the setting is undecided, and reports are held, not dropped.
    @ObservationIgnored private var isDecided = false
    /// Reports that arrived before the setting was decided (the one that relaunched the app, say), the newest 16, handled
    /// when it is switched on and dropped when it is switched off.
    @ObservationIgnored private(set) var heldReports: [ProximityReport] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - scanner: `BluetoothCentral` in the app.
    ///   - refresh: `BackgroundRefreshScheduler` in the app.
    ///   - now: the wall clock (fixed dates in tests).
    ///   - rearmAfter: `ProximityTiming.rearmAfterReport` unless a test says otherwise.
    public init(scanner: any ProximityScanning, refresh: any ProximityRefreshScheduling,
                now: @escaping @Sendable () -> Date = { Date() }, log: any BenchLog = SilentBenchLog(),
                rearmAfter: Duration = ProximityTiming.rearmAfterReport) {
        self.scanner = scanner
        self.refresh = refresh
        self.now = now
        self.log = log
        rules = ProximityRestartRules(rearmAfter: rearmAfter)
        (arrivals, arrivalSink) = AsyncStream.makeStream(of: ProximityArrival.self, bufferingPolicy: .bufferingNewest(32))
    }

    deinit {
        // The reading tasks hold the model weakly and end at their next element.
        arrivalSink.finish()
    }

    /// Starts reading the scanner's reports and Bluetooth state. Call once, early at launch (a relaunch for the scan delivers
    /// its report within about 70 ms; the scanner holds reports until this reads them). Reports read before the first
    /// `setEnabled(_:)` are held for it, so this may run before the setting can be read. Calling it again does nothing.
    public func launch() {
        guard tasks.isEmpty else { return }
        let reports = scanner.proximityReports
        let powers = scanner.powerState
        tasks.append(Task { [weak self] in
            for await report in reports {
                guard let self else { return }
                await self.handle(report)
            }
        })
        tasks.append(Task { [weak self] in
            for await state in powers {
                guard let self else { return }
                await self.handle(power: state)
            }
        })
    }

    /// The catalogue's cameras, for the confirmation. Call at launch and whenever a camera is added or its Bluetooth
    /// identifier stored.
    public func setKnownCameras(_ cameras: [CameraRecord]) {
        confirmer = ProximityConfirmer(known: cameras.map {
            KnownCamera(key: $0.key.rawValue, peripheral: $0.bluetoothPeripheralID.map(PeripheralID.init), model: $0.model)
        })
    }

    /// Switches the scan on or off with the reminder (W18 owns the setting). Call with the stored setting at launch, once it
    /// can be read. The first call always acts: on starts the scan (keeping one iOS handed back) and handles the reports held
    /// until then; off stops the scan (so one iOS handed back no longer wakes the app), drops them and cancels the refresh.
    /// Later calls act only on a change.
    public func setEnabled(_ on: Bool) async {
        guard !isDecided || on != isEnabled else { return }
        isDecided = true
        isEnabled = on
        let held = heldReports
        heldReports = []
        if on {
            log.note("proximity: scan switched on")
            await apply(rules.handle(.enabled, at: now()))
            for report in held { await handle(report) }
        } else {
            log.note("proximity: scan switched off")
            rules.reset()
            await scanner.stopProximityScan()
            askRefresh(nil)
        }
    }

    /// The app came to the front: restart the scan, so cameras in range are reported afresh.
    public func appBecameActive() async {
        guard isEnabled else { return }
        await apply(rules.handle(.foreground, at: now()))
    }

    /// The app-refresh task ran (`BackgroundRefreshScheduler`): restart the scan if a re-arm is due, and ask for the next one.
    /// Returns once that ask has reached iOS, or after `refreshSettleLimit`.
    public func refreshTaskRan() async {
        // Running the task uses up the request, and an earlier submit may have failed: ask again even for the same date.
        askedRefresh = nil
        if isEnabled {
            await apply(rules.handle(.refreshTask, at: now()))
        } else {
            askRefresh(nil)
        }
        // The task is completed when this returns, and iOS may suspend the app then: the ask above goes to iOS
        // asynchronously (`submitTaskRequest`), so wait for it, or the chain of refreshes could stop here.
        await refresh.settle(within: Self.refreshSettleLimit)
    }

    /// How long the refresh task waits for its ask to reach iOS before it ends anyway; well inside the time iOS gives an
    /// app-refresh task (about 30 s, Apple's documentation). `unverified` how long `submitTaskRequest` takes on a device.
    public nonisolated static let refreshSettleLimit: Duration = .seconds(5)

    // MARK: Events (internal for tests)

    func handle(_ report: ProximityReport) async {
        guard isDecided else {
            heldReports.append(report)
            if heldReports.count > 16 { heldReports.removeFirst(heldReports.count - 16) }
            return
        }
        guard isEnabled else { return }
        let at = now()
        guard let confirmation = confirmer.confirm(report) else {
            log.note("proximity: ignored a report that isn't a known camera (\(report.source == .advertisement ? "advertisement" : "connection event"))")
            await apply(rules.handle(.otherReported, at: at))
            return
        }
        let camera = CameraKey(rawValue: confirmation.camera.key)
        lastNearby[camera] = report.at
        log.note("proximity: known camera nearby, confirmed by \(confirmation.match) at \(Self.time(report.at)), \(report.rssi.map { "RSSI \($0) dBm" } ?? "no RSSI")")
        arrivalSink.yield(ProximityArrival(camera: camera, report: report, match: confirmation.match))
        await apply(rules.handle(.cameraReported, at: at))
    }

    func handle(power state: BluetoothPower) async {
        let previous = power
        power = state
        guard isEnabled, state == .poweredOn, previous != .poweredOn else { return }
        await apply(rules.handle(.bluetoothPoweredOn, at: now()))
    }

    // MARK: Private

    private func apply(_ decision: ProximityScanDecision) async {
        switch decision.action {
        case .none: break
        case .start: await scanner.startProximityScan()
        case .restart:
            log.note("proximity: scan restarted")
            await scanner.restartProximityScan()
        }
        askRefresh(decision.refreshAt)
    }

    private func askRefresh(_ date: Date?) {
        if let asked = askedRefresh, asked == date { return }
        askedRefresh = .some(date)
        refresh.scheduleRefresh(earliest: date)
    }

    /// A report's time for the log, to the second, in UTC (the time is what the option (d) comparison needs, W18).
    private static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
