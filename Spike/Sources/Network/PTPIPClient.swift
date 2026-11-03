import Foundation
// DispatchWorkItem is not yet annotated Sendable; its cancel() is thread-safe, which is all the receive
// callback uses it for.
@preconcurrency import Dispatch
import Network
import CryptoKit
import PTPKit

/// Days 7–9: a PTP/IP initiator on Network.framework, built on PTPKit's stream decoder and transaction.
///
/// Two TCP connections to port 15740: the command/data channel and the event channel, each with its own
/// `PTPIPStreamDecoder`. `perform` sends one Cmd_Request, feeds what the socket delivers through the decoder into
/// a `PTPIPTransaction`, streams the data phase to a sink (a 1 GB clip is never held in memory), answers pings,
/// forwards events, and returns the Cmd_Response. Strictly one operation in flight: a second `perform` while one
/// is running throws `.busy` (actor reentrancy would otherwise interleave two transactions on one socket).
///
/// Any link failure (timeout, drop, framing error, file error mid-transfer) poisons the client: every later call
/// throws the same error until a new client connects. That is what the day-9 resume test relies on.
///
/// One client per connection attempt: make a new one to reconnect.
actor PTPIPClient {
    enum LogLevel: Sendable { case note, warn, error }
    typealias Logger = @Sendable (LogLevel, String) -> Void

    enum ClientError: Error, CustomStringConvertible {
        case notConnected
        case busy(running: PTPOperationCode, requested: PTPOperationCode)
        case connectTimeout(channel: String, endpoint: String, seconds: Double)
        case refused(channel: String, endpoint: String)
        case network(channel: String, error: NWError)
        case closed(channel: String)
        case closedByCamera(channel: String)
        case linkLost(channel: String)
        case idleTimeout(channel: String, seconds: Double)
        case initFail(channel: String, reason: UInt32)
        case unexpectedPacket(channel: String, type: PTPIPPacketType)
        case protocolViolation(String)
        case response(operation: PTPOperationCode, code: PTPResponseCode)
        case dataTooLarge(operation: PTPOperationCode, limit: Int)
        case fileError(String)
        /// Build 14: the app cut the data phase off (TransferAbort: the copy's continued task expired). The channel is
        /// left mid-transaction, so the client is poisoned like after a link failure.
        case aborted(String)

        var description: String {
            switch self {
            case .notConnected:
                return "not connected (tap Connect first)"
            case .busy(let running, let requested):
                return "\(requested) refused: \(running) is still in flight (one operation at a time)"
            case .connectTimeout(let channel, let endpoint, let seconds):
                return "\(channel) channel: no TCP connection to \(endpoint) within \(Int(seconds)) s"
            case .refused(let channel, let endpoint):
                return "\(channel) channel: \(endpoint) refused the connection (nothing listening on the port)"
            case .network(let channel, let error):
                return "\(channel) channel: network error \(error)"
            case .closed(let channel):
                return "\(channel) channel closed"
            case .closedByCamera(let channel):
                return "\(channel) channel closed by the camera"
            case .linkLost(let channel):
                return "\(channel) channel: link lost (path not viable; Wi-Fi off or out of range?)"
            case .idleTimeout(let channel, let seconds):
                return "\(channel) channel: nothing received for \(Int(seconds)) s"
            case .initFail(let channel, let reason):
                return "Init_Fail on the \(channel) channel: \(PTPIP.InitFailReason.describe(reason))"
            case .unexpectedPacket(let channel, let type):
                return "\(channel) channel: unexpected \(type) packet"
            case .protocolViolation(let text):
                return "protocol error: \(text)"
            case .response(let operation, let code):
                return "\(operation) answered \(code) (0x\(String(format: "%04X", code.rawValue)))"
            case .dataTooLarge(let operation, let limit):
                return "\(operation): data phase larger than \(limit / 1_048_576) MiB; refused to buffer it"
            case .fileError(let text):
                return "file error: \(text)"
            case .aborted(let text):
                return "\(text): cut off by the app"
            }
        }

        /// True when the link itself is gone: reconnect (and resume) rather than retry.
        var isLinkFailure: Bool {
            switch self {
            case .connectTimeout, .refused, .network, .closed, .closedByCamera, .linkLost, .idleTimeout: return true
            default: return false
            }
        }
    }

    /// What the two-channel handshake took. `total` is the ptpip.<net>.handshake measurement.
    struct Handshake: Sendable {
        let connectionNumber: UInt32
        let responderName: String
        let responderGUID: UUID
        let protocolVersion: UInt32
        let commandConnect: Double
        let commandAck: Double
        let eventConnect: Double
        let eventAck: Double
        let total: Double

        var breakdown: String {
            String(format: "command TCP %.3f s + Init_Command_Ack %.3f s, event TCP %.3f s + Init_Event_Ack %.3f s (an ack includes any time spent confirming on the camera)",
                   commandConnect, commandAck, eventConnect, eventAck)
        }
    }

    struct IncomingEvent: Sendable {
        let event: PTPIP.Event
        /// The whole PTP/IP Event packet (length, type, payload) as received: the fixture format.
        let packet: Data
        /// "event" or "command": which connection it arrived on.
        let channel: String
        let receivedAt: Date
    }

    struct FileDownload: Sendable {
        let bytes: UInt64
        let sha256: String
        /// Wall time from sending Cmd_Request to Cmd_Response: the transfer itself, no session setup.
        let seconds: Double
        /// What Start_Data announced (nil if "unknown").
        let announcedLength: UInt64?
    }

    static let connectTimeout: Double = 10
    /// Long enough for the user to accept a "connect to this device?" prompt on the camera (day 7).
    static let ackTimeout: Double = 60
    static let idleTimeout: Double = 30

    nonisolated let host: String
    nonisolated let port: UInt16
    nonisolated let guid: UUID
    nonisolated let friendlyName: String
    nonisolated let log: Logger
    /// Events from both channels, in arrival order per channel. Finishes when the client disconnects.
    nonisolated let events: AsyncStream<IncomingEvent>
    private let eventContinuation: AsyncStream<IncomingEvent>.Continuation

    private var command: PTPIPChannel?
    private var event: PTPIPChannel?
    private var commandDecoder = PTPIPStreamDecoder()
    /// Decoder output that arrived after the last transaction's response (or during the handshake) and has not
    /// been consumed yet. The next transaction sees it first.
    private var leftover: [PTPIPStreamDecoder.Event] = []
    private var tx = PTPTransactionCounter()
    private var inFlight: PTPOperationCode?
    private var sessionOpen = false
    private var eventTask: Task<Void, Never>?
    private(set) var handshake: Handshake?
    private(set) var deviceInfo: PTPDeviceInfo?

    /// `guid` must be stable per install so the camera can remember us (day 7 question).
    init(host: String, port: UInt16 = PTPIP.defaultPort, guid: UUID, friendlyName: String = "Shutter Bridge spike",
         log: @escaping Logger) {
        self.host = host
        self.port = port
        self.guid = guid
        self.friendlyName = friendlyName
        self.log = log
        let (stream, continuation) = AsyncStream.makeStream(of: IncomingEvent.self, bufferingPolicy: .bufferingNewest(512))
        self.events = stream
        self.eventContinuation = continuation
    }

    /// The error that poisoned the command channel, if any (nil while the link is healthy).
    var linkFailure: ClientError? { command?.failure }
    var isConnected: Bool { command != nil && command?.failure == nil }

    // MARK: Connection and handshake

    /// Init_Command_Request → Init_Command_Ack on the command channel, then Init_Event_Request → Init_Event_Ack on
    /// a second connection, then starts the event loop. Times out instead of hanging; logs .waiting states.
    func connect() async throws -> Handshake {
        guard command == nil else { throw ClientError.protocolViolation("this client already connected once; make a new one to reconnect") }
        do {
            return try await handshakeBothChannels()
        } catch {
            closeChannels()
            throw error
        }
    }

    private func handshakeBothChannels() async throws -> Handshake {
        let clock = ContinuousClock()
        let started = clock.now

        let cmd = PTPIPChannel(name: "command", host: host, port: port, log: log)
        command = cmd
        commandDecoder = PTPIPStreamDecoder()
        leftover = []
        let commandConnect = try await cmd.open(timeout: Self.connectTimeout)

        let ackStarted = clock.now
        try await cmd.send(PTPIP.initCommandRequest(guid: guid, friendlyName: friendlyName).encode())
        log(.note, "Init_Command_Request sent; waiting up to \(Int(Self.ackTimeout)) s for Init_Command_Ack (accept the connection on the camera if it asks, and note its wording)")
        let ackPacket = try await nextCommandControlPacket(timeout: Self.ackTimeout)
        let ack: PTPIP.InitCommandAck
        switch ackPacket.type {
        case .initCommandAck:
            do { ack = try PTPIP.decodeInitCommandAck(ackPacket) } catch {
                throw ClientError.protocolViolation("Init_Command_Ack undecodable (\(error)): \(ackPacket.encode().hexDump())")
            }
        case .initFail:
            throw ClientError.initFail(channel: "command", reason: PTPIP.decodeInitFail(ackPacket))
        default:
            throw ClientError.unexpectedPacket(channel: "command", type: ackPacket.type)
        }
        let commandAck = (clock.now - ackStarted).inSeconds

        let evt = PTPIPChannel(name: "event", host: host, port: port, log: log)
        event = evt
        let eventConnect = try await evt.open(timeout: Self.connectTimeout)
        let eventAckStarted = clock.now
        try await evt.send(PTPIP.initEventRequest(connectionNumber: ack.connectionNumber).encode())
        var eventDecoder = PTPIPStreamDecoder()
        var eventPending: [PTPIPStreamDecoder.Event] = []
        let eventAckPacket = try await Self.firstControlPacket(on: evt, decoder: &eventDecoder, pending: &eventPending, timeout: Self.ackTimeout)
        switch eventAckPacket.type {
        case .initEventAck:
            break
        case .initFail:
            throw ClientError.initFail(channel: "event", reason: PTPIP.decodeInitFail(eventAckPacket))
        default:
            throw ClientError.unexpectedPacket(channel: "event", type: eventAckPacket.type)
        }
        let eventAck = (clock.now - eventAckStarted).inSeconds

        let result = Handshake(connectionNumber: ack.connectionNumber, responderName: ack.responderName,
                               responderGUID: ack.responderGUID, protocolVersion: ack.protocolVersion,
                               commandConnect: commandConnect, commandAck: commandAck,
                               eventConnect: eventConnect, eventAck: eventAck,
                               total: (clock.now - started).inSeconds)
        handshake = result
        startEventLoop(evt, decoder: eventDecoder, pending: eventPending)
        return result
    }

    /// CloseSession (if a session is open and the link is healthy), then closes both connections and finishes
    /// the event stream.
    func disconnect(closingSession: Bool = true) async {
        if closingSession, sessionOpen, inFlight == nil, let cmd = command, cmd.failure == nil {
            do {
                try await perform(PTPCommand.closeSession(tx: tx.take()), idleTimeout: 5)
                log(.note, "CloseSession OK")
            } catch {
                log(.warn, "CloseSession: \(error)")
            }
        }
        sessionOpen = false
        closeChannels()
        eventContinuation.finish()
    }

    private func closeChannels() {
        eventTask?.cancel()
        eventTask = nil
        command?.close()
        event?.close()
        command = nil
        event = nil
        leftover = []
        commandDecoder = PTPIPStreamDecoder()
    }

    /// Reads the command channel until one whole control packet is available (handshake only).
    private func nextCommandControlPacket(timeout: Double) async throws -> PTPIP.Packet {
        guard let cmd = command else { throw ClientError.notConnected }
        while true {
            if !leftover.isEmpty {
                let first = leftover.removeFirst()
                guard case .packet(let p) = first else {
                    throw ClientError.protocolViolation("data packet on the command channel during the handshake")
                }
                return p
            }
            let bytes = try await cmd.receive(idleTimeout: timeout)
            leftover.append(contentsOf: try feedCommandDecoder(bytes, channel: cmd))
        }
    }

    private static func firstControlPacket(on channel: PTPIPChannel, decoder: inout PTPIPStreamDecoder,
                                           pending: inout [PTPIPStreamDecoder.Event], timeout: Double) async throws -> PTPIP.Packet {
        while true {
            if !pending.isEmpty {
                let first = pending.removeFirst()
                guard case .packet(let p) = first else {
                    throw ClientError.protocolViolation("data packet on the \(channel.name) channel during the handshake")
                }
                return p
            }
            let bytes = try await channel.receive(idleTimeout: timeout)
            do {
                pending.append(contentsOf: try decoder.feed(bytes))
            } catch {
                let failure = ClientError.protocolViolation("\(channel.name) channel framing: \(error)")
                channel.fail(failure)
                throw failure
            }
        }
    }

    private func feedCommandDecoder(_ bytes: Data, channel: PTPIPChannel) throws -> [PTPIPStreamDecoder.Event] {
        do {
            return try commandDecoder.feed(bytes)
        } catch {
            let failure = ClientError.protocolViolation("command channel framing: \(error) near \(bytes.hexDump(limit: 32))")
            channel.fail(failure)
            throw failure
        }
    }

    // MARK: Event channel

    /// The event channel's own loop with its own decoder: forwards Event packets, answers Ping with Pong on this
    /// connection, and ends when the connection does.
    private func startEventLoop(_ channel: PTPIPChannel, decoder: PTPIPStreamDecoder, pending: [PTPIPStreamDecoder.Event]) {
        let continuation = eventContinuation
        let log = self.log
        eventTask = Task.detached(priority: .userInitiated) {
            var decoder = decoder
            var queue = pending
            while !Task.isCancelled {
                for item in queue {
                    guard case .packet(let p) = item else {
                        log(.warn, "event channel: unexpected data-phase bytes (\(item)); ignored")
                        continue
                    }
                    switch p.type {
                    case .event:
                        do {
                            let e = try PTPIP.decodeEvent(p)
                            continuation.yield(IncomingEvent(event: e, packet: p.encode(), channel: "event", receivedAt: Date()))
                        } catch {
                            log(.warn, "event channel: undecodable Event packet (\(error)): \(p.encode().hexDump())")
                        }
                    case .ping:
                        do {
                            try await channel.send(PTPIP.pong().encode())
                            log(.note, "event channel: Ping answered with Pong")
                        } catch {
                            log(.warn, "event channel: Pong failed: \(error)")
                        }
                    case .pong:
                        break
                    default:
                        log(.warn, "event channel: unexpected \(p.type) packet: \(p.encode().hexDump())")
                    }
                }
                queue = []
                do {
                    let bytes = try await channel.receive(idleTimeout: nil)
                    queue = try decoder.feed(bytes)
                } catch {
                    if !channel.isClosingIntentionally {
                        log(.warn, "event channel ended: \(error)")
                        channel.fail(.closed(channel: channel.name))
                    }
                    break
                }
            }
        }
    }

    private func forward(_ e: PTPIP.Event, packet: Data?, channel: String) {
        let raw = packet ?? PTPIP.event(e.code, transactionID: e.transactionID, parameters: e.parameters).encode()
        eventContinuation.yield(IncomingEvent(event: e, packet: raw, channel: channel, receivedAt: Date()))
    }

    // MARK: Transactions

    /// Sends `command` and runs its transaction to Cmd_Response. Data-phase bytes go to `dataSink` as they arrive
    /// (nil: discarded). Throws `.response` for any code other than OK (the channel stays usable), and poisons the
    /// channel on anything that leaves it mid-transaction.
    @discardableResult
    func perform(_ command: PTPContainer,
                 dataSink: ((Data) throws -> Void)? = nil,
                 onDataStarted: ((UInt64?) -> Void)? = nil,
                 idleTimeout: Double = PTPIPClient.idleTimeout) async throws -> PTPIP.CmdResponse {
        guard let channel = self.command else { throw ClientError.notConnected }
        if let failure = channel.failure { throw failure }
        let op = command.operationCode
        if let running = inFlight { throw ClientError.busy(running: running, requested: op) }
        inFlight = op
        defer { inFlight = nil }

        var transaction = PTPIPTransaction(transactionID: command.transactionID)
        do {
            try await channel.send(PTPIP.cmdRequest(command).encode())
            var queue: [PTPIPStreamDecoder.Event] = leftover
            leftover = []
            var index = 0
            while !transaction.isComplete {
                if index >= queue.count {
                    let bytes = try await channel.receive(idleTimeout: idleTimeout)
                    queue = try feedCommandDecoder(bytes, channel: channel)
                    index = 0
                    continue
                }
                let item = queue[index]
                index += 1
                var rawEvent: Data? = nil
                if case .packet(let p) = item, p.type == .event { rawEvent = p.encode() }
                let outputs: [PTPIPTransaction.Output]
                do {
                    outputs = try transaction.consume(item)
                } catch {
                    throw ClientError.protocolViolation("\(op) tx \(command.transactionID): \(error)")
                }
                for output in outputs {
                    switch output {
                    case .dataStarted(let total):
                        onDataStarted?(total)
                    case .data(let bytes):
                        try dataSink?(bytes)
                    case .event(let e):
                        forward(e, packet: rawEvent, channel: "command")
                    case .pingReceived:
                        try await channel.send(PTPIP.pong().encode())
                        log(.note, "command channel: Ping answered with Pong")
                    case .response:
                        break
                    }
                }
            }
            if index < queue.count {
                try await keep(Array(queue[index...]), channel: channel)
            }
        } catch let error as ClientError {
            channel.fail(error)
            throw error
        } catch {
            // Only the data sink throws anything else (a file write): the data phase is cut off mid-stream.
            let failure = ClientError.fileError("\(op): \(error)")
            channel.fail(failure)
            throw failure
        }

        guard let response = transaction.response else {
            throw ClientError.protocolViolation("\(op): transaction ended without a response")
        }
        if let mismatch = transaction.dataLengthMismatch {
            log(.warn, "\(op): Start_Data announced \(mismatch.expected) bytes but \(mismatch.received) arrived")
        }
        guard response.code.isOK else { throw ClientError.response(operation: op, code: response.code) }
        return response
    }

    /// Decoder output that followed the response in the same read: events go to the event stream now, pings are
    /// answered now, anything else waits for the next transaction (which will reject it if it is out of step).
    private func keep(_ rest: [PTPIPStreamDecoder.Event], channel: PTPIPChannel) async throws {
        for item in rest {
            if case .packet(let p) = item {
                switch p.type {
                case .event:
                    if let e = try? PTPIP.decodeEvent(p) {
                        forward(e, packet: p.encode(), channel: "command")
                        continue
                    }
                case .ping:
                    try await channel.send(PTPIP.pong().encode())
                    log(.note, "command channel: Ping answered with Pong")
                    continue
                case .pong:
                    continue
                default:
                    break
                }
            }
            leftover.append(item)
        }
        if !leftover.isEmpty {
            log(.note, "command channel: \(leftover.count) decoder event(s) after the response kept for the next transaction")
        }
    }

    /// Runs `command` and returns its whole data phase. Only for small datasets (DeviceInfo, ObjectInfo, thumbs,
    /// partial-object chunks): refuses anything over `limit`.
    private func collect(_ command: PTPContainer, limit: Int = 64 * 1024 * 1024, idleTimeout: Double = PTPIPClient.idleTimeout) async throws -> Data {
        var data = Data()
        let op = command.operationCode
        try await perform(command, dataSink: { bytes in
            if data.count + bytes.count > limit { throw ClientError.dataTooLarge(operation: op, limit: limit) }
            data.append(bytes)
        }, idleTimeout: idleTimeout)
        return data
    }

    private func decoded<T>(_ what: String, _ raw: Data, _ decode: (Data) throws -> T) throws -> T {
        do {
            return try decode(raw)
        } catch {
            throw ClientError.protocolViolation("\(what) did not decode (\(error)); \(raw.count) bytes: \(raw.hexDump())")
        }
    }

    // MARK: Operations

    /// OpenSession is sent with transaction ID 0; the counter then restarts at 1. SessionAlreadyOpen counts as
    /// success (returns true), which is what a reconnect with the same GUID may get.
    @discardableResult
    func openSession(id: UInt32 = 1) async throws -> Bool {
        do {
            try await perform(PTPCommand.openSession(sessionID: id, tx: 0))
            tx = PTPTransactionCounter()
            sessionOpen = true
            return false
        } catch ClientError.response(_, let code) where code == .sessionAlreadyOpen {
            tx = PTPTransactionCounter()
            sessionOpen = true
            return true
        }
    }

    func closeSession() async throws {
        try await perform(PTPCommand.closeSession(tx: tx.take()))
        sessionOpen = false
    }

    /// `idleTimeout` is shorter for the keep-alive and the back-from-background check, which must not hold the
    /// session for 30 s if the camera has gone.
    func getDeviceInfo(idleTimeout: Double = PTPIPClient.idleTimeout) async throws -> (info: PTPDeviceInfo, raw: Data) {
        let raw = try await collect(PTPCommand.getDeviceInfo(tx: tx.take()), idleTimeout: idleTimeout)
        let info = try decoded("DeviceInfo", raw) { try PTPDeviceInfo.decode($0) }
        deviceInfo = info
        return (info, raw)
    }

    func getStorageIDs() async throws -> (ids: [PTPStorageID], raw: Data) {
        let raw = try await collect(PTPCommand.getStorageIDs(tx: tx.take()))
        return (try decoded("StorageIDs", raw) { try PTPStorageID.decodeArray($0) }, raw)
    }

    func getStorageInfo(_ id: PTPStorageID) async throws -> (info: PTPStorageInfo, raw: Data) {
        let raw = try await collect(PTPCommand.getStorageInfo(id, tx: tx.take()))
        return (try decoded("StorageInfo", raw) { try PTPStorageInfo.decode($0) }, raw)
    }

    /// Every object in `storage` (parent 0 = all levels, not just the root).
    func getObjectHandles(storage: PTPStorageID) async throws -> (handles: [PTPObjectHandle], raw: Data) {
        let raw = try await collect(PTPCommand.getObjectHandles(storage: storage, tx: tx.take()), idleTimeout: 60)
        return (try decoded("ObjectHandles", raw) { try PTPObjectHandle.decodeArray($0) }, raw)
    }

    func getObjectInfo(_ handle: PTPObjectHandle) async throws -> (info: PTPObjectInfo, raw: Data) {
        let raw = try await collect(PTPCommand.getObjectInfo(handle, tx: tx.take()))
        return (try decoded("ObjectInfo \(handle)", raw) { try PTPObjectInfo.decode($0) }, raw)
    }

    func getThumb(_ handle: PTPObjectHandle) async throws -> Data {
        try await collect(PTPCommand.getThumb(handle, tx: tx.take()), limit: 8 * 1024 * 1024)
    }

    /// GetObject streamed to `url` (created or truncated) with an incremental SHA-256; nothing is buffered beyond
    /// one socket read. Build 14: `progress` gets the bytes received so far, from the data sink, at most every 0.25 s
    /// (throttled here, so the read loop makes no actor hop per chunk; the callback hops once itself); `abort`, once
    /// set, cuts the data phase off at the next chunk with `.aborted` (the client is then poisoned).
    func getObject(_ handle: PTPObjectHandle, to url: URL, abort: TransferAbort? = nil,
                   progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> FileDownload {
        let file: FileHandle
        do {
            try Data().write(to: url)
            file = try FileHandle(forWritingTo: url)
        } catch {
            throw ClientError.fileError("cannot create \(url.lastPathComponent): \(error)")
        }
        defer { try? file.close() }
        var hasher = SHA256()
        var bytes: UInt64 = 0
        var announced: UInt64? = nil
        let clock = ContinuousClock()
        let started = clock.now
        var lastProgress = started
        try await perform(PTPCommand.getObject(handle, tx: tx.take()), dataSink: { chunk in
            if let abort, abort.isAborted { throw ClientError.aborted("GetObject") }
            try file.write(contentsOf: chunk)
            hasher.update(data: chunk)
            bytes += UInt64(chunk.count)
            if let progress {
                let now = clock.now
                if now - lastProgress >= .milliseconds(250) {
                    lastProgress = now
                    progress(bytes)
                }
            }
        }, onDataStarted: { total in
            announced = total
        })
        let seconds = (clock.now - started).inSeconds
        return FileDownload(bytes: bytes, sha256: Self.hex(hasher.finalize()), seconds: seconds, announcedLength: announced)
    }

    /// One chunk of a byte-range read, in any of PTPPartialRead's layouts: GetPartialObject 0x101B with three or
    /// four parameters, GetPartialObject64 0x95C1, or Sony's SDIO_GetPartialLargeObject guesses on 0x9211 and
    /// 0x9219 (`unverified`). PTPPartialRead.command builds each; the data phase is the same GetObject-style IN data
    /// for all of them. `idleTimeout` is shorter for the partial read probe, where a layout the camera doesn't
    /// understand may get no answer at all (the timeout then poisons the client, as any link failure does).
    func getPartialObject(_ handle: PTPObjectHandle, chunk: PTPPartialRead.Chunk, variant: PTPPartialRead.Variant,
                          idleTimeout: Double = PTPIPClient.idleTimeout) async throws -> Data {
        // Build the command before taking the transaction ID so a planning error doesn't skip an ID.
        let cmd = try PTPPartialRead.command(handle, chunk: chunk, variant: variant, tx: tx.peek)
        _ = tx.take()
        return try await collect(cmd, limit: Int(chunk.length) + 1024 * 1024, idleTimeout: idleTimeout)
    }

    /// GetDevicePropValue: the raw value bytes (BatteryLevel 0x5001 is one UINT8).
    func getDevicePropValue(_ code: UInt16) async throws -> Data {
        try await collect(PTPCommand.getDevicePropValue(PTPDevicePropCode(rawValue: code), tx: tx.take()), limit: 1024 * 1024)
    }

    /// Experimental, PC Remote modes: Sony SDIO_Connect phase 1, 2 or 3 (PTPKit's builder: p2 = p3 = 0, and a short
    /// data phase that libgphoto2 discards). `unverified` on the α7C II.
    func sonySDIOConnect(phase: UInt32) async throws -> Data {
        try await collect(PTPCommand.sonySDIOConnect(phase: phase, tx: tx.take()), limit: 1024 * 1024)
    }

    /// Experimental: Sony SDIO_GetExtDeviceInfo with protocol `version` (0x12C = 3.00, 0xC8 = 2.00) and p2 = 1, via
    /// PTPKit's builder. The data phase lists Sony's vendor operation/property codes. `unverified`.
    func sonySDIOGetExtDeviceInfo(version: UInt32 = 0x12C) async throws -> Data {
        try await collect(PTPCommand.sonySDIOGetExtDeviceInfo(version: version, tx: tx.take()), limit: 1024 * 1024)
    }

    /// Experimental, PC Remote modes: Sony SDIO_OpenSession (0x9210) with [sessionID 1, functionMode] in place of
    /// OpenSession (0x1002); sending both answers SessionAlreadyOpen (0x201E). functionMode 1 is ContentsTransfer
    /// (the whole card), 0 RemoteControl. Numbered from the running counter (1 on a fresh connection), as Imagedge
    /// numbers it, and the counter keeps running afterwards. Marks the session open on OK; any other response
    /// throws `.response`. `unverified` on the α7C II (Imagedge field-tested it on a ZV-E10).
    func sonySDIOOpenSession(functionMode: UInt32) async throws {
        try await perform(PTPCommand.sonySDIOOpenSession(sessionID: 1, functionMode: functionMode, tx: tx.take()))
        sessionOpen = true
    }

    /// Experimental: Sony SDIO_SetContentsTransferMode (0x9212) with three parameters (Imagedge: [2,0,0] then
    /// [2,1,0] for the whole card, [1,0,0] for photos sent from the camera). Any data phase is discarded.
    /// `unverified` on the α7C II.
    func sonySetContentsTransferMode(_ p1: UInt32, _ p2: UInt32, _ p3: UInt32) async throws {
        try await perform(PTPCommand.sonySetContentsTransferMode(p1, p2, p3, tx: tx.take()))
    }

    // MARK: Helpers

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of bytes in memory, as lowercase hex.
    static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// SHA-256 of a file, read in 4 MiB pieces.
    static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// Day 6: does anything accept a TCP connection on the PTP/IP port? Returns the seconds to connect.
    static func probePort(host: String, port: UInt16 = PTPIP.defaultPort, timeout: Double = 10,
                          log: @escaping Logger) async throws -> Double {
        let channel = PTPIPChannel(name: "probe", host: host, port: port, log: log)
        defer { channel.close() }
        return try await channel.open(timeout: timeout)
    }

    /// Bridges client log lines onto the main-actor SpikeLog.
    static func logger(_ spikeLog: SpikeLog) -> Logger {
        return { level, text in
            Task { @MainActor in
                switch level {
                case .note: spikeLog.note(text)
                case .warn: spikeLog.warn(text)
                case .error: spikeLog.error(text)
                }
            }
        }
    }
}

// MARK: - One TCP connection

/// One NWConnection with timeouts, failure tracking and drop detection. Callbacks arrive on its own queue; the
/// mutable state is guarded by a lock. The first failure sticks: every later send or receive throws it.
final class PTPIPChannel: @unchecked Sendable {
    let name: String
    let endpoint: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let log: PTPIPClient.Logger
    private let lock = NSLock()
    private var failureValue: PTPIPClient.ClientError?
    private var readyWaiter: OnceContinuation<Void>?
    private var pendingReceive: OnceContinuation<Data>?
    private var closing = false
    private var viable = true
    private var reportedNotViable = false

    /// Largest single socket read; bounds memory per receive.
    static let maxRead = 1 << 20
    /// How long a connection may stay not viable (Wi-Fi gone) before it is failed.
    static let viabilityGrace: Double = 3

    init(name: String, host: String, port: UInt16, log: @escaping PTPIPClient.Logger) {
        self.name = name
        self.endpoint = "\(host):\(port)"
        self.log = log
        self.queue = DispatchQueue(label: "spike.ptpip.\(name)")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(PTPIPClient.connectTimeout)
        // Keepalives notice a camera that vanished while a channel is idle (the event channel usually is).
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        // The camera is only ever on Wi-Fi; without this a dead Wi-Fi path could be retried over cellular.
        params.requiredInterfaceType = .wifi
        let nwPort: NWEndpoint.Port = NWEndpoint.Port(String(port)) ?? 15740
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    var failure: PTPIPClient.ClientError? {
        lock.lock(); defer { lock.unlock() }
        return failureValue
    }

    var isClosingIntentionally: Bool {
        lock.lock(); defer { lock.unlock() }
        return closing
    }

    /// Starts the connection and waits for .ready. Returns the seconds it took.
    func open(timeout: Double) async throws -> Double {
        let clock = ContinuousClock()
        let started = clock.now
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceContinuation(c)
            lock.lock()
            readyWaiter = once
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            connection.viabilityUpdateHandler = { [weak self] isViable in self?.handleViability(isViable) }
            connection.start(queue: queue)
            let channelName = name
            let endpointText = endpoint
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                let error = PTPIPClient.ClientError.connectTimeout(channel: channelName, endpoint: endpointText, seconds: timeout)
                if once.resume(throwing: error) { self?.fail(error) }
            }
        }
        return (clock.now - started).inSeconds
    }

    func send(_ data: Data, timeout: Double = 30) async throws {
        if let f = failure { throw f }
        let channelName = name
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceContinuation(c)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    let failure = PTPIPClient.ClientError.network(channel: channelName, error: error)
                    once.resume(throwing: failure)
                    self?.fail(failure)
                } else {
                    once.resume(returning: ())
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                let failure = PTPIPClient.ClientError.idleTimeout(channel: channelName, seconds: timeout)
                if once.resume(throwing: failure) { self?.fail(failure) }
            }
        }
    }

    /// One socket read of up to `maxRead` bytes. `idleTimeout` nil waits indefinitely (the event channel); a
    /// timeout fails the channel, since the outstanding read can't be withdrawn.
    func receive(idleTimeout: Double?) async throws -> Data {
        if let f = failure { throw f }
        let channelName = name
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let once = OnceContinuation(c)
            lock.lock()
            pendingReceive = once
            let alreadyFailed = failureValue
            lock.unlock()
            if let alreadyFailed {
                once.resume(throwing: alreadyFailed)
                return
            }
            let timer: DispatchWorkItem? = idleTimeout.map { seconds in
                let item = DispatchWorkItem { [weak self] in
                    let failure = PTPIPClient.ClientError.idleTimeout(channel: channelName, seconds: seconds)
                    if once.resume(throwing: failure) { self?.fail(failure) }
                }
                queue.asyncAfter(deadline: .now() + seconds, execute: item)
                return item
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRead) { [weak self] data, _, isComplete, error in
                timer?.cancel()
                self?.clearPending(once)
                if let data, !data.isEmpty {
                    once.resume(returning: data)
                } else if let error {
                    let failure = PTPIPClient.ClientError.network(channel: channelName, error: error)
                    once.resume(throwing: failure)
                    self?.fail(failure)
                } else if isComplete {
                    let failure = PTPIPClient.ClientError.closedByCamera(channel: channelName)
                    once.resume(throwing: failure)
                    self?.fail(failure)
                } else {
                    once.resume(returning: Data())
                }
            }
        }
    }

    /// Marks the channel failed (first failure wins), wakes any waiter, and cancels the connection.
    func fail(_ error: PTPIPClient.ClientError) {
        lock.lock()
        if failureValue == nil { failureValue = error }
        let ready = readyWaiter
        readyWaiter = nil
        let pending = pendingReceive
        pendingReceive = nil
        lock.unlock()
        ready?.resume(throwing: error)
        pending?.resume(throwing: error)
        connection.cancel()
    }

    func close() {
        lock.lock()
        closing = true
        lock.unlock()
        fail(.closed(channel: name))
    }

    private func clearPending(_ once: OnceContinuation<Data>) {
        lock.lock()
        if pendingReceive === once { pendingReceive = nil }
        lock.unlock()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            lock.lock()
            let ready = readyWaiter
            readyWaiter = nil
            lock.unlock()
            ready?.resume(returning: ())
        case .waiting(let error):
            // Not fatal per Network.framework, but a Local Network denial or a closed port shows up here.
            log(.warn, "PTP/IP \(name) channel to \(endpoint) waiting: \(error)\(Self.hint(for: error, path: connection.currentPath))")
            if case .posix(let code) = error, code == .ECONNREFUSED {
                fail(.refused(channel: name, endpoint: endpoint))
            }
        case .failed(let error):
            if !isClosingIntentionally { log(.error, "PTP/IP \(name) channel failed: \(error)") }
            fail(.network(channel: name, error: error))
        case .cancelled:
            fail(.closed(channel: name))
        default:
            break
        }
    }

    private func handleViability(_ isViable: Bool) {
        lock.lock()
        viable = isViable
        let closingNow = closing
        let wasReported = reportedNotViable
        if !isViable { reportedNotViable = true }
        lock.unlock()
        guard !closingNow else { return }
        if isViable {
            if wasReported { log(.note, "PTP/IP \(name) channel viable again") }
            return
        }
        log(.warn, "PTP/IP \(name) channel not viable (Wi-Fi lost?); failing it in \(Int(Self.viabilityGrace)) s unless it recovers")
        let channelName = name
        queue.asyncAfter(deadline: .now() + Self.viabilityGrace) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillDead = !self.viable
            self.lock.unlock()
            if stillDead { self.fail(.linkLost(channel: channelName)) }
        }
    }

    /// A human hint for the common .waiting causes.
    static func hint(for error: NWError, path: NWPath?) -> String {
        if let path, path.status != .satisfied, path.unsatisfiedReason == .localNetworkDenied {
            return " — Local Network access is off for SB Spike: Settings → Privacy & Security → Local Network"
        }
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return " — nothing listening on that port (camera mode? PTP/IP responder not up yet?)"
        case .posix(let code) where code == .ENETDOWN || code == .ENETUNREACH || code == .EHOSTUNREACH:
            return " — no Wi-Fi route to the camera (on the right network? Local Network permission?)"
        case .dns(let code) where code == -65570:
            return " — policy denied: Local Network permission off, or still waiting for the prompt"
        default:
            return " — if the Local Network prompt is showing, allow it; this connection retries until it times out"
        }
    }
}

// MARK: - One-shot continuation

/// Resumes a checked continuation at most once, from whichever callback or timer gets there first. `resume`
/// returns true for the caller that won.
final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        guard let c = take() else { return false }
        c.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard let c = take() else { return false }
        c.resume(throwing: error)
        return true
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}

/// Build 14: a flag the main actor sets to cut a GetObject off at its next chunk (the copy's continued task expired:
/// the copy finishes nothing more). Read from the client's data sink, so it is a lock, not actor state.
final class TransferAbort: @unchecked Sendable {
    private let lock = NSLock()
    private var aborted = false

    var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    func abort() {
        lock.lock()
        aborted = true
        lock.unlock()
    }
}
