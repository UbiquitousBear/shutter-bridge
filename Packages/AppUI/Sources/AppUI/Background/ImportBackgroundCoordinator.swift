import Foundation
import ImportEngine

/// `ImportModel`'s side of the background run: one run per stretch of the job between taps, begun when the person taps
/// *Import* or *Continue*, fed the job's progress in bytes, finished when the job ends, and handed back to the model
/// when iOS ends it early (`onExpired`). Begun without waiting: the import never waits for iOS's answer, and goes on in
/// the foreground if iOS refuses.
@MainActor
final class ImportBackgroundCoordinator {
    /// Called when iOS ends the live run early (an expiry, or Stop); the run is finished, unsuccessfully, once it
    /// returns. The model flushes, pauses and notifies here, and returns what is left to do once the run is finished:
    /// the link's abort, which may wait on the camera and so must not hold the run past its end.
    var onExpired: (@MainActor () async -> (@MainActor () async -> Void)?)?

    private let run: any ImportBackgroundRun
    private let log: any BenchLog
    /// Goes up whenever the live run (or the one being begun) stops being the current one.
    private var generation = 0
    private var handle: (any ImportBackgroundHandle)?
    /// The generation of the `run.begin` in flight, if one is: the current one's while it is being begun for this
    /// stretch, an older one's when the job ended (or the run was dropped) before iOS answered.
    private var beginningGeneration: Int?
    /// How a run being begun is finished if the job ends first.
    private var endedWhileBeginning: Bool?
    /// A begin asked for while an older `run.begin` was still in flight: made once that one returns, because the live
    /// run waits for one request at a time and would refuse a second (`ContinuedImportRunner`'s broker).
    private var beginAgain = false
    private var expiryTask: Task<Void, Never>?
    private var latest: ImportProgress?
    private var reported: (done: UInt64, total: UInt64, subtitle: String)?

    init(run: any ImportBackgroundRun, log: any BenchLog) {
        self.run = run
        self.log = log
    }

    /// A run is live, or being begun (now, or once an older request iOS hasn't answered returns).
    var isRunning: Bool { handle != nil || beginningGeneration == generation || beginAgain }

    /// Begins a run unless one is live or being begun. Call only from a person's tap (iOS's rule).
    func begin(_ progress: ImportProgress) {
        guard !isRunning else { return }
        latest = progress
        guard beginningGeneration == nil else {
            beginAgain = true   // an older request is still in flight; begun once it returns
            return
        }
        start()
    }

    private func start() {
        guard let progress = latest else { return }
        generation += 1
        let mine = generation
        beginningGeneration = mine
        endedWhileBeginning = nil
        let run = self.run
        let subtitle = ImportBackgroundWording.subtitle(progress)
        Task { @MainActor [weak self] in
            do {
                let handle = try await run.begin(title: ImportBackgroundWording.title, subtitle: subtitle)
                guard let self else {
                    handle.finish(success: false)
                    return
                }
                self.adopt(handle, mine, subtitle: subtitle)
            } catch {
                guard let self else { return }
                self.beginningGeneration = nil
                if mine == self.generation {
                    self.log.note("import: no continued task (\(error)); the import goes on while the app is in front")
                }
                self.startIfAskedAgain()
            }
        }
    }

    /// The request in flight has returned: makes the begin asked for meanwhile.
    private func startIfAskedAgain() {
        guard beginAgain else { return }
        beginAgain = false
        start()
    }

    /// The job's latest progress, for the system's UI: bytes, and the files in the subtitle when they change.
    func update(_ progress: ImportProgress) {
        latest = progress
        report()
    }

    /// The job ended: the live run ends with it (`success` when it completed).
    func finish(success: Bool) {
        beginAgain = false
        if beginningGeneration == generation {
            generation += 1
            endedWhileBeginning = success
        }
        guard let handle else { return }
        generation += 1
        self.handle = nil
        expiryTask?.cancel()
        expiryTask = nil
        handle.finish(success: success)
        log.note("import: continued task finished (\(success ? "completed" : "not completed"))")
    }

    private func adopt(_ handle: any ImportBackgroundHandle, _ mine: Int, subtitle: String) {
        beginningGeneration = nil
        guard mine == generation else {
            // The job ended while iOS was starting this one.
            handle.finish(success: endedWhileBeginning ?? false)
            startIfAskedAgain()
            return
        }
        self.handle = handle
        reported = (0, 0, subtitle)
        log.note("import: continued task started")
        report()
        let expired = handle.expired
        expiryTask = Task { @MainActor [weak self] in
            for await _ in expired {
                await self?.expired(mine)
                return
            }
        }
    }

    private func report() {
        guard let handle, let progress = latest else { return }
        let subtitle = ImportBackgroundWording.subtitle(progress)
        if let r = reported, r.done == progress.bytesDone, r.total == progress.bytesTotal, r.subtitle == subtitle {
            return
        }
        let changed = reported?.subtitle != subtitle
        reported = (progress.bytesDone, progress.bytesTotal, subtitle)
        handle.update(completedBytes: Int64(clamping: progress.bytesDone),
                      totalBytes: Int64(clamping: progress.bytesTotal), title: nil, subtitle: changed ? subtitle : nil)
    }

    private func expired(_ mine: Int) async {
        guard mine == generation, let handle else { return }
        generation += 1
        self.handle = nil
        expiryTask = nil
        log.note("import: iOS ended the continued task (an expiry, or Stop)")
        let afterwards = await onExpired?() ?? nil
        handle.finish(success: false)
        await afterwards?()
    }
}
