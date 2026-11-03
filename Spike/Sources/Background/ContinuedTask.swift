import Foundation
import Observation
import BackgroundTasks
import UIKit

/// Day 5: does a user-started transfer keep running when the phone locks, if it is wrapped in a
/// BGContinuedProcessingTask (iOS 26+)? `run` submits one request and executes the caller's work inside it once
/// the system starts it, reporting progress to the system UI and recording when (if) the system expires it.
/// The Background tab's timer test needs no camera; the Wired and Wi-Fi tabs wrap real downloads with it.
@Observable
@MainActor
final class ContinuedTask {
    static let identifier = "net.shamil.shutter-bridge.spike.import"

    private(set) var state = "idle"
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var isRunning = false
    private(set) var expired = false
    /// Build 14: the units of the running (or latest) task are bytes (the copies), so the state row shows GB.
    private(set) var byteUnits = false
    /// Build 14: when the system expired the latest task, and the conditions then (iOS gives no reason): locked, app
    /// in front, Low Power Mode, thermal state, battery, seconds since the last progress update, bytes per second over
    /// the last 30 s. Nil until an expiry.
    private(set) var expiredAt: Date?
    private(set) var expiryConditions: String?
    var log: SpikeLog?
    /// Build 14: called on the main actor right after an expiry is noted, so the work can cut off what is in flight
    /// (the copies abort the file being fetched). Cleared when the task ends.
    @ObservationIgnored var onExpire: (@MainActor () -> Void)?
    /// Build 14: when `report` last moved the progress, and recent (time, units) reports for the rate at an expiry.
    @ObservationIgnored private var lastReportAt: ContinuousClock.Instant?
    @ObservationIgnored private var reports: [(at: ContinuousClock.Instant, units: Int)] = []

    /// The work the launch handler runs. Set just before a request is submitted; one task at a time.
    nonisolated(unsafe) private static var pending: (@Sendable (BGContinuedProcessingTask) -> Void)?

    /// Call before the app finishes launching (SpikeApp.init).
    static func registerLaunchHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            if let work = pending { pending = nil; work(continued) } else { continued.setTaskCompleted(success: false) }
        }
    }

    /// Reports one more unit done (and optionally a new subtitle) from inside `work`.
    typealias Report = @MainActor (_ completedUnits: Int, _ subtitle: String?) -> Void
    /// True once the system has expired the task or the user stopped it; `work` should checkpoint and return.
    typealias ShouldStop = @MainActor () -> Bool

    /// Submits a continued-processing request and, once the system starts it, runs `work` inside it. `work`
    /// returns whether it finished. Must be called from a user action (a button tap). `byteUnits` (build 14): the
    /// units are bytes, for the state row ("4.3 of 11.5 GB").
    func run(title: String, subtitle: String, totalUnits: Int, byteUnits: Bool = false,
             work: @escaping @MainActor (_ report: @escaping Report, _ shouldStop: @escaping ShouldStop) async -> Bool) {
        guard !isRunning else { log?.warn("a continued task is already running"); return }
        total = max(totalUnits, 1)
        completed = 0
        expired = false
        self.byteUnits = byteUnits
        expiredAt = nil
        expiryConditions = nil
        lastReportAt = nil
        reports = []
        isRunning = true
        state = "submitting"
        let submittedAt = Date()

        Self.pending = { [weak self] task in
            Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                await self.execute(task, title: title, submittedAt: submittedAt, work: work)
            }
        }

        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: title, subtitle: subtitle)
        // .fail: start now or tell us immediately; .queue would let the system defer it, which we don't want for a tap.
        request.strategy = .fail
        // iOS 27 deprecates submit(_:) for submitTaskRequest, which reports every error condition (identifier not
        // permitted, too many pending, background refresh off, not eligible to run now). The launch handler may
        // run before this await returns; `pending` is already set, so that is fine.
        Task { @MainActor [weak self] in
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
                self?.log?.note("BGContinuedProcessingTaskRequest submitted: \(title)")
            } catch {
                Self.pending = nil
                self?.isRunning = false
                self?.state = "submit failed"
                self?.log?.error("BGContinuedProcessingTask submit failed: \(error) (the Simulator has no scheduler; test on the device)")
            }
        }
    }

    private func execute(_ task: BGContinuedProcessingTask, title: String, submittedAt: Date,
                         work: @MainActor (_ report: @escaping Report, _ shouldStop: @escaping ShouldStop) async -> Bool) async {
        let startedAt = Date()
        // Stop may have been tapped while the request was still submitting: keep it, so shouldStop ends the work.
        if state != "stopped" { state = "running" }
        log?.measure("bgcontinued.startLatency", startedAt.timeIntervalSince(submittedAt), "s", context: title)
        log?.note("BGContinuedProcessingTask started (\(title)); lock the phone now")
        task.progress.totalUnitCount = Int64(total)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.expired = true
                self.expiredAt = Date()
                // Taken now: by the time the work has wound down, the app may be about to be suspended.
                let conditions = self.conditions()
                self.expiryConditions = conditions
                self.state = "expired by system"
                // The expiration handler also runs when Stop is tapped in the Live Activity (Lock Screen, Dynamic Island).
                self.log?.warn("BGContinuedProcessingTask ended by iOS (an expiry, or Stop in the Live Activity) at \(self.progressText) after \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s (iOS gives no reason; conditions: \(conditions)) — production checkpoints here")
                self.onExpire?()
            }
        }

        let report: Report = { [weak self] done, subtitle in
            guard let self else { return }
            self.completed = min(done, self.total)
            task.progress.completedUnitCount = Int64(self.completed)
            if let subtitle { task.updateTitle(title, subtitle: subtitle) }
            self.noteReport(self.completed)
        }
        let shouldStop: ShouldStop = { [weak self] in
            guard let self else { return true }
            return self.expired || self.state == "stopped"
        }

        let finished = await work(report, shouldStop)
        let ran = Date().timeIntervalSince(startedAt)
        log?.measure("bgcontinued.ran", ran, "s", context: "\(title); finished=\(finished) expired=\(expired)")
        state = finished ? "finished" : (expired ? "expired by system" : "stopped")
        isRunning = false
        onExpire = nil
        task.setTaskCompleted(success: finished)
    }

    /// The state row's progress: "4.3 of 11.5 GB" for a task counted in bytes, "12 of 240" otherwise.
    var progressText: String {
        guard byteUnits else { return "\(completed) of \(total)" }
        return String(format: "%.1f of %.1f GB", Double(completed) / 1e9, Double(total) / 1e9)
    }

    /// Build 14: keeps the time of every progress report and enough of them for the rate over the last 30 s (one
    /// report at or before 30 s ago, and every later one).
    private func noteReport(_ units: Int) {
        let now = ContinuousClock().now
        // Only a report that moved the progress: an unchanged one isn't progress, for iOS or for the expiry's conditions.
        if reports.last?.units != units { lastReportAt = now }
        reports.append((at: now, units: units))
        while reports.count > 1 && (now - reports[1].at).inSeconds >= 30 { reports.removeFirst() }
    }

    /// Build 14: the conditions iOS gives no reason for, for an expiry's log line and measurement context: whether
    /// the phone is locked and the app in front, Low Power Mode, the thermal state, the battery level and charging
    /// state, the seconds since the last progress update, and the rate over the last 30 s (bytes per second for a
    /// task counted in bytes, units otherwise).
    func conditions() -> String {
        let app = UIApplication.shared
        let device = UIDevice.current
        let monitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let charging: String
        switch device.batteryState {
        case .unplugged: charging = "unplugged"
        case .charging: charging = "charging"
        case .full: charging = "full"
        case .unknown: charging = "charging state unknown"
        @unknown default: charging = "charging state unknown"
        }
        device.isBatteryMonitoringEnabled = monitoring
        let now = ContinuousClock().now
        let sinceReport = lastReportAt.map { String(format: "%.1f s since the progress last moved", (now - $0).inSeconds) }
            ?? "the progress hasn't moved yet"
        var rate = "no progress reported"
        // The units 30 s ago: the latest report at or before then (nothing moved between it and then), else the first.
        if let base = reports.last(where: { (now - $0.at).inSeconds >= 30 }) ?? reports.first {
            let span = min(30, (now - base.at).inSeconds)
            if span > 0 {
                let perSecond = Double(completed - base.units) / span
                rate = byteUnits
                    ? String(format: "%.0f bytes/s (%.1f MB/s) over the last %.0f s", perSecond, perSecond / 1e6, span)
                    : String(format: "%.2f units/s over the last %.0f s", perSecond, span)
            }
        }
        let front: String
        switch app.applicationState {
        case .active: front = "app in front"
        case .inactive: front = "app inactive (in front, interrupted)"
        case .background: front = "app in the background"
        @unknown default: front = "app state unknown"
        }
        let battery = level >= 0 ? String(format: "battery %.0f %%", Double(level) * 100) : "battery level unknown"
        return "\(app.isProtectedDataAvailable ? "not locked" : "locked"), \(front), Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"), thermal state \(CopyAllFormat.thermalState()), \(battery) (\(charging)), \(sinceReport), \(rate)"
    }

    /// The camera-free test: `units` steps of 0.5 s each. Start it, then lock the phone.
    func startTimerTest(units: Int = 240) {
        run(title: "Importing from camera (spike)", subtitle: "0 of \(units)", totalUnits: units) { report, shouldStop in
            for i in 1 ... units {
                try? await Task.sleep(for: .milliseconds(500))
                if shouldStop() { return false }
                report(i, i % 20 == 0 ? "\(i) of \(units)" : nil)
            }
            return true
        }
    }

    func stop() {
        guard isRunning else { return }
        state = "stopped"
        log?.note("continued task stop requested")
    }
}
