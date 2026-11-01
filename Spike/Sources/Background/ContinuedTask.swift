import Foundation
import Observation
import BackgroundTasks

/// Day 5: does a user-started transfer keep running when the phone locks, if it is wrapped in a
/// BGContinuedProcessingTask (iOS 26+)? `run` submits one request and executes the caller's work inside it once
/// the system starts it, reporting progress to the system UI and recording when (if) the system expires it.
/// The Background tab's timer test needs no camera; the Wired and Wi-Fi tabs wrap real downloads with it.
@Observable
@MainActor
final class ContinuedTask {
    static let identifier = "com.ubiquitousbear.shutterbridge.spike.import"

    private(set) var state = "idle"
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var isRunning = false
    private(set) var expired = false
    var log: SpikeLog?

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
    /// returns whether it finished. Must be called from a user action (a button tap).
    func run(title: String, subtitle: String, totalUnits: Int,
             work: @escaping @MainActor (_ report: @escaping Report, _ shouldStop: @escaping ShouldStop) async -> Bool) {
        guard !isRunning else { log?.warn("a continued task is already running"); return }
        total = max(totalUnits, 1)
        completed = 0
        expired = false
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
        state = "running"
        log?.measure("bgcontinued.startLatency", startedAt.timeIntervalSince(submittedAt), "s", context: title)
        log?.note("BGContinuedProcessingTask started (\(title)); lock the phone now")
        task.progress.totalUnitCount = Int64(total)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.expired = true
                self.state = "expired by system"
                self.log?.warn("BGContinuedProcessingTask expired at \(self.completed)/\(self.total) after \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s — production checkpoints here")
            }
        }

        let report: Report = { [weak self] done, subtitle in
            guard let self else { return }
            self.completed = min(done, self.total)
            task.progress.completedUnitCount = Int64(self.completed)
            if let subtitle { task.updateTitle(title, subtitle: subtitle) }
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
        task.setTaskCompleted(success: finished)
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
