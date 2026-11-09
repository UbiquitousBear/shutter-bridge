import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

/// What `IPLink` records for the bench log (W20) against the simulated α7C II: the open's times and listing poll, each
/// keep-alive with its spacing, no GetDevicePropValue, a lost session, a 0x9211 resume with its offset and reads, a refused
/// first read, and the diagnostics at close. Times are on `CameraClock`, so they are exact.
@Suite("IPLink's trace against the simulated camera", .timeLimit(.minutes(1)))
struct IPLinkTraceAgainstSimulatorTests {
    typealias LinkBench = IPLinkAgainstSimulatorTests.Bench

    final class Recorder: Sendable {
        private let events = Mutex<[TransportTraceEvent]>([])
        var trace: TransportTrace { TransportTrace { [self] event in events.withLock { $0.append(event) } } }
        var all: [TransportTraceEvent] { events.withLock { $0 } }

        var keepAlives: [TransportTraceEvent] {
            all.filter { if case .keepAlive = $0 { true } else { false } }
        }

        var closed: IPLinkDiagnostics? {
            all.lazy.compactMap { if case let .linkClosed(diagnostics) = $0 { diagnostics } else { nil } }.last
        }
    }

    @Test func theOpenIsRecordedWithItsPollAndTheCardReady() async throws {
        let recorder = Recorder()
        let bench = try LinkBench(trace: recorder.trace)
        try await bench.open()
        let diagnostics = await bench.link.diagnostics
        let events = recorder.all
        #expect(events.first == .linkConnected(after: .zero, reopening: false))
        let opened = try #require(events.last)
        guard case let .linkOpened(after, reopening, wholeCard, polls, listedAfter, timedOut) = opened else {
            Issue.record("expected the open, got \(opened)")
            return
        }
        #expect(after == bench.clock.elapsed)
        #expect(!reopening && wholeCard && !timedOut)
        #expect(polls == diagnostics.pollAttempts && polls >= 1)
        #expect(listedAfter == diagnostics.timeToListing)
        await bench.link.close()
    }

    /// A new link the caller marks as reopening (the session's second import inside the stay) is recorded as reopening,
    /// as the bench sheet's check 5 reads it, though this link had no earlier session of its own.
    @Test func aLinkConfiguredAsReopeningIsRecordedAsReopening() async throws {
        let recorder = Recorder()
        let bench = try LinkBench(trace: recorder.trace) { $0.reopening = true }
        try await bench.open()
        let events = recorder.all
        #expect(events.first == .linkConnected(after: .zero, reopening: true))
        let opened = try #require(events.last)
        guard case let .linkOpened(after, reopening, wholeCard, polls, _, timedOut) = opened else {
            Issue.record("expected the open, got \(opened)")
            return
        }
        #expect(after == bench.clock.elapsed)
        #expect(reopening && wholeCard && !timedOut)
        #expect(polls == (await bench.link.diagnostics).pollAttempts)
        await bench.link.close()
    }

    @Test func eachKeepAliveIsRecordedWithItsSpacingAndNoGetDevicePropValueIsSent() async throws {
        let recorder = Recorder()
        let bench = try LinkBench(trace: recorder.trace)
        try await bench.open()
        let items = try await bench.link.list()
        for item in items.prefix(2) {
            _ = try await bench.link.thumbnail(of: item.id)
            _ = try await bench.link.bytes(of: item.id, into: bench.directory)
        }
        try await bench.clock.waitUntil { $0.sleepers > 0 }  // the keep-alive timer, armed as the last command ended
        for _ in 1 ... 4 { try await bench.clock.tick(.seconds(10)) }
        #expect(recorder.keepAlives == [
            .keepAlive(number: 1, answered: true, idle: .seconds(10), sincePrevious: nil),
            .keepAlive(number: 2, answered: true, idle: .seconds(10), sincePrevious: .seconds(10)),
            .keepAlive(number: 3, answered: true, idle: .seconds(10), sincePrevious: .seconds(10)),
            .keepAlive(number: 4, answered: true, idle: .seconds(10), sincePrevious: .seconds(10)),
        ])
        #expect(await bench.link.diagnostics.devicePropValueReads == 0)
        await bench.link.close()
        let closed = try #require(recorder.closed)
        #expect(closed.keepAlivesAnswered == 4 && closed.keepAlivesFailed == 0)
        #expect(closed.devicePropValueReads == 0)
        #expect(closed.sessionsOpened == 1 && closed.sessionsLost == 0)
        #expect(!bench.camera.commandsAnswered.contains(.getDevicePropValue))
    }

    @Test func aCutDownloadRecordsTheLossThenTheResumeFromItsOffset() async throws {
        let recorder = Recorder()
        let bench = try IPLinkResumeAgainstSimulatorTests.bench(trace: recorder.trace)
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let raw = try #require(try await bench.link.list().first { $0.format == .raw })
        let (_, checkpoints) = try await IPLinkResumeAgainstSimulatorTests.cutFreshDownload(raw, at: 0.54, on: bench,
                                                                                            events: &events)
        let last = try #require(checkpoints.last)
        #expect(recorder.all.contains { if case .linkLost(.some, _) = $0 { true } else { false } })

        try await bench.open()
        #expect(recorder.all.contains { if case .linkOpened(_, true, true, _, _, _) = $0 { true } else { false } })
        _ = try await bench.link.bytes(of: raw.id, into: bench.directory, resuming: last, checkpoint: { _ in },
                                       progress: { _ in })
        let chunk = UInt64(IPLinkResumeAgainstSimulatorTests.chunk)
        let reads = Int((raw.size - last.bytesWritten + chunk - 1) / chunk)
        let resumed = recorder.all.filter {
            switch $0 {
            case .resumeStarted, .resumeFinished, .resumeRefused: true
            default: false
            }
        }
        #expect(resumed == [.resumeStarted(offset: last.bytesWritten, size: raw.size), .resumeFinished(reads: reads)])
        await bench.link.close()
        let closed = try #require(recorder.closed)
        #expect(closed.resumes == 1 && closed.partialReads == reads && closed.sessionsLost == 1)
        #expect(closed.devicePropValueReads == 0)
    }

    @Test func aRefusedFirst0x9211ReadIsRecordedWithItsOffset() async throws {
        let recorder = Recorder()
        let bench = try IPLinkResumeAgainstSimulatorTests.bench(trace: recorder.trace)
        try await bench.open()
        let raw = try #require(try await bench.link.list().first { $0.format == .raw })
        let content = try IPLinkResumeAgainstSimulatorTests.content(of: raw, on: bench.camera)
        let chunk = Int(IPLinkResumeAgainstSimulatorTests.chunk)
        let partial = bench.directory.appendingPathComponent(raw.name)
        try FileManager.default.createDirectory(at: bench.directory, withIntermediateDirectories: true)
        try content.prefix(chunk).write(to: partial)
        bench.camera.withResponder { $0.inject(.invalidObjectHandle, forNext: .sonySDIOGetPartialLargeObject) }
        _ = try await bench.link.bytes(of: raw.id, into: bench.directory,
                                       resuming: PartialDownload(file: partial, bytesWritten: UInt64(chunk)),
                                       checkpoint: { _ in }, progress: { _ in })
        #expect(recorder.all.contains(.resumeStarted(offset: UInt64(chunk), size: raw.size)))
        #expect(recorder.all.contains(.resumeRefused(offset: UInt64(chunk))))
        #expect(!recorder.all.contains { if case .resumeFinished = $0 { true } else { false } })
        await bench.link.close()
    }

    // MARK: Thumbnails (bench 19.1: thumbnails that never loaded, with nothing logged)

    @Test func answeredThumbnailsAreCountedWithTheirBytesAndTheFirstOnesTime() async throws {
        let recorder = Recorder()
        let bench = try LinkBench(trace: recorder.trace)
        try await bench.open()
        let items = try await bench.link.list()
        var bytes: UInt64 = 0
        for item in items.prefix(2) { bytes += UInt64(try await bench.link.thumbnail(of: item.id).count) }
        await bench.link.close()
        let seen = try #require(recorder.closed).thumbnails
        #expect(seen.asked == 2 && seen.answered == 2)
        #expect(seen.bytesTotal == bytes && bytes > 0)
        #expect(seen.failuresByCode.isEmpty && seen.timeouts == 0 && seen.otherFailures == 0 && seen.notListed == 0)
        // Nothing moved the camera's clock between the open and the thumbnail.
        #expect(seen.firstAfterOpen == .zero)
    }

    @Test func aThumbnailNotListedInDeviceInfoIsCountedAndNeverSent() async throws {
        var info = try CapturedA7C2.deviceInfo(.ptpIP)
        info.operationsSupported.removeAll { $0 == PTPOperationCode.getThumb.rawValue }
        let bench = try LinkBench(deviceInfo: info)
        try await bench.open()
        let item = try #require(try await bench.link.list().first)
        await #expect(throws: CameraLinkFailure.self) { try await bench.link.thumbnail(of: item.id) }
        #expect(!bench.camera.commandsAnswered.contains(.getThumb))
        let seen = await bench.link.diagnostics.thumbnails
        #expect(seen.notListed == 1 && seen.asked == 0)
        await bench.link.close()
    }

    @Test(arguments: [PTPResponseCode.operationNotSupported, .noThumbnailPresent])
    func aRefusedThumbnailIsCountedByCodeAndTheSessionStays(code: PTPResponseCode) async throws {
        let bench = try LinkBench()
        try await bench.open()
        let item = try #require(try await bench.link.list().first)
        bench.camera.withResponder { $0.inject(code, forNext: .getThumb) }
        await #expect(throws: CameraLinkFailure.self) { try await bench.link.thumbnail(of: item.id) }
        #expect(await bench.link.isOpen)
        #expect(try await !bench.link.thumbnail(of: item.id).isEmpty)
        let seen = await bench.link.diagnostics.thumbnails
        #expect(seen.asked == 2 && seen.answered == 1)
        #expect(seen.failuresByCode == [code: 1] && seen.refused == 1)
        await bench.link.close()
    }

    @Test func aThumbnailNeverAnsweredLosesTheSessionAndCountsATimeout() async throws {
        let recorder = Recorder()
        // A short reply limit on the real clock, so the unanswered GetThumb ends quickly; the simulated camera answers
        // everything else at once.
        let bench = try LinkBench(trace: recorder.trace) { $0.timing.reply = .seconds(1) }
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let item = try #require(try await bench.link.list().first)
        bench.camera.withResponder { $0.silence(forNext: .getThumb) }
        await #expect(throws: CameraLinkFailure.self) { try await bench.link.thumbnail(of: item.id) }
        #expect(await events.next() == .sessionLost)
        #expect(!(await bench.link.isOpen))
        #expect(recorder.all.contains { if case .linkLost(.timedOut?, _) = $0 { true } else { false } })
        await bench.link.close()
        let seen = try #require(recorder.closed).thumbnails
        #expect(seen.asked == 1 && seen.answered == 0 && seen.timeouts == 1)
        #expect(seen.firstAfterOpen == nil)
    }

    @Test func withoutATraceNothingIsRecordedAndTheLinkBehavesAlike() async throws {
        let bench = try LinkBench()
        try await bench.open()
        let traced = Recorder()
        let other = try LinkBench(trace: traced.trace)
        try await other.open()
        #expect(bench.camera.commandsAnswered == other.camera.commandsAnswered)
        #expect(bench.clock.elapsed == other.clock.elapsed)
        await bench.link.close()
        await other.link.close()
    }
}
