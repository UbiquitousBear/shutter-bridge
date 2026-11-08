import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

@Suite("Progress, throttling and the rate", .timeLimit(.minutes(1)))
struct ProgressReportingTests {
    @Test func progressIsPublishedAtMostFourTimesASecond() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.items([card[0]]), from: link)
        await h.trace.next(.published(.zero))
        let a = await link.nextHeldCall("A.JPG")
        for n in 1 ... 100 { a.progress(UInt64(n)) }
        #expect(try await h.engine.append([card[1]]) == 1)
        #expect(h.trace.count { $0.isPublished } == 1)

        await h.advance(by: .milliseconds(250))
        await h.trace.next(.published(.milliseconds(250)))
        var updates = h.engine.progress.makeAsyncIterator()
        let p = try #require(await updates.next())
        #expect(p.bytesDone == 100)
        #expect(p.filesTotal == 2)
        #expect(p.state == .running)

        await h.advance(by: .milliseconds(250)) // nothing changed: a tick, no update
        #expect(h.trace.count { $0.isPublished } == 2)

        a.progress(200)
        await h.advance(by: .milliseconds(250))
        await h.trace.next(.published(.milliseconds(750)))
        let times = h.trace.log.compactMap { e -> Duration? in if case let .published(t) = e { t } else { nil } }
        for (x, y) in zip(times, times.dropFirst()) { #expect(y - x >= .milliseconds(250)) }

        a.release()
        #expect(await h.waitFinished() == .completed)
        await h.cleanup()
    }

    @Test func theLastUpdateOfAJobIsFlushed() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        try await h.start(.items(card), from: link)
        #expect(await h.waitFinished() == .completed)
        await h.advance(by: .milliseconds(250))
        var updates = h.engine.progress.makeAsyncIterator()
        let p = try #require(await updates.next())
        #expect(p.state == .finished(.completed))
        #expect(p.filesDone == 1)
        await h.cleanup()
    }

    @Test func throttleRules() {
        func p(_ n: Int) -> ImportProgress { ImportProgress(filesDone: n, filesTotal: 10, bytesDone: 0, bytesTotal: 0) }
        var t = ProgressThrottle(interval: .milliseconds(250))
        #expect(t.offer(p(1), at: .zero) == p(1))
        #expect(t.offer(p(2), at: .milliseconds(100)) == nil)
        #expect(t.offer(p(3), at: .milliseconds(200)) == nil)
        #expect(t.hasPending)
        #expect(t.due(at: .milliseconds(240)) == nil)
        #expect(t.due(at: .milliseconds(250)) == p(3))
        #expect(!t.hasPending)
        #expect(t.offer(p(3), at: .milliseconds(550)) == nil)
        #expect(t.offer(p(4), at: .milliseconds(600)) == p(4))
    }

    @Test func rateLeavesOutAFileInFlightAcrossAPause() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"], sizes: [40_000, 35_400, 40_000])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        try await h.start(.items(card), from: link)

        let a = await link.nextHeldCall("A.JPG")
        await h.advance(by: .seconds(1))
        a.release()
        await h.trace.next(.imported("A.JPG", .photos))
        let b = await link.nextHeldCall("B.JPG")
        var p = await h.engine.currentProgress
        #expect(p.bytesPerSecond == 40_000)
        #expect(p.bytesDone == 40_000)
        #expect(p.estimatedTimeRemaining == .milliseconds(1885)) // 75 400 B at 40 000 B/s

        await h.advance(by: .milliseconds(500))
        link.send(.didSuspend)
        await h.trace.next(.paused(.appInBackground))
        await h.advance(by: .seconds(600))
        try await h.engine.resume(.appInBackground)
        await h.trace.next(.resumed)
        b.release() // "35.4 MB at 1745 MB/s" after a continue
        await h.trace.next(.imported("B.JPG", .photos))
        p = await h.engine.currentProgress
        #expect(p.bytesPerSecond == 40_000)

        let c = await link.nextHeldCall("C.JPG")
        await h.advance(by: .seconds(2))
        c.release()
        await h.trace.next(.imported("C.JPG", .photos))
        p = await h.engine.currentProgress
        #expect(p.bytesPerSecond == 80_000.0 / 3)
        #expect(await h.waitFinished() == .completed)
        await h.cleanup()
    }

    /// A restarted download holds its place in the bar until the new attempt passes it.
    @Test func bytesDoneNeverGoesBackwards() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"], sizes: [10_000])
        let link = h.link(card)
        await link.script("A.JPG", .hold, .hold)
        try await h.start(.items(card), from: link)
        let first = await link.nextHeldCall("A.JPG")
        first.progress(6000)
        #expect(await h.engine.currentProgress.bytesDone == 6000)
        await h.advance(by: .seconds(30))
        await h.trace.next(.stalled("A.JPG", count: 1))
        #expect(await h.engine.currentProgress.bytesDone == 6000)
        await h.advance(by: .seconds(5))
        let second = await link.nextHeldCall("A.JPG")
        second.progress(3000)
        #expect(await h.engine.currentProgress.bytesDone == 6000)
        second.progress(7000)
        #expect(await h.engine.currentProgress.bytesDone == 7000)
        second.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await h.engine.currentProgress.bytesDone == 10_000)
        await h.cleanup()
    }

    @Test func rateEstimatorUnion() {
        var r = RateEstimator(capacity: 8)
        #expect(r.bytesPerSecond == nil)
        r.record(start: .zero, end: .seconds(2), bytes: 80)
        r.record(start: .seconds(1), end: .seconds(3), bytes: 80)
        #expect(r.bytesPerSecond == 160.0 / 3) // overlapping files aren't counted twice

        var zero = RateEstimator(capacity: 8)
        zero.record(start: .seconds(1), end: .seconds(1), bytes: 100)
        #expect(zero.bytesPerSecond == nil)

        var last = RateEstimator(capacity: 2)
        last.record(start: .zero, end: .seconds(1), bytes: 1_000_000)
        last.record(start: .seconds(1), end: .seconds(2), bytes: 10)
        last.record(start: .seconds(2), end: .seconds(3), bytes: 30)
        #expect(last.samples.count == 2)
        #expect(last.bytesPerSecond == 20)
    }
}
