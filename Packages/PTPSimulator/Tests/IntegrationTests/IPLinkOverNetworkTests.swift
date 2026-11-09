#if canImport(Network)
import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import Synchronization
import Testing

/// `IPLink` over real TCP: `NWByteChannelFactory(interface: .loopbackForTests)` against `PTPIPSimulatorServer` on
/// loopback (wireless plan W9). Compiled and run by CI's Xcode 27 job in the iOS Simulator (Network.framework isn't on
/// Linux, where `IPLinkAgainstSimulatorTests` covers the same link over in-memory channels). It covers a full open, a
/// list, a thumbnail and a download byte for byte, the camera dropping both connections (`.sessionLost`, then a reopen),
/// a refused port (through the link and on the channel alone), and the channel's own contract (its states, and `close()`
/// ending every call). The other end closing (end of stream) is covered through the link, by `dropConnections()`.
///
/// The server keeps no clock, so the card is ready the moment `[2, 1, 0]` is answered and the idle drop is off; the
/// link's own waits (the plan's 200 ms and 1.5 s pauses, the retry and reopen pauses) run on `CameraClock`, moved only
/// while the link is parked on it, and the connection's time limits stay on the continuous clock, never reached on
/// loopback. The Local Network wait can't be shown here (loopback needs no permission): that is a bench check.
@Suite("IPLink over Network.framework against the simulated camera", .timeLimit(.minutes(1)))
struct IPLinkOverNetworkTests {
    static let guid = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let utc = TimeZone(identifier: "UTC")!
    static let horizon: Duration = .seconds(10)

    /// A server on loopback with a small card, and a link to it over Network.framework.
    struct Bench: Sendable {
        let server: PTPIPSimulatorServer
        let card: ScriptedCard
        let clock: CameraClock
        let link: IPLink
        let directory: URL

        static func make() async throws -> Bench {
            let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .jpeg, .raw])).scaled(down: 100)
            var behaviour = WholeCardBehaviour()
            behaviour.readinessDelay = .zero  // no clock in the server: the card is there at once
            behaviour.idleDropAfter = nil
            let responder = try PTPResponder(card: card, flavour: .ptpIP, wholeCard: behaviour)
            // Small Data packets, so a download spans many packets and reads.
            let server = PTPIPSimulatorServer(core: PTPIPResponderCore(responder: responder), packetSize: 4096)
            let port = try await server.start()
            var configuration = IPLink.Configuration(guid: IPLinkOverNetworkTests.guid,
                                                     endpoint: PTPIPEndpoint(host: "127.0.0.1", port: port))
            configuration.timeZone = IPLinkOverNetworkTests.utc
            let clock = CameraClock()
            let descriptor = CameraDescriptor(id: .init(rawValue: "wifi-loopback"), name: "ILCE-7CM2",
                                              mode: .wifi(.cameraNetwork))
            let link = IPLink(descriptor: descriptor, configuration: configuration,
                              channels: NWByteChannelFactory(interface: .loopbackForTests), clock: clock,
                              connectionClock: ContinuousClock())
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("IPLinkOverNetworkTests-\(UUID().uuidString)", isDirectory: true)
            return Bench(server: server, card: card, clock: clock, link: link, directory: directory)
        }

        /// Opens the link, moving the virtual clock through the plan's waits.
        func open() async throws {
            let link = link
            let result = try await clock.drive(within: IPLinkOverNetworkTests.horizon) {
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

        func finish() async {
            await link.close()
            await server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Waits in real time (the suite's limit is the backstop) until `condition` holds.
    static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: The link

    @Test func opensListsThumbnailsAndCopiesAFileOverTCP() async throws {
        let bench = try await Bench.make()
        try await bench.open()
        #expect(await bench.link.isOpen)
        #expect(await bench.link.sessionKind == .wholeCardContentsTransfer)
        #expect(await bench.link.deviceInfo?.model == "ILCE-7CM2")
        #expect(await bench.server.isConnected)
        // The plan's two pauses, and the card listed at the first poll.
        #expect(bench.clock.elapsed == .milliseconds(1_700))

        let items = try await bench.link.list()
        #expect(items.count == bench.card.objects.count)
        let raw = try #require(items.first { $0.format == .raw })
        let handle = try #require(bench.card.objects.first { $0.filename == raw.name }?.handle)
        #expect(try await bench.link.thumbnail(of: raw.id) == bench.card.thumbnail(for: handle))

        let url = try await bench.link.bytes(of: raw.id, into: bench.directory)
        #expect(url.lastPathComponent == raw.name)
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: handle, in: 0 ..< raw.size))

        await bench.link.close()
        let server = bench.server
        #expect(await Self.eventually { await !server.isConnected })
        await bench.finish()
    }

    @Test func droppedConnectionsAreASessionLostAndOpenReopens() async throws {
        let bench = try await Bench.make()
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let count = try await bench.link.list().count

        // The camera going out of range: both TCP connections close under the link.
        await bench.server.dropConnections()
        #expect(await events.next() == .sessionLost)
        #expect(!(await bench.link.isOpen))
        let failure = await #expect(throws: CameraLinkFailure.self) { try await bench.link.list() }
        #expect(failure?.kind == .disconnected)

        // A new connection after the reopen pause, the whole plan again, the same card.
        try await bench.open()
        #expect(try await bench.link.list().count == count)
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.sessionsOpened == 2 && diagnostics.sessionsLost == 1)
        await bench.finish()
    }

    @Test func aPortWithNothingListeningIsRefused() async throws {
        let bench = try await Bench.make()
        await bench.server.stop()  // returns once the listener is cancelled: the port refuses
        let failure = await #expect(throws: CameraLinkFailure.self) { try await bench.open() }
        #expect(failure?.kind == .refused)
        // Tried once more on a new connection, 1 s later.
        #expect(bench.clock.elapsed == .seconds(1))
        await bench.finish()
    }

    // MARK: The channel

    @Test func theChannelReportsItsStatesAndEndsEveryCallOnceClosed() async throws {
        let bench = try await Bench.make()
        let port = try #require(await bench.server.port)
        let states = StateLog()
        let channel = try await NWByteChannelFactory(interface: .loopbackForTests)
            .open(PTPIPEndpoint(host: "127.0.0.1", port: port), timeout: .seconds(10)) { states.add($0) }
        let seen = states.values
        #expect(seen.last == .ready && !seen.contains(.waitingForLocalNetwork), "\(seen)")

        // The server says nothing before Init_Command_Request, so this read waits until `close()` ends it.
        let pending = Task { try await channel.receive(atMost: 64) }
        try await Task.sleep(for: .milliseconds(20))
        await channel.close()
        await #expect(throws: ByteChannelFailure.closed) { try await pending.value }
        await #expect(throws: ByteChannelFailure.closed) { try await channel.send(Data([1])) }
        await #expect(throws: ByteChannelFailure.closed) { try await channel.receive(atMost: 1) }
        await channel.close()  // idempotent
        await bench.finish()
    }

    @Test func aClosedPortRefusesTheChannel() async throws {
        let bench = try await Bench.make()
        let port = try #require(await bench.server.port)
        await bench.server.stop()  // returns once the listener is cancelled: the port refuses
        await #expect(throws: ByteChannelFailure.refused) {
            try await NWByteChannelFactory(interface: .loopbackForTests)
                .open(PTPIPEndpoint(host: "127.0.0.1", port: port), timeout: .seconds(10)) { _ in }
        }
        await bench.finish()
    }
}

/// The states a channel reported while opening.
final class StateLog: Sendable {
    private let state = Mutex<[ByteChannelState]>([])
    func add(_ value: ByteChannelState) { state.withLock { $0.append(value) } }
    var values: [ByteChannelState] { state.withLock { $0 } }
}
#endif
