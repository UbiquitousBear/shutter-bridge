// The calls waiting on Core Bluetooth's delegate callbacks, and the link-state streams. Pure Swift, so the exactly-once,
// time-limit and cancellation rules that `BluetoothCentral` (Apple-only) depends on are tested on Linux.

import BLEKit
import Foundation
import Synchronization

/// What a call is waiting for: the delegate callback that will answer it. Peripherals are named by the identifier iOS gave
/// them.
enum GATTWaitKey: Hashable, Sendable {
    /// `centralManagerDidUpdateState` leaving `unknown` or `resetting`.
    case power
    /// `didDiscover` reporting the camera during the connect's scan.
    case scan
    /// `didConnect` (or `didFailToConnect`).
    case connect(UUID)
    /// `didDiscoverServices`.
    case services(UUID)
    /// `didDiscoverCharacteristicsFor` service 8000CC00.
    case characteristics(UUID)
    /// `didUpdateValueFor` answering a read.
    case read(UUID, CameraControlCharacteristic)
    /// `didWriteValueFor`.
    case write(UUID, CameraControlCharacteristic)
    /// `didUpdateNotificationStateFor`.
    case notify(UUID, CameraControlCharacteristic)

    /// The peripheral the wait is about, or nil for `power` and `scan`.
    var peripheral: UUID? {
        switch self {
        case .power, .scan: nil
        case .connect(let id), .services(let id), .characteristics(let id): id
        case .read(let id, _), .write(let id, _), .notify(let id, _): id
        }
    }
}

/// How a waiting call ended.
enum GATTCallOutcome: Sendable, Equatable {
    /// Answered without a value (a connect, a discovery, a write, the power settling, the scan finding the camera).
    case done
    /// A read's value.
    case value(Data)
    /// A notification switch was answered; whether notifications are now on, as iOS reported it in the callback.
    case notifying(Bool)
    /// The callback's error, mapped; or `.timedOut` (the call's limit passed) or `.cancelled` (the calling task was cancelled).
    case failed(GATTFailure)
}

/// The calls waiting on delegate callbacks, each ended exactly once: by its answer, its time limit, the calling task's
/// cancellation, or the link or Bluetooth going away, whichever comes first; later ones find nothing and do nothing.
///
/// Several calls may wait on the same key (two reads of CC09, a timed-out read and its retry); an answer goes to the one
/// that has waited longest, as Core Bluetooth answers requests to one characteristic in the order they were made.
///
/// Thread-safe. A continuation is never resumed with the lock held. `call` starts the request (`start`) on the caller's
/// isolation, after the call is registered, so the request and its answer can't pass each other.
final class GATTCallBroker: Sendable {
    private struct Parked {
        let key: GATTWaitKey
        let continuation: CheckedContinuation<GATTCallOutcome, Never>
        var timer: Task<Void, Never>?
    }

    private struct State {
        var next: UInt64 = 0
        var parked: [UInt64: Parked] = [:]
        /// Waiting call ids per key, oldest first.
        var queues: [GATTWaitKey: [UInt64]] = [:]
        /// Calls cancelled after they were numbered and before they were registered.
        var cancelledEarly: Set<UInt64> = []

        /// Removes a parked call from the table and its key's queue; nil when it isn't parked.
        mutating func unpark(_ id: UInt64) -> Parked? {
            guard let parked = parked.removeValue(forKey: id) else { return nil }
            queues[parked.key]?.removeAll { $0 == id }
            if queues[parked.key]?.isEmpty == true { queues[parked.key] = nil }
            return parked
        }
    }

    private let state = Mutex(State())
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    /// Registers a call on `key`, runs `start` (which sends the request to Core Bluetooth), and waits for the outcome.
    ///
    /// - Parameters:
    ///   - timeout: nil waits until the answer, a cancellation or a `fail`: the pairing read waits for the person.
    ///   - start: not run when the calling task is already cancelled.
    /// - Returns: the answer, `.failed(.timedOut)` when `timeout` passed first, or `.failed(.cancelled)` when the calling task
    ///   was cancelled first (the waiting continuation is dropped at once: *Cancel* during the pairing read).
    func call(
        _ key: GATTWaitKey, timeout: Duration?, isolation: isolated (any Actor)? = #isolation, start: () -> Void
    ) async -> GATTCallOutcome {
        let id = state.withLock { s -> UInt64 in
            s.next += 1
            return s.next
        }
        defer { state.withLock { _ = $0.cancelledEarly.remove(id) } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<GATTCallOutcome, Never>) in
                let registered = state.withLock { s -> Bool in
                    if s.cancelledEarly.remove(id) != nil { return false }
                    s.parked[id] = Parked(key: key, continuation: continuation)
                    s.queues[key, default: []].append(id)
                    return true
                }
                guard registered else {
                    continuation.resume(returning: .failed(.cancelled))
                    return
                }
                if let timeout { arm(timeout, for: id) }
                start()
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// Answers the call that has waited longest on `key`. Returns false when none was waiting (a late answer, or a value
    /// that wasn't asked for).
    @discardableResult
    func answer(_ key: GATTWaitKey, _ outcome: GATTCallOutcome) -> Bool {
        guard let id = state.withLock({ $0.queues[key]?.first }) else { return false }
        return finish(id, with: outcome)
    }

    /// Answers every call waiting on `key` (the power settling ends every wait for it). Returns how many there were.
    @discardableResult
    func answerAll(_ key: GATTWaitKey, _ outcome: GATTCallOutcome) -> Int {
        let ids = state.withLock { $0.queues[key] ?? [] }
        return ids.reduce(0) { $0 + (finish($1, with: outcome) ? 1 : 0) }
    }

    /// Fails every waiting call whose key matches (a peripheral's calls when its link drops; all of them when Bluetooth goes
    /// off). Returns how many there were.
    @discardableResult
    func fail(_ failure: GATTFailure, where matches: (GATTWaitKey) -> Bool) -> Int {
        let ids = state.withLock { s in s.parked.filter { matches($0.value.key) }.keys.sorted() }
        return ids.reduce(0) { $0 + (finish($1, with: .failed(failure)) ? 1 : 0) }
    }

    /// Whether a call is waiting on `key`.
    func isWaiting(_ key: GATTWaitKey) -> Bool {
        state.withLock { !($0.queues[key]?.isEmpty ?? true) }
    }

    /// How many calls are waiting (for tests).
    var waitingCount: Int { state.withLock { $0.parked.count } }

    // MARK: Private

    private func arm(_ timeout: Duration, for id: UInt64) {
        let clock = clock
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            self?.finish(id, with: .failed(.timedOut))
        }
        let stillWaiting = state.withLock { s -> Bool in
            guard s.parked[id] != nil else { return false }
            s.parked[id]?.timer = timer
            return true
        }
        if !stillWaiting { timer.cancel() }
    }

    /// The calling task's cancellation: ends the call with `.cancelled` if it is parked, else marks it so that registering
    /// it fails at once. Both are decided in one critical section. `onCancel` runs on whichever thread cancels the task (the
    /// main actor when *Cancel* is tapped) while the body registers the call on the central's queue; with two separate locks
    /// the body could register between "not parked" and "mark", and the call would stay parked (for ever, for the pairing
    /// read). The interleaving can't be forced deterministically from a test, so no test covers it.
    private func cancel(_ id: UInt64) {
        let parked = state.withLock { s -> Parked? in
            guard let parked = s.unpark(id) else {
                // Not registered yet (or already finished, in which case this entry is removed when `call` returns).
                s.cancelledEarly.insert(id)
                return nil
            }
            return parked
        }
        guard let parked else { return }
        parked.timer?.cancel()
        parked.continuation.resume(returning: .failed(.cancelled))
    }

    /// Ends one call; false when it had already ended (or never registered), in which case nothing happens.
    @discardableResult
    private func finish(_ id: UInt64, with outcome: GATTCallOutcome) -> Bool {
        guard let parked = state.withLock({ $0.unpark(id) }) else { return false }
        parked.timer?.cancel()
        parked.continuation.resume(returning: outcome)
        return true
    }
}

/// A value that changes over time, for any number of readers: each `subscribe()` returns a new stream that starts with the
/// current value and then gets every later one, in order. `finish()` ends every stream after the value it holds; a stream
/// subscribed after that gets the last value and ends. What `GATTLink.state` ("starts with the current state") and
/// `BluetoothCentral.powerState` need.
///
/// Thread-safe. Values sent from one serial context (the central's queue) reach each stream in the order sent. A continuation
/// is only ever finished with the lock released, since finishing runs its termination handler, which takes the lock.
final class LatestValueFanOut<Element: Sendable>: Sendable {
    private struct State {
        var current: Element
        var nextKey: UInt64 = 0
        /// Nil once finished.
        var subscribers: [UInt64: AsyncStream<Element>.Continuation]? = [:]
    }

    private let state: Mutex<State>

    init(_ initial: Element) {
        state = Mutex(State(current: initial))
    }

    /// The value now.
    var current: Element { state.withLock { $0.current } }

    /// Whether `finish()` has been called.
    var isFinished: Bool { state.withLock { $0.subscribers == nil } }

    /// Streams still being read (for tests).
    var subscriberCount: Int { state.withLock { $0.subscribers?.count ?? 0 } }

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .unbounded)
        // The current value is yielded under the lock, so no `send` can slip in before it. Yielding to a stream nobody has
        // read yet can't run a termination handler, so this is the one continuation call made with the lock held.
        let key: UInt64? = state.withLock { s in
            continuation.yield(s.current)
            guard s.subscribers != nil else { return nil }
            let key = s.nextKey
            s.nextKey += 1
            s.subscribers?[key] = continuation
            return key
        }
        if let key {
            continuation.onTermination = { [weak self] _ in self?.drop(key) }
        } else {
            continuation.finish()
        }
        return stream
    }

    /// Makes `value` current and sends it to every live stream. Ignored after `finish()`.
    func send(_ value: Element) {
        let live = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            guard let subscribers = s.subscribers else { return [] }
            s.current = value
            return Array(subscribers.values)
        }
        for continuation in live { continuation.yield(value) }
    }

    /// Ends every stream. Idempotent.
    func finish() {
        let live = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            defer { s.subscribers = nil }
            return s.subscribers.map { Array($0.values) } ?? []
        }
        for continuation in live { continuation.finish() }
    }

    private func drop(_ key: UInt64) {
        state.withLock { s in _ = s.subscribers?.removeValue(forKey: key) }
    }
}
