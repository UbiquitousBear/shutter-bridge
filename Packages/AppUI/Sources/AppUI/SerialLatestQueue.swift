import Foundation

/// Applies the values sent to it one at a time, in the order sent, and keeps only the newest value sent while an earlier one
/// is still being applied (`bufferingNewest(1)`). For asks where each replaces the one before, such as the proximity
/// app-refresh task's earliest date (`BackgroundRefreshScheduler`): iOS 27's `submitTaskRequest` is asynchronous, so without
/// a queue a cancel sent straight after a submit could reach the scheduler first and leave a refresh asked for.
///
/// - `send(_:)` never waits. A value sent while nothing is being applied is applied next; values sent while one is being
///   applied replace each other, and the newest is applied once the current one returns. So the last value sent is always
///   applied last, and no two are ever applied at once.
/// - The queue ends when it is released: a value already taken is still applied, and nothing after it.
final class SerialLatestQueue<Value: Sendable>: Sendable {
    private let continuation: AsyncStream<Value>.Continuation

    /// - Parameter apply: called with each value taken, never twice at once. It runs on a task of the queue's own.
    init(apply: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        // Holds the stream, not the queue, so releasing the queue finishes the stream and ends this task.
        Task {
            for await value in stream {
                await apply(value)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Queues `value` to be applied after the one being applied, replacing any value still waiting.
    func send(_ value: Value) {
        continuation.yield(value)
    }
}
