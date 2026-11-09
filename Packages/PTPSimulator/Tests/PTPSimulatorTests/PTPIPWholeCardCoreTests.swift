import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

// The whole-card session over PTP/IP at the core (no sockets): the handshake, Sony's operations as packets, the events
// on the second channel, and the waits the behaviour names, all on a clock the test advances.

private func core(behaviour: WholeCardBehaviour = WholeCardBehaviour()) throws -> PTPIPResponderCore {
    let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 10_000)
    return PTPIPResponderCore(responder: try PTPResponder(card: card, flavour: .ptpIP, wholeCard: behaviour))
}

extension LoopbackInitiator {
    /// Time goes by: what the core sends or closes as a result.
    mutating func advance(_ elapsed: Duration) {
        perform(core.advance(by: elapsed))
    }

    /// The events waiting on the event channel.
    mutating func events() throws -> [PTPIP.Event] {
        try packets(on: 2).map(PTPIP.decodeEvent)
    }

    /// The plan's steps as the PTP/IP initiator sends them, with the plan's pauses on the core's clock.
    mutating func openWholeCardSession() throws -> SonySessionRunner.Action {
        var runner = SonySessionRunner(plan: .wholeCard())
        var action = runner.next(nil)
        while true {
            switch action {
            case let .send(step):
                let command = step.operation.command(using: &tx)
                let reply = try transact(command)
                if step.operation == .getDeviceInfo, reply.response.code == .ok {
                    action = runner.next(.deviceInfo(try PTPDeviceInfo.decode(reply.data)))
                } else {
                    action = runner.next(.response(reply.response.code))
                }
            case let .wait(pause):
                advance(pause)
                action = runner.next(nil)
            case .list, .stop:
                return action
            }
        }
    }
}

@Suite("PTP/IP whole-card core")
struct PTPIPWholeCardCoreTests {
    @Test func theWholeSequenceRunsOverThePackets() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        guard case .list = try i.openWholeCardSession() else {
            Issue.record("the plan didn't reach the listing")
            return
        }
        // The plan paused 1.5 s after the switch and the default delay is 300 ms: StoreAdded arrived during the pause,
        // and the poll's first attempt lists the card, as it did on the camera.
        let added = try i.events()
        #expect(added.map(\.code) == [.storeAdded] && added.first?.parameters == [0x0001_0001])
        #expect(added.first?.transactionID == 0xFFFF_FFFF)

        let handles = try PTPObjectHandle.decodeArray(try i.command { PTPCommand.getObjectHandles(tx: $0) }.data)
        #expect(handles == i.core.responder.card.handles)
        // Download one file by 0x9211 in three pieces: it matches the scripted bytes.
        let o = i.core.responder.card.objects[0]
        var got = Data()
        let piece = o.size / 3 + 1
        for _ in 0 ..< 4 where UInt64(got.count) < o.size {
            let read = try i.command {
                PTPCommand.sonyGetPartialLargeObject(code: 0x9211, o.handle, offset: UInt64(got.count), length: piece, tx: $0)
            }
            #expect(read.response.code == .ok)
            got += read.data
        }
        #expect(got == ScriptedCard.content(of: o.handle, in: 0 ..< o.size))
    }

    @Test func aPlainSessionOverThePacketsAnswersStoreNotAvailable() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        #expect(try i.transact(PTPCommand.openSession(sessionID: 1)).response.code == .ok)
        #expect(try i.command { PTPCommand.getStorageIDs(tx: $0) }.response.code == .storeNotAvailable)
        i.advance(.seconds(10))
        #expect(try i.command { PTPCommand.getStorageIDs(tx: $0) }.response.code == .storeNotAvailable)
    }

    @Test func aReadinessDelayOfZeroSendsStoreAddedRightAfterTheResponse() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.readinessDelay = .zero
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        _ = try i.connect()
        _ = try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        #expect(try i.events().isEmpty)
        let reply = try i.transact(PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 2))
        #expect(reply.response.code == .ok)
        #expect(try i.events().map(\.code) == [.storeAdded])
    }

    @Test func theCardDropsOnTheEventChannelBeforeTheNextGetObjectFails() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.readinessDelay = .zero
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        _ = try i.connect()
        _ = try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        _ = try i.transact(PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 2))
        _ = try i.events()
        let h = i.core.responder.card.handles[0]
        #expect(try i.command { PTPCommand.getObject(h, tx: $0) }.response.code == .ok)

        i.perform(i.core.dropCard())
        let removed = try i.events()
        #expect(removed.map(\.code) == [.storeRemoved] && removed.first?.parameters == [0x0001_0001])
        #expect(try i.command { PTPCommand.getObject(h, tx: $0) }.response.code == .storeNotAvailable)

        i.perform(i.core.restoreCard())
        #expect(try i.events().map(\.code) == [.storeAdded])
        #expect(try i.command { PTPCommand.getObject(h, tx: $0) }.response.code == .ok)
        // No event channel, no events: the core says nothing to nobody.
        i.perform(i.core.disconnected(1))
        #expect(i.core.dropCard().isEmpty && i.core.restoreCard().isEmpty)
    }

    @Test func getDevicePropValueGetsNoResponseAtAll() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        _ = try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        i.write(PTPIP.cmdRequest(PTPCommand.getDevicePropValue(.batteryLevel, tx: 2)).encode(), on: 1)
        #expect(try i.packets(on: 1).isEmpty)
        // The next command is answered as usual; the transaction that never finished is the initiator's to give up on.
        #expect(try i.transact(PTPCommand.getDeviceInfo(tx: 3)).response.code == .ok)
    }

    // MARK: - Waits

    @Test func theFirstInitAckIsHeldForTheDelayAndOnlyTheFirst() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.firstInitAckDelay = .seconds(40)
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "slow").encode(), on: 1)
        #expect(try i.packets(on: 1).isEmpty)
        i.advance(.milliseconds(39_999))
        #expect(try i.packets(on: 1).isEmpty)
        i.advance(.milliseconds(1))
        let ack = try PTPIP.decodeInitCommandAck(try #require(try i.packets(on: 1).first))
        #expect(ack.connectionNumber == 1)
        // The event channel opens as usual with the number from the ack.
        i.open(2)
        i.write(PTPIP.initEventRequest(connectionNumber: ack.connectionNumber).encode(), on: 2)
        #expect(try i.packets(on: 2).map(\.type) == [.initEventAck])

        // After the connection ends, the next attempt is answered at once.
        i.perform(i.core.disconnected(1))
        i.open(3)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "again").encode(), on: 3)
        #expect(try i.packets(on: 3).map(\.type) == [.initCommandAck])
    }

    @Test func aHeldAckForAConnectionThatLeftIsNeverSent() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.firstInitAckDelay = .seconds(40)
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "gave up").encode(), on: 1)
        i.perform(i.core.disconnected(1))
        i.advance(.seconds(60))
        #expect(try i.packets(on: 1).isEmpty && !i.core.isConnected)
    }

    @Test func dropAllArmsTheHoldAgainForTheReconnect() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.firstInitAckDelay = .seconds(40)
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "first").encode(), on: 1)
        i.advance(.seconds(40))
        #expect(try i.packets(on: 1).map(\.type) == [.initCommandAck])

        // The Wi-Fi restarts: the reconnect's first answer is slow again, and the one after it is not.
        i.perform(i.core.dropAll())
        i.open(2)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "recovery").encode(), on: 2)
        #expect(try i.packets(on: 2).isEmpty)
        i.advance(.milliseconds(39_999))
        #expect(try i.packets(on: 2).isEmpty)
        i.advance(.milliseconds(1))
        #expect(try i.packets(on: 2).map(\.type) == [.initCommandAck])
        i.perform(i.core.disconnected(2))
        i.open(3)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "retry").encode(), on: 3)
        #expect(try i.packets(on: 3).map(\.type) == [.initCommandAck])
    }

    @Test func anIdleDropDoesNotArmTheHoldAgain() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.firstInitAckDelay = .seconds(40)
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "first").encode(), on: 1)
        i.advance(.seconds(40))
        _ = try i.packets(on: 1)
        i.open(2)
        i.write(PTPIP.initEventRequest(connectionNumber: 1).encode(), on: 2)
        _ = try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        i.advance(.seconds(30))
        #expect(!i.core.isConnected)
        // The camera's Wi-Fi stayed up: the reconnect is answered at once.
        i.open(3)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "again").encode(), on: 3)
        #expect(try i.packets(on: 3).map(\.type) == [.initCommandAck])
    }

    @Test func holdNextInitAckHoldsTheNextRequestOnly() throws {
        var i = LoopbackInitiator(core: try core())
        i.core.holdNextInitAck(for: .seconds(5))
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "slow").encode(), on: 1)
        #expect(try i.packets(on: 1).isEmpty)
        i.advance(.seconds(5))
        #expect(try i.packets(on: 1).map(\.type) == [.initCommandAck])
        i.perform(i.core.disconnected(1))
        i.open(2)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "fast").encode(), on: 2)
        #expect(try i.packets(on: 2).map(\.type) == [.initCommandAck])
    }

    @Test func aSecondInitiatorIsBusyWhileTheFirstAckIsHeld() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.firstInitAckDelay = .seconds(40)
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "first").encode(), on: 1)
        i.open(2)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "second").encode(), on: 2)
        let refusal = try #require(try i.packets(on: 2).first)
        #expect(refusal.type == .initFail && PTPIP.decodeInitFail(refusal) == PTPIP.InitFailReason.busy.rawValue)
    }

    @Test func anIdleSessionClosesBothChannelsAndAnotherCanConnect() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        _ = try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        i.advance(.seconds(29))
        #expect(i.closed.isEmpty && i.core.isConnected)
        i.advance(.seconds(1))
        #expect(i.closed == [1, 2] && !i.core.isConnected && i.core.responder.sessionID == nil)

        i.closed = []
        _ = try i.connect()
        #expect(try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).response.code == .ok)
    }

    @Test func aKeepAliveEveryTenSecondsKeepsTheSessionAndAnythingElseDoesToo() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        _ = try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        for _ in 0 ..< 30 {
            i.advance(.seconds(10))
            _ = try i.command { PTPCommand.getDeviceInfo(tx: $0) }
        }
        #expect(i.closed.isEmpty && i.core.isConnected)
    }

    @Test func theCardIsAnnouncedBeforeAnIdleDropInTheSameStep() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        _ = try i.transact(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        _ = try i.transact(PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 2))
        i.advance(.seconds(60))
        // Event first, then the close: the event channel carries StoreAdded before it ends.
        #expect(try i.events().map(\.code) == [.storeAdded])
        #expect(i.closed == [1, 2])
    }

    @Test func dropAllEndsAHeldHandshakeAndTheSession() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.firstInitAckDelay = .seconds(40)
        var i = LoopbackInitiator(core: try core(behaviour: behaviour))
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "x").encode(), on: 1)
        i.perform(i.core.dropAll())
        #expect(i.closed == [1])
        i.advance(.seconds(60))
        #expect(try i.packets(on: 1).isEmpty)
    }
}
