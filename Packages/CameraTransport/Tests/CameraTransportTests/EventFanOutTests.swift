import Testing
@testable import CameraTransport

/// The fan-out behind `USBLink.events` (Apple-only), tested here: the `CameraLink.events` contract, live events for
/// each read.
@Suite("Live events for every reader", .timeLimit(.minutes(1)))
struct EventFanOutTests {
    /// Everything a stream gets until it finishes.
    private func collect(_ stream: AsyncStream<Int>) async -> [Int] {
        var seen: [Int] = []
        for await e in stream { seen.append(e) }
        return seen
    }

    @Test func subscribeThenSendDelivers() async {
        let fanOut = EventFanOut<Int>()
        let stream = fanOut.subscribe()
        fanOut.send(1)
        fanOut.send(2)
        fanOut.send(3)
        fanOut.finish()
        #expect(await collect(stream) == [1, 2, 3])
    }

    @Test func sendBeforeSubscribeIsNotDelivered() async {
        let fanOut = EventFanOut<Int>()
        fanOut.send(1) // no one listening: dropped, never buffered for a later reader
        let stream = fanOut.subscribe()
        fanOut.send(2)
        let late = fanOut.subscribe()
        fanOut.send(3)
        fanOut.finish()
        #expect(await collect(stream) == [2, 3])
        #expect(await collect(late) == [3])
    }

    @Test func twoSubscribersBothGetEveryEvent() async {
        let fanOut = EventFanOut<Int>()
        let first = fanOut.subscribe()
        let second = fanOut.subscribe()
        #expect(fanOut.subscriberCount == 2)
        fanOut.send(1)
        fanOut.send(2)
        fanOut.finish()
        #expect(await collect(first) == [1, 2])
        #expect(await collect(second) == [1, 2])
    }

    @Test func aTerminatedSubscriberIsDropped() async {
        let fanOut = EventFanOut<Int>()
        let kept = fanOut.subscribe()
        let gone = fanOut.subscribe()
        let (started, ready) = AsyncStream.makeStream(of: Void.self)
        let reader = Task {
            ready.yield()
            for await _ in gone {}
        }
        for await _ in started { break }
        reader.cancel()
        await reader.value
        #expect(fanOut.subscriberCount == 1)

        // A stream dropped without ever being read is removed too.
        do { _ = fanOut.subscribe() }
        #expect(fanOut.subscriberCount == 1)

        fanOut.send(7) // still reaches the reader that's left
        fanOut.finish()
        #expect(await collect(kept) == [7])
    }

    @Test func finishEndsEveryStreamAndLaterReads() async {
        let fanOut = EventFanOut<Int>()
        let a = fanOut.subscribe()
        let b = fanOut.subscribe()
        fanOut.finish()
        #expect(fanOut.isFinished)
        #expect(fanOut.subscriberCount == 0)
        fanOut.send(1) // after finish: goes nowhere
        fanOut.finish() // idempotent
        #expect(await collect(a) == [])
        #expect(await collect(b) == [])
        #expect(await collect(fanOut.subscribe()) == [])
    }
}
