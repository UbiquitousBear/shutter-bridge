import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// The engine's trace as the app's log uses it (I8): the public sink and its `.none` default, and the two timings the bench
/// sheet reads (the job carrying on after the camera was lost, and the first byte after that), on the manual clock. Every
/// wait is on the trace; none is on the wall clock.
@Suite("Engine trace: the sink and the reconnect timings", .timeLimit(.minutes(1)))
struct EngineTraceTests {
    private static func isReconnected(_ event: EngineTrace) -> Bool {
        if case .reconnected = event { true } else { false }
    }

    private static func isFirstByte(_ event: EngineTrace) -> Bool {
        if case .firstByteAfterReconnect = event { true } else { false }
    }

    /// A USB job whose camera is pulled and plugged back in 3 s later says how long it waited and how many files were
    /// left; the first byte of the copy after it is reported once, with its time since the job carried on.
    @Test func aUSBReplugSaysHowLongTheJobWaitedAndWhenTheFirstByteCame() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link1 = h.link(card, mode: .usb(.mtp))
        await link1.script("B.JPG", .hold)
        try await h.start(.items(card), from: link1)
        let b = await link1.nextHeldCall("B.JPG")
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        b.release(.fail(.disconnected))

        await h.advance(by: .seconds(3))
        let link2 = h.link(h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s2"), mode: .usb(.mtp))
        await link2.script("B.JPG", .hold)
        try await h.engine.reconnect(link2)
        await h.trace.next(.reconnected(.usb, sinceLost: .seconds(3), filesLeft: 2))

        let held = await link2.nextHeldCall("B.JPG")
        await h.advance(by: .seconds(1))
        held.progress(1000)
        await h.advance(by: .milliseconds(250))
        await h.trace.next(.firstByteAfterReconnect("B.JPG", bytes: 1000, sinceResumed: .seconds(1)))

        // Later progress of the same call, and of the next file, is not a first byte again.
        held.progress(2000)
        held.release()
        #expect(await h.waitFinished() == .completed)
        #expect(h.trace.count(where: Self.isFirstByte) == 1)
        #expect(h.trace.count(where: Self.isReconnected) == 1)
        await h.cleanup()
    }

    /// A file that starts and finishes between two progress ticks after the reconnect still owns the first-byte line, with
    /// the time its bytes came; the next file does not get one with a longer time.
    @Test func aFileThatFinishesBetweenTwoTicksStillOwnsTheFirstByte() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link1 = h.link(card, mode: .usb(.mtp))
        await link1.script("B.JPG", .hold)
        try await h.start(.items(card), from: link1)
        let b = await link1.nextHeldCall("B.JPG")
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        b.release(.fail(.disconnected))

        await h.advance(by: .seconds(3))
        let link2 = h.link(h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s2"), mode: .usb(.mtp))
        await link2.script("B.JPG", .hold)
        try await h.engine.reconnect(link2)
        await h.trace.next(.reconnected(.usb, sinceLost: .seconds(3), filesLeft: 2))

        let held = await link2.nextHeldCall("B.JPG")
        await h.advance(by: .seconds(1))
        // The tick event is recorded as the tick begins; a call into the engine returns only once that tick is over, so
        // the bytes and the end of the call below have no tick between them (the manual clock ticks only when advanced).
        _ = await h.engine.state
        held.progress(1000)
        held.release()
        await h.trace.next(.firstByteAfterReconnect("B.JPG", bytes: 1000, sinceResumed: .seconds(1)))
        #expect(await h.waitFinished() == .completed)
        #expect(h.trace.count(where: Self.isFirstByte) == 1)
        await h.cleanup()
    }

    /// A Wi-Fi job whose session is lost names its carrier, and the time runs from the loss, not from the reconnect.
    @Test func aLostWiFiSessionIsTimedFromTheLoss() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(1650))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        await h.advance(by: .seconds(2))
        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        #expect(h.trace.log.contains(.reconnected(.wifi, sinceLost: .seconds(2), filesLeft: 2)))
        await h.cleanup()
    }

    /// A job that was never interrupted has no reconnect line, and a pause that is not a loss (the person's) has none.
    @Test func anUninterruptedJobHasNoReconnectEvent() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        try await h.start(.items(card), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(h.trace.count(where: Self.isReconnected) == 0)
        #expect(h.trace.count(where: Self.isFirstByte) == 0)
        await h.cleanup()
    }

    /// The public initialiser takes a sink: the app's log gets the events; `.none` records nothing and costs nothing.
    @Test func thePublicInitialiserTakesASinkAndDefaultsToNone() async throws {
        #expect(EngineTraceSink.none.isOn == false)
        let recorder = TraceRecorder()
        let sink = EngineTraceSink { recorder.record($0) }
        #expect(sink.isOn)

        for trace in [sink, .none] {
            let h = Harness()
            let engine = ImportEngine(catalogue: InMemoryCatalogue(), stagingDirectory: h.staging, clock: h.clock,
                                      timeZone: h.zone, trace: trace)
            let card = h.singles(["A.JPG"])
            let link = h.link(card)
            try await engine.start(.items(card), from: link, camera: h.camera, to: h.stageRoute)
            if trace.isOn {
                await recorder.next(.listed(onCard: 1, queued: 1))
                await recorder.next { if case .finished(.completed) = $0 { true } else { false } }
                #expect(recorder.log.contains { if case .staged("A.JPG", _) = $0 { true } else { false } })
            } else {
                // Nothing to wait on: wait for the job through its state, bounded by the suite's time limit.
                while await engine.state.isActive { await Task.yield() }
                #expect(await engine.state == .finished(.completed))
            }
            await h.cleanup()
        }
    }
}
