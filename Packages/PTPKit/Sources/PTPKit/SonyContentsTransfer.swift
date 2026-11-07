// Sony's whole-card contents-transfer session over PTP/IP, as a plan a transport can run: the commands in order,
// what to do with each answer, the pauses, the listing poll and the timeouts. Pure values, no I/O.
//
// Every Sony value here is `unverified` on the α7C II until a fixture captures it. The sequence is Imagedge's
// (field-tested on a ZV-E10); what the spike saw on the α7C II (builds 0.1 (7.1) to 0.1 (14.1), 2–4 Nov 2026) is in each doc
// comment. Source of the facts: Spike/Sources/Views/WirelessView.swift (`openContents`, `sonyInitSequence`,
// `initStep`, `setTransferMode`, `pollForHandles`, `connectFresh`, `startKeepAlive`) and docs/spike-findings.md
// "Wireless browsing in 1.0" and "PTP/IP and join facts".
//
// Out of scope: the selected-on-camera set ([1, 0, 0] after OpenSession), copy and recovery orchestration, joining
// the network, SSDP and Bluetooth, and parsing ExtDeviceInfo.

import Foundation

/// One step of a session plan: a command built with PTPCommand's builders, and what to do with its answer.
public struct SonySessionStep: Equatable, Sendable {
    public enum Operation: Equatable, Sendable, CustomStringConvertible {
        case sdioOpenSession(sessionID: UInt32, functionMode: UInt32)  // PTPCommand.sonySDIOOpenSession
        case openSession(sessionID: UInt32)                            // PTPCommand.openSession
        case getDeviceInfo                                             // PTPCommand.getDeviceInfo
        case getStorageIDs                                             // PTPCommand.getStorageIDs
        case sdioConnect(phase: UInt32)                                // PTPCommand.sonySDIOConnect
        case sdioGetExtDeviceInfo(version: UInt32)                     // PTPCommand.sonySDIOGetExtDeviceInfo
        case setContentsTransferMode(UInt32, UInt32, UInt32)           // PTPCommand.sonySetContentsTransferMode

        public var operationCode: PTPOperationCode {
            switch self {
            case .sdioOpenSession: .sonySDIOOpenSession
            case .openSession: .openSession
            case .getDeviceInfo: .getDeviceInfo
            case .getStorageIDs: .getStorageIDs
            case .sdioConnect: .sonySDIOConnect
            case .sdioGetExtDeviceInfo: .sonySDIOGetExtDeviceInfo
            case .setContentsTransferMode: .sonySDIOSetContentsTransferMode
            }
        }

        /// What Cmd_Request's data-phase flag says: every step's data, if any, flows responder to initiator, so
        /// `.none` for all of them.
        public var dataPhase: PTPIP.DataPhase { .none }

        /// The container, with exactly the ID given.
        public func command(tx: UInt32) -> PTPContainer {
            switch self {
            case .sdioOpenSession(let sessionID, let mode):
                PTPCommand.sonySDIOOpenSession(sessionID: sessionID, functionMode: mode, tx: tx)
            case .openSession(let sessionID):
                PTPCommand.openSession(sessionID: sessionID, tx: tx)
            case .getDeviceInfo:
                PTPCommand.getDeviceInfo(tx: tx)
            case .getStorageIDs:
                PTPCommand.getStorageIDs(tx: tx)
            case .sdioConnect(let phase):
                PTPCommand.sonySDIOConnect(phase: phase, tx: tx)
            case .sdioGetExtDeviceInfo(let version):
                PTPCommand.sonySDIOGetExtDeviceInfo(version: version, tx: tx)
            case .setContentsTransferMode(let a, let b, let c):
                PTPCommand.sonySetContentsTransferMode(a, b, c, tx: tx)
            }
        }

        /// The container with the session's numbering: OpenSession is always sent with transaction ID 0 and
        /// restarts `counter` (the next ID is 1); every other operation, SDIO_OpenSession included, takes
        /// `counter.take()` (on a fresh connection 0x9210 gets 1, as in the spike and Imagedge).
        public func command(using counter: inout PTPTransactionCounter) -> PTPContainer {
            if case .openSession = self {
                counter = PTPTransactionCounter()
                return command(tx: 0)
            }
            return command(tx: counter.take())
        }

        /// For logs: e.g. "SDIO_OpenSession (0x9210) [1, 1]", "OpenSession (0x1002) [1]", "GetDeviceInfo (0x1001)",
        /// "SDIO_Connect (0x9201) [2]", "SDIO_GetExtDeviceInfo (0x9202) [0x12C]",
        /// "SDIO_SetContentsTransferMode (0x9212) [2, 1, 0]".
        public var description: String {
            let code = "0x" + String(operationCode.rawValue, radix: 16, uppercase: true)
            func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16, uppercase: true) }
            switch self {
            case .sdioOpenSession(let sessionID, let mode): return "SDIO_OpenSession (\(code)) [\(sessionID), \(mode)]"
            case .openSession(let sessionID): return "OpenSession (\(code)) [\(sessionID)]"
            case .getDeviceInfo: return "GetDeviceInfo (\(code))"
            case .getStorageIDs: return "GetStorageIDs (\(code))"
            case .sdioConnect(let phase): return "SDIO_Connect (\(code)) [\(phase)]"
            case .sdioGetExtDeviceInfo(let version): return "SDIO_GetExtDeviceInfo (\(code)) [\(hex(version))]"
            case .setContentsTransferMode(let a, let b, let c): return "SDIO_SetContentsTransferMode (\(code)) [\(a), \(b), \(c)]"
            }
        }
    }

    public enum OnNotOK: Equatable, Sendable {
        /// The session can't be used.
        case abort
        /// Note it and go on.
        case continuePlan
        /// Send this instead; its own rule applies to its answer.
        indirect case fallback(SonySessionStep)
    }

    public var operation: Operation
    /// Codes accepted as well as OK (OpenSession: SessionAlreadyOpen).
    public var treatedAsOK: [PTPResponseCode]
    public var onNotOK: OnNotOK
    /// A GetDeviceInfo whose decoded dataset must show `SonyCapabilities.wholeCardContentsTransfer`; otherwise the
    /// plan stops as unsupported.
    public var verifiesCapabilities: Bool
    /// Waited after this step (after its fallback, if one ran), whatever the answer, unless the plan stopped.
    public var pauseAfter: Duration?

    public init(_ operation: Operation, treatedAsOK: [PTPResponseCode] = [], onNotOK: OnNotOK = .continuePlan,
                verifiesCapabilities: Bool = false, pauseAfter: Duration? = nil) {
        self.operation = operation
        self.treatedAsOK = treatedAsOK
        self.onNotOK = onNotOK
        self.verifiesCapabilities = verifiesCapabilities
        self.pauseAfter = pauseAfter
    }

    /// `code == .ok || treatedAsOK.contains(code)`.
    public func accepts(_ code: PTPResponseCode) -> Bool { code == .ok || treatedAsOK.contains(code) }
}

/// The listing poll after the steps.
public struct SonyListingPoll: Equatable, Sendable {
    /// The waits between the first attempts: 2 s, 3 s, 5 s in the spike.
    public var initialWaits: [Duration]
    /// The wait between every later attempt: 5 s.
    public var laterWait: Duration
    /// How long to keep polling: 120 s for a fresh session, 30 s for a reopen.
    public var limit: Duration
    /// The reply timeout for GetObjectHandles: 60 s (the spike's); other commands use the plan's `replyTimeout`.
    public var handlesReplyTimeout: Duration

    public init(initialWaits: [Duration], laterWait: Duration, limit: Duration, handlesReplyTimeout: Duration) {
        self.initialWaits = initialWaits
        self.laterWait = laterWait
        self.limit = limit
        self.handlesReplyTimeout = handlesReplyTimeout
    }

    /// The wait before the next attempt after attempt `attempt` (1-based; < 1 is treated as 1), or nil when
    /// `elapsed` + wait > `limit` (equal is allowed, as in the spike). `elapsed` counts from the first attempt.
    public func wait(afterAttempt attempt: Int, elapsed: Duration) -> Duration? {
        let n = max(attempt, 1)
        let next = n <= initialWaits.count ? initialWaits[n - 1] : laterWait
        return elapsed + next > limit ? nil : next
    }

    /// The storages to ask: those with a logical store (low 16 bits non-zero), in the order given.
    public static func storagesToList(_ ids: [PTPStorageID]) -> [PTPStorageID] {
        ids.filter(\.hasLogicalStore)
    }

    /// GetObjectHandles(storage, all formats, parent nil → 0, i.e. every object), or nil for a storage without a
    /// logical store.
    public static func handlesCommand(for storage: PTPStorageID, tx: UInt32) -> PTPContainer? {
        guard storage.hasLogicalStore else { return nil }
        return PTPCommand.getObjectHandles(storage: storage, format: nil, parent: nil, tx: tx)
    }

    /// True when any storage listed a handle.
    public static func isReady(handleCounts: [Int]) -> Bool { handleCounts.contains { $0 > 0 } }
}

/// Sony's whole-card contents-transfer session for PTP/IP, as the spike opened it on the α7C II (Imagedge's
/// sequence, field-tested on a ZV-E10). Unverified on the α7C II until a fixture captures it; what the spike saw is
/// in each step's doc. A transport runs it with `SonySessionRunner` after the PTP/IP handshake; the plan holds no I/O.
/// Every step's data phase, if any, flows responder → initiator, so Cmd_Request's flag is always `DataPhase.none`.
public struct SonyContentsTransferPlan: Equatable, Sendable {
    public var steps: [SonySessionStep]
    public var listing: SonyListingPoll
    /// 30 s; a timeout poisons the channel, so close and reconnect.
    public var replyTimeout: Duration
    /// 10 s; send only while no other transaction is in flight. GetDeviceInfo, because the camera reports a drop
    /// after about 30 s idle (Imagedge) and never answers GetDevicePropValue in this session.
    public var keepAliveInterval: Duration
    /// 500 ms after closing a previous connection (spike code, Imagedge's advice; the findings don't record the
    /// α7C II needing it).
    public var reconnectPause: Duration
    /// 1 s; one retry of a failed handshake on a new connection (spike code, Imagedge's advice).
    public var handshakeRetryDelay: Duration

    public init(steps: [SonySessionStep], listing: SonyListingPoll, replyTimeout: Duration, keepAliveInterval: Duration,
                reconnectPause: Duration, handshakeRetryDelay: Duration) {
        self.steps = steps
        self.listing = listing
        self.replyTimeout = replyTimeout
        self.keepAliveInterval = keepAliveInterval
        self.reconnectPause = reconnectPause
        self.handshakeRetryDelay = handshakeRetryDelay
    }

    /// The 12 steps below plus the poll; `reopening` only shortens the poll limit to 30 s (a reopen after a drop
    /// took about 2.5 s and kept the same handles in the spike).
    ///
    /// The spike's order, and what it saw on the α7C II (unverified):
    /// 0. SDIO_OpenSession 0x9210 [1, 1] in place of OpenSession; answered OK, transaction ID 1 on a fresh
    ///    connection. On a non-OK answer fall back to OpenSession 0x1002 (transaction ID 0, counter restarts at 1),
    ///    treating SessionAlreadyOpen as success; the fallback was never exercised. Sending both answers 0x201E
    ///    (Imagedge), so never send OpenSession after a successful 0x9210.
    /// 1. GetDeviceInfo; a failure aborts, and the dataset must list 0x9210 and 0x9212.
    /// 2. GetDeviceInfo again (Imagedge's order).
    /// 3. GetStorageIDs (StoreNotAvailable in a plain session; tolerated).
    /// 4–5. SDIO_Connect 1 and 2 (OK, 8 zero bytes each).
    /// 6. SDIO_GetExtDeviceInfo 0x12C (OK, 970 bytes: version 0x12C, 421 then 59 codes); if not OK retry with
    ///    0xC8 (never needed on the α7C II).
    /// 7. SDIO_Connect 3 (OK).
    /// 8. SDIO_GetExtDeviceInfo 0x12C again (the same 970 bytes).
    /// 9. GetDeviceInfo (81 operations, 48 events, 0 properties, before and after).
    /// 10. SDIO_SetContentsTransferMode [2, 0, 0], pause 200 ms. A non-OK answer is noted and the plan goes on.
    /// 11. SDIO_SetContentsTransferMode [2, 1, 0], pause 1500 ms. Both answered OK, then StoreAdded 0x4004
    ///     [0x00010001] arrived.
    ///
    /// Removing any of steps 2, 8 or 9 is untested.
    public static func wholeCard(reopening: Bool = false) -> SonyContentsTransferPlan {
        let steps: [SonySessionStep] = [
            SonySessionStep(.sdioOpenSession(sessionID: 1, functionMode: 1),
                            onNotOK: .fallback(SonySessionStep(.openSession(sessionID: 1),
                                                               treatedAsOK: [.sessionAlreadyOpen], onNotOK: .abort))),
            SonySessionStep(.getDeviceInfo, onNotOK: .abort, verifiesCapabilities: true),
            SonySessionStep(.getDeviceInfo),
            SonySessionStep(.getStorageIDs),
            SonySessionStep(.sdioConnect(phase: 1)),
            SonySessionStep(.sdioConnect(phase: 2)),
            SonySessionStep(.sdioGetExtDeviceInfo(version: 0x12C),
                            onNotOK: .fallback(SonySessionStep(.sdioGetExtDeviceInfo(version: 0xC8)))),
            SonySessionStep(.sdioConnect(phase: 3)),
            SonySessionStep(.sdioGetExtDeviceInfo(version: 0x12C)),
            SonySessionStep(.getDeviceInfo),
            SonySessionStep(.setContentsTransferMode(2, 0, 0), pauseAfter: .milliseconds(200)),
            SonySessionStep(.setContentsTransferMode(2, 1, 0), pauseAfter: .milliseconds(1500)),
        ]
        let listing = SonyListingPoll(initialWaits: [.seconds(2), .seconds(3), .seconds(5)], laterWait: .seconds(5),
                                      limit: reopening ? .seconds(30) : .seconds(120), handlesReplyTimeout: .seconds(60))
        return SonyContentsTransferPlan(steps: steps, listing: listing, replyTimeout: .seconds(30),
                                        keepAliveInterval: .seconds(10), reconnectPause: .milliseconds(500),
                                        handshakeRetryDelay: .seconds(1))
    }

    /// The keep-alive: GetDeviceInfo, never GetDevicePropValue (see `SonyCapabilities.mayRead`).
    public static func keepAliveCommand(tx: UInt32) -> PTPContainer {
        PTPCommand.getDeviceInfo(tx: tx)
    }
}

/// Walks a plan one answer at a time. The transport sends what `.send` gives (building the command with
/// `operation.command(using:)` on its counter), waits on `.wait`, then calls `next` again; `.list` and `.stop`
/// are final and are returned again on every later call. Misuse never traps.
public struct SonySessionRunner: Sendable, CustomStringConvertible {
    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        /// The response, with any data phase discarded or not needed.
        case response(PTPResponseCode)
        /// OK, with GetDeviceInfo's dataset decoded.
        case deviceInfo(PTPDeviceInfo)
        /// OK, but the data phase didn't decode; link healthy.
        case undecodable
        /// Timeout, drop, framing error.
        case linkFailed

        /// For logs. A decoded DeviceInfo shows as the capabilities summary, never with its serial number.
        public var description: String {
            switch self {
            case .response(let code): "response \(code)"
            case .deviceInfo(let info): "deviceInfo (\(SonyCapabilities(deviceInfo: info)))"
            case .undecodable: "undecodable"
            case .linkFailed: "linkFailed"
            }
        }
    }

    public enum Action: Equatable, Sendable {
        case send(SonySessionStep)
        case wait(Duration)
        /// The steps are done; run the poll.
        case list(SonyListingPoll)
        case stop(Failure)
    }

    public enum Failure: Error, Equatable, Sendable {
        case linkFailed(SonySessionStep.Operation)
        /// The response code, or nil when there was no usable dataset.
        case stepFailed(SonySessionStep.Operation, PTPResponseCode?)
        case unsupported(SonyCapabilities)
        /// `next(nil)` while a step's answer was due, or an outcome while nothing was awaited.
        case outOfOrder
    }

    /// One per answered step, fallbacks included.
    public struct Record: Equatable, Sendable, CustomStringConvertible {
        public let operation: SonySessionStep.Operation
        /// nil for `.undecodable` and `.linkFailed`; `.ok` for `.deviceInfo`.
        public let response: PTPResponseCode?
        public let accepted: Bool

        public init(operation: SonySessionStep.Operation, response: PTPResponseCode?, accepted: Bool) {
            self.operation = operation
            self.response = response
            self.accepted = accepted
        }

        /// e.g. "SDIO_OpenSession (0x9210) [1, 1]: OK".
        public var description: String {
            guard let response else { return "\(operation): no usable answer" }
            return accepted ? "\(operation): \(response)" : "\(operation): \(response) (not accepted)"
        }
    }

    /// For logs: how far the session got, with the camera as its capabilities summary, never with its serial number.
    public var description: String {
        let camera = latestDeviceInfo.map { "\(SonyCapabilities(deviceInfo: $0))" } ?? "no DeviceInfo yet"
        return "SonySessionRunner(\(records.count) answered, \(camera), state \(state))"
    }

    private enum State: Equatable, Sendable {
        case start
        case awaiting(SonySessionStep)
        case pausing
        case finished(Action)
    }

    public let plan: SonyContentsTransferPlan
    public private(set) var records: [Record] = []
    public private(set) var latestDeviceInfo: PTPDeviceInfo?
    private var state: State = .start
    /// Index of the main step in progress (a fallback runs under its main step's index).
    private var index = 0

    public init(plan: SonyContentsTransferPlan) {
        self.plan = plan
    }

    /// First call: `next(nil)`. After `.send`: `next(outcome)`. After `.wait`: `next(nil)`.
    public mutating func next(_ outcome: Outcome?) -> Action {
        switch state {
        case .finished(let action):
            return action
        case .start:
            guard outcome == nil else { return finish(.stop(.outOfOrder)) }
            index = 0
            return begin(index)
        case .pausing:
            guard outcome == nil else { return finish(.stop(.outOfOrder)) }
            index += 1
            return begin(index)
        case .awaiting(let step):
            guard let outcome else { return finish(.stop(.outOfOrder)) }
            return judge(outcome, for: step)
        }
    }

    private mutating func begin(_ i: Int) -> Action {
        guard i < plan.steps.count else { return finish(.list(plan.listing)) }
        let step = plan.steps[i]
        state = .awaiting(step)
        return .send(step)
    }

    private mutating func finish(_ action: Action) -> Action {
        state = .finished(action)
        return action
    }

    private mutating func moveOn() -> Action {
        if let pause = plan.steps[index].pauseAfter {
            state = .pausing
            return .wait(pause)
        }
        index += 1
        return begin(index)
    }

    private mutating func judge(_ outcome: Outcome, for step: SonySessionStep) -> Action {
        let op = step.operation
        let accepted: Bool
        let code: PTPResponseCode?
        switch outcome {
        case .linkFailed:
            records.append(Record(operation: op, response: nil, accepted: false))
            return finish(.stop(.linkFailed(op)))
        case .response(let c):
            if step.verifiesCapabilities && c == .ok {
                // OK with no dataset to verify.
                accepted = false
                code = nil
            } else {
                accepted = step.accepts(c)
                code = c
            }
            records.append(Record(operation: op, response: c, accepted: accepted))
        case .deviceInfo(let info):
            latestDeviceInfo = info
            records.append(Record(operation: op, response: .ok, accepted: true))
            if step.verifiesCapabilities {
                let caps = SonyCapabilities(deviceInfo: info)
                if !caps.wholeCardContentsTransfer { return finish(.stop(.unsupported(caps))) }
            }
            return moveOn()
        case .undecodable:
            accepted = false
            code = nil
            records.append(Record(operation: op, response: nil, accepted: false))
        }

        if accepted { return moveOn() }
        switch step.onNotOK {
        case .abort:
            return finish(.stop(.stepFailed(op, code)))
        case .continuePlan:
            return moveOn()
        case .fallback(let fallback):
            state = .awaiting(fallback)
            return .send(fallback)
        }
    }
}

/// What an event means to a whole-card session.
public enum SonySessionEvent: Equatable, Sendable {
    /// 0x4004 [storage]; seen after 0x9212 [2,1,0] and after a camera restart.
    case storeAdded(PTPStorageID?)
    /// 0x4005; seen before StoreNotAvailable and the camera closing both channels.
    case storeRemoved(PTPStorageID?)
    /// 0x4002 or 0xC201 [first parameter]; 0xC201's 0xFFFFC001 is a buffer slot, not a card handle.
    case objectAdded(PTPObjectHandle?)
    /// Everything else, including 0xC223 (shutter state), 0xC206 and 0xC225 (seen twice on a reopen; meaning
    /// unknown, no action).
    case other(PTPEventCode)

    public init(code: PTPEventCode, parameters: [UInt32]) {
        let first = parameters.first
        switch code {
        case .storeAdded: self = .storeAdded(first.map(PTPStorageID.init(rawValue:)))
        case .storeRemoved: self = .storeRemoved(first.map(PTPStorageID.init(rawValue:)))
        case .objectAdded, .sonyObjectAdded: self = .objectAdded(first.map(PTPObjectHandle.init(rawValue:)))
        default: self = .other(code)
        }
    }

    public init(_ event: PTPIP.Event) {
        self.init(code: event.code, parameters: event.parameters)
    }
}
