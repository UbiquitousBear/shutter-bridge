#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import Foundation

/// The live `ImportBackgroundRun`: a `BGContinuedProcessingTask` (iOS 26 and later) per run, as the spike ran it
/// (`Spike/Sources/Background/ContinuedTask.swift`; backlog Iteration 3, section 9, and section 13).
///
/// - `register()` installs the launch handler for `identifier`, which `App/Info.plist` lists under
///   `BGTaskSchedulerPermittedIdentifiers`. It must run before the app finishes launching
///   (`LiveLaunch.beforeLaunchFinishes()`, from the app's `init`).
/// - `begin(title:subtitle:)` submits a `BGContinuedProcessingTaskRequest` with `strategy = .fail` (start now or say
///   so at once: a tap mustn't be queued) through `submitTaskRequest` (iOS 27; `submit(_:)` is deprecated), then waits
///   for iOS to hand the task to the launch handler: 0.01–0.04 s in every spike run.
/// - The handle reports progress in bytes through the task's `progress`, changes the title and subtitle with
///   `updateTitle(_:subtitle:)`, forwards the task's `expirationHandler` (an expiry, or Stop in the system's UI) to
///   `expired`, and ends the task with `setTaskCompleted(success:)`.
///
/// One run at a time, as the app runs one import at a time. The app's models get it for Wi-Fi jobs only
/// (`WiFiOnlyBackgroundRun`, W16), so a USB import keeps its leaving rule.
public final class ContinuedImportRunner: ImportBackgroundRun {
    /// The task identifier, prefixed with the bundle identifier as iOS requires.
    public static let identifier = "net.shamil.shutter-bridge.import"
    /// How long `begin` waits for iOS to start an accepted request before giving up. The spike measured 0.01–0.04 s;
    /// 10 s is a margin, `unverified`.
    public static let startTimeout: Duration = .seconds(10)

    private static let broker = Broker()

    public init() {}

    /// Installs the launch handler. Call once, before the app finishes launching: iOS raises an exception for a
    /// registration after that, and for an identifier the Info.plist doesn't list.
    public static func register() {
        let broker = self.broker
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            broker.started(task)
        }
    }

    public func begin(title: String, subtitle: String) async throws -> any ImportBackgroundHandle {
        let broker = Self.broker
        let token = broker.nextToken()
        return try await withCheckedThrowingContinuation { continuation in
            guard broker.wait(token, title: title, subtitle: subtitle, continuation) else {
                continuation.resume(throwing: ImportBackgroundRunError.refused)   // another begin is waiting
                return
            }
            Task {
                // The launch handler may run before this await returns; the continuation is already waiting for it.
                let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: title,
                                                               subtitle: subtitle)
                request.strategy = .fail
                do {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } catch {
                    broker.fail(token)
                    return
                }
                try? await Task.sleep(for: Self.startTimeout)
                broker.fail(token)   // does nothing once the task has started
            }
        }
    }

    /// The one `begin` waiting for iOS to start its task, and the launch handler's side of it. iOS calls the launch
    /// handler on a queue of its own, hence the lock.
    private final class Broker: @unchecked Sendable {
        private struct Waiting {
            var token: Int
            var title: String
            var subtitle: String
            var continuation: CheckedContinuation<any ImportBackgroundHandle, any Error>
        }

        private let lock = NSLock()
        private var counter = 0
        private var waiting: Waiting?

        func nextToken() -> Int {
            lock.withLock {
                counter += 1
                return counter
            }
        }

        /// False when another `begin` is already waiting.
        func wait(_ token: Int, title: String, subtitle: String,
                  _ continuation: CheckedContinuation<any ImportBackgroundHandle, any Error>) -> Bool {
            lock.withLock {
                guard waiting == nil else { return false }
                waiting = Waiting(token: token, title: title, subtitle: subtitle, continuation: continuation)
                return true
            }
        }

        /// The request `token` was refused or timed out: its `begin` throws, if it is still waiting.
        func fail(_ token: Int) {
            let failed = lock.withLock { () -> Waiting? in
                guard let w = waiting, w.token == token else { return nil }
                waiting = nil
                return w
            }
            failed?.continuation.resume(throwing: ImportBackgroundRunError.refused)
        }

        /// The launch handler: hands the task to the waiting `begin`, or ends it at once when nobody waits (a request
        /// that timed out) or it isn't a continued task.
        func started(_ task: BGTask) {
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let taken = lock.withLock { () -> Waiting? in
                defer { waiting = nil }
                return waiting
            }
            guard let taken else {
                continued.setTaskCompleted(success: false)
                return
            }
            let handle = ContinuedImportHandle(task: continued, title: taken.title, subtitle: taken.subtitle)
            taken.continuation.resume(returning: handle)
        }
    }
}

/// One `BGContinuedProcessingTask`, as `ImportBackgroundHandle`. The task's methods are called under the lock, from
/// whichever thread the model's task runs on; `Progress` is thread-safe.
private final class ContinuedImportHandle: ImportBackgroundHandle, @unchecked Sendable {
    let expired: AsyncStream<Void>
    private let sink: AsyncStream<Void>.Continuation
    private let task: BGContinuedProcessingTask
    private let lock = NSLock()
    private var title: String
    private var subtitle: String
    private var finished = false

    init(task: BGContinuedProcessingTask, title: String, subtitle: String) {
        (expired, sink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.task = task
        self.title = title
        self.subtitle = subtitle
        let sink = self.sink
        // Runs on iOS's queue when the task expires or the person taps Stop; the model flushes, pauses and finishes.
        task.expirationHandler = {
            sink.yield(())
        }
    }

    func update(completedBytes: Int64, totalBytes: Int64, title: String?, subtitle: String?) {
        lock.withLock {
            guard !finished else { return }
            let total = max(totalBytes, 0)
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = min(max(completedBytes, 0), total)
            let newTitle = title ?? self.title
            let newSubtitle = subtitle ?? self.subtitle
            guard newTitle != self.title || newSubtitle != self.subtitle else { return }
            self.title = newTitle
            self.subtitle = newSubtitle
            task.updateTitle(newTitle, subtitle: newSubtitle)
        }
    }

    func finish(success: Bool) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        task.setTaskCompleted(success: success)
        sink.finish()
    }
}
#endif
