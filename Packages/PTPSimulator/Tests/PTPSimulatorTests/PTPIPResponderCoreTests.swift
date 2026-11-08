import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

/// A PTP/IP initiator built from PTPKit, wired to the core in memory: connection 1 is the command channel, 2 the
/// event channel. Requests go in a few bytes at a time, so the core's framing is exercised across splits.
struct LoopbackInitiator {
    var core: PTPIPResponderCore
    var inbound: [Int: Data] = [:]
    var closed: Set<Int> = []
    var decoders: [Int: PTPIPStreamDecoder] = [:]
    var tx = PTPTransactionCounter()
    let split: Int

    init(core: PTPIPResponderCore, split: Int = 5) {
        self.core = core
        self.split = split
    }

    mutating func open(_ id: Int) {
        core.connected(id)
        inbound[id] = Data()
        decoders[id] = PTPIPStreamDecoder()
    }

    mutating func write(_ bytes: Data, on id: Int) {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let end = min(i + split, bytes.endIndex)
            perform(core.received(bytes.subdata(in: i ..< end), on: id))
            i = end
        }
    }

    mutating func perform(_ actions: [PTPIPResponderCore.Action]) {
        for action in actions {
            switch action {
            case let .send(packet, to: id):
                inbound[id, default: Data()] += packet.encode()
            case let .sendData(transactionID, phase, to: id):
                for packet in DataPhasePackets(transactionID: transactionID, phase: phase, packetSize: 1000) {
                    inbound[id, default: Data()] += packet
                }
            case let .close(id):
                closed.insert(id)
            }
        }
    }

    /// Whole packets waiting on a connection (no data phases expected).
    mutating func packets(on id: Int) throws -> [PTPIP.Packet] {
        let events = try decoders[id]!.feed(inbound[id] ?? Data())
        inbound[id] = Data()
        return events.compactMap { if case let .packet(p) = $0 { p } else { nil } }
    }

    /// The handshake on both channels; returns the command ack.
    mutating func connect(name: String = "test initiator") throws -> PTPIP.InitCommandAck {
        open(1)
        write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: name).encode(), on: 1)
        let ack = try PTPIP.decodeInitCommandAck(try #require(try packets(on: 1).first))
        open(2)
        write(PTPIP.initEventRequest(connectionNumber: ack.connectionNumber).encode(), on: 2)
        #expect(try packets(on: 2).map(\.type) == [.initEventAck])
        return ack
    }

    /// One transaction on the command channel: its data phase and response.
    mutating func transact(_ command: PTPContainer) throws -> (data: Data, response: PTPIP.CmdResponse, dataPackets: Int) {
        write(PTPIP.cmdRequest(command).encode(), on: 1)
        let events = try decoders[1]!.feed(inbound[1] ?? Data())
        inbound[1] = Data()
        var t = PTPIPTransaction(transactionID: command.transactionID)
        var data = Data()
        var dataPackets = 0
        for event in events {
            if case .dataPacketBegan = event { dataPackets += 1 }
            for output in try t.consume(event) {
                if case let .data(d) = output { data += d }
            }
        }
        let response = try #require(t.response, "no response to \(command.operationCode)")
        #expect(t.dataLengthMismatch == nil && !t.dataPhaseUnterminated)
        return (data, response, dataPackets)
    }

    mutating func command(_ make: (UInt32) -> PTPContainer) throws -> (data: Data, response: PTPIP.CmdResponse, dataPackets: Int) {
        try transact(make(tx.take()))
    }
}

private func core(_ card: ScriptedCard? = nil, flavour: SimulatorFlavour = .usbMTP) throws -> PTPIPResponderCore {
    let card = try card ?? #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 10_000)
    return PTPIPResponderCore(responder: try PTPResponder(card: card, flavour: flavour))
}

@Suite("PTP/IP responder core")
struct PTPIPResponderCoreTests {
    @Test func handshakeOnBothChannels() throws {
        var i = LoopbackInitiator(core: try core())
        let ack = try i.connect()
        #expect(ack.connectionNumber == 1 && ack.responderName == "ILCE-7CM2 (simulated)")
        #expect(ack.protocolVersion == PTPIP.protocolVersion)
        #expect(i.core.isConnected && i.closed.isEmpty)
    }

    @Test func listsTheCardOverPTPIP() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        let info = try PTPDeviceInfo.decode(try i.command { PTPCommand.getDeviceInfo(tx: $0) }.data)
        #expect(info.model == "ILCE-7CM2" && info.operationsSupported.count == 24)
        #expect(try i.transact(PTPCommand.openSession(sessionID: 1)).response.code == .ok)
        let ids = try PTPStorageID.decodeArray(try i.command { PTPCommand.getStorageIDs(tx: $0) }.data)
        #expect(ids == [ScriptedCard.defaultStorageID])
        let handles = try PTPObjectHandle.decodeArray(try i.command { PTPCommand.getObjectHandles(tx: $0) }.data)
        var names: [String] = []
        for h in handles {
            names.append(try PTPObjectInfo.decode(try i.command { PTPCommand.getObjectInfo(h, tx: $0) }.data).filename)
        }
        #expect(names == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.ARW", "DSC00002.JPG", "DSC00003.JPG"])
        #expect(try i.command { PTPCommand.closeSession(tx: $0) }.response.code == .ok)
    }

    @Test func getObjectArrivesInSeveralDataPackets() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        _ = try i.transact(PTPCommand.openSession(sessionID: 1))
        let o = i.core.responder.card.objects[0]
        let reply = try i.command { PTPCommand.getObject(o.handle, tx: $0) }
        #expect(reply.response.code == .ok)
        #expect(reply.data == ScriptedCard.content(of: o.handle, in: 0 ..< o.size))
        // 1000-byte packets: Data packets for every full one but the last, then End_Data.
        #expect(reply.dataPackets == Int((o.size + 999) / 1000))
        let part = try i.command { PTPCommand.getPartialObject(o.handle, offset: 10, length: 2500, tx: $0) }
        #expect(part.response.parameters == [2500] && part.data == ScriptedCard.content(of: o.handle, in: 10 ..< 2510))
    }

    @Test func aSecondInitiatorIsRefusedAsBusy() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        i.open(3)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "other").encode(), on: 3)
        let refusal = try #require(try i.packets(on: 3).first)
        #expect(refusal.type == .initFail && PTPIP.decodeInitFail(refusal) == PTPIP.InitFailReason.busy.rawValue)
        #expect(i.closed == [3] && i.core.isConnected)
    }

    @Test func anEventChannelWithTheWrongNumberIsRefused() throws {
        var i = LoopbackInitiator(core: try core())
        i.open(1)
        i.write(PTPIP.initCommandRequest(guid: UUID(), friendlyName: "x").encode(), on: 1)
        let ack = try PTPIP.decodeInitCommandAck(try #require(try i.packets(on: 1).first))
        i.open(2)
        i.write(PTPIP.initEventRequest(connectionNumber: ack.connectionNumber + 1).encode(), on: 2)
        #expect(try i.packets(on: 2).map(\.type) == [.initFail])
        #expect(i.closed == [2] && !i.core.isConnected)
    }

    @Test func pingIsAnsweredAndAnInitiatorDataPhaseIsSwallowed() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        i.write(PTPIP.ping().encode(), on: 2)
        #expect(try i.packets(on: 2).map(\.type) == [.pong])
        // A command with an initiator data phase: answered once End_Data has arrived.
        let command = PTPCommand.getDeviceInfo(tx: 9)
        i.write(PTPIP.cmdRequest(command, dataPhase: .initiatorToResponder).encode(), on: 1)
        i.write(PTPIP.startData(transactionID: 9, totalLength: 3).encode(), on: 1)
        #expect(try i.packets(on: 1).isEmpty)
        i.write(PTPIP.endData(transactionID: 9, bytes: Data([1, 2, 3])).encode(), on: 1)
        let events = try i.decoders[1]!.feed(i.inbound[1]!)
        #expect(events.contains { if case let .packet(p) = $0 { p.type == .cmdResponse } else { false } })
    }

    @Test func shootingSendsObjectAddedOnTheEventChannel() throws {
        var i = LoopbackInitiator(core: try core())
        // Before anyone connects, objects are added with no event.
        #expect(i.core.shoot([.jpeg]).isEmpty)
        _ = try i.connect()
        i.perform(i.core.shoot([.rawPlusJPEG]))
        let events = try i.packets(on: 2).map(PTPIP.decodeEvent)
        #expect(events.map(\.code) == [.objectAdded, .objectAdded])
        let card = i.core.responder.card
        #expect(events.map(\.parameters) == card.objects.suffix(2).map { [$0.handle.rawValue] })

        var ip = LoopbackInitiator(core: try core(flavour: .ptpIP))
        _ = try ip.connect()
        ip.perform(ip.core.shoot([.jpeg]))
        let sony = try ip.packets(on: 2).map(PTPIP.decodeEvent)
        #expect(sony.map(\.code) == [.sonyObjectAdded] && sony.first?.parameters == [0xFFFF_C001])
    }

    @Test func losingTheCommandChannelEndsTheSession() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        _ = try i.transact(PTPCommand.openSession(sessionID: 1))
        #expect(i.core.responder.sessionID == 1)
        i.perform(i.core.disconnected(1))
        #expect(i.closed == [2] && !i.core.isConnected && i.core.responder.sessionID == nil)
        // A new initiator can connect and open a session again.
        _ = try i.connect()
        #expect(try i.transact(PTPCommand.openSession(sessionID: 1)).response.code == .ok)
    }

    @Test func malformedOrMisplacedPacketsCloseTheConnection() throws {
        var i = LoopbackInitiator(core: try core())
        _ = try i.connect()
        // A command on the event channel.
        i.write(PTPIP.cmdRequest(PTPCommand.getDeviceInfo(tx: 1)).encode(), on: 2)
        #expect(i.closed == [2])
        // An unknown packet type on the command channel closes it, and the session with it.
        var garbage = PTPWriter()
        garbage.u32(8)
        garbage.u32(99)
        i.write(garbage.data, on: 1)
        #expect(i.closed.contains(1) && !i.core.isConnected)
        #expect(i.core.dropAll().isEmpty)
    }

    @Test func dataPhasePacketsCoverEveryLength() throws {
        func decoded(_ phase: PTPResponder.DataPhase, size: Int) throws -> (types: [PTPIPPacketType], bytes: Data) {
            var decoder = PTPIPStreamDecoder()
            var types: [PTPIPPacketType] = []
            var bytes = Data()
            for packet in DataPhasePackets(transactionID: 4, phase: phase, packetSize: size) {
                for event in try decoder.feed(packet) {
                    switch event {
                    case let .packet(p): types.append(p.type)
                    case let .dataPacketBegan(type, tx, _):
                        types.append(type)
                        #expect(tx == 4)
                    case let .dataBytes(d): bytes += d
                    case .dataPacketEnded: break
                    }
                }
            }
            return (types, bytes)
        }
        #expect(try decoded(.bytes(Data()), size: 4).types == [.startData, .endData])
        let exact = try decoded(.bytes(Data(0 ..< 8)), size: 4)
        #expect(exact.types == [.startData, .data, .endData] && exact.bytes == Data(0 ..< 8))
        let object = try decoded(.object(PTPObjectHandle(rawValue: 3), offset: 5, length: 9), size: 4)
        #expect(object.types == [.startData, .data, .data, .endData])
        #expect(object.bytes == ScriptedCard.content(of: PTPObjectHandle(rawValue: 3), in: 5 ..< 14))
    }
}
