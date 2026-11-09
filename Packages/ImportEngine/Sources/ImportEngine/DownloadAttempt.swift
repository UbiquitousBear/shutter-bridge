import CameraTransport
import Foundation
import PTPKit
import Synchronization

/// The bytes a link has reported for one download, and when they last grew. The link's progress callback writes it
/// from wherever the link runs; the engine's tick reads it. The engine never hops to its actor once per callback, so
/// out-of-order hops can't make the count go backwards.
final class TransferMeter: Sendable {
    private struct State {
        var bytes: UInt64 = 0
        var grewAt: Duration?
    }

    private let state = Mutex(State())
    private let clock: EngineClock

    init(clock: EngineClock) { self.clock = clock }

    func record(_ bytes: UInt64) {
        let now = clock.now
        state.withLock { s in
            if bytes > s.bytes {
                s.bytes = bytes
                s.grewAt = now
            }
        }
    }

    /// The most bytes reported, and when that number was first reached (nil before any progress).
    var reading: (bytes: UInt64, grewAt: Duration?) { state.withLock { ($0.bytes, $0.grewAt) } }
}

/// A partly written file on a link that resumes, with the facts of the camera's file whose start it holds: what a
/// resume continues from, once the file's name and size are checked against the camera's (backlog Iteration 3,
/// section 2, *Identity still decides*).
struct PartialSeed: Sendable, Hashable {
    var download: PartialDownload
    /// The camera file's name and size when these bytes were written.
    var name: String
    var size: UInt64

    var offset: UInt64 { download.bytesWritten }
}

/// A gate that opens once and lets every waiter through: the end of a link's call, which the next attempt at the
/// same file waits for before it continues the file the call was writing. Waiting is cancellable.
final class Latch: Sendable {
    private struct State {
        var open = false
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var next = 0
    }

    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for w in waiters { w.resume() }
    }

    var isOpen: Bool { state.withLock { $0.open } }

    /// Returns once the latch is open, or at once if the waiting task is cancelled.
    func wait() async {
        let token = state.withLock { s -> Int in
            s.next += 1
            return s.next
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if s.open || Task.isCancelled { return true }
                    s.waiters[token] = c
                    return false
                }
                if ready { c.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: token) }
            waiter?.resume()
        }
    }
}

/// One `bytes` call that the engine can walk away from. A stall, a removal, a stop or a cancel never waits for a
/// link that ignores cancellation: `abandon()` frees the lane at once, and if the link finishes later its file (or
/// failure) is discarded, so a late file can never be committed. `abandon()` also cancels the call's task, so a link
/// that honours cancellation (`IPLink`, Iteration 3) stops transferring the abandoned file; one that ignores it
/// (ImageCaptureCore) can still have that call in flight beside the retry.
///
/// **Two kinds of attempt.** On a link that can't resume (USB) each attempt writes into a folder of its own, which
/// `abandon()` and a discarded late file delete, so an interrupted file is copied again from its start (decision 7).
/// On a link that resumes (`CameraLinkCapabilities.resumesPartialFiles`, Wi-Fi) every attempt at one file writes
/// into the same folder and keeps it (`keepsFiles`): the link reports a checkpoint whenever a prefix of the file is
/// on disk (`latestCheckpoint`), and the next attempt continues from the latest one. It first waits for the earlier
/// call to end (so two calls never write one file), then checks the file on disk holds the checkpoint's bytes and
/// asks the camera for the file's current name and size (`info(of:)`): a handle is a hint, not an identity. A file
/// whose name or size changed ends the attempt as `.identityChanged`, and the engine finds the file again by its
/// listing and copies it from its start.
final class DownloadAttempt: Sendable {
    enum Outcome: Sendable {
        case written(URL)
        case failed(CameraLinkFailure)
        /// The camera's file under this ID is no longer the one the partial file was begun from (another name or
        /// size): the partial wasn't continued.
        case identityChanged(CameraItem)
        case abandoned
    }

    /// What a resumable attempt continues from: the previous attempt at the same file (its latest checkpoint, read
    /// once that call has ended), or a partial file found through the catalogue (an earlier job's).
    struct Resume: Sendable {
        var previous: DownloadAttempt?
        var adopted: PartialSeed?

        /// What the attempt continues from: the previous attempt's latest checkpoint (final once its call has
        /// ended), or the adopted partial file.
        var carried: PartialSeed? { previous?.latestCheckpoint ?? adopted }
    }

    private enum State {
        case running(CheckedContinuation<Outcome, Never>?)
        case done(Outcome)
        case abandoned
    }

    private struct Checkpoints {
        var latest: PartialSeed?
        /// The offset the last checkpoint reported, to tell when one crosses the catalogue interval.
        var lastReported: UInt64 = 0
    }

    /// Crossings not yet handed to `onCheckpoint`, in the order the link reported them, and whether a task is
    /// handing them over: one at a time, so the catalogue sees them in order.
    private struct Crossings {
        var pending: [PartialSeed] = []
        var draining = false
    }

    /// The folder the link writes a fresh copy into: one per attempt on a link that can't resume, one per file
    /// (shared by its attempts) on one that can.
    let directory: URL
    let meter: TransferMeter
    /// Whether the folder outlives the attempt (a link that resumes): never deleted here.
    let keepsFiles: Bool
    /// The camera file's name and size as the engine knew them when the attempt began.
    let origin: (name: String, size: UInt64)
    private let state = Mutex(State.running(nil))
    /// The task running the link's call, cancelled (never awaited) when the attempt is abandoned.
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let checkpoints = Mutex(Checkpoints())
    private let crossings = Mutex(Crossings())
    private let callEnded = Latch()
    private let checkpointInterval: UInt64
    private let onDiscard: (@Sendable () -> Void)?
    /// Called when a checkpoint crosses a multiple of the catalogue interval, from a task of its own, one crossing
    /// at a time and in order.
    private let onCheckpoint: (@Sendable (DownloadAttempt, PartialSeed) async -> Void)?

    init(directory: URL, clock: EngineClock, origin: (name: String, size: UInt64), keepsFiles: Bool = false,
         checkpointInterval: UInt64 = 16 * 1024 * 1024,
         onDiscard: (@Sendable () -> Void)?,
         onCheckpoint: (@Sendable (DownloadAttempt, PartialSeed) async -> Void)? = nil) {
        self.directory = directory
        self.meter = TransferMeter(clock: clock)
        self.origin = origin
        self.keepsFiles = keepsFiles
        self.checkpointInterval = checkpointInterval
        self.onDiscard = onDiscard
        self.onCheckpoint = onCheckpoint
    }

    /// The newest prefix of the file known to be on disk: the link's latest checkpoint, or what the attempt resumed
    /// from until the link reports one. Final once the call has ended (`waitForCallToEnd()`).
    var latestCheckpoint: PartialSeed? { checkpoints.withLock { $0.latest } }

    /// Returns once the link's call has returned or thrown (at once if it never started), or when the waiting task
    /// is cancelled.
    func waitForCallToEnd() async { await callEnded.wait() }

    /// Whether the link's call has ended (or will never start), so a later attempt may write the file.
    var callHasEnded: Bool { callEnded.isOpen }

    /// Starts the link's call in its own task. Called once. `resume` only on a link that resumes.
    func start(link: any CameraLink, item: CameraItem.ID, resume: Resume? = nil) {
        let directory = self.directory
        let meter = self.meter
        // Held from the start, so a flush or a retry never finds an attempt with nothing while it waits for its
        // predecessor; read again once that call has ended. (A resume checks the file's length before using it.)
        if let resume { checkpoints.withLock { $0.latest = resume.carried } }
        let call = Task {
            // Opened when this attempt can no longer write the file, which a later attempt waits for. An attempt
            // abandoned while its predecessor's call still runs opens it only once that call has ended, so a chain
            // of abandoned attempts never lets a third call write beside the first.
            var opensOnExit = true
            defer { if opensOnExit { self.callEnded.open() } }
            var resuming: PartialDownload?
            if let resume {
                if let previous = resume.previous { await previous.waitForCallToEnd() }
                // Until the link reports a checkpoint, this attempt holds what it continues from: a retry, a flush
                // or `ResumableFile.best` reads it here, whether the camera is still being asked or the ask failed.
                self.checkpoints.withLock { $0.latest = resume.carried }
                if Task.isCancelled {
                    // Nothing touched the folder: what this attempt would have continued from still holds.
                    if let previous = resume.previous, !previous.callHasEnded {
                        opensOnExit = false
                        // Not a child task, so not cancelled with this one: it waits for the earlier call to end.
                        Task {
                            await previous.waitForCallToEnd()
                            self.checkpoints.withLock { $0.latest = previous.latestCheckpoint }
                            self.callEnded.open()
                        }
                    }
                    self.complete(.failed(CameraLinkFailure(.noAnswer, detail: "abandoned before the call")))
                    return
                }
                switch await self.resumePoint(resume, link: link, item: item) {
                case let .resume(seed):
                    self.checkpoints.withLock { $0 = Checkpoints(latest: seed, lastReported: seed.offset) }
                    if Task.isCancelled { // abandoned while the camera was asked: the next attempt takes it from here
                        self.complete(.failed(CameraLinkFailure(.noAnswer, detail: "abandoned before the call")))
                        return
                    }
                    resuming = seed.download
                case .fresh:
                    self.checkpoints.withLock { $0 = Checkpoints() }
                    Self.empty(directory)
                case let .stop(outcome):
                    self.complete(outcome)
                    return
                }
            }
            let result: Outcome
            do throws(CameraLinkFailure) {
                let url = try await link.bytes(
                    of: item, into: directory, resuming: resuming,
                    checkpoint: { self.record($0) }, progress: { meter.record($0) })
                result = .written(url)
            } catch {
                result = .failed(error)
            }
            self.complete(result)
        }
        task.withLock { $0 = call }
        if isAbandoned { call.cancel() } // abandoned before the handle was kept
    }

    private enum ResumePoint {
        case resume(PartialSeed)
        case fresh
        case stop(Outcome)
    }

    /// Where a resumable attempt starts: the seed, if its bytes are on disk, it was begun from the file the engine
    /// is asking for now (name and size), and the camera still has that file under this ID; from 0 otherwise.
    private func resumePoint(_ resume: Resume, link: any CameraLink, item: CameraItem.ID) async -> ResumePoint {
        guard let seed = resume.carried, seed.offset > 0,
              seed.offset < seed.size, seed.name == origin.name, seed.size == origin.size,
              Self.length(of: seed.download.file) >= seed.offset else { return .fresh }
        let now: CameraItem
        do throws(CameraLinkFailure) {
            now = try await link.info(of: item)
        } catch {
            return .stop(.failed(error))
        }
        guard now.name == seed.name, now.size == seed.size else { return .stop(.identityChanged(now)) }
        return .resume(seed)
    }

    /// A checkpoint from the link: kept as the latest, and passed on when it crosses the catalogue interval.
    private func record(_ checkpoint: PartialDownload) {
        let seed = PartialSeed(download: checkpoint, name: origin.name, size: origin.size)
        // The link reports in order, within one call, and never after the call has ended.
        let crossed = checkpoints.withLock { c -> Bool in
            let crossed = PTPPartialRead.crossesCheckpoint(from: c.lastReported, to: checkpoint.bytesWritten,
                                                           interval: checkpointInterval)
            c.latest = seed
            c.lastReported = checkpoint.bytesWritten
            return crossed
        }
        if crossed { handOver(seed) }
    }

    /// Queues a crossing for `onCheckpoint`, starting the task that hands crossings over if none is running.
    private func handOver(_ seed: PartialSeed) {
        guard let onCheckpoint else { return }
        let starts = crossings.withLock { c -> Bool in
            c.pending.append(seed)
            guard !c.draining else { return false }
            c.draining = true
            return true
        }
        guard starts else { return }
        Task {
            while let next = self.crossings.withLock({ c -> PartialSeed? in
                guard !c.pending.isEmpty else {
                    c.draining = false
                    return nil
                }
                return c.pending.removeFirst()
            }) {
                await onCheckpoint(self, next)
            }
        }
    }

    private var isAbandoned: Bool {
        state.withLock { s in
            if case .abandoned = s { true } else { false }
        }
    }

    /// How the call ended, or `.abandoned` if the engine walked away (or the waiting task was cancelled) first.
    func outcome() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
                let ready = state.withLock { s -> Outcome? in
                    switch s {
                    case .running(.none):
                        s = .running(c)
                        return nil
                    case .running(.some):
                        return .abandoned // one waiter only; a second is a bug, answered harmlessly
                    case let .done(outcome):
                        return outcome
                    case .abandoned:
                        return .abandoned
                    }
                }
                if let ready { c.resume(returning: ready) }
            }
        } onCancel: {
            self.abandon()
        }
    }

    /// Walks away from the call: the waiter (if any) gets `.abandoned` at once, and the call's task is cancelled
    /// without waiting for it. The folder is deleted unless the attempt keeps its files. Idempotent.
    func abandon() {
        let (waiter, changed) = state.withLock { s -> (CheckedContinuation<Outcome, Never>?, Bool) in
            switch s {
            case let .running(w):
                s = .abandoned
                return (w, true)
            case .done:
                s = .abandoned
                return (nil, true)
            case .abandoned:
                return (nil, false)
            }
        }
        guard changed else { return }
        task.withLock { $0 }?.cancel()
        if !keepsFiles { try? FileManager.default.removeItem(at: directory) }
        waiter?.resume(returning: .abandoned)
    }

    private func complete(_ result: Outcome) {
        enum Next { case resume(CheckedContinuation<Outcome, Never>), discard, nothing }
        let next = state.withLock { s -> Next in
            switch s {
            case let .running(w):
                s = .done(result)
                return w.map(Next.resume) ?? .nothing
            case .abandoned:
                return .discard
            case .done:
                return .nothing
            }
        }
        switch next {
        case let .resume(c):
            c.resume(returning: result)
        case .discard:
            if !keepsFiles { try? FileManager.default.removeItem(at: directory) }
            onDiscard?()
        case .nothing:
            break
        }
    }

    /// The length of the file at `url`, 0 if there is none.
    static func length(of url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    /// Removes what an earlier attempt left in a resumable file's folder before a fresh copy (another name, a file
    /// that couldn't be continued), keeping the folder.
    static func empty(_ folder: URL) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }
}
