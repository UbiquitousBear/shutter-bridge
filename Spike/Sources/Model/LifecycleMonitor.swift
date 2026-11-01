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

    private func enteredBackground() {
        let now = Date()
        backgroundedAt = now
        // A transfer counts as running if it reported progress in the last minute (Wi-Fi reports once per file):
        // only then does "no progress while away" mean the session died, rather than that nothing was running.
        transferWasActive = lastProgressAt.map { now.timeIntervalSince($0) < Self.activeWindow } ?? false
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
