import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

// The whole-card session on the PTP/IP flavour, at the responder (no sockets). Everything the simulator encodes about
// the requests is `unverified`: no fixture holds a 0x9210 to 0x9212 exchange. What the spike measured on the camera is
// named in each test.

/// A PTP/IP responder over three RAW+JPEG frames, scaled down so a download is cheap, no session open.
func wholeCardResponder(frames: [ScriptedCard.Frame] = [.rawPlusJPEG, .rawPlusJPEG, .jpeg],
                        behaviour: WholeCardBehaviour = WholeCardBehaviour()) throws -> PTPResponder {
    let card = try #require(ScriptedCard.shoot(frames)).scaled(down: 10_000)
    return try PTPResponder(card: card, flavour: .ptpIP, wholeCard: behaviour)
}

/// What a responder answers `SonySessionRunner` with, and the time the plan waited.
struct PlanRun {
    var counter = PTPTransactionCounter()
    var records: [SonySessionRunner.Record] = []
    var waited: Duration = .zero
    var final: SonySessionRunner.Action = .stop(.outOfOrder)
}

/// Runs `plan` against the responder as a transport would: build each command with the plan's numbering, answer from
/// the responder, advance its clock by every pause. Ends at `.list` or `.stop`.
func run(_ plan: SonyContentsTransferPlan, on r: inout PTPResponder, counter: PTPTransactionCounter = PTPTransactionCounter()) throws -> PlanRun {
    var out = PlanRun()
    out.counter = counter
    var runner = SonySessionRunner(plan: plan)
    var action = runner.next(nil)
    while true {
        switch action {
        case let .send(step):
            let reply = r.respond(to: step.operation.command(using: &out.counter))
            if step.operation == .getDeviceInfo, reply.code == .ok, let data = reply.data {
                action = runner.next(.deviceInfo(try PTPDeviceInfo.decode(data.allBytes)))
            } else {
                action = runner.next(.response(reply.code))
            }
        case let .wait(pause):
            out.waited += pause
            _ = r.advance(by: pause)
            action = runner.next(nil)
        case .list, .stop:
            out.records = runner.records
            out.final = action
            return out
        }
    }
}

private func ids(_ reply: PTPResponder.Reply) throws -> [PTPStorageID] {
    try PTPStorageID.decodeArray(try #require(reply.data).allBytes)
}

private func handles(_ reply: PTPResponder.Reply) throws -> [PTPObjectHandle] {
    try PTPObjectHandle.decodeArray(try #require(reply.data).allBytes)
}

@Suite("Whole-card session")
struct WholeCardSessionTests {
    private let storeAdded = PTPContainer(type: .event, code: 0x4004, transactionID: 0xFFFF_FFFF, parameters: [0x0001_0001])
    private let storeRemoved = PTPContainer(type: .event, code: 0x4005, transactionID: 0xFFFF_FFFF, parameters: [0x0001_0001])

    /// 0x9210 [1, 1], then the two contents-transfer steps; the card is not offered until time has passed.
    private func open(_ r: inout PTPResponder, switchToContents: Bool = true) throws {
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).code == .ok)
        guard switchToContents else { return }
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 0, 0, tx: 2)).code == .ok)
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 3)).code == .ok)
    }

    // MARK: - Opening

    @Test func aPlainSessionListsNothing() throws {
        var r = try wholeCardResponder()
        #expect(r.respond(to: PTPCommand.openSession(sessionID: 1)).code == .ok)
        // Measured: GetStorageIDs answers StoreNotAvailable in a plain session.
        #expect(r.respond(to: PTPCommand.getStorageIDs(tx: 1)).code == .storeNotAvailable)
        // Unverified, in the same spirit.
        #expect(r.respond(to: PTPCommand.getStorageInfo(ScriptedCard.defaultStorageID, tx: 2)).code == .storeNotAvailable)
        #expect(r.respond(to: PTPCommand.getObjectHandles(tx: 3)).code == .storeNotAvailable)
        let h = r.card.handles[0]
        #expect(r.respond(to: PTPCommand.getObjectInfo(h, tx: 4)).code == .invalidObjectHandle)
        #expect(r.respond(to: PTPCommand.getObject(h, tx: 5)).code == .invalidObjectHandle)
        #expect(!r.isWholeCardSession && !r.cardIsListed)
    }

    @Test func theUSBFlavourStillListsInAPlainSession() throws {
        let card = try #require(ScriptedCard.shoot([.jpeg]))
        var r = try PTPResponder(card: card, flavour: .usbMTP)
        #expect(r.respond(to: PTPCommand.openSession(sessionID: 1)).code == .ok)
        #expect(r.cardIsListed)
        #expect(try ids(r.respond(to: PTPCommand.getStorageIDs(tx: 1))) == [ScriptedCard.defaultStorageID])
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 2)).code == .operationNotSupported)
        // The idle drop is the PTP/IP flavour's.
        #expect(!r.advance(by: .seconds(600)).sessionDropped && r.sessionID == 1)
    }

    @Test func sdioOpenSessionOpensTheWholeCardSession() throws {
        var r = try wholeCardResponder()
        // Nothing is open: 0x9201 and 0x9212 need a session.
        #expect(r.respond(to: PTPCommand.sonySDIOConnect(phase: 1, tx: 1)).code == .sessionNotOpen)
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 0, 0, tx: 1)).code == .sessionNotOpen)
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).code == .ok)
        #expect(r.sessionID == 1 && r.isWholeCardSession)
        // Sending OpenSession as well answers SessionAlreadyOpen (0x201E), as Imagedge warned.
        let again = r.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(again.code == .sessionAlreadyOpen && again.code.rawValue == 0x201E)
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 3)).code == .sessionAlreadyOpen)
        #expect(r.respond(to: PTPCommand.closeSession(tx: 4)).code == .ok)
        #expect(r.sessionID == nil && !r.isWholeCardSession)
    }

    @Test func sdioOpenSessionAfterAPlainOneIsRefusedAndLeavesItPlain() throws {
        var r = try wholeCardResponder()
        _ = r.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).code == .sessionAlreadyOpen)
        #expect(!r.isWholeCardSession)
    }

    @Test func sdioOpenSessionChecksItsParameters() throws {
        var r = try wholeCardResponder()
        let short = PTPContainer(type: .command, code: PTPOperationCode.sonySDIOOpenSession.rawValue, transactionID: 1,
                                 parameters: [1])
        #expect(r.respond(to: short).code == .invalidParameter)
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(sessionID: 0, functionMode: 1, tx: 2)).code == .invalidParameter)
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 7, tx: 3)).code == .invalidParameter)
        #expect(r.sessionID == nil)
        // Function mode 0 (remote control) opens a session that lists nothing (unverified).
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 0, tx: 4)).code == .ok)
        #expect(r.sessionID == 1 && !r.isWholeCardSession)
        #expect(r.respond(to: PTPCommand.getStorageIDs(tx: 5)).code == .storeNotAvailable)
    }

    // MARK: - The init sequence

    @Test func sdioConnectAnswersOKWithEightZeroBytes() throws {
        var r = try wholeCardResponder()
        try open(&r, switchToContents: false)
        for phase: UInt32 in 1 ... 3 {
            let reply = r.respond(to: PTPCommand.sonySDIOConnect(phase: phase, tx: phase))
            #expect(reply.code == .ok && reply.data?.allBytes == Data(count: 8))
        }
        #expect(r.respond(to: PTPCommand.sonySDIOConnect(phase: 0, tx: 9)).code == .invalidParameter)
        #expect(r.respond(to: PTPCommand.sonySDIOConnect(phase: 4, tx: 9)).code == .invalidParameter)
        // A plain session runs the sequence too (the spike's first Sony route did).
        var plain = try wholeCardResponder()
        _ = plain.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(plain.respond(to: PTPCommand.sonySDIOConnect(phase: 1, tx: 1)).code == .ok)
    }

    @Test func extDeviceInfoIsTheCapturedNineHundredAndSeventyBytes() throws {
        var r = try wholeCardResponder()
        try open(&r, switchToContents: false)
        let captured = try CapturedA7C2.sdioExtDeviceInfo()
        for version: UInt32 in [0x12C, 0xC8] {
            let reply = r.respond(to: PTPCommand.sonySDIOGetExtDeviceInfo(version: version, tx: 1))
            #expect(reply.code == .ok)
            let bytes = try #require(reply.data).allBytes
            #expect(bytes.count == 970 && bytes == captured)
            // The reply's first field is the version the camera speaks: 0x12C (little-endian u16, unverified layout).
            #expect(bytes.prefix(2) == Data([0x2C, 0x01]))
        }
    }

    @Test func deviceInfoIsTheSameBeforeAndAfterTheInitSequence() throws {
        var r = try wholeCardResponder()
        try open(&r, switchToContents: false)
        func info() throws -> PTPDeviceInfo {
            try PTPDeviceInfo.decode(try #require(r.respond(to: PTPCommand.getDeviceInfo(tx: 1)).data).allBytes)
        }
        let before = try info()
        _ = r.respond(to: PTPCommand.sonySDIOConnect(phase: 1, tx: 2))
        _ = r.respond(to: PTPCommand.sonySDIOGetExtDeviceInfo(tx: 3))
        let after = try info()
        #expect(before == after)
        #expect(after.operationsSupported.count == 81 && after.eventsSupported.count == 48 && after.devicePropertiesSupported.isEmpty)
    }

    // MARK: - The card appears

    @Test func theCardAppearsAfterTheReadinessDelayWithStoreAdded() throws {
        var r = try wholeCardResponder()
        try open(&r)
        // Before: GetStorageIDs and GetObjectHandles answer empty lists, the store isn't known yet.
        #expect(try ids(r.respond(to: PTPCommand.getStorageIDs(tx: 4))).isEmpty)
        #expect(try handles(r.respond(to: PTPCommand.getObjectHandles(tx: 5))).isEmpty)
        #expect(r.respond(to: PTPCommand.getStorageInfo(ScriptedCard.defaultStorageID, tx: 6)).code == .invalidStorageID)
        #expect(r.respond(to: PTPCommand.getObjectInfo(r.card.handles[0], tx: 7)).code == .invalidObjectHandle)

        // The default delay (300 ms from the switch, `unverified`) is shorter than the plan's 1.5 s pause after it.
        let early = r.advance(by: .milliseconds(299))
        #expect(early.events.isEmpty && !early.sessionDropped && !r.cardIsListed)
        #expect(try handles(r.respond(to: PTPCommand.getObjectHandles(tx: 8))).isEmpty)

        let due = r.advance(by: .milliseconds(1))
        #expect(due.events == [storeAdded])
        #expect(r.cardIsListed)
        #expect(try ids(r.respond(to: PTPCommand.getStorageIDs(tx: 9))) == [ScriptedCard.defaultStorageID])
        #expect(try handles(r.respond(to: PTPCommand.getObjectHandles(tx: 10))) == r.card.handles)
        let info = try PTPObjectInfo.decode(try #require(r.respond(to: PTPCommand.getObjectInfo(r.card.handles[0], tx: 11)).data).allBytes)
        #expect(info.filename == "DSC00001.ARW")
        // Time going by again announces nothing twice.
        #expect(r.advance(by: .seconds(1)).events.isEmpty)
    }

    @Test func theEventIsTheCapturedOneByteForByte() throws {
        var r = try wholeCardResponder()
        try open(&r)
        let added = try #require(r.advance(by: .seconds(2)).events.first)
        let addedPacket = PTPIP.event(added.eventCode, transactionID: added.transactionID, parameters: added.parameters)
        // The 18 bytes inline (length 18, type 8, code 0x4004, transaction ID 0xFFFFFFFF, storage 0x00010001), so the
        // check doesn't depend on the repository's Fixtures/ being readable; the capture is compared as well when it is.
        #expect(addedPacket.encode() == Data([0x12, 0, 0, 0, 0x08, 0, 0, 0, 0x04, 0x40, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0, 0x01, 0]))
        if let fixture = CapturedFixtureCopyTests.repositoryFixture("ptpip/event-4004.bin") { #expect(addedPacket.encode() == fixture) }
        let removed = try #require(r.dropCard().first)
        let removedPacket = PTPIP.event(removed.eventCode, transactionID: removed.transactionID, parameters: removed.parameters)
        #expect(removedPacket.encode() == Data([0x12, 0, 0, 0, 0x08, 0, 0, 0, 0x05, 0x40, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0, 0x01, 0]))
        if let fixture = CapturedFixtureCopyTests.repositoryFixture("ptpip/event-4005.bin") { #expect(removedPacket.encode() == fixture) }
    }

    @Test func oneBigStepOfTimeIsTheSameAsManySmallOnes() throws {
        var r = try wholeCardResponder()
        try open(&r)
        #expect(r.advance(by: .seconds(10)).events == [storeAdded])
        #expect(r.cardIsListed)
    }

    @Test func aZeroReadinessDelayAnnouncesTheCardInTheReplyItself() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.readinessDelay = .zero
        var r = try wholeCardResponder(behaviour: behaviour)
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).code == .ok)
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 0, 0, tx: 2)).events.isEmpty)
        let reply = r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 3))
        #expect(reply.code == .ok && reply.events == [storeAdded] && r.cardIsListed)
    }

    @Test func theReadinessDelayIsTheCallersToSet() throws {
        var behaviour = WholeCardBehaviour()
        behaviour.readinessDelay = .seconds(10)
        var r = try wholeCardResponder(behaviour: behaviour)
        try open(&r)
        #expect(r.advance(by: .milliseconds(9_999)).events.isEmpty)
        #expect(r.advance(by: .milliseconds(1)).events == [storeAdded])
    }

    @Test func aReopenWaitsTheSameDelayAndTheHandlesAreTheSameOnes() throws {
        var r = try wholeCardResponder()
        try open(&r)
        _ = r.advance(by: .seconds(2))
        #expect(r.respond(to: PTPCommand.closeSession(tx: 4)).code == .ok)

        // A reopen isn't shown to be quicker on the camera (spike-findings.md), so it has the same delay.
        try open(&r)
        #expect(r.advance(by: .milliseconds(299)).events.isEmpty && !r.cardIsListed)
        #expect(r.advance(by: .milliseconds(1)).events == [storeAdded])
        #expect(try handles(r.respond(to: PTPCommand.getObjectHandles(tx: 5))) == r.card.handles)
    }

    @Test func theSwitchWithoutTheFirstStepIsAcceptedAndTheSecondRepeatedChangesNothing() throws {
        var r = try wholeCardResponder()
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).code == .ok)
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 2)).code == .ok)
        #expect(r.advance(by: .milliseconds(200)).events.isEmpty)
        // A repeat doesn't restart the wait.
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 3)).code == .ok)
        #expect(r.advance(by: .milliseconds(100)).events == [storeAdded])
        // Once listed a repeat of the first step changes nothing either.
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 0, 0, tx: 4)).code == .ok && r.cardIsListed)
    }

    @Test func theContentsTransferStepsCheckTheirParameters() throws {
        var r = try wholeCardResponder()
        try open(&r, switchToContents: false)
        let short = PTPContainer(type: .command, code: PTPOperationCode.sonySDIOSetContentsTransferMode.rawValue,
                                 transactionID: 1, parameters: [2, 1])
        #expect(r.respond(to: short).code == .invalidParameter)
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(9, 0, 0, tx: 2)).code == .invalidParameter)
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(2, 2, 0, tx: 3)).code == .invalidParameter)
        // Sony's set of photos selected on the camera isn't simulated.
        #expect(r.respond(to: PTPCommand.sonySetContentsTransferMode(1, 0, 0, tx: 4)).code == .parameterNotSupported)
        // In a plain session the operation isn't there (unverified answer).
        var plain = try wholeCardResponder()
        _ = plain.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(plain.respond(to: PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 1)).code == .operationNotSupported)
    }

    // MARK: - Reading

    @Test func sdio9211ReadsByteRangesWithFiveParameters() throws {
        var r = try wholeCardResponder()
        try open(&r)
        _ = r.advance(by: .seconds(2))
        let o = r.card.objects[0]
        let read = { (offset: UInt64, length: UInt64, tx: UInt32) in
            r.respond(to: PTPCommand.sonyGetPartialLargeObject(code: 0x9211, o.handle, offset: offset, length: length, tx: tx))
        }
        let mid = read(100, 500, 1)
        #expect(mid.code == .ok && mid.data?.allBytes == r.card.content(of: o.handle, in: 100 ..< 600))
        // Past the end it sends what there is.
        let tail = read(o.size - 10, 500, 2)
        #expect(tail.code == .ok && tail.data?.length == 10)
        // Length all ones: to the end.
        #expect(read(0, UInt64.max, 3).data?.length == o.size)
        // An offset at the end is an empty read; past it is refused.
        #expect(read(o.size, 10, 4).data?.length == 0)
        #expect(read(o.size + 1, 10, 5).code == .invalidParameter)
        // A 64-bit offset (high word set) is read as such.
        #expect(read(1 << 32, 10, 6).code == .invalidParameter)
        // Four parameters is the 0x101B layout, not this one.
        let four = PTPContainer(type: .command, code: 0x9211, transactionID: 7, parameters: [o.handle.rawValue, 0, 0, 10])
        #expect(r.respond(to: four).code == .invalidParameter)
        #expect(r.respond(to: PTPCommand.sonyGetPartialLargeObject(code: 0x9211, PTPObjectHandle(rawValue: 0xFFFF_C001),
                                                                    offset: 0, length: 10, tx: 8)).code == .invalidObjectHandle)
    }

    @Test func aResumedReadMatchesTheWholeObject() throws {
        var r = try wholeCardResponder()
        try open(&r)
        _ = r.advance(by: .seconds(2))
        let o = r.card.objects[1]
        // The spike's chunked read, cut short and resumed: pieces joined equal GetObject.
        var got = Data()
        let chunk: UInt64 = 997
        while UInt64(got.count) < o.size {
            let reply = r.respond(to: PTPCommand.sonyGetPartialLargeObject(
                code: 0x9211, o.handle, offset: UInt64(got.count), length: chunk, tx: 1))
            #expect(reply.code == .ok)
            got += try #require(reply.data).allBytes
        }
        #expect(got == (try #require(r.respond(to: PTPCommand.getObject(o.handle, tx: 2)).data).allBytes))
    }

    @Test func standardPartialReadAnd0x9219AnswerInvalidObjectHandle() throws {
        var r = try wholeCardResponder()
        try open(&r)
        _ = r.advance(by: .seconds(2))
        let o = r.card.objects[0]
        // Measured, 2 Nov: 0x101B in three and in four parameters, and 0x9219, whatever the handle.
        #expect(r.respond(to: PTPCommand.getPartialObject(o.handle, offset: 0, length: 10, tx: 1)).code == .invalidObjectHandle)
        #expect(r.respond(to: PTPCommand.getPartialObjectSony(o.handle, offset: 0, length: 10, tx: 2)).code == .invalidObjectHandle)
        #expect(r.respond(to: PTPCommand.sonyGetPartialLargeObject(code: 0x9219, o.handle, offset: 0, length: 10, tx: 3)).code
            == .invalidObjectHandle)
        // A plain GetObject still works in the whole-card session.
        #expect(r.respond(to: PTPCommand.getObject(o.handle, tx: 4)).code == .ok)
    }

    @Test func theBufferSlotHasNoObjectInfo() throws {
        var r = try wholeCardResponder()
        try open(&r)
        _ = r.advance(by: .seconds(2))
        #expect(r.respond(to: PTPCommand.getObjectInfo(PTPResponder.sonyBufferSlot, tx: 1)).code == .invalidObjectHandle)
        #expect(r.respond(to: PTPCommand.getObject(PTPResponder.sonyBufferSlot, tx: 2)).code == .invalidObjectHandle)
        // A shot announces the slot, not the file: the new object is on the card under its own handle.
        let events = r.shoot([.jpeg])
        #expect(events.map(\.parameters) == [[0xFFFF_C001]] && events.map(\.eventCode) == [.sonyObjectAdded])
        let newest = try #require(r.card.objects.last)
        #expect(newest.handle != PTPResponder.sonyBufferSlot)
        #expect(r.respond(to: PTPCommand.getObjectInfo(newest.handle, tx: 3)).code == .ok)
    }

    // MARK: - Properties that never answer

    @Test func getDevicePropValueIsNeverAnsweredInTheWholeCardSession() throws {
        var r = try wholeCardResponder()
        // The camera lists no properties and not the operation, yet the battery read hung (B:69): silence is
        // for any GetDevicePropValue in the session, listed or not.
        #expect(!r.deviceInfo.supports(.getDevicePropValue) && r.deviceInfo.devicePropertiesSupported.isEmpty)
        try open(&r)
        let battery = PTPCommand.getDevicePropValue(PTPDevicePropCode(rawValue: 0x5001), tx: 9)
        let reply = r.respond(to: battery)
        #expect(reply.isSilent && reply.data == nil)
        #expect(r.commandsAnswered.last == .getDevicePropValue)
        // The camera is still usable afterwards; only that reply is missing.
        #expect(r.respond(to: PTPCommand.getDeviceInfo(tx: 10)).code == .ok)

        var plain = try wholeCardResponder()
        _ = plain.respond(to: PTPCommand.openSession(sessionID: 1))
        let other = plain.respond(to: battery)
        #expect(!other.isSilent && other.code == .operationNotSupported)

        var answers = WholeCardBehaviour()
        answers.getDevicePropValueNeverAnswers = false
        var open = try wholeCardResponder(behaviour: answers)
        _ = open.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1))
        #expect(!open.respond(to: battery).isSilent)
    }

    // MARK: - The card drops

    @Test func theCardDropsAndComesBack() throws {
        var r = try wholeCardResponder()
        try open(&r)
        _ = r.advance(by: .seconds(2))
        let h = r.card.handles[0]
        #expect(r.respond(to: PTPCommand.getObject(h, tx: 4)).code == .ok)

        #expect(r.dropCard() == [storeRemoved])
        #expect(!r.cardIsListed)
        // StoreRemoved, then StoreNotAvailable on the next GetObject (B:208).
        #expect(r.respond(to: PTPCommand.getObject(h, tx: 5)).code == .storeNotAvailable)
        #expect(r.respond(to: PTPCommand.getObjectInfo(h, tx: 6)).code == .storeNotAvailable)
        #expect(r.respond(to: PTPCommand.getThumb(h, tx: 7)).code == .storeNotAvailable)
        #expect(r.respond(to: PTPCommand.getObjectHandles(tx: 8)).code == .storeNotAvailable)
        #expect(r.respond(to: PTPCommand.sonyGetPartialLargeObject(code: 0x9211, h, offset: 0, length: 4, tx: 9)).code == .storeNotAvailable)
        #expect(try ids(r.respond(to: PTPCommand.getStorageIDs(tx: 10))).isEmpty)
        // Nothing to drop twice, nothing to restore that is there.
        #expect(r.dropCard().isEmpty)

        #expect(r.restoreCard() == [storeAdded])
        #expect(r.cardIsListed)
        #expect(r.respond(to: PTPCommand.getObject(h, tx: 11)).code == .ok)
        #expect(r.restoreCard().isEmpty)
    }

    @Test func droppingAndRestoringDoNothingOutsideAListingSession() throws {
        var r = try wholeCardResponder()
        #expect(r.dropCard().isEmpty && r.restoreCard().isEmpty)
        _ = r.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(r.dropCard().isEmpty)
        var w = try wholeCardResponder()
        try open(&w)
        // Dropped while still indexing: the card never arrives on its own.
        #expect(w.dropCard() == [storeRemoved])
        #expect(w.advance(by: .seconds(5)).events.isEmpty && !w.cardIsListed)
    }

    @Test func aNewSessionStartsWithTheCardBack() throws {
        var r = try wholeCardResponder()
        try open(&r)
        _ = r.advance(by: .seconds(2))
        _ = r.dropCard()
        r.endSession()
        try open(&r)
        #expect(r.advance(by: .milliseconds(300)).events == [storeAdded] && r.cardIsListed)
    }

    // MARK: - The idle drop

    @Test func anIdleSessionIsDroppedAfterTheLimit() throws {
        var r = try wholeCardResponder()
        _ = r.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(!r.advance(by: .milliseconds(29_999)).sessionDropped && r.sessionID == 1)
        let dropped = r.advance(by: .milliseconds(1))
        #expect(dropped.sessionDropped && r.sessionID == nil)
        // No session, nothing to drop.
        #expect(!r.advance(by: .seconds(60)).sessionDropped)
    }

    @Test func aKeepAliveEveryTenSecondsKeepsTheSessionUp() throws {
        var r = try wholeCardResponder()
        try open(&r)
        for i in 1 ... 20 {
            let advance = r.advance(by: .seconds(10))
            #expect(!advance.sessionDropped, "after \(i * 10) s")
            #expect(r.respond(to: PTPCommand.getDeviceInfo(tx: UInt32(10 + i))).code == .ok)
        }
        #expect(r.sessionID == 1 && r.cardIsListed)
    }

    @Test func theIdleLimitIsTheCallersToSetOrSwitchOff() throws {
        var short = WholeCardBehaviour()
        short.idleDropAfter = .seconds(5)
        var r = try wholeCardResponder(behaviour: short)
        _ = r.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(r.advance(by: .seconds(5)).sessionDropped)

        var never = WholeCardBehaviour()
        never.idleDropAfter = nil
        var n = try wholeCardResponder(behaviour: never)
        _ = n.respond(to: PTPCommand.openSession(sessionID: 1))
        #expect(!n.advance(by: .seconds(86_400)).sessionDropped && n.sessionID == 1)
    }

    @Test func aCardDueBeforeTheDropIsAnnouncedFirst() throws {
        var r = try wholeCardResponder()
        try open(&r)
        let both = r.advance(by: .seconds(60))
        #expect(both.events == [storeAdded] && both.sessionDropped)
        // A card due after the drop never arrives: the session is gone first.
        var late = WholeCardBehaviour()
        late.readinessDelay = .seconds(40)
        var l = try wholeCardResponder(behaviour: late)
        try open(&l)
        let only = l.advance(by: .seconds(60))
        #expect(only.events.isEmpty && only.sessionDropped)
    }

    // MARK: - The whole sequence with SonySessionRunner

    @Test func theRunnerOpensTheSessionAndTheCardListsAtTheFirstPoll() throws {
        var r = try wholeCardResponder()
        let plan = SonyContentsTransferPlan.wholeCard()
        let run = try run(plan, on: &r)
        guard case let .list(poll) = run.final else {
            Issue.record("the plan stopped: \(run.final)")
            return
        }
        #expect(run.records.count == 12)
        #expect(run.records.map(\.operation.operationCode) == [
            .sonySDIOOpenSession, .getDeviceInfo, .getDeviceInfo, .getStorageIDs, .sonySDIOConnect, .sonySDIOConnect,
            .sonySDIOGetExtDeviceInfo, .sonySDIOConnect, .sonySDIOGetExtDeviceInfo, .getDeviceInfo,
            .sonySDIOSetContentsTransferMode, .sonySDIOSetContentsTransferMode,
        ])
        // GetStorageIDs in the init sequence is the one that answers StoreNotAvailable, and the plan goes on.
        #expect(run.records[3].response == .storeNotAvailable && !run.records[3].accepted)
        #expect(run.records.enumerated().allSatisfy { $0.offset == 3 || $0.element.accepted })
        #expect(run.counter.peek == 13 && r.isWholeCardSession && r.sessionID == 1)
        // 200 ms and 1,500 ms of pauses: StoreAdded came during the second pause, as on the camera (every fresh
        // session was ready at the first poll).
        #expect(run.waited == .milliseconds(1_700) && r.cardIsListed)

        // The poll: the card lists at attempt 1.
        var tx = run.counter
        var elapsed: Duration = .zero
        var attempts = 0
        var listed: [PTPObjectHandle] = []
        while true {
            attempts += 1
            let storages = try ids(r.respond(to: PTPCommand.getStorageIDs(tx: tx.take())))
            let counts = try storages.filter(\.hasLogicalStore).map {
                try handles(r.respond(to: PTPCommand.getObjectHandles(storage: $0, tx: tx.take()))).count
            }
            if SonyListingPoll.isReady(handleCounts: counts) {
                listed = try handles(r.respond(to: PTPCommand.getObjectHandles(storage: storages[0], tx: tx.take())))
                break
            }
            let wait = try #require(poll.wait(afterAttempt: attempts, elapsed: elapsed))
            elapsed += wait
            _ = r.advance(by: wait)
        }
        #expect(attempts == 1 && elapsed == .zero && listed == r.card.handles)
    }

    @Test func aSlowCardIsEmptyAtTheFirstPollAndListsAtTheSecond() throws {
        // The path the camera didn't show but a bigger card might (unmeasured): 2 s from the switch, so the first poll,
        // 1.5 s after it, sees an empty list and the second, 2 s later, the card.
        var slow = WholeCardBehaviour()
        slow.readinessDelay = .seconds(2)
        var r = try wholeCardResponder(behaviour: slow)
        let run = try run(.wholeCard(), on: &r)
        guard case let .list(poll) = run.final else {
            Issue.record("the plan stopped: \(run.final)")
            return
        }
        #expect(!r.cardIsListed)
        var tx = run.counter
        var elapsed: Duration = .zero
        var attempts = 0
        var listed: [PTPObjectHandle] = []
        while true {
            attempts += 1
            let counts = try handles(r.respond(to: PTPCommand.getObjectHandles(tx: tx.take()))).count
            if SonyListingPoll.isReady(handleCounts: [counts]) {
                listed = try handles(r.respond(to: PTPCommand.getObjectHandles(tx: tx.take())))
                break
            }
            let wait = try #require(poll.wait(afterAttempt: attempts, elapsed: elapsed))
            elapsed += wait
            _ = r.advance(by: wait)
        }
        #expect(attempts == 2 && elapsed == .seconds(2) && listed == r.card.handles)
    }

    @Test func aReopenedSessionListsAtTheFirstPollAndOnlyNewHandlesAreAskedFor() throws {
        var r = try wholeCardResponder()
        let first = try run(.wholeCard(), on: &r)
        _ = r.advance(by: .seconds(2))
        let listed = SonyHandleSet(try handles(r.respond(to: PTPCommand.getObjectHandles(tx: first.counter.peek))).map(\.rawValue))
        #expect(listed.count == r.card.objects.count)

        // The camera drops the session; the app reopens it and the same handles come back (B:91).
        r.endSession()
        let again = try run(.wholeCard(reopening: true), on: &r)
        guard case let .list(poll) = again.final else {
            Issue.record("the reopen stopped: \(again.final)")
            return
        }
        #expect(poll.limit == .seconds(30) && r.cardIsListed)
        let relist = SonyHandleSet(try handles(r.respond(to: PTPCommand.getObjectHandles(tx: 99))).map(\.rawValue))
        #expect(listed.unseen(in: relist).isEmpty && listed.gone(in: relist).isEmpty)

        // One RAW+JPEG frame is shot meanwhile: only its two handles need GetObjectInfo.
        _ = r.shoot([.rawPlusJPEG])
        let later = SonyHandleSet(try handles(r.respond(to: PTPCommand.getObjectHandles(tx: 100))).map(\.rawValue))
        let new = listed.unseen(in: later)
        #expect(new.count == 2 && new == r.card.objects.suffix(2).map(\.handle.rawValue))
    }

    @Test func aPlainOpenSessionPlanFallsBackAndListsNothing() throws {
        // The plan's fallback: a camera that refuses 0x9210 gets OpenSession. The simulator on the USB flavour doesn't
        // list the operation, so the plan's step 0 falls back, then stops at the capabilities check.
        let card = try #require(ScriptedCard.shoot([.jpeg]))
        var r = try PTPResponder(card: card, flavour: .usbMTP)
        let run = try run(.wholeCard(), on: &r)
        guard case let .stop(failure) = run.final, case .unsupported = failure else {
            Issue.record("expected unsupported, got \(run.final)")
            return
        }
        #expect(run.records.first?.response == .operationNotSupported && r.sessionID == 1)
    }
}
