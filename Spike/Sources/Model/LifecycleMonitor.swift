import Foundation
import Observation
import UIKit

/// Day 5: what happens to a transfer when the phone locks or the user switches apps? Records when the app went
/// to the background and when the device locked, lets long-running work report progress, and on return to the
/// foreground logs `<link>.lifecycle.progressAfterBackground`: how long work kept making progress after leaving
/// the foreground. That fills the "Session survives phone lock (seconds)" row of the measurements table.
@Observable
@MainActor
final class LifecycleMonitor {
    private(set) var backgroundedAt: Date?
    private(set) var lockedAt: Date?
    private(set) var lastProgressAt: Date?
    private(set) var lastProgressNote = ""
    /// Measurement prefix of the link that last made progress: "usb", "ptpip.ap" or "ptpip.lan".
    private(set) var lastProgressLink = "usb"
    var log: SpikeLog?

    private var observers: [NSObjectProtocol] = []
    /// Whether a transfer was making progress when the app left the foreground (see `activeWindow`).
    private var transferWasActive = false
    /// When the last operation (a button's run) ended: progress from before then is a finished operation's.
    private var lastOperationEndAt: Date?
    /// Transfers (downloads, resumable reads) running now, and the link of the latest to start: a transfer locked
    /// before its first file finishes has reported no progress yet but is still running.
    private var runningTransfers = 0
    private var runningLink = "usb"
    /// Times the app has come back to the foreground, and how long it was away the last time: the guided runner
    /// waits on these for "lock the phone" and "switch apps" steps.
    private(set) var foregroundReturns = 0
    private(set) var lastAwaySeconds: Double = 0
    private(set) var backgroundEntries = 0
    /// Progress this recent when the app is backgrounded means a transfer was running.
    private static let activeWindow: TimeInterval = 60

    init() {
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (LifecycleMonitor) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            })
        }
        on(UIApplication.didEnterBackgroundNotification) { $0.enteredBackground() }
        on(UIApplication.willEnterForegroundNotification) { $0.enteringForeground() }
        on(UIApplication.protectedDataWillBecomeUnavailableNotification) { $0.locked() }
        on(UIApplication.protectedDataDidBecomeAvailableNotification) { $0.unlocked() }
    }

    /// "foreground", "background +12.3 s", "locked +5.0 s": appended to progress log lines.
    var stateDescription: String {
        if let lockedAt { return String(format: "locked +%.1f s", Date().timeIntervalSince(lockedAt)) }
        if let backgroundedAt { return String(format: "background +%.1f s", Date().timeIntervalSince(backgroundedAt)) }
        return "foreground"
    }

    var isInForeground: Bool { backgroundedAt == nil }

    /// Long-running work calls this after each unit (file, chunk) completes. `link` is the measurement prefix
    /// ("usb", "ptpip.ap", "ptpip.lan") so the result lands in the right column of the measurements table.
    func noteProgress(_ what: String, link: String) {
        lastProgressAt = Date()
        lastProgressNote = what
        lastProgressLink = link
        if !isInForeground { log?.note("progress while \(stateDescription): \(what)") }
    }

    /// An operation finished (or failed or stopped). Without this, a listing that ended seconds before the phone
    /// was locked counted as a transfer that made no progress while away (1 Nov 23:39, a false 0.00 s).
    func operationEnded() {
        lastOperationEndAt = Date()
    }

    /// A download or resumable read started on `link` ("usb", "ptpip.ap", "ptpip.lan"); pair with transferEnded().
    func transferStarted(link: String) {
        runningTransfers += 1
        runningLink = link
    }

    func transferEnded() {
        runningTransfers = max(0, runningTransfers - 1)
    }

    private func enteredBackground() {
        let now = Date()
        backgroundedAt = now
        backgroundEntries += 1
        // A transfer counts as running if it reported progress in the last minute (Wi-Fi reports once per file) and
        // no operation has ended since: only then does "no progress while away" mean the session died, rather than
        // that nothing was running.
        let recent = lastProgressAt.map { now.timeIntervalSince($0) < Self.activeWindow } ?? false
        let endedSince = lastProgressAt.map { progress in lastOperationEndAt.map { $0 >= progress } ?? false } ?? false
        transferWasActive = runningTransfers > 0 || (recent && !endedSince)
        // A 0 s result belongs in the running transfer's column even before it has reported progress.
        if runningTransfers > 0 { lastProgressLink = runningLink }
        log?.note("app entered background" + (transferWasActive ? " during a transfer" : ""))
    }

    private func locked() {
        lockedAt = Date()
        log?.note("device locked (protected data unavailable)")
    }

    private func unlocked() {
        log?.note("device unlocked" + (lockedAt.map { String(format: " after %.1f s", Date().timeIntervalSince($0)) } ?? ""))
        lockedAt = nil
    }

    private func enteringForeground() {
        guard let since = backgroundedAt else { return }
        let away = Date().timeIntervalSince(since)
        log?.note(String(format: "app returning to foreground after %.1f s", away))
        lastAwaySeconds = away
        foregroundReturns += 1
        if let last = lastProgressAt, last > since {
            log?.measure("\(lastProgressLink).lifecycle.progressAfterBackground", last.timeIntervalSince(since), "s",
                         context: String(format: "away %.0f s; last: %@", away, lastProgressNote))
        } else if transferWasActive {
            log?.measure("\(lastProgressLink).lifecycle.progressAfterBackground", 0, "s",
                         context: String(format: "no progress while away (%.0f s)", away))
        } else if lastProgressAt != nil {
            log?.note("no transfer running when the app left; nothing recorded")
        }
        backgroundedAt = nil
        transferWasActive = false
    }
}
