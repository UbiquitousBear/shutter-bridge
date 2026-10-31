import Foundation
import Observation
import BackgroundTasks

/// Day 5: does a user-started transfer keep running when the phone locks, if it is wrapped in a
/// BGContinuedProcessingTask (iOS 26+)? This wrapper submits one, reports progress, and records when the
/// system ends it. The "work" here is a timer so the mechanism can be tested without the camera first.
@Observable
@MainActor
final class ContinuedTask {
    static let identifier = "com.ubiquitousbear.shutterbridge.spike.import"

    private(set) var state = "idle"
    private(set) var completed = 0
    private(set) var total = 0
    var log: SpikeLog?

    nonisolated(unsafe) private static var runningWork: (@Sendable (BGContinuedProcessingTask) -> Void)?

    /// Call before the app finishes launching (SpikeApp.init).
    static func registerLaunchHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            if let work = runningWork { work(continued) } else { continued.setTaskCompleted(success: false) }
        }
    }

    /// Submits the request and runs `units` steps of ~0.5 s each; lock the phone part-way through.
    func start(units: Int = 240) {
        total = units
        completed = 0
        state = "submitting"
        let log = self.log

        Self.runningWork = { [weak self] task in
            task.expirationHandler = {
                Task { @MainActor in
                    self?.state = "expired by system"
                    log?.warn("BGContinuedProcessingTask expired at \(self?.completed ?? 0)/\(units) — checkpoint here in production")
                }
            }
            task.progress.totalUnitCount = Int64(units)
            Task { @MainActor in
                self?.state = "running"
                log?.note("BGContinuedProcessingTask started; lock the phone now")
                for i in 1 ... units {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard self?.state == "running" else { break }
                    self?.completed = i
                    task.progress.completedUnitCount = Int64(i)
                    if i % 20 == 0 { log?.note("…\(i)/\(units)") }
                }
                let finished = self?.completed == units
                self?.state = finished ? "finished" : "stopped"
                task.setTaskCompleted(success: finished)
                log?.note("BGContinuedProcessingTask completed success=\(finished)")
            }
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.identifier,
            title: "Importing from α7C II (spike)",
            subtitle: "0 of \(units)"
        )
        // .fail: start now or tell us immediately; .queue would let the system defer it, which we don't want for a user tap.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            log?.note("BGContinuedProcessingTaskRequest submitted")
        } catch {
            state = "submit failed"
            log?.error("submit failed: \(error) (Simulator has no scheduler; test on the device)")
        }
    }

    func stop() {
        state = "stopped"
    }
}
