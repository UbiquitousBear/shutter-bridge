import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

/// `IPLink` against the simulated α7C II over `InMemoryByteChannel`, through public API only (plan W6): the whole-card
/// session opened in the planned order, list, thumbnail and bytes, the plain-session fallback, the keep-alive against
/// the camera's idle drop, serial pinning, decision 6 (only listed operations, never GetDevicePropValue), events, and
/// the Local Network wait.
///
/// The link's own waits (the plan's pauses, the poll, the keep-alive, the retry and reopen pauses) run on
/// `CameraClock`, which moves the camera's time with it, so they are exact; the connection's time limits stay on the
/// continuous clock and are never reached, because the simulated camera answers at once.
@Suite("IPLink against the simulated camera", .timeLimit(.minutes(1)))
struct IPLinkAgainstSimulatorTests {
    static let guid = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let utc = TimeZone(identifier: "UTC")!

    /// The opening's waits all end well inside this; the keep-alive (armed as the open ends, 10 s later) is past it.
    static let openHorizon: Duration = .seconds(10)

    /// One camera, one clock in step with it, a gate on the channels, one link, and a folder for downloads.
    final class Bench: Sendable {
        let camera: InMemoryPTPIPCamera
        let gate: ChannelGate
        let clock: CameraClock
        let link: IPLink
        let directory: URL

        init(frames: [ScriptedCard.Frame] = [.rawPlusJPEG, .jpeg, .raw],
             configure: (inout IPLink.Configuration) -> Void = { _ in }) throws {
            let card = try #require(ScriptedCard.shoot(frames)).scaled(down: 100)
            // Small Data packets, so a download spans many packets and reads.
            let camera = try InMemoryPTPIPCamera(card: card, flavour: .ptpIP, packetSize: 4096)
            self.camera = camera
            clock = CameraClock { camera.advance(by: $0) }
            var configuration = IPLink.Configuration(guid: IPLinkAgainstSimulatorTests.guid)
            configuration.timeZone = IPLinkAgainstSimulatorTests.utc
            configuration.timing.maxRead = 1500
            configure(&configuration)
            let descriptor = CameraDescriptor(id: .init(rawValue: "wifi-test"), name: "ILCE-7CM2",
                                              mode: .wifi(.cameraNetwork))
            gate = ChannelGate(camera)
            link = IPLink(descriptor: descriptor, configuration: configuration, channels: gate, clock: clock,
                          connectionClock: ContinuousClock())
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("IPLinkTests-\(UUID().uuidString)", isDirectory: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// Opens the link, moving the clock through the plan's waits.
        func open() async throws {
            let link = link
            let result = await clock.drive(within: IPLinkAgainstSimulatorTests.openHorizon) {
                () async -> Result<Void, CameraLinkFailure> in
                do throws(CameraLinkFailure) {
                    try await link.open()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            try result.get()
        }

        /// Starts a download whose first read holds the gate, and returns once it has: the GetObject stays on the
        /// wire until `gate.release()`.
        func downloadHeldOnTheWire(_ item: CameraItem, progress: Progressions = Progressions()) async throws
            -> Task<URL, any Error> {
            let link = link
            let directory = directory
            let gate = gate
            let download = Task { () async throws -> URL in
                try await link.bytes(of: item.id, into: directory) { written in
                    if progress.values.isEmpty { gate.hold() }
                    progress.add(written)
                }
            }
            while progress.values.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
            return download
        }

        /// The camera's handles in the order the link should list them: newest first, ties by name.
        var handlesNewestFirst: [PTPObjectHandle] {
            camera.card.objects
                .sorted { ($0.captureDateRaw, $1.filename) > ($1.captureDateRaw, $0.filename) }
                .map(\.handle)
        }
    }

    // MARK: Open

    @Test func opensTheWholeCardSessionInThePlannedOrder() async throws {
        let bench = try Bench()
        try await bench.open()
        #expect(await bench.link.isOpen)
        #expect(await bench.link.sessionKind == .wholeCardContentsTransfer)
        #expect(await bench.link.deviceInfo?.model == "ILCE-7CM2")
        // The spike's sequence (SonyContentsTransferPlan.wholeCard), then one poll that finds the card.
        #expect(bench.camera.commandsAnswered == [
            .sonySDIOOpenSession, .getDeviceInfo, .getDeviceInfo, .getStorageIDs,
            .sonySDIOConnect, .sonySDIOConnect, .sonySDIOGetExtDeviceInfo, .sonySDIOConnect, .sonySDIOGetExtDeviceInfo,
            .getDeviceInfo, .sonySDIOSetContentsTransferMode, .sonySDIOSetContentsTransferMode,
            .getStorageIDs, .getObjectHandles,
        ])
        // 200 ms after [2, 0, 0] and 1.5 s after [2, 1, 0]; the card arrived in the pause, so the first poll listed it.
        #expect(bench.clock.elapsed == .milliseconds(1_700))
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.pollAttempts == 1 && !diagnostics.pollTimedOut && diagnostics.timeToListing == .zero)
        // Every step accepted but GetStorageIDs, which answers StoreNotAvailable before the switch (tolerated).
        #expect(diagnostics.steps.count == 12)
        #expect(diagnostics.steps.filter { !$0.accepted }.map(\.operation) == [.getStorageIDs])
        #expect(diagnostics.steps.first { $0.operation == .getStorageIDs }?.response == .storeNotAvailable)
        #expect(diagnostics.skippedSteps.isEmpty && diagnostics.sessionsOpened == 1)
        await bench.link.close()
    }

    @Test func aSlowCardIsPolledUntilItLists() async throws {
        let bench = try Bench()
        // The card appears 6 s after [2, 1, 0] (sent at 0.2 s): the polls at 1.7 s and 3.7 s find nothing, the one at
        // 6.7 s (after 2 s and 3 s waits) lists it.
        bench.camera.withResponder { $0.wholeCard.readinessDelay = .seconds(6) }
        try await bench.open()
        #expect(bench.clock.elapsed == .milliseconds(6_700))
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.pollAttempts == 3 && diagnostics.timeToListing == .seconds(5))
        #expect(try await bench.link.list().count == bench.camera.card.objects.count)
        await bench.link.close()
    }

    @Test func aPlainSessionFallbackListsNothing() async throws {
        let bench = try Bench()
        // SDIO_OpenSession refused: the plan falls back to OpenSession, which on this camera lists nothing.
        bench.camera.withResponder { $0.inject(.operationNotSupported, forNext: .sonySDIOOpenSession) }
        try await bench.open()
        #expect(await bench.link.sessionKind == .plain)
        #expect(bench.camera.commandsAnswered.prefix(2) == [.sonySDIOOpenSession, .openSession])
        // No poll: a plain session never lists here.
        #expect(!bench.camera.commandsAnswered.contains(.getObjectHandles))
        #expect(await bench.link.diagnostics.pollAttempts == 0)
        #expect(try await bench.link.list().isEmpty)
        await bench.link.close()
    }

    @Test func aChangedSerialIsRefusedBeforeAnythingIsListed() async throws {
        let bench = try Bench { $0.knownSerial = "a serial this camera doesn't have" }
        let failure = await #expect(throws: CameraLinkFailure.self) { try await bench.open() }
        #expect(failure?.kind == .identityChanged && failure?.outcome == .stopJob)
        // Neither serial reaches the detail, only their lengths.
        #expect(failure?.detail?.contains("a serial this camera") == false)
        #expect(!(await bench.link.isOpen))
        #expect(!bench.camera.commandsAnswered.contains(.getObjectHandles))
        #expect(!bench.camera.isConnected)
        await #expect(throws: CameraLinkFailure(.disconnected, detail: "list: no open session")) {
            try await bench.link.list()
        }
    }

    @Test func theKnownSerialOpens() async throws {
        let serial = try CapturedA7C2.deviceInfo(.ptpIP).serialNumber
        let bench = try Bench { $0.knownSerial = serial }
        try await bench.open()
        #expect(await bench.link.isOpen)
        await bench.link.close()
    }

    @Test func aRefusedPortIsTriedOnceMoreThenRefused() async throws {
        let bench = try Bench()
        bench.camera.refusesConnections = true
        let failure = await #expect(throws: CameraLinkFailure.self) { try await bench.open() }
        #expect(failure?.kind == .refused)
        // One retry on a new connection, 1 s later.
        #expect(bench.camera.openCount == 2)
        #expect(bench.clock.elapsed == .seconds(1))
    }

    @Test func theLocalNetworkWaitIsAnEventNotAFailure() async throws {
        let bench = try Bench()
        bench.camera.statesOnOpen = [.connecting, .waitingForLocalNetwork, .ready]
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        // Both channels waited.
        #expect(await events.next() == .waitingForLocalNetwork)
        #expect(await events.next() == .waitingForLocalNetwork)
        await bench.link.close()
        #expect(await events.next() == nil)
    }

    // MARK: List, thumbnail, bytes

    @Test func listsNewestFirstThenThumbnailsAndCopiesAFile() async throws {
        let bench = try Bench()
        try await bench.open()
        let items = try await bench.link.list()
        let card = bench.camera.card
        #expect(items.count == card.objects.count)
        #expect(items.map(\.id.rawValue) == bench.handlesNewestFirst.map { "h-" + String($0.rawValue, radix: 16) })
        for item in items {
            let object = try #require(card.objects.first { $0.filename == item.name })
            #expect(item.size == object.size)
            #expect(item.captureDate == PTPDateTime.parse(object.captureDateRaw, defaultTimeZone: Self.utc))
            // The simulator serves no folder objects, so no folder can be named.
            #expect(item.folder.isEmpty)
            #expect(try await bench.link.info(of: item.id) == item)
        }

        let raw = try #require(items.first { $0.format == .raw })
        let handle = try #require(card.objects.first { $0.filename == raw.name }?.handle)
        #expect(try await bench.link.thumbnail(of: raw.id) == card.thumbnail(for: handle))

        let progress = Progressions()
        let url = try await bench.link.bytes(of: raw.id, into: bench.directory) { progress.add($0) }
        #expect(url.lastPathComponent == raw.name)
        // Byte for byte against the camera's content (stronger than comparing digests).
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: handle, in: 0 ..< raw.size))
        #expect(progress.values.last == raw.size && progress.values == progress.values.sorted())
        #expect(bench.camera.commandsAnswered.last == .getObject)
        await bench.link.close()
    }

    @Test func aThumbnailAskedForDuringADownloadWaitsItsTurn() async throws {
        let bench = try Bench()
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first { $0.format == .raw })
        let jpeg = try #require(items.first { $0.format == .jpeg })
        let link = bench.link
        let download = try await bench.downloadHeldOnTheWire(raw)
        // Asked for while the GetObject is on the wire: sent at once, either would fail as busy.
        let thumbnails = [jpeg, raw].map { item in Task { try await link.thumbnail(of: item.id) } }
        // Time for both to queue (if they haven't by then, they still go after the download).
        try await Task.sleep(for: .milliseconds(20))
        bench.gate.release()
        let url = try await download.value
        for thumbnail in thumbnails { #expect(try await !thumbnail.value.isEmpty) }
        #expect(try Data(contentsOf: url).count == Int(raw.size))
        #expect(Array(bench.camera.commandsAnswered.suffix(3)) == [.getObject, .getThumb, .getThumb])
        await link.close()
    }

    @Test func cancellingAThumbnailOnTheWireLetsItFinishAndKeepsTheSession() async throws {
        let bench = try Bench()
        let events = bench.link.events
        try await bench.open()
        let item = try #require(try await bench.link.list().first)
        let handle = try #require(bench.camera.card.objects.first { $0.filename == item.name }?.handle)
        let link = bench.link
        bench.gate.hold()
        let thumbnail = Task { try await link.thumbnail(of: item.id) }
        // The camera has answered GetThumb: the transaction is on the wire, its reply held at the gate.
        while bench.camera.commandsAnswered.last != .getThumb { try await Task.sleep(for: .milliseconds(1)) }
        thumbnail.cancel()  // a cell scrolled off screen
        bench.gate.release()
        #expect(try await thumbnail.value == bench.camera.card.thumbnail(for: handle))
        #expect(await link.isOpen)
        #expect(try await link.list().count == bench.camera.card.objects.count)
        #expect(await link.diagnostics.sessionsLost == 0)
        await link.close()
        var forwarded: [CameraLinkEvent] = []
        for await event in events { forwarded.append(event) }
        #expect(!forwarded.contains(.sessionLost))
    }

    @Test func aListingDuringADownloadHoldsTheTurnFromStartToEnd() async throws {
        let bench = try Bench()
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first { $0.format == .raw })
        let jpeg = try #require(items.first { $0.format == .jpeg })
        let link = bench.link
        let directory = bench.directory
        let before = bench.camera.commandsAnswered.count
        let first = try await bench.downloadHeldOnTheWire(raw)
        let listing = Task { try await link.list() }
        let second = Task { try await link.bytes(of: jpeg.id, into: directory) }
        try await Task.sleep(for: .milliseconds(20))
        bench.gate.release()
        #expect(try await listing.value.count == items.count)
        _ = try await (first.value, second.value)
        let sent = Array(bench.camera.commandsAnswered.dropFirst(before))
        #expect(sent.first == .getObject && sent.filter { $0 == .getObject }.count == 2)
        // No download in the middle of the listing: GetStorageIDs to the last GetObjectInfo in one run.
        let start = try #require(sent.firstIndex(of: .getStorageIDs))
        let end = try #require(sent.lastIndex(of: .getObjectInfo))
        let run = sent[start ... end]
        #expect(run.count == 2 + bench.camera.card.objects.count, "\(sent)")
        #expect(run.allSatisfy { [.getStorageIDs, .getObjectHandles, .getObjectInfo].contains($0) }, "\(sent)")
        await link.close()
    }

    @Test func sessionNotOpenDropsTheSessionSoOpenReopensIt() async throws {
        let bench = try Bench()
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let item = try #require(try await bench.link.list().first)
        // The camera restarted its responder and forgot the session.
        bench.camera.withResponder { $0.inject(.sessionNotOpen, forNext: .getObjectInfo) }
        let failure = await #expect(throws: CameraLinkFailure.self) { try await bench.link.info(of: item.id) }
        #expect(failure?.kind == .disconnected)
        #expect(await events.next() == .sessionLost)
        #expect(!(await bench.link.isOpen))
        try await bench.open()
        #expect(try await bench.link.list().count == bench.camera.card.objects.count)
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.sessionsOpened == 2 && diagnostics.sessionsLost == 1)
        await bench.link.close()
    }

    @Test func aFileGoneFromACardThatIsStillThereIsSkipped() async throws {
        let bench = try Bench()
        try await bench.open()
        let item = try #require(try await bench.link.list().first)
        bench.camera.withResponder { $0.inject(.invalidObjectHandle, forNext: .getObject) }
        let failure = await #expect(throws: CameraLinkFailure.self) {
            try await bench.link.bytes(of: item.id, into: bench.directory)
        }
        #expect(failure?.kind == .itemNotFound)
        // The storages were checked before calling it a missing file, and nothing was left on the phone.
        #expect(bench.camera.commandsAnswered.suffix(2) == [.getObject, .getStorageIDs])
        #expect(!FileManager.default.fileExists(atPath: bench.directory.appendingPathComponent(item.name).path))
        // The session is unharmed.
        #expect(try await bench.link.list().count == bench.camera.card.objects.count)
        await bench.link.close()
    }

    // MARK: Events

    @Test func aDroppedCardPausesRatherThanSkipsUntilItIsBack() async throws {
        let bench = try Bench()
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let item = try #require(try await bench.link.list().first)

        bench.camera.dropCard()
        // The opening's own StoreAdded was not forwarded: the first event is the drop.
        #expect(await events.next() == .storeRemoved)
        let failure = await #expect(throws: CameraLinkFailure.self) {
            try await bench.link.bytes(of: item.id, into: bench.directory)
        }
        #expect(failure?.kind == .cardUnavailable && failure?.outcome == .retryOnReconnect)
        await #expect(throws: CameraLinkFailure.self) { try await bench.link.thumbnail(of: item.id) }

        bench.camera.restoreCard()
        #expect(await events.next() == .storeAdded)
        let url = try await bench.link.bytes(of: item.id, into: bench.directory)
        #expect(try Data(contentsOf: url).count == Int(item.size))
        await bench.link.close()
    }

    @Test func aShotIsNotedAndIgnored() async throws {
        let bench = try Bench()
        let events = bench.link.events
        try await bench.open()
        bench.camera.shoot([.jpeg])
        // The camera announces it as Sony's 0xC201 with the buffer slot; the link only notes it.
        var noted = false
        for _ in 0 ..< 2_000 where !noted {
            noted = await bench.link.diagnostics.ignoredEvents.contains(.sonyObjectAdded)
            if !noted { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(noted)
        await bench.link.close()
        var forwarded: [CameraLinkEvent] = []
        for await event in events { forwarded.append(event) }
        #expect(forwarded.isEmpty)
    }

    // MARK: Keep-alive and the idle drop

    @Test func theKeepAliveHoldsTheSessionPastTheIdleDrop() async throws {
        let bench = try Bench()
        try await bench.open()
        await bench.clock.waitUntil { $0.sleepers > 0 }  // the keep-alive timer, armed as the open ended
        // 40 s without a call: a GetDeviceInfo every 10 s keeps the camera's 30 s idle drop away.
        for _ in 1 ... 4 { await bench.clock.tick(.seconds(10)) }
        #expect(bench.camera.isConnected)
        #expect(await bench.link.diagnostics.keepAlivesAnswered == 4)
        #expect(Array(bench.camera.commandsAnswered.suffix(4)) == Array(repeating: .getDeviceInfo, count: 4))
        #expect(try await bench.link.list().count == bench.camera.card.objects.count)
        await bench.link.close()
    }

    @Test func withoutTheKeepAliveTheIdleDropLosesTheSessionAndOpenReopensIt() async throws {
        let bench = try Bench { $0.keepAlive = nil }
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        bench.clock.advance(by: .seconds(30))
        #expect(await events.next() == .sessionLost)
        #expect(!(await bench.link.isOpen))
        let failure = await #expect(throws: CameraLinkFailure.self) { try await bench.link.list() }
        #expect(failure?.kind == .disconnected)

        // Reopen: a new connection 500 ms later, the whole plan again as a reopen, the same serial.
        let before = bench.clock.elapsed
        try await bench.open()
        #expect(bench.clock.elapsed - before == .milliseconds(2_200))
        #expect(try await bench.link.list().count == bench.camera.card.objects.count)
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.sessionsOpened == 2 && diagnostics.sessionsLost == 1)
        await bench.link.close()
    }

    // MARK: Decision 6 and closing

    @Test func onlyListedOperationsAreSentAndNeverGetDevicePropValue() async throws {
        let bench = try Bench()
        try await bench.open()
        let items = try await bench.link.list()
        for item in items.prefix(2) {
            _ = try await bench.link.thumbnail(of: item.id)
            _ = try await bench.link.bytes(of: item.id, into: bench.directory)
        }
        await bench.clock.tick(.seconds(10))
        await bench.link.close()
        let info = try #require(await bench.link.deviceInfo)
        let sent = bench.camera.commandsAnswered
        #expect(!sent.contains(.getDevicePropValue))
        #expect(sent.allSatisfy { info.supports($0) }, "\(sent.filter { !info.supports($0) })")
        // The session listed no property, so none may be read.
        #expect(!SonyCapabilities(deviceInfo: info).mayRead(PTPDevicePropCode(rawValue: 0x5001)))
    }

    @Test func closeSendsCloseSessionAndEndsEverything() async throws {
        let bench = try Bench()
        let events = bench.link.events
        try await bench.open()
        await bench.link.close()
        #expect(bench.camera.commandsAnswered.last == .closeSession)
        #expect(!bench.camera.isConnected)
        for await _ in events {}
        await #expect(throws: CameraLinkFailure(.disconnected, detail: "open: the link is closed")) {
            try await bench.link.open()
        }
        await bench.link.close()  // idempotent
    }
}

/// Progress values reported by a download.
final class Progressions: Sendable {
    private let state = Mutex<[UInt64]>([])
    func add(_ value: UInt64) { state.withLock { $0.append(value) } }
    var values: [UInt64] { state.withLock { $0 } }
}
