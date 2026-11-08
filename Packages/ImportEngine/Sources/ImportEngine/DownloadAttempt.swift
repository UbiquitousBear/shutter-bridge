import CameraTransport
import Foundation
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

/// One `bytes(of:into:progress:)` call that the engine can walk away from. A stall, a removal, a stop or a cancel
/// never waits for a link that ignores cancellation: `abandon()` frees the lane at once, deletes the attempt's
/// folder, and if the link finishes later its file (or failure) is discarded and the folder deleted again, so a
/// late file can neither leak nor be committed. `abandon()` also cancels the call's task, so a link that honours
/// cancellation (`IPLink`, Iteration 3) stops transferring the abandoned file; one that ignores it (ImageCaptureCore)
/// can still have that call in flight beside the retry.
final class DownloadAttempt: Sendable {
    enum Outcome: Sendable {
        case written(URL)
        case failed(CameraLinkFailure)
        case abandoned
    }

    private enum State {
        case running(CheckedContinuation<Outcome, Never>?)
        case done(Outcome)
        case abandoned
    }

    /// The folder the link writes into: one per attempt, under the job's staging folder.
    let directory: URL
    let meter: TransferMeter
    private let state = Mutex(State.running(nil))
    /// The task running the link's call, cancelled (never awaited) when the attempt is abandoned.
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let onDiscard: (@Sendable () -> Void)?

    init(directory: URL, clock: EngineClock, onDiscard: (@Sendable () -> Void)?) {
        self.directory = directory
        self.meter = TransferMeter(clock: clock)
        self.onDiscard = onDiscard
    }

    /// Starts the link's call in its own task. Called once.
    func start(link: any CameraLink, item: CameraItem.ID) {
        let directory = self.directory
        let meter = self.meter
        let call = Task {
            let result: Outcome
            do throws(CameraLinkFailure) {
                result = .written(try await link.bytes(of: item, into: directory, progress: { meter.record($0) }))
            } catch {
                result = .failed(error)
            }
            self.complete(result)
        }
        task.withLock { $0 = call }
        if isAbandoned { call.cancel() } // abandoned before the handle was kept
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

    /// Walks away from the call: the waiter (if any) gets `.abandoned` at once, the call's task is cancelled without
    /// waiting for it, and the folder is deleted. Idempotent.
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
        try? FileManager.default.removeItem(at: directory)
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
            try? FileManager.default.removeItem(at: directory)
            onDiscard?()
        case .nothing:
            break
        }
    }
}
