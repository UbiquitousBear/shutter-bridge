#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import Foundation
import Synchronization

/// The app-refresh task that restarts the proximity scan (decided 9 Nov: background app refresh; backlog section 11, "Restart
/// from a discovery, a connection event or a background refresh"). Identifier `ProximityModel.refreshTaskIdentifier`, listed in
/// App/Info.plist's `BGTaskSchedulerPermittedIdentifiers`, with the `fetch` background mode. Compiled only for iOS (CI's
/// Xcode 27 job); the rules it serves are `ProximityRestartRules`, tested on Linux.
///
/// iOS runs a refresh task no earlier than asked, when it chooses, or not at all (the person can turn Background App Refresh
/// off); how often it ran on the bench is unmeasured, so the scan never depends on it alone.
///
/// Asks go to iOS through `submitTaskRequest` (iOS 27 deprecates `submit(_:)`; the new call reports every error
/// condition). It is asynchronous, and Apple's documentation says not to call it on the main thread, so the asks pass
/// through a `SerialLatestQueue`, off the main actor: each reaches iOS only after the one before it has, and a cancel can't
/// overtake the submit it follows. Asks made while one is with iOS replace each other, as every ask replaces the one
/// before. The refresh task waits for its own ask before it ends (`settle(within:)`, from `ProximityModel.refreshTaskRan`).
/// The app makes one scheduler (`LiveRoot.wireless`); copies share its queue.
public struct BackgroundRefreshScheduler: ProximityRefreshScheduling {
    private let asks: SerialLatestQueue<Date?>
    private let log: any BenchLog

    public init(log: any BenchLog = SilentBenchLog()) {
        self.log = log
        asks = SerialLatestQueue { date in await Self.apply(date, log: log) }
    }

    /// Registers the task's launch handler. Call once, before the app finishes launching (Apple's rule: a registration after
    /// that, or of an identifier not in Info.plist, raises an exception), and before anything is scheduled. `handler` runs on a
    /// background queue; it is cancelled if iOS expires the task, and the task is marked complete when it returns.
    ///
    /// - Returns: whether iOS accepted the registration.
    @discardableResult
    public static func register(handler: @escaping @Sendable () async -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ProximityModel.refreshTaskIdentifier, using: nil) { task in
            let box = RefreshTaskBox(task)
            let work = Task {
                await handler()
                box.complete(success: !Task.isCancelled)
            }
            task.expirationHandler = {
                work.cancel()
                box.complete(success: false)
            }
        }
    }

    public func scheduleRefresh(earliest date: Date?) {
        asks.send(date)
    }

    public func settle(within limit: Duration) async {
        let reached = await asks.idle(within: limit)
        if reached { return }
        if Task.isCancelled {
            log.note("proximity: the app-refresh task expired before its ask reached iOS")
        } else {
            log.note("proximity: the app-refresh ask hadn't reached iOS after \(limit); the task ends anyway")
        }
    }

    /// Hands one ask to iOS; the queue calls it for one ask at a time.
    private static func apply(_ date: Date?, log: any BenchLog) async {
        let identifier = ProximityModel.refreshTaskIdentifier
        guard let date else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = date
        do {
            // Replaces an earlier request with the same identifier that hasn't run yet (Apple's documentation for
            // `submitTaskRequest`, as for `submit(_:)`).
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } catch {
            // Refused in the Simulator, with Background App Refresh off, or with too many requests pending.
            let code = (error as NSError).code
            log.note("proximity: the app-refresh task couldn't be scheduled (BGTaskScheduler error \(code))")
        }
    }
}

/// The running task, completed exactly once (by the handler returning or by expiry, whichever comes first).
/// `@unchecked Sendable`: `BGTask`'s `setTaskCompleted(success:)` may be called from any thread (Apple's documentation), and
/// the flag that keeps it to one call is behind a lock.
private final class RefreshTaskBox: @unchecked Sendable {
    private let task: BGTask
    private let completed = Mutex(false)

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        let first = completed.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { task.setTaskCompleted(success: success) }
    }
}
#endif
