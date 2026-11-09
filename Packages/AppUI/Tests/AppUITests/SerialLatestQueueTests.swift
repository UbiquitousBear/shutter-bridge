import Foundation
import Synchronization
import Testing
@testable import AppUI

/// Records what `SerialLatestQueue` applies, and can hold an apply until released (bounded: an apply held for more than
/// about 5 s carries on, so a broken test fails on its checks rather than hanging).
private final class ApplyRecorder: Sendable {
    private struct State {
        var started: [Int?] = []
        var applied: [Int?] = []
        var running = 0
        var mostAtOnce = 0
        var held = false
    }

    private let state = Mutex(State())

    var started: [Int?] { state.withLock { $0.started } }
    var applied: [Int?] { state.withLock { $0.applied } }
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }

    func hold() { state.withLock { $0.held = true } }
    func release() { state.withLock { $0.held = false } }

    func apply(_ value: Int?) async {
        state.withLock { s in
            s.started.append(value)
            s.running += 1
            s.mostAtOnce = max(s.mostAtOnce, s.running)
        }
        for _ in 0..<1000 {
            guard state.withLock({ $0.held }) else { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        state.withLock { s in
            s.running -= 1
            s.applied.append(value)
        }
    }
}

@Suite("Serial latest-wins queue (the proximity refresh task's asks)", .timeLimit(.minutes(1)))
struct SerialLatestQueueTests {
    @Test("Values sent while nothing is being applied are each applied, in order")
    func appliesEachValueInOrder() async {
        let recorder = ApplyRecorder()
        let queue = SerialLatestQueue<Int?> { await recorder.apply($0) }
        for value in [1, 2, 3] {
            queue.send(value)
            #expect(await eventually { recorder.applied.count == value })
        }
        #expect(recorder.applied == [1, 2, 3])
        #expect(recorder.mostAtOnce == 1)
    }

    @Test("Values sent while one is being applied replace each other; only the newest is applied next")
    func keepsOnlyTheNewestWhileOneIsApplied() async {
        let recorder = ApplyRecorder()
        let queue = SerialLatestQueue<Int?> { await recorder.apply($0) }
        recorder.hold()
        queue.send(1)
        #expect(await eventually { recorder.started == [1] })
        queue.send(2)
        queue.send(3)
        queue.send(4)
        // Still one at a time: nothing else starts while the first is held.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.started == [1])
        recorder.release()
        #expect(await eventually { recorder.applied == [1, 4] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.applied == [1, 4])
        #expect(recorder.mostAtOnce == 1)
    }

    @Test("A cancel (nil) sent during a submit is applied after it, and a later ask replaces a waiting cancel")
    func aCancelWaitsForTheSubmitBeforeIt() async {
        let recorder = ApplyRecorder()
        let queue = SerialLatestQueue<Int?> { await recorder.apply($0) }

        recorder.hold()
        queue.send(10)
        #expect(await eventually { recorder.started == [10] })
        queue.send(nil)
        recorder.release()
        #expect(await eventually { recorder.applied == [10, nil] })

        recorder.hold()
        queue.send(20)
        #expect(await eventually { recorder.started == [10, nil, 20] })
        queue.send(nil)
        queue.send(30)
        recorder.release()
        #expect(await eventually { recorder.applied == [10, nil, 20, 30] })
        #expect(recorder.mostAtOnce == 1)
    }

    @Test("Many sends from many tasks: never two at once, and the last value sent is applied last")
    func burstsFromManyTasks() async {
        let recorder = ApplyRecorder()
        let queue = SerialLatestQueue<Int?> { await recorder.apply($0) }
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<200 {
                group.addTask { queue.send(value) }
            }
        }
        queue.send(1_000)
        #expect(await eventually { recorder.applied.last == 1_000 })
        #expect(recorder.mostAtOnce == 1)
        #expect(recorder.applied.count <= 202)
    }
}
