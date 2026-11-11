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
    /// The job being run was started as *Stage*: the run's title says so.
    private var staging = false
    private var reported: (done: UInt64, total: UInt64, subtitle: String)?
    /// Made-up bytes a recovery's waits have shown on top of the job's (`nudge()`): what the run shows until the job's
    /// own bytes pass it. 0 for none.
    private var madeUp: UInt64 = 0

    /// How far `nudge()` moves the run: the spike's copy recovery (1 MB a second of waiting).
    static let nudgeBytes: UInt64 = 1_000_000
    /// How far each report moves the run while it shows made-up bytes, so it doesn't stand still while the job's own
    /// bytes catch up: the spike's 4 KB.
    static let catchUpBytes: UInt64 = 4_096

    init(run: any ImportBackgroundRun, log: any BenchLog) {
        self.run = run
        self.log = log
    }

    /// A run is live, or being begun (now, or once an older request iOS hasn't answered returns).
    var isRunning: Bool { handle != nil || beginningGeneration == generation || beginAgain }

    /// Begins a run unless one is live or being begun. Call only from a person's tap (iOS's rule).
    ///
    /// - Parameter staging: The job was started as *Stage*, so the system's UI says "Staging photos".
    func begin(_ progress: ImportProgress, staging: Bool = false) {
        guard !isRunning else { return }
        latest = progress
        self.staging = staging
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
        let title = ImportBackgroundWording.title(staging: staging)
        Task { @MainActor [weak self] in
            do {
                let handle = try await run.begin(title: title, subtitle: subtitle)
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
        madeUp = 0
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

    /// A recovery is waiting (W14): moves the live run by made-up bytes, never up to the total, so iOS doesn't see a
    /// task standing still through the waits (the spike's copy recovery did this; `unverified` whether iOS ends a
    /// continued task whose progress stands still).
    func nudge() {
        guard handle != nil, let progress = latest, progress.bytesTotal > 1 else { return }
        let shown = max(madeUp, progress.bytesDone)
        madeUp = min(shown + Self.nudgeBytes, progress.bytesTotal - 1)
        report(catchingUp: false)
    }

    private func report(catchingUp: Bool = true) {
        guard let handle, let progress = latest else { return }
        var done = progress.bytesDone
        if madeUp > done, progress.bytesTotal > 1 {
            if catchingUp { madeUp = min(madeUp + Self.catchUpBytes, progress.bytesTotal - 1) }
            done = max(madeUp, done)
        } else {
            madeUp = 0
        }
        let subtitle = ImportBackgroundWording.subtitle(progress)
        if let r = reported, r.done == done, r.total == progress.bytesTotal, r.subtitle == subtitle {
            return
        }
        let changed = reported?.subtitle != subtitle
        reported = (done, progress.bytesTotal, subtitle)
        handle.update(completedBytes: Int64(clamping: done),
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
