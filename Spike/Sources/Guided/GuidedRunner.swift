import SwiftUI
import UIKit
import ImageCaptureCore

/// What the tester is asked to do, or wait for, shown as an alert over whichever tab is open.
struct GuidedPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Buttons besides "Cancel run". Empty for a waiting alert, which closes itself when its condition is met.
    let buttons: [String]
    /// Offer "Cancel run" (every alert during a run; not the notice at its end).
    let allowsCancel: Bool
}

/// The tester tapped "Cancel run".
struct GuidedCancelled: Error {}

/// A section can't go on (no camera, the session didn't open); the run moves to the next section.
struct GuidedStop: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// One guided run on the Guided tab: a sequence of the spike's own test functions, with alerts for the physical
/// steps in between (change the camera's USB mode, pull the cable, lock the phone, press the shutter). Where the app
/// can see the step happen (the cable pulled, the camera back, the app back in front) the alert closes by itself.
struct GuidedScript: Identifiable {
    let id: String
    let group: String
    let title: String
    let summary: String
    let run: @MainActor (GuidedRunner) async throws -> Void
}

/// A flag a Task can set and a polling loop can read.
@MainActor
final class GuidedFlag {
    var value = false
}

/// Runs guided scripts and owns the alert they show. Each run logs "◆" lines, and at the end its log entries and the
/// measurements table go on the clipboard, ready to paste into the chat.
@Observable
@MainActor
final class GuidedRunner {
    static let cancelLabel = "Cancel run"

    private(set) var runningTitle: String?
    private(set) var step = ""
    /// The steps of the current or last run, for the Guided tab.
    private(set) var steps: [String] = []
    private(set) var prompt: GuidedPrompt?
    private(set) var lastReport: String?
    /// A step the tester does in another tab (scan the QR code, type an IP): shown on the Guided tab with Done and
    /// Skip, not as an alert, so the other tabs stay usable.
    private(set) var pending: PendingStep?

    struct PendingStep: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @ObservationIgnored let log: SpikeLog
    @ObservationIgnored let browser: DeviceBrowser
    @ObservationIgnored let usb: USBLab
    @ObservationIgnored let wireless: WirelessLab
    @ObservationIgnored let scanner: AdvertisementScanner
    @ObservationIgnored let continued: ContinuedTask
    @ObservationIgnored let lifecycle: LifecycleMonitor
    @ObservationIgnored let proximity: ProximityWatcher
    /// Build 10: switches the camera's Wi-Fi on over Bluetooth and reads its network name and password.
    @ObservationIgnored let handover: SonyWiFiHandover
    @ObservationIgnored private var continuation: CheckedContinuation<String, Never>?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var pendingAnswer: String?
    /// When the last alert closed: the next one waits until 450 ms after it, so SwiftUI sees the old one go first.
    @ObservationIgnored private var closedAt = Date.distantPast
    /// Build 13: a Wi-Fi run switched the camera's Wi-Fi on over Bluetooth (joinCameraOverBluetooth), so the Bluetooth
    /// link and its notifications stay up until the run ends (the Wi-Fi may go off when the link closes); the end of
    /// the run, however it ends, turns the notifications off and disconnects (releaseKeptBluetooth).
    @ObservationIgnored var keepsBluetoothUntilRunEnds = false

    init(log: SpikeLog, browser: DeviceBrowser, usb: USBLab, wireless: WirelessLab, scanner: AdvertisementScanner,
         continued: ContinuedTask, lifecycle: LifecycleMonitor, proximity: ProximityWatcher,
         handover: SonyWiFiHandover) {
        self.log = log
        self.browser = browser
        self.usb = usb
        self.wireless = wireless
        self.scanner = scanner
        self.continued = continued
        self.lifecycle = lifecycle
        self.proximity = proximity
        self.handover = handover
    }

    var isRunning: Bool { runningTitle != nil }

    // MARK: - Running a script

    func start(_ script: GuidedScript) {
        guard runningTitle == nil else { return }
        if usb.isBusy || wireless.busy || continued.isRunning || handover.busy {
            log.warn("Guided run \(script.title): another operation is running; wait for it or stop it first")
            return
        }
        runningTitle = script.title
        steps = []
        step = ""
        cancelled = false
        lastReport = nil
        startedAt = Date()
        log.note("◆ Guided run: \(script.title)")
        Task {
            var outcome = "finished"
            do {
                try await script.run(self)
            } catch is GuidedCancelled {
                outcome = "cancelled"
                stopRunningWork()
            } catch let stop as GuidedStop {
                outcome = "stopped: \(stop.reason)"
            } catch {
                outcome = "failed: \(error)"
            }
            // Finish, Cancel run or an error alike: a Bluetooth link kept for the run is released here.
            await releaseKeptBluetooth()
            log.note("◆ Guided run \(outcome): \(script.title)")
            let report = makeReport()
            UIPasteboard.general.string = report
            lastReport = report
            runningTitle = nil
            step = ""
            await present(GuidedPrompt(title: "Run \(outcome.hasPrefix("finished") ? "finished" : outcome)",
                                       message: "This run's log and the measurements table are on the clipboard. Paste them into the chat.",
                                       buttons: ["OK"], allowsCancel: false))
        }
    }

    /// From "Cancel run" on an alert or the Guided tab.
    func requestCancel() {
        guard runningTitle != nil, !cancelled else { return }
        cancelled = true
        log.warn("◆ Guided run: cancel requested")
        stopRunningWork()
        if let prompt { answer(Self.cancelLabel, for: prompt.id) }
        pendingAnswer = Self.cancelLabel
    }

    /// The alert's buttons call this.
    func answer(_ button: String, for id: UUID) {
        guard prompt?.id == id else { return }
        if button == Self.cancelLabel {
            cancelled = true
            if runningTitle != nil { log.warn("◆ Guided run: cancel requested") }
            stopRunningWork()
        }
        finishPrompt(with: button)
    }

    private func stopRunningWork() {
        if usb.isBusy { usb.session?.requestStop() }
        if continued.isRunning { continued.stop() }
        if scanner.isScanning { scanner.stop() }
        if wireless.busy { log.warn("◆ A Wi-Fi operation is still running; it ends on its own (the Wi-Fi tab has no Stop)") }
    }

    /// The end of a run that kept the Bluetooth link up (keepsBluetoothUntilRunEnds): every notification turned off,
    /// waiting for the camera's answers when no other Bluetooth operation is running (Disconnect turns any left off
    /// without waiting), then Bluetooth disconnects. Shows no alert, so it works after "Cancel run" too.
    private func releaseKeptBluetooth() async {
        guard keepsBluetoothUntilRunEnds else { return }
        keepsBluetoothUntilRunEnds = false
        guard handover.isConnected || handover.busy else {
            log.note("◆ The Bluetooth link kept for this run (the camera's Wi-Fi was switched on over it) is already down")
            // No Disconnect here: there is no link to end, and these codes stay listed for the next Bluetooth connect's
            // unsubscribe, which clears them (build 14: Disconnect keeps them too).
            if !handover.earlierLinkCodes.isEmpty {
                log.warn("◆ Notifications this app turned on (\(handover.earlierLinkCodes.joined(separator: ", "))) couldn't be turned off: the link dropped; the camera may keep them on for this phone until the next Bluetooth connect turns them off")
            }
            return
        }
        if handover.isConnected && !handover.busy && (handover.notifyingCount > 0 || !handover.earlierLinkCodes.isEmpty) {
            do {
                let left = try await handover.unsubscribeAll()
                log.note("◆ Notifications off at the end of the run: \(left.isEmpty ? "all confirmed" : "not confirmed: \(left.joined(separator: ", "))")")
            } catch {
                log.warn("◆ Turning the notifications off at the end of the run didn't finish (\(SonyWiFiHandover.errorName(error))); Disconnect turns any left off without waiting")
            }
        }
        handover.disconnect()
        log.note("◆ Bluetooth link kept for this run (the camera's Wi-Fi was switched on over it) disconnected (\(handover.status))")
    }

    private func makeReport() -> String {
        let entries = log.entries.filter { $0.at >= startedAt }
        let serviceUUID = UserDefaults.standard.string(forKey: ProximityWatcher.Keys.serviceUUID) ?? ""
        return log.plainText(entries, device: DeviceContext.current())
            + "\n\n" + log.measurementsTableMarkdown(serviceUUID: serviceUUID.isEmpty ? nil : serviceUUID)
    }

    // MARK: - Alerts

    private func finishPrompt(with answer: String) {
        let waiting = continuation
        continuation = nil
        if prompt != nil { closedAt = Date() }
        prompt = nil
        waiting?.resume(returning: answer)
    }

    /// Replaces any alert on screen (giving the old one time to go), then shows `p` and waits for a button.
    private func present(_ p: GuidedPrompt) async -> String {
        await replaceAlert()
        return await withCheckedContinuation { c in
            continuation = c
            prompt = p
        }
    }

    /// Closes any alert on screen, then waits until 450 ms after the last one closed (however it closed), so SwiftUI
    /// dismisses it before the next is set; replacing one alert with another in the same turn leaves the old one up.
    private func replaceAlert() async {
        // Loops because a notice can take the screen while this one sleeps; it is closed and waited out in turn.
        while true {
            if prompt != nil { finishPrompt(with: "") }
            let wait = closedAt.addingTimeInterval(0.45).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if prompt == nil { return }
        }
    }

    private func checkCancelled() throws {
        if cancelled { throw GuidedCancelled() }
    }

    // MARK: - Primitives for scripts

    /// A step of the run: shown on the Guided tab and logged.
    func step(_ text: String) {
        step = text
        steps.append(text)
        log.note("◆ \(text)")
    }

    /// Shows an alert and returns the button tapped; "Cancel run" throws GuidedCancelled.
    @discardableResult
    func ask(_ title: String, _ message: String, buttons: [String] = ["OK"]) async throws -> String {
        try checkCancelled()
        let answer = await present(GuidedPrompt(title: title, message: message, buttons: buttons, allowsCancel: true))
        try checkCancelled()
        log.note("  guided: \(title) → \(answer)")
        return answer
    }

    /// Shows a waiting alert (only "Cancel run") until `condition` holds, polling four times a second; false after
    /// `timeout` seconds. The alert closes by itself.
    @discardableResult
    func waitUntil(_ title: String, _ message: String, timeout: Double,
                   _ condition: @escaping @MainActor () -> Bool) async throws -> Bool {
        try checkCancelled()
        if condition() { return true }
        await replaceAlert()
        let waiting = GuidedPrompt(title: title, message: message, buttons: [], allowsCancel: true)
        prompt = waiting
        let deadline = Date().addingTimeInterval(timeout)
        var met = false
        while !cancelled {
            if condition() { met = true; break }
            if Date() > deadline { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if prompt?.id == waiting.id {
            prompt = nil
            closedAt = Date()
        }
        try checkCancelled()
        if !met { log.warn("  guided: \(title): not done after \(Int(timeout)) s") }
        return met
    }

    /// A notice that doesn't block the run (PULL NOW): it replaces the alert on screen, and the next alert replaces
    /// it in turn.
    func notice(_ title: String, _ message: String) {
        guard runningTitle != nil, !cancelled else { return }
        // Only a waiting alert (no continuation) may give way; an alert waiting for a button keeps the screen.
        guard continuation == nil else { return }
        Task {
            if prompt != nil && continuation == nil {
                prompt = nil
                closedAt = Date()
            }
            let wait = closedAt.addingTimeInterval(0.45).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard runningTitle != nil, !cancelled, prompt == nil, continuation == nil else { return }
            prompt = GuidedPrompt(title: title, message: message, buttons: ["OK"], allowsCancel: false)
        }
    }

    /// The Guided tab's Done and Skip buttons for a pending step.
    func answerPending(_ answer: String) {
        pendingAnswer = answer
    }

    /// A step done in another tab: listed on the Guided tab until `condition` holds or the tester taps Done or Skip
    /// there. Returns "met", "Done", "Skip" or "timeout".
    @discardableResult
    func waitInTabs(_ title: String, _ message: String, timeout: Double,
                    _ condition: @escaping @MainActor () -> Bool) async throws -> String {
        try checkCancelled()
        if condition() { return "met" }
        await replaceAlert()
        pendingAnswer = nil
        pending = PendingStep(title: title, message: message)
        log.note("  guided: \(title) (waiting on the Guided tab)")
        defer { pending = nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !cancelled {
            if condition() { return "met" }
            if let answer = pendingAnswer {
                log.note("  guided: \(title) → \(answer)")
                return answer
            }
            if Date() > deadline { return "timeout" }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw GuidedCancelled()
    }

    /// A part of a longer run the tester can start or skip. A GuidedStop inside it ends only this section.
    func section(_ title: String, _ intro: String, _ body: () async throws -> Void) async throws {
        let choice = try await ask(title, intro, buttons: ["Start", "Skip"])
        guard choice == "Start" else {
            log.note("◆ \(title): skipped")
            return
        }
        step(title)
        if keepsBluetoothUntilRunEnds {
            log.note("  guided: \(title): the Bluetooth link with Sony's notifications is still up (the camera's Wi-Fi was switched on over Bluetooth earlier in this run), so this section's Wi-Fi measurements are taken with it up; its notifications can wake this app in the background")
        }
        do {
            try await body()
        } catch let stop as GuidedStop {
            log.warn("◆ \(title) stopped: \(stop.reason)")
            try await ask("\(title) stopped", stop.reason, buttons: ["Continue"])
        }
    }
}
