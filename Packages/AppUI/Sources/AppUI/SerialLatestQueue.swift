import Foundation
import Synchronization

/// Applies the values sent to it one at a time, in the order sent, and keeps only the newest value sent while an earlier one
/// is still being applied (`bufferingNewest(1)`). For asks where each replaces the one before, such as the proximity
/// app-refresh task's earliest date (`BackgroundRefreshScheduler`): iOS 27's `submitTaskRequest` is asynchronous, so without
/// a queue a cancel sent straight after a submit could reach the scheduler first and leave a refresh asked for.
///
/// - `send(_:)` never waits. Values that arrive while one is being applied (or before the queue's task first runs) replace
///   each other, and the newest is applied once the current one returns. So the last value sent is always applied last,
///   and no two are ever applied at once.
/// - `idle(within:)` waits until everything sent so far has been applied, or replaced by a later value that has.
/// - The queue ends when it is released: the value being applied and the newest one still waiting are applied, then its
///   task ends.
final class SerialLatestQueue<Value: Sendable>: Sendable {
    private let continuation: AsyncStream<(UInt64, Value)>.Continuation
    private let progress = Progress()

    /// - Parameter apply: called with each value taken, never twice at once. It runs on a task of the queue's own, off the
    ///   main actor.
    init(apply: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: (UInt64, Value).self,
                                                            bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        // Holds the stream and the progress, not the queue, so releasing the queue finishes the stream and ends this task.
        let progress = self.progress
        Task {
            for await (number, value) in stream {
                await apply(value)
                progress.applied(number)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Queues `value` to be applied after the one being applied, replacing any value still waiting.
    func send(_ value: Value) {
        progress.numberAndYield { number in continuation.yield((number, value)) }
    }

    /// Waits until every value sent before this call has been applied, or replaced by a later value that has; gives up
    /// after `limit`, or when the calling task is cancelled.
    ///
    /// - Returns: whether the queue got there.
    @discardableResult
    func idle(within limit: Duration) async -> Bool {
        let target = progress.lastSent
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while progress.lastApplied < target {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Numbers each value as it is sent, and records the number of the last one applied. A value that was replaced is
    /// never applied, but the newer value that replaced it has a higher number, so `lastApplied` still passes it.
    private final class Progress: Sendable {
        private struct Numbers {
            var sent: UInt64 = 0
            var applied: UInt64 = 0
        }

        private let numbers = Mutex(Numbers())

        var lastSent: UInt64 { numbers.withLock { $0.sent } }
        var lastApplied: UInt64 { numbers.withLock { $0.applied } }

        /// Takes the next number and yields under the lock, so values enter the stream in the order they are numbered.
        func numberAndYield(_ yield: (UInt64) -> Void) {
            numbers.withLock { n in
                n.sent += 1
                yield(n.sent)
            }
        }

        func applied(_ number: UInt64) {
            numbers.withLock { $0.applied = max($0.applied, number) }
        }
    }
}
