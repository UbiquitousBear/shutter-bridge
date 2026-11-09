import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

/// `PTPIPConnection` against the simulated camera over `InMemoryByteChannel`, through public API only (plan W3): the
/// handshake, transactions with data phases, events on the event channel, a second initiator refused as busy, and
/// the camera going away. Time limits run on the continuous clock but are never reached: every wait here is answered.
@Suite("PTP/IP connection against the simulated camera", .timeLimit(.minutes(1)))
struct PTPIPConnectionAgainstSimulatorTests {
    static let guid = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    /// The transport doesn't care which flavour the camera speaks. Tests that open a session and list use `.usbMTP`,
    /// where a plain OpenSession serves the card; in the PTP/IP flavour the real camera (and W1's simulator) needs
    /// Sony's whole-card session for that, which is the link's business, not this layer's.
    static func camera(flavour: SimulatorFlavour = .ptpIP) throws -> InMemoryPTPIPCamera {
        let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .jpeg])).scaled(down: 100)
        // Small Data packets, so a data phase spans many packets and reads.
        return try InMemoryPTPIPCamera(card: card, flavour: flavour, packetSize: 4096)
    }

    static func connection(to camera: InMemoryPTPIPCamera, maxRead: Int = 1500) -> PTPIPConnection {
        PTPIPConnection(endpoint: .cameraNetwork, guid: guid, friendlyName: "Shutter Bridge",
                        timing: .init(maxRead: maxRead), channels: camera)
    }

    /// The whole data phase of one transaction, and its reply.
    static func collect(_ connection: PTPIPConnection, _ command: PTPContainer) async throws -> (Data, PTPIPConnection.Reply) {
        let collected = Bytes()
        let reply = try await connection.perform(command) { collected.append($0) }
        return (collected.data, reply)
    }

    @Test func handshakeThenListAndCopyAFile() async throws {
        let camera = try Self.camera(flavour: .usbMTP)
        let connection = Self.connection(to: camera)
        let ack = try await connection.connect()
        #expect(ack.responderName == "ILCE-7CM2 (simulated)" && ack.connectionNumber == 1)
        #expect(camera.isConnected && camera.openCount == 2)

        var tx = PTPTransactionCounter()
        let (infoBytes, infoReply) = try await Self.collect(connection, PTPCommand.getDeviceInfo(tx: tx.take()))
        #expect(infoReply.code == .ok && infoReply.dataIsComplete)
        let info = try PTPDeviceInfo.decode(infoBytes)
        #expect(info.model == "ILCE-7CM2")

        #expect(try await connection.perform(PTPCommand.openSession(sessionID: 1)).code == .ok)
        let (handleBytes, _) = try await Self.collect(connection, PTPCommand.getObjectHandles(tx: tx.take()))
        let handles = try PTPObjectHandle.decodeArray(handleBytes)
        #expect(handles == camera.card.handles)

        let object = try #require(camera.card.objects.first)
        let (content, reply) = try await Self.collect(connection, PTPCommand.getObject(object.handle, tx: tx.take()))
        #expect(reply.code == .ok && reply.announcedDataLength == object.size && reply.dataIsComplete)
        #expect(content == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))

        #expect(try await connection.perform(PTPCommand.closeSession(tx: tx.take())).code == .ok)
        await connection.close()
        #expect(!camera.isConnected)
    }

    @Test func aShotArrivesOnTheEventChannel() async throws {
        let camera = try Self.camera()
        let connection = Self.connection(to: camera)
        var events = connection.events.makeAsyncIterator()
        _ = try await connection.connect()
        // No session: the event channel carries the shot without one, and a plain session means something else in
        // this flavour once the simulator plays the whole-card camera (W1).
        let added = camera.shoot([.jpeg])
        let event = try #require(await events.next())
        #expect(event.channel == .event)
        // The PTP/IP flavour announces a shot as Sony's 0xC201 with the buffer-slot handle.
        #expect(event.event.code.signalsNewObject)
        #expect(added.count == 1)
        await connection.close()
    }

    @Test func aSecondInitiatorIsRefusedAsBusy() async throws {
        let camera = try Self.camera()
        let first = Self.connection(to: camera)
        _ = try await first.connect()
        let second = Self.connection(to: camera)
        let failure = await #expect(throws: PTPIPConnectionFailure.self) { try await second.connect() }
        #expect(failure?.initFailReason == .busy)
        // The first is unharmed.
        #expect(try await first.perform(PTPCommand.getDeviceInfo(tx: 1)).code == .ok)
        await first.close()
    }

    @Test func aCameraInAnotherModeRefusesThePort() async throws {
        let camera = try Self.camera()
        camera.refusesConnections = true
        await #expect(throws: PTPIPConnectionFailure.refused(initFailReason: nil)) {
            try await Self.connection(to: camera).connect()
        }
    }

    @Test func theLocalNetworkWaitReachesTheStates() async throws {
        let camera = try Self.camera()
        camera.statesOnOpen = [.connecting, .waitingForLocalNetwork, .ready]
        let connection = Self.connection(to: camera)
        let states = connection.states
        _ = try await connection.connect()
        await connection.close()
        var seen: [ByteChannelState] = []
        for await state in states { seen.append(state) }
        #expect(seen == [.connecting, .waitingForLocalNetwork, .ready, .connecting, .waitingForLocalNetwork, .ready])
    }

    @Test func theCameraGoingAwayPoisonsTheConnection() async throws {
        let camera = try Self.camera()
        let connection = Self.connection(to: camera)
        let events = connection.events
        _ = try await connection.connect()
        camera.dropAll()
        for await _ in events {}
        #expect(await connection.linkFailure == .linkLost(posix: 53))
        await #expect(throws: PTPIPConnectionFailure.linkLost(posix: 53)) {
            try await connection.perform(PTPCommand.getDeviceInfo(tx: 1))
        }
        // The camera accepts a new initiator afterwards.
        let again = Self.connection(to: camera)
        _ = try await again.connect()
        #expect(try await again.perform(PTPCommand.getDeviceInfo(tx: 1)).code == .ok)
        await again.close()
    }
}

/// Collects data-phase bytes from a sink.
private final class Bytes: Sendable {
    private let bytes = Mutex(Data())
    func append(_ data: Data) { bytes.withLock { $0.append(data) } }
    var data: Data { bytes.withLock { $0 } }
}
