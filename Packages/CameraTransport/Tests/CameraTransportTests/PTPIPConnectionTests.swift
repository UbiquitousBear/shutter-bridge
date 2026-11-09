import Foundation
import PTPKit
import Testing
@testable import CameraTransport

/// `PTPIPConnection` against scripted channels on a manual clock (plan W3; backlog section 1): handshake order, the
/// ack and reply timeouts, poisoning, pings on both channels, events in a data phase, Init_Fail, the Local Network
/// wait, one transaction at a time and leftovers. Every timeout is driven by the clock, never by waiting.
@Suite("PTP/IP connection over scripted channels", .timeLimit(.minutes(1)))
struct PTPIPConnectionTests {
    static let initiator = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let camera = UUID(uuidString: "5A5A0000-0000-4000-8000-00000000A7C2")!
    static let connectionNumber: UInt32 = 7

    static var commandAck: PTPIP.Packet {
        PTPIP.initCommandAck(connectionNumber: connectionNumber, guid: camera, name: "ILCE-7CM2")
    }

    struct Rig {
        let connection: PTPIPConnection
        let command: ScriptedChannel
        let event: ScriptedChannel
        let factory: ScriptedFactory
        let clock: ManualClock
    }

    /// A connection whose factory will hand out `command` then `event`.
    static func rig(command: ScriptedChannel = ScriptedChannel(), event: ScriptedChannel = ScriptedChannel(),
                    steps: [ScriptedFactory.Step]? = nil, timing: PTPIPConnection.Timing = .init()) -> Rig {
        let factory = ScriptedFactory(steps ?? [.channel(command), .channel(event)])
        let clock = ManualClock()
        let connection = PTPIPConnection(endpoint: .cameraNetwork, guid: initiator, friendlyName: "Shutter Bridge",
                                         timing: timing, channels: factory, clock: clock)
        return Rig(connection: connection, command: command, event: event, factory: factory, clock: clock)
    }

    /// A rig that has finished the handshake (both acks queued before connecting).
    static func connected(commandChunk: Int = .max) async throws -> Rig {
        let r = rig(command: ScriptedChannel(readChunk: commandChunk))
        r.command.push(commandAck)
        r.event.push(PTPIP.initEventAck())
        _ = try await r.connection.connect()
        return r
    }

    static func deviceInfo(tx: UInt32 = 1) -> PTPContainer { PTPCommand.getDeviceInfo(tx: tx) }

    // MARK: Handshake

    @Test func handshakeOpensTheEventChannelOnlyAfterTheCommandAck() async throws {
        let r = Self.rig()
        let connecting = Task { try await r.connection.connect() }

        await r.command.waitForSends(1)
        let request = try #require(r.command.sentPackets.first)
        #expect(request.type == .initCommandRequest)
        let decoded = try PTPIP.decodeInitCommandRequest(request)
        #expect(decoded.guid == Self.initiator && decoded.friendlyName == "Shutter Bridge")
        #expect(decoded.protocolVersion == PTPIP.protocolVersion)
        // No second connection until the camera has acked the first.
        await r.command.waitForPendingReceive()
        #expect(r.factory.openCount == 1)

        r.command.push(Self.commandAck)
        await r.event.waitForSends(1)
        #expect(r.factory.openCount == 2)
        #expect(r.event.sentPackets == [PTPIP.initEventRequest(connectionNumber: Self.connectionNumber)])
        #expect(r.factory.opened.allSatisfy { $0.endpoint == .cameraNetwork && $0.timeout == .seconds(10) })

        r.event.push(PTPIP.initEventAck())
        let ack = try await connecting.value
        #expect(ack.connectionNumber == Self.connectionNumber && ack.responderName == "ILCE-7CM2")
        #expect(ack.responderGUID == Self.camera)
        #expect(await r.connection.isConnected)
        #expect(await r.connection.initCommandAck == ack)
    }

    @Test func noCommandAckWithinTheLimitTimesOutAndClosesTheChannel() async throws {
        let r = Self.rig()
        let connecting = Task { try await r.connection.connect() }
        await r.command.waitForPendingReceive()
        await r.clock.waitForSleepers(1)
        r.clock.advance(by: .seconds(60))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.initCommandAck)) { try await connecting.value }
        #expect(r.command.isClosed)
        #expect(r.factory.openCount == 1)
        #expect(await r.connection.linkFailure == .timedOut(.initCommandAck))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.initCommandAck)) {
            try await r.connection.perform(Self.deviceInfo())
        }
    }

    @Test func noEventAckTimesOutAndClosesBothChannels() async throws {
        let r = Self.rig()
        r.command.push(Self.commandAck)
        let connecting = Task { try await r.connection.connect() }
        await r.event.waitForPendingReceive()
        await r.clock.waitForSleepers(1)
        r.clock.advance(by: .seconds(60))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.initEventAck)) { try await connecting.value }
        #expect(r.command.isClosed && r.event.isClosed)
    }

    @Test func initFailBusyIsRefusedWithItsReason() async throws {
        let r = Self.rig()
        r.command.push(PTPIP.initFail(reason: PTPIP.InitFailReason.busy.rawValue))
        let failure = await #expect(throws: PTPIPConnectionFailure.self) { try await r.connection.connect() }
        #expect(failure == .refused(initFailReason: 2))
        #expect(failure?.initFailReason == .busy)
        #expect(r.command.isClosed)
        #expect(r.factory.openCount == 1)
    }

    @Test func initFailOnTheEventChannelIsRefusedToo() async throws {
        let r = Self.rig()
        r.command.push(Self.commandAck)
        r.event.push(PTPIP.initFail(reason: PTPIP.InitFailReason.rejectedInitiator.rawValue))
        await #expect(throws: PTPIPConnectionFailure.refused(initFailReason: 1)) { try await r.connection.connect() }
        #expect(r.command.isClosed && r.event.isClosed)
    }

    @Test func aRefusedPortIsRefusedWithNoReason() async throws {
        let r = Self.rig(steps: [.fail(.refused)])
        await #expect(throws: PTPIPConnectionFailure.refused(initFailReason: nil)) { try await r.connection.connect() }
    }

    @Test func somethingElseInsteadOfTheAckIsAProtocolViolation() async throws {
        let r = Self.rig()
        r.command.push(PTPIP.initEventAck())
        let failure = await #expect(throws: PTPIPConnectionFailure.self) { try await r.connection.connect() }
        guard case .protocolViolation? = failure else {
            Issue.record("expected a protocol violation, got \(String(describing: failure))")
            return
        }
        #expect(r.command.isClosed)
    }

    @Test func aPingBeforeTheAckIsAnswered() async throws {
        let r = Self.rig()
        r.command.push(PTPIP.ping(), Self.commandAck)
        r.event.push(PTPIP.ping(), PTPIP.initEventAck())
        _ = try await r.connection.connect()
        #expect(r.command.sentPackets.map(\.type) == [.initCommandRequest, .pong])
        #expect(r.event.sentPackets.map(\.type) == [.initEventRequest, .pong])
    }

    @Test func connectingTwiceOrPerformingFirstIsMisuseAndDoesNotPoison() async throws {
        let fresh = Self.rig()
        await #expect(throws: PTPIPConnectionFailure.notConnected) { try await fresh.connection.perform(Self.deviceInfo()) }
        #expect(await fresh.connection.linkFailure == nil)

        let r = try await Self.connected()
        await #expect(throws: PTPIPConnectionFailure.alreadyUsed) { try await r.connection.connect() }
        #expect(await r.connection.isConnected)
        await #expect(throws: PTPIPConnectionFailure.invalidCommand) {
            try await r.connection.perform(PTPContainer(type: .response, code: 0x2001, transactionID: 1))
        }
        #expect(await r.connection.isConnected)
    }

    // MARK: Local Network

    @Test func theLocalNetworkWaitIsPassedThroughAndGetsTheLongerLimit() async throws {
        let r = Self.rig(steps: [.hang(states: [.connecting, .waitingForLocalNetwork])])
        var states = r.connection.states.makeAsyncIterator()
        let connecting = Task { try await r.connection.connect() }
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .waitingForLocalNetwork)

        // At the plain 10 s limit the open is still allowed to wait: the timer goes on to the prompt's limit.
        await r.clock.waitForSleepers(1)
        r.clock.advance(by: .seconds(10))
        await r.clock.waitForSleepers(1)
        r.clock.advance(by: .seconds(50))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.connect)) { try await connecting.value }
        // The streams finish with the connection.
        #expect(await states.next() == nil)
    }

    @Test func withoutTheLocalNetworkWaitTheConnectLimitIsTenSeconds() async throws {
        let r = Self.rig(steps: [.hang(states: [.connecting])])
        let connecting = Task { try await r.connection.connect() }
        await r.factory.waitForOpens(1)
        await r.clock.waitForSleepers(1)
        r.clock.advance(by: .seconds(10))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.connect)) { try await connecting.value }
    }

    // MARK: Transactions

    @Test func aTransactionStreamsItsDataPhaseAndReturnsTheResponse() async throws {
        let r = try await Self.connected(commandChunk: 7)
        let payload = Data((0 ..< 300).map { UInt8($0 & 0xFF) })
        for packet in PTPIP.dataPhase(transactionID: 1, payload: payload, packetSize: 64) { r.command.push(packet) }
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 1, parameters: [9]))
        let collected = Collected()
        let reply = try await r.connection.perform(Self.deviceInfo()) { collected.append($0) }
        #expect(collected.data == payload)
        #expect(reply.code == .ok && reply.parameters == [9])
        #expect(reply.announcedDataLength == 300 && reply.receivedDataLength == 300 && reply.dataIsComplete)
        #expect(r.command.sentPackets.last == PTPIP.cmdRequest(Self.deviceInfo()))
    }

    @Test func aNonOKResponseIsReturnedAndTheConnectionStaysUsable() async throws {
        let r = try await Self.connected()
        r.command.push(PTPIP.cmdResponse(.storeNotAvailable, transactionID: 1))
        let reply = try await r.connection.perform(PTPCommand.getStorageIDs(tx: 1))
        #expect(reply.code == .storeNotAvailable && !reply.hadDataPhase)
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 2))
        #expect(try await r.connection.perform(Self.deviceInfo(tx: 2)).code == .ok)
        #expect(await r.connection.isConnected)
    }

    @Test func noReplyWithinTheLimitPoisonsTheConnection() async throws {
        let r = try await Self.connected()
        let performing = Task { try await r.connection.perform(Self.deviceInfo()) }
        await r.command.waitForPendingReceive()
        await r.clock.waitForSleepers(1)
        r.clock.advance(by: .seconds(30))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.transaction)) { try await performing.value }
        await r.command.waitUntilClosed()
        await r.event.waitUntilClosed()
        // Poisoned: a late reply changes nothing, and every later call throws the same failure.
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 1))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.transaction)) {
            try await r.connection.perform(Self.deviceInfo(tx: 2))
        }
        #expect(await !r.connection.isConnected)
    }

    @Test func aPerCallTimeoutReplacesTheReplyLimit() async throws {
        let r = try await Self.connected()
        let performing = Task { try await r.connection.perform(PTPCommand.closeSession(tx: 1), timeout: .seconds(5)) }
        await r.command.waitForPendingReceive()
        await r.clock.waitForSleepers(1)
        r.clock.advance(by: .seconds(5))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.transaction)) { try await performing.value }
    }

    @Test func aPingOnTheCommandChannelIsAnsweredInTheTransaction() async throws {
        let r = try await Self.connected()
        let performing = Task { try await r.connection.perform(Self.deviceInfo()) }
        await r.command.waitForSends(2)
        r.command.push(PTPIP.ping())
        await r.command.waitForSends(3)
        #expect(r.command.sentPackets.last == PTPIP.pong())
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 1))
        #expect(try await performing.value.code == .ok)
    }

    @Test func eventsInterleavedInADataPhaseAreForwardedAndTheDataIsWhole() async throws {
        let r = try await Self.connected(commandChunk: 5)
        var events = r.connection.events.makeAsyncIterator()
        let first = Data(repeating: 0xAB, count: 40)
        let second = Data(repeating: 0xCD, count: 25)
        r.command.push(PTPIP.startData(transactionID: 1, totalLength: 65),
                       PTPIP.data(transactionID: 1, bytes: first),
                       PTPIP.event(.objectAdded, parameters: [0x4000_10A3]),
                       PTPIP.ping(),
                       PTPIP.endData(transactionID: 1, bytes: second),
                       PTPIP.cmdResponse(.ok, transactionID: 1))
        let collected = Collected()
        let reply = try await r.connection.perform(PTPCommand.getObject(PTPObjectHandle(rawValue: 0x4000_10A3), tx: 1)) {
            collected.append($0)
        }
        #expect(collected.data == first + second)
        #expect(reply.dataIsComplete)
        let event = await events.next()
        #expect(event == PTPIPEvent(try PTPIP.decodeEvent(PTPIP.event(.objectAdded, parameters: [0x4000_10A3])),
                                    on: .command))
        #expect(r.command.sentPackets.last == PTPIP.pong())
    }

    @Test func aShortDataPhaseIsReportedNotHidden() async throws {
        let r = try await Self.connected()
        r.command.push(PTPIP.startData(transactionID: 1, totalLength: 100),
                       PTPIP.endData(transactionID: 1, bytes: Data(count: 60)),
                       PTPIP.cmdResponse(.ok, transactionID: 1))
        let reply = try await r.connection.perform(Self.deviceInfo())
        #expect(reply.announcedDataLength == 100 && reply.receivedDataLength == 60 && !reply.dataIsComplete)
    }

    @Test func aSecondTransactionWhileOneRunsIsBusyAndDoesNotPoison() async throws {
        let r = try await Self.connected()
        let first = Task { try await r.connection.perform(Self.deviceInfo()) }
        await r.command.waitForPendingReceive()
        await #expect(throws: PTPIPConnectionFailure.busy) { try await r.connection.perform(Self.deviceInfo(tx: 2)) }
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 1))
        #expect(try await first.value.code == .ok)
        #expect(await r.connection.isConnected)
        // Only one Cmd_Request went out.
        #expect(r.command.sentPackets.filter { $0.type == .cmdRequest }.count == 1)
    }

    @Test func leftoverDecoderOutputIsCarriedIntoTheNextTransaction() async throws {
        let r = try await Self.connected()
        var events = r.connection.events.makeAsyncIterator()
        // One read holds the first response, an event, a ping and the start of the next transaction's reply.
        let next = PTPIP.cmdResponse(.ok, transactionID: 2, parameters: [42]).encode()
        var bytes = PTPIP.cmdResponse(.ok, transactionID: 1).encode()
        bytes += PTPIP.event(.storeAdded, parameters: [0x0001_0001]).encode()
        bytes += PTPIP.ping().encode()
        bytes += next.prefix(6)
        r.command.push(bytes)
        #expect(try await r.connection.perform(Self.deviceInfo()).code == .ok)
        // The event went out and the ping was answered at once, before the next transaction.
        #expect(await events.next()?.event.code == .storeAdded)
        #expect(r.command.sentPackets.map(\.type) == [.initCommandRequest, .cmdRequest, .pong])

        r.command.push(next.dropFirst(6))
        let reply = try await r.connection.perform(Self.deviceInfo(tx: 2))
        #expect(reply.parameters == [42])
    }

    @Test func aWholeLeftoverResponseNeedsNoFurtherRead() async throws {
        let r = try await Self.connected()
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 1), PTPIP.cmdResponse(.ok, transactionID: 2, parameters: [3]))
        _ = try await r.connection.perform(Self.deviceInfo())
        let reads = r.command.receiveCount
        #expect(try await r.connection.perform(Self.deviceInfo(tx: 2)).parameters == [3])
        #expect(r.command.receiveCount == reads)
    }

    @Test func anotherTransactionsResponseIsAProtocolViolation() async throws {
        let r = try await Self.connected()
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 9))
        let failure = await #expect(throws: PTPIPConnectionFailure.self) { try await r.connection.perform(Self.deviceInfo()) }
        guard case .protocolViolation? = failure else {
            Issue.record("expected a protocol violation, got \(String(describing: failure))")
            return
        }
        #expect(r.command.isClosed)
    }

    @Test func anInitiatorDataPhaseFollowsTheRequest() async throws {
        let r = try await Self.connected()
        let out = Data([1, 2, 3, 4, 5])
        let command = PTPContainer(type: .command, code: 0x1016, transactionID: 1, parameters: [0x5001])
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 1))
        _ = try await r.connection.perform(command, dataOut: out)
        let sent = Array(r.command.sentPackets.dropFirst())
        #expect(sent == [PTPIP.cmdRequest(command, dataPhase: .initiatorToResponder),
                         PTPIP.startData(transactionID: 1, totalLength: 5),
                         PTPIP.endData(transactionID: 1, bytes: out)])
    }

    @Test func aThrowingSinkPoisonsTheConnection() async throws {
        struct DiskFull: Error {}
        let r = try await Self.connected()
        r.command.push(PTPIP.startData(transactionID: 1, totalLength: 10),
                       PTPIP.endData(transactionID: 1, bytes: Data(count: 10)),
                       PTPIP.cmdResponse(.ok, transactionID: 1))
        let failure = await #expect(throws: PTPIPConnectionFailure.self) {
            try await r.connection.perform(Self.deviceInfo()) { _ in throw DiskFull() }
        }
        guard case .sinkFailed? = failure else {
            Issue.record("expected a sink failure, got \(String(describing: failure))")
            return
        }
        #expect(r.command.isClosed && r.event.isClosed)
    }

    @Test func aLinkLossMidTransferPoisonsWithThePOSIXError() async throws {
        let r = try await Self.connected()
        r.command.push(PTPIP.startData(transactionID: 1, totalLength: 1000), PTPIP.data(transactionID: 1, bytes: Data(count: 100)))
        r.command.hangUp(.linkLost(posix: 53))
        await #expect(throws: PTPIPConnectionFailure.linkLost(posix: 53)) { try await r.connection.perform(Self.deviceInfo()) }
        #expect(r.event.isClosed)
    }

    // MARK: Ending

    @Test func abortTransferCutsTheDataPhaseAtOnce() async throws {
        let r = try await Self.connected()
        let collected = Collected()
        let performing = Task {
            try await r.connection.perform(PTPCommand.getObject(PTPObjectHandle(rawValue: 1), tx: 1)) { collected.append($0) }
        }
        r.command.push(PTPIP.startData(transactionID: 1, totalLength: 1 << 30), PTPIP.data(transactionID: 1, bytes: Data(count: 512)))
        await r.command.waitForSends(2)
        // The first chunk is through and the connection is waiting for more.
        await r.command.waitForPendingReceive()
        #expect(collected.data.count == 512)
        await r.connection.abortTransfer()
        await #expect(throws: PTPIPConnectionFailure.aborted) { try await performing.value }
        // Both channels are closed by the time the interrupted call returns, so a reconnect can't meet the old ones.
        #expect(r.command.isClosed && r.event.isClosed)
        await #expect(throws: PTPIPConnectionFailure.aborted) { try await r.connection.perform(Self.deviceInfo(tx: 2)) }
    }

    @Test func cancellingTheCallerPoisonsTheConnection() async throws {
        let r = try await Self.connected()
        let performing = Task { try await r.connection.perform(Self.deviceInfo()) }
        await r.command.waitForPendingReceive()
        performing.cancel()
        await #expect(throws: PTPIPConnectionFailure.cancelled) { try await performing.value }
        #expect(r.command.isClosed)
    }

    @Test func aCallerCancelledBeforePerformSendsNothingAndDoesNotPoison() async throws {
        let r = try await Self.connected()
        let performing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await r.connection.perform(Self.deviceInfo())
        }
        await #expect(throws: PTPIPConnectionFailure.cancelledBeforeStart) { try await performing.value }
        #expect(r.command.sentPackets.map(\.type) == [.initCommandRequest])
        #expect(await r.connection.isConnected && !r.command.isClosed && !r.event.isClosed)
        r.command.push(PTPIP.cmdResponse(.ok, transactionID: 1))
        #expect(try await r.connection.perform(Self.deviceInfo()).code == .ok)
    }

    @Test func aCallerCancelledBeforeConnectOpensNothing() async throws {
        let r = Self.rig()
        let connecting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await r.connection.connect()
        }
        await #expect(throws: PTPIPConnectionFailure.cancelledBeforeStart) { try await connecting.value }
        #expect(r.factory.openCount == 0)
        #expect(await r.connection.linkFailure == nil)
        // The connection is still unused, so it can connect.
        r.command.push(Self.commandAck)
        r.event.push(PTPIP.initEventAck())
        _ = try await r.connection.connect()
        #expect(await r.connection.isConnected)
    }

    @Test func closeEndsTheStreamsAndEveryLaterCall() async throws {
        let r = try await Self.connected()
        let events = r.connection.events
        let performing = Task { try await r.connection.perform(Self.deviceInfo()) }
        await r.command.waitForPendingReceive()
        await r.connection.close()
        await #expect(throws: PTPIPConnectionFailure.closed) { try await performing.value }
        #expect(r.command.isClosed && r.event.isClosed)
        for await _ in events {}
        await #expect(throws: PTPIPConnectionFailure.closed) { try await r.connection.perform(Self.deviceInfo(tx: 2)) }
        await #expect(throws: PTPIPConnectionFailure.closed) { try await r.connection.connect() }
        await r.connection.close()
    }

    @Test func closeDuringTheHandshakeEndsIt() async throws {
        let r = Self.rig()
        let connecting = Task { try await r.connection.connect() }
        await r.command.waitForPendingReceive()
        await r.connection.close()
        await #expect(throws: PTPIPConnectionFailure.closed) { try await connecting.value }
        #expect(r.command.isClosed)
    }

    // MARK: Event channel

    @Test func theEventChannelForwardsEventsAndAnswersPings() async throws {
        let r = try await Self.connected()
        var events = r.connection.events.makeAsyncIterator()
        r.event.push(PTPIP.ping(), PTPIP.event(.storeAdded, parameters: [0x0001_0001]))
        let event = await events.next()
        #expect(event == PTPIPEvent(try PTPIP.decodeEvent(PTPIP.event(.storeAdded, parameters: [0x0001_0001])), on: .event))
        await r.event.waitForSends(2)
        #expect(r.event.sentPackets.map(\.type) == [.initEventRequest, .pong])
        // The event channel waits with no time limit: nothing is sleeping on the clock.
        await r.event.waitForPendingReceive()
        #expect(r.clock.sleeperCount == 0)
    }

    @Test func losingTheEventChannelPoisonsTheConnection() async throws {
        let r = try await Self.connected()
        let events = r.connection.events
        r.event.hangUp(.linkLost(posix: 53))
        for await _ in events {}
        await r.command.waitUntilClosed()
        #expect(await r.connection.linkFailure == .linkLost(posix: 53))
        await #expect(throws: PTPIPConnectionFailure.linkLost(posix: 53)) { try await r.connection.perform(Self.deviceInfo()) }
    }

    // MARK: Endpoint

    @Test func theEndpointWithholdsAnyAddressButTheCamerasOwn() {
        #expect(PTPIPEndpoint.cameraNetwork.host == "192.168.122.1" && PTPIPEndpoint.cameraNetwork.port == 15740)
        #expect(PTPIPEndpoint.cameraNetwork.description.contains("192.168.122.1"))
        let home = PTPIPEndpoint(host: "10.0.0.20")
        #expect(!home.description.contains("10.0.0.20"))
    }

    // MARK: Test support

    @Test func theManualClockWakesAWaitForFewerSleepers() async {
        let clock = ManualClock()
        let short = Task { try await clock.sleep(for: .seconds(1)) }
        let long = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        long.cancel()
        await clock.waitForSleepers(0)
        _ = await (short.result, long.result)
    }
}
