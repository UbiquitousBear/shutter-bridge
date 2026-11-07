import Testing
import Foundation
@testable import PTPKit

/// Synthetic DeviceInfos, shaped like what the spike logged from the α7C II. Both are SYNTHETIC until camera
/// fixtures land in Fixtures/a7c2/; none of these bytes came from a camera.
private enum SonyDevices {
    /// Shaped like the α7C II's PC Remote DeviceInfo over Wi-Fi as the spike logged it (synthetic; the real one
    /// lists 81 operations).
    static let pcRemote = PTPDeviceInfo(
        standardVersion: 100, vendorExtensionID: 0x11, vendorExtensionVersion: 100,
        vendorExtensionDescription: "Sony PTP Extensions", functionalMode: 0,
        operationsSupported: [0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007, 0x1008, 0x1009, 0x100A, 0x100D, 0x101B,
                              0x9201, 0x9202, 0x9210, 0x9211, 0x9212, 0x9219, 0x9801, 0x9802, 0x9803, 0x9805],
        eventsSupported: [0x4004, 0x4005, 0xC201, 0xC202],
        devicePropertiesSupported: [],
        captureFormats: [],
        imageFormats: [0x3001, 0x3801, 0xB101, 0x300B, 0xB982, 0xB110],
        manufacturer: "Sony Corporation", model: "ILCE-7CM2", deviceVersion: "2.01", serialNumber: "0000000000000000")

    /// Shaped like the α7C II's USB MTP-mode DeviceInfo (the 24 operations from the findings; synthetic).
    static let mtpMode = PTPDeviceInfo(
        standardVersion: 100, vendorExtensionID: 0xFFFF_FFFF, vendorExtensionVersion: 0,
        vendorExtensionDescription: "", functionalMode: 0,
        operationsSupported: [0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007, 0x1008, 0x1009, 0x100A, 0x1014, 0x1015,
                              0x1016, 0x101B, 0x9801, 0x9802, 0x9803, 0x9805, 0x9280, 0x9281, 0x9282, 0x9283, 0x9284, 0x9285],
        eventsSupported: [0x4004, 0x4005, 0x4006],
        devicePropertiesSupported: [0x5001, 0xD402, 0xD406, 0xD407, 0xD303],
        captureFormats: [], imageFormats: [],
        manufacturer: "Sony Corporation", model: "ILCE-7CM2", deviceVersion: "2.0", serialNumber: "")

    /// Another maker whose vendor codes clash with Sony's numbers.
    static let nikonWithClashingCodes = PTPDeviceInfo(
        standardVersion: 100, vendorExtensionID: 0x0A, vendorExtensionVersion: 100,
        vendorExtensionDescription: "", functionalMode: 0,
        operationsSupported: [0x9210, 0x9211, 0x9212, 0x9201, 0x101B],
        eventsSupported: [0xC201], devicePropertiesSupported: [], captureFormats: [], imageFormats: [],
        manufacturer: "Nikon", model: "Z 6", deviceVersion: "1.0", serialNumber: "")
}

private func collectSteps(_ steps: [SonySessionStep]) -> [SonySessionStep] {
    steps.flatMap { step -> [SonySessionStep] in
        if case .fallback(let f) = step.onNotOK { return [step] + collectSteps([f]) }
        return [step]
    }
}

@Suite("Sony whole-card plan")
struct SonyContentsTransferPlanTests {
    let plan = SonyContentsTransferPlan.wholeCard()

    static let operations: [SonySessionStep.Operation] = [
        .sdioOpenSession(sessionID: 1, functionMode: 1), .getDeviceInfo, .getDeviceInfo, .getStorageIDs,
        .sdioConnect(phase: 1), .sdioConnect(phase: 2), .sdioGetExtDeviceInfo(version: 0x12C), .sdioConnect(phase: 3),
        .sdioGetExtDeviceInfo(version: 0x12C), .getDeviceInfo,
        .setContentsTransferMode(2, 0, 0), .setContentsTransferMode(2, 1, 0),
    ]

    @Test("The whole-card plan is the spike's sequence, in order")
    func steps() {
        #expect(plan.steps.map(\.operation) == Self.operations)
    }

    @Test("Steps build their commands with PTPCommand's builders")
    func commands() {
        typealias Op = SonySessionStep.Operation
        let table: [(Op, PTPContainer, UInt16, [UInt32])] = [
            (.sdioOpenSession(sessionID: 1, functionMode: 1), PTPCommand.sonySDIOOpenSession(sessionID: 1, functionMode: 1, tx: 7), 0x9210, [1, 1]),
            (.openSession(sessionID: 1), PTPCommand.openSession(sessionID: 1, tx: 7), 0x1002, [1]),
            (.getDeviceInfo, PTPCommand.getDeviceInfo(tx: 7), 0x1001, []),
            (.getStorageIDs, PTPCommand.getStorageIDs(tx: 7), 0x1004, []),
            (.sdioConnect(phase: 2), PTPCommand.sonySDIOConnect(phase: 2, tx: 7), 0x9201, [2, 0, 0]),
            (.sdioGetExtDeviceInfo(version: 0x12C), PTPCommand.sonySDIOGetExtDeviceInfo(version: 0x12C, tx: 7), 0x9202, [0x12C, 1]),
            (.sdioGetExtDeviceInfo(version: 0xC8), PTPCommand.sonySDIOGetExtDeviceInfo(version: 0xC8, tx: 7), 0x9202, [0xC8, 1]),
            (.setContentsTransferMode(2, 0, 0), PTPCommand.sonySetContentsTransferMode(2, 0, 0, tx: 7), 0x9212, [2, 0, 0]),
            (.setContentsTransferMode(2, 1, 0), PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 7), 0x9212, [2, 1, 0]),
        ]
        for (op, builder, code, params) in table {
            let c = op.command(tx: 7)
            #expect(c == builder)
            #expect(c.code == code && op.operationCode.rawValue == code)
            #expect(c.parameters == params)
            #expect(c.type == .command && c.transactionID == 7)
        }
    }

    @Test("Transaction IDs: 0x9210 takes 1 on a fresh counter; the OpenSession fallback uses 0 and restarts the counter")
    func numbering() {
        var counter = PTPTransactionCounter()
        #expect(plan.steps.map { $0.operation.command(using: &counter).transactionID } == Array(1 ... 12))

        counter = PTPTransactionCounter()
        let open = plan.steps[0].operation.command(using: &counter)
        guard case .fallback(let fallback) = plan.steps[0].onNotOK else { Issue.record("no fallback"); return }
        let reopen = fallback.operation.command(using: &counter)
        let info1 = plan.steps[1].operation.command(using: &counter)
        let info2 = plan.steps[2].operation.command(using: &counter)
        #expect([open.transactionID, reopen.transactionID, info1.transactionID, info2.transactionID] == [1, 0, 1, 2])
        #expect(reopen.code == 0x1002)
    }

    @Test("Tolerance, fallbacks and pauses match the spike")
    func tolerance() {
        let s = plan.steps
        guard case .fallback(let openFallback) = s[0].onNotOK else { Issue.record("step 0 has no fallback"); return }
        #expect(openFallback.operation == .openSession(sessionID: 1))
        #expect(openFallback.treatedAsOK == [.sessionAlreadyOpen])
        #expect(openFallback.onNotOK == .abort)

        #expect(s[1].verifiesCapabilities && s[1].onNotOK == .abort)
        for i in [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11] { #expect(!s[i].verifiesCapabilities, "step \(i)") }

        guard case .fallback(let extFallback) = s[6].onNotOK else { Issue.record("step 6 has no fallback"); return }
        #expect(extFallback.operation == .sdioGetExtDeviceInfo(version: 0xC8))
        #expect(extFallback.onNotOK == .continuePlan)

        for i in [2, 3, 4, 5, 7, 8, 9, 10, 11] { #expect(s[i].onNotOK == .continuePlan, "step \(i)") }
        for i in 0 ..< s.count {
            let expected: Duration? = i == 10 ? .milliseconds(200) : i == 11 ? .milliseconds(1500) : nil
            #expect(s[i].pauseAfter == expected, "step \(i)")
        }

        #expect(s[0].accepts(.ok))
        #expect(openFallback.accepts(.sessionAlreadyOpen))
        #expect(!s[3].accepts(.storeNotAvailable))
        #expect(!s[0].accepts(.sessionAlreadyOpen))
    }

    @Test("Poll schedule: 2, 3, 5 s then every 5 s, up to 120 s (30 s on a reopen)")
    func pollSchedule() {
        let poll = plan.listing
        #expect(poll.wait(afterAttempt: 1, elapsed: .zero) == .seconds(2))
        #expect(poll.wait(afterAttempt: 2, elapsed: .seconds(2)) == .seconds(3))
        #expect(poll.wait(afterAttempt: 3, elapsed: .seconds(5)) == .seconds(5))
        #expect(poll.wait(afterAttempt: 4, elapsed: .seconds(10)) == .seconds(5))
        #expect(poll.wait(afterAttempt: 0, elapsed: .zero) == .seconds(2))
        #expect(poll.limit == .seconds(120))
        #expect(poll.wait(afterAttempt: 9, elapsed: .seconds(115)) == .seconds(5))
        #expect(poll.wait(afterAttempt: 9, elapsed: .seconds(116)) == nil)

        let reopen = SonyContentsTransferPlan.wholeCard(reopening: true).listing
        #expect(reopen.limit == .seconds(30))
        #expect(reopen.wait(afterAttempt: 5, elapsed: .seconds(26)) == nil)
        #expect(reopen.wait(afterAttempt: 5, elapsed: .seconds(25)) == .seconds(5))
        #expect(poll.handlesReplyTimeout == .seconds(60))
        #expect(reopen.handlesReplyTimeout == .seconds(60))
    }

    @Test("Poll lists only storages with a logical store, all objects")
    func pollStorages() {
        func id(_ v: UInt32) -> PTPStorageID { PTPStorageID(rawValue: v) }
        #expect(SonyListingPoll.storagesToList([id(0x0001_0001), id(0x0002_0000), id(0x0003_0002)]) == [id(0x0001_0001), id(0x0003_0002)])
        let cmd = SonyListingPoll.handlesCommand(for: id(0x0001_0001), tx: 5)
        #expect(cmd?.code == 0x1007)
        #expect(cmd?.parameters == [0x0001_0001, 0, 0])
        #expect(cmd?.transactionID == 5)
        #expect(SonyListingPoll.handlesCommand(for: id(0x0002_0000), tx: 5) == nil)
        #expect(!SonyListingPoll.isReady(handleCounts: []))
        #expect(!SonyListingPoll.isReady(handleCounts: [0, 0]))
        #expect(SonyListingPoll.isReady(handleCounts: [0, 3]))
    }

    @Test("Plan constants: keep-alive, timeouts and reconnect pauses")
    func constants() {
        #expect(plan.keepAliveInterval == .seconds(10))
        #expect(plan.replyTimeout == .seconds(30))
        #expect(plan.reconnectPause == .milliseconds(500))
        #expect(plan.handshakeRetryDelay == .seconds(1))
        #expect(SonyContentsTransferPlan.keepAliveCommand(tx: 3) == PTPCommand.getDeviceInfo(tx: 3))

        let reopen = SonyContentsTransferPlan.wholeCard(reopening: true)
        #expect(plan == SonyContentsTransferPlan.wholeCard(reopening: false))
        #expect(plan != reopen)
        var adjusted = reopen
        adjusted.listing.limit = plan.listing.limit
        #expect(adjusted == plan)
    }

    @Test("Every step crosses PTP/IP with no data-out phase")
    func wire() throws {
        for (n, step) in collectSteps(plan.steps).enumerated() {
            let cmd = step.operation.command(tx: UInt32(n + 1))
            #expect(step.operation.dataPhase == .none)
            let decoded = try PTPIP.decodeCmdRequest(PTPIP.cmdRequest(cmd, dataPhase: step.operation.dataPhase))
            #expect(decoded.dataPhase == PTPIP.DataPhase.none.rawValue)
            #expect(decoded.command == cmd)
        }
    }

    @Test("Descriptions name the code and parameters")
    func descriptions() {
        #expect(SonySessionStep.Operation.sdioOpenSession(sessionID: 1, functionMode: 1).description == "SDIO_OpenSession (0x9210) [1, 1]")
        #expect(SonySessionStep.Operation.setContentsTransferMode(2, 1, 0).description == "SDIO_SetContentsTransferMode (0x9212) [2, 1, 0]")
        #expect(SonySessionStep.Operation.sdioGetExtDeviceInfo(version: 0x12C).description == "SDIO_GetExtDeviceInfo (0x9202) [0x12C]")
        #expect(SonySessionStep.Operation.getDeviceInfo.description == "GetDeviceInfo (0x1001)")
        #expect(SonySessionStep.Operation.openSession(sessionID: 1).description == "OpenSession (0x1002) [1]")
        #expect(SonySessionStep.Operation.sdioConnect(phase: 2).description == "SDIO_Connect (0x9201) [2]")
    }
}

@Suite("Sony session runner")
struct SonySessionRunnerTests {
    static let plan = SonyContentsTransferPlan.wholeCard()
    typealias Runner = SonySessionRunner

    /// A runner advanced to just before step `index` has been answered: step `index` has been sent.
    static func runner(sentUpTo index: Int) -> Runner {
        var r = Runner(plan: plan)
        var action = r.next(nil)
        for i in 0 ..< index {
            #expect(action == .send(plan.steps[i]))
            if i == 1 {
                action = r.next(.deviceInfo(SonyDevices.pcRemote))
            } else {
                action = r.next(.response(.ok))
            }
            if case .wait = action { action = r.next(nil) }
        }
        #expect(action == .send(plan.steps[index]))
        return r
    }

    @Test("The happy path walks all twelve steps, then lists")
    func happyPath() {
        let steps = Self.plan.steps
        var r = Runner(plan: Self.plan)
        #expect(r.next(nil) == .send(steps[0]))
        #expect(r.next(.response(.ok)) == .send(steps[1]))
        #expect(r.next(.deviceInfo(SonyDevices.pcRemote)) == .send(steps[2]))
        #expect(r.latestDeviceInfo == SonyDevices.pcRemote)
        for i in 2 ..< 9 { #expect(r.next(.response(.ok)) == .send(steps[i + 1]), "after step \(i)") }
        var modified = SonyDevices.pcRemote
        modified.operationsSupported.append(0x9999)
        #expect(r.next(.deviceInfo(modified)) == .send(steps[10]))
        #expect(r.latestDeviceInfo == modified)
        #expect(r.next(.response(.ok)) == .wait(.milliseconds(200)))
        #expect(r.next(nil) == .send(steps[11]))
        #expect(r.next(.response(.ok)) == .wait(.milliseconds(1500)))
        #expect(r.next(nil) == .list(Self.plan.listing))
        #expect(r.next(.response(.ok)) == .list(Self.plan.listing))
        #expect(r.records.count == 12)
        let allAccepted = r.records.allSatisfy { $0.accepted }
        #expect(allAccepted)
        #expect(r.records[0].description == "SDIO_OpenSession (0x9210) [1, 1]: OK")
    }

    @Test("A failed 0x9210 falls back to OpenSession, and SessionAlreadyOpen is success")
    func openSessionFallback() {
        let steps = Self.plan.steps
        guard case .fallback(let fallback) = steps[0].onNotOK else { Issue.record("no fallback"); return }
        var r = Runner(plan: Self.plan)
        #expect(r.next(nil) == .send(steps[0]))
        #expect(r.next(.response(.operationNotSupported)) == .send(fallback))
        #expect(r.next(.response(.sessionAlreadyOpen)) == .send(steps[1]))
        #expect(r.records[0] == Runner.Record(operation: steps[0].operation, response: .operationNotSupported, accepted: false))
        #expect(r.records[1].accepted)
        #expect(r.records[1].operation == .openSession(sessionID: 1))
    }

    @Test("If the OpenSession fallback fails too, the plan stops")
    func openSessionFallbackFails() {
        var r = Runner(plan: Self.plan)
        _ = r.next(nil)
        guard case .send(let fallback) = r.next(.response(.generalError)) else { Issue.record("no fallback sent"); return }
        #expect(fallback.operation == .openSession(sessionID: 1))
        #expect(r.next(.response(.generalError)) == .stop(.stepFailed(.openSession(sessionID: 1), .generalError)))
    }

    @Test("ExtDeviceInfo retries with 0xC8, and the retry's failure is tolerated")
    func extDeviceInfoFallback() {
        let steps = Self.plan.steps
        guard case .fallback(let retry) = steps[6].onNotOK else { Issue.record("no fallback"); return }
        var r = Self.runner(sentUpTo: 6)
        #expect(r.next(.response(.parameterNotSupported)) == .send(retry))
        #expect(r.next(.response(.generalError)) == .send(steps[7]))

        var second = Self.runner(sentUpTo: 6)
        #expect(second.next(.undecodable) == .send(retry))
    }

    @Test("Tolerated steps continue, and a pause still happens after a non-OK answer")
    func toleratedStepsContinue() {
        let steps = Self.plan.steps
        var r = Self.runner(sentUpTo: 3)
        #expect(r.next(.response(.storeNotAvailable)) == .send(steps[4]))
        #expect(r.records.last?.accepted == false)

        var s = Self.runner(sentUpTo: 10)
        #expect(s.next(.response(.invalidParameter)) == .wait(.milliseconds(200)))
        #expect(s.next(nil) == .send(steps[11]))
    }

    @Test("A link failure stops the plan at once, with no pause")
    func linkFailureStops() {
        var r = Self.runner(sentUpTo: 4)
        #expect(r.next(.linkFailed) == .stop(.linkFailed(.sdioConnect(phase: 1))))
        var s = Self.runner(sentUpTo: 10)
        #expect(s.next(.linkFailed) == .stop(.linkFailed(.setContentsTransferMode(2, 0, 0))))
        #expect(s.next(nil) == .stop(.linkFailed(.setContentsTransferMode(2, 0, 0))))
    }

    @Test("Descriptions of capabilities, outcomes and failures never show the camera serial")
    func descriptionsOmitSerial() {
        var info = SonyDevices.mtpMode
        info.serialNumber = "SERIAL-1234567"
        let caps = SonyCapabilities(deviceInfo: info)
        #expect(caps.description == "Sony ILCE-7CM2 2.0: 0x9210 not listed, 0x9212 not listed")
        let texts = [
            "\(caps)",
            "\(SonySessionRunner.Failure.unsupported(caps))",
            "\(SonySessionRunner.Action.stop(.unsupported(caps)))",
            "\(SonySessionRunner.Outcome.deviceInfo(info))",
            "\(Optional(SonySessionRunner.Outcome.deviceInfo(info)) as Any)",
        ]
        for text in texts {
            #expect(!text.contains("1234567"), "\(text)")
        }
        #expect("\(SonySessionRunner.Outcome.deviceInfo(SonyDevices.pcRemote))"
                == "deviceInfo (Sony ILCE-7CM2 2.01: 0x9210 listed, 0x9212 listed)")
    }

    @Test("The capability gate stops a camera that can't do a whole-card session")
    func capabilityGate() {
        var r = Self.runner(sentUpTo: 1)
        #expect(r.next(.deviceInfo(SonyDevices.mtpMode)) == .stop(.unsupported(SonyCapabilities(deviceInfo: SonyDevices.mtpMode))))

        var s = Self.runner(sentUpTo: 1)
        #expect(s.next(.response(.ok)) == .stop(.stepFailed(.getDeviceInfo, nil)))

        var t = Self.runner(sentUpTo: 1)
        #expect(t.next(.undecodable) == .stop(.stepFailed(.getDeviceInfo, nil)))

        var u = Self.runner(sentUpTo: 1)
        #expect(u.next(.response(.generalError)) == .stop(.stepFailed(.getDeviceInfo, .generalError)))
    }

    @Test("Misuse never traps and stops are final")
    func misuseNeverTraps() {
        var r = Self.runner(sentUpTo: 2)
        #expect(r.next(nil) == .stop(.outOfOrder))
        #expect(r.next(.response(.ok)) == .stop(.outOfOrder))

        var w = Self.runner(sentUpTo: 10)
        #expect(w.next(.response(.ok)) == .wait(.milliseconds(200)))
        #expect(w.next(.response(.ok)) == .stop(.outOfOrder))
        #expect(w.next(nil) == .stop(.outOfOrder))

        var fresh = Runner(plan: Self.plan)
        #expect(fresh.next(.response(.ok)) == .stop(.outOfOrder))

        var empty = Runner(plan: SonyContentsTransferPlan(steps: [], listing: Self.plan.listing, replyTimeout: .seconds(1),
                                                          keepAliveInterval: .seconds(1), reconnectPause: .zero, handshakeRetryDelay: .zero))
        #expect(empty.next(nil) == .list(Self.plan.listing))
    }
}

@Suite("Sony capabilities and events")
struct SonyCapabilitiesTests {
    @Test("A PC Remote DeviceInfo offers every Sony feature")
    func pcRemote() {
        let caps = SonyCapabilities(deviceInfo: SonyDevices.pcRemote)
        #expect(caps.isSony && caps.wholeCardContentsTransfer && caps.sdioInitSequence && caps.extDeviceInfo)
        #expect(caps.largeObjectPartialRead && caps.sonyObjectAdded)
        #expect(caps.partialReadVariant(objectSize: 50_000_000, in: .wholeCardContentsTransfer) == .sonyLarge9211)
        #expect(caps.partialReadVariant(objectSize: 5 << 30, in: .wholeCardContentsTransfer) == .sonyLarge9211)
        #expect(!caps.mayRead(.batteryLevel))
    }

    @Test("An MTP-mode DeviceInfo is Sony but offers no Sony feature")
    func mtpMode() {
        let caps = SonyCapabilities(deviceInfo: SonyDevices.mtpMode)
        #expect(caps.isSony)
        #expect(!caps.wholeCardContentsTransfer && !caps.sdioInitSequence && !caps.extDeviceInfo)
        #expect(!caps.largeObjectPartialRead && !caps.sonyObjectAdded)
        #expect(caps.partialReadVariant(objectSize: 50_000_000, in: .plain) == .standard32)
        #expect(caps.partialReadVariant(objectSize: 5 << 30, in: .plain) == nil)
        #expect(caps.partialReadVariant(objectSize: 50_000_000, in: .wholeCardContentsTransfer) == nil)
        #expect(caps.mayRead(.batteryLevel))
    }

    @Test("Sony's vendor codes mean nothing on another maker's body")
    func vendorCodesNeedSony() {
        let caps = SonyCapabilities(deviceInfo: SonyDevices.nikonWithClashingCodes)
        #expect(!caps.isSony)
        #expect(!caps.wholeCardContentsTransfer && !caps.sdioInitSequence && !caps.extDeviceInfo)
        #expect(!caps.largeObjectPartialRead && !caps.sonyObjectAdded)
        #expect(caps.partialReadVariant(objectSize: 50_000_000, in: .wholeCardContentsTransfer) == nil)
    }

    @Test("Events map to what a whole-card session cares about")
    func events() {
        func code(_ v: UInt16) -> PTPEventCode { PTPEventCode(rawValue: v) }
        #expect(SonySessionEvent(code: code(0x4004), parameters: [0x0001_0001]) == .storeAdded(PTPStorageID(rawValue: 0x0001_0001)))
        #expect(SonySessionEvent(code: code(0x4004), parameters: []) == .storeAdded(nil))
        #expect(SonySessionEvent(code: code(0x4005), parameters: [0x0001_0001]) == .storeRemoved(PTPStorageID(rawValue: 0x0001_0001)))
        #expect(SonySessionEvent(code: code(0xC201), parameters: [0xFFFF_C001]) == .objectAdded(PTPObjectHandle(rawValue: 0xFFFF_C001)))
        #expect(SonySessionEvent(code: code(0x4002), parameters: [5]) == .objectAdded(PTPObjectHandle(rawValue: 5)))
        #expect(SonySessionEvent(code: code(0xC225), parameters: []) == .other(code(0xC225)))
        #expect(SonySessionEvent(code: code(0xC223), parameters: [7]) == .other(code(0xC223)))
        let event = (try? PTPIP.decodeEvent(PTPIP.event(.storeAdded, parameters: [0x0001_0001])))
        #expect(event.map(SonySessionEvent.init) == .storeAdded(PTPStorageID(rawValue: 0x0001_0001)))
    }
}
