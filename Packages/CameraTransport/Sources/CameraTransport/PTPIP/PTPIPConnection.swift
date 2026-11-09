import Foundation
import PTPKit
import Synchronization

/// An event the camera sent, and which connection it came on. Most come on the event channel; the camera may also
/// send one on the command channel in the middle of a transaction, and `PTPIPConnection` forwards those too.
public struct PTPIPEvent: Sendable, Equatable {
    public enum Channel: Sendable, Equatable {
        case command
        case event
    }

    public var event: PTPIP.Event
    public var channel: Channel

    public init(_ event: PTPIP.Event, on channel: Channel) {
        self.event = event
        self.channel = channel
    }
}

/// Why a `PTPIPConnection` call failed. Every case except `.busy`, `.notConnected`, `.alreadyUsed`,
/// `.invalidCommand` and `.cancelledBeforeStart` poisons the connection: it is closed, and every later call throws the same failure (see
/// `poisons`).
public enum PTPIPConnectionFailure: Error, Sendable, Equatable {
    /// Which wait a timeout or a link failure interrupted.
    public enum Stage: Sendable, Equatable {
        /// Opening a TCP connection (either channel).
        case connect
        /// Waiting for Init_Command_Ack (the camera may be asking on its screen first).
        case initCommandAck
        /// Waiting for Init_Event_Ack.
        case initEventAck
        /// A transaction on the command channel.
        case transaction
        /// The event channel after the handshake (a Pong that couldn't be sent).
        case eventChannel
    }

    /// The camera refused: Init_Fail with its reason (1 rejected initiator, 2 busy, 3 unspecified; see
    /// `PTPIP.InitFailReason`), or nil when the TCP port itself refused the connection.
    case refused(initFailReason: UInt32?)
    /// A time limit passed. The channel is closed, since a pending read can't be withdrawn.
    case timedOut(Stage)
    /// The path went away (Wi-Fi off, out of range), with the POSIX error when the system gave one.
    case linkLost(posix: Int32?)
    /// A channel closed: `close()` was called, or the camera closed it.
    case closed
    /// Another transaction is in flight: one at a time (backlog section 1). Doesn't poison.
    case busy
    /// `perform` before `connect()` has finished. Doesn't poison.
    case notConnected
    /// `connect()` on a connection that has already connected or tried to: make a new one to reconnect. Doesn't
    /// poison.
    case alreadyUsed
    /// `perform` was given a container that isn't a command. Doesn't poison.
    case invalidCommand
    /// The camera's bytes broke PTP/IP: bad framing, a packet out of place, another transaction's ID.
    case protocolViolation(String)
    /// `abortTransfer()` cut the connection off.
    case aborted
    /// The data sink threw, leaving the data phase unread.
    case sinkFailed(String)
    /// The calling task was cancelled mid-call, leaving the channel out of step.
    case cancelled
    /// The calling task was already cancelled when `connect()` or `perform` began, so nothing was opened or sent.
    /// Doesn't poison.
    case cancelledBeforeStart

    init(_ failure: ByteChannelFailure, stage: Stage) {
        switch failure {
        case .refused: self = .refused(initFailReason: nil)
        case let .linkLost(posix): self = .linkLost(posix: posix)
        case .timedOut: self = .timedOut(stage)
        case .closed: self = .closed
        }
    }

    /// Whether this failure ended the connection. False only for misuse that left the channels untouched.
    public var poisons: Bool {
        switch self {
        case .busy, .notConnected, .alreadyUsed, .invalidCommand, .cancelledBeforeStart: false
        default: true
        }
    }

    /// The Init_Fail reason, when the camera sent one this module knows.
    public var initFailReason: PTPIP.InitFailReason? {
        if case let .refused(raw?) = self { PTPIP.InitFailReason(rawValue: raw) } else { nil }
    }
}

/// The two PTP/IP connections to a camera (CIPA DC-005) as one actor, independent of the network stack: the command
/// channel, which carries one transaction at a time, and the event channel. Written against `ByteChannelFactory`, so
/// it builds and is tested on Linux; Network.framework sits behind its own adapter.
///
/// Rules, from the spike's `PTPIPClient` (`Spike/Sources/Network/PTPIPClient.swift`) and backlog section 1:
/// - **Handshake:** open the command channel, send Init_Command_Request (the GUID kept per camera, and the friendly
///   name), wait for Init_Command_Ack, then open the event channel and send Init_Event_Request with the ack's
///   connection number, and wait for Init_Event_Ack. Init_Fail or a refused port is `.refused`.
/// - **One transaction at a time:** a second `perform` while one is running throws `.busy` (actor reentrancy would
///   otherwise interleave two transactions on one socket).
/// - **Poisoning:** the first link failure, timeout, framing error, sink error, cancellation mid-call,
///   `abortTransfer()` or `close()` closes both channels, finishes `events` and `states`, and is thrown by every later
///   call; the call that hit it returns only once both channels are closed. One connection per attempt: make a new one
///   to reconnect. A caller that was cancelled before the call began gets `.cancelledBeforeStart`, and nothing is
///   opened, sent or poisoned.
/// - **Always call `close()`:** once connected, the event channel's read loop holds the connection, so one that is
///   let go without `close()` (or a failure) is never freed and keeps both TCP connections to the camera open, and
///   the camera, which takes one initiator, refuses the next with Init_Fail(busy).
/// - **Pings:** a Ping on either channel is answered with a Pong on the same channel. The command channel is read only
///   during a transaction, so a Ping there is answered then.
/// - **Leftovers:** decoder output that follows a response in the same read is kept: events are forwarded and pings
///   answered at once, anything else is carried into the next transaction (which rejects it if it is out of step).
/// - **Time limits:** every wait has one, on the injected clock; the event channel alone waits indefinitely, as it is
///   idle between events. A timeout fails the whole connection, because a pending read can't be withdrawn (the
///   spike's rule).
/// - **Non-OK responses** are returned, not thrown, and the connection stays usable: whether StoreNotAvailable or
///   SessionAlreadyOpen is an error is the session's decision.
///
/// It speaks PTP/IP only: transaction IDs, sessions, the Sony whole-card sequence and the keep-alive belong to the
/// link above it.
public actor PTPIPConnection {
    /// Time limits and read size. The defaults are the spike's (`PTPIPClient.swift` lines 127-130).
    public struct Timing: Sendable, Equatable {
        /// Opening one TCP connection. The spike's `connectTimeout`.
        public var connect: Duration
        /// Waiting for each Init ack. The first ack can wait for a "connect to this device?" prompt on the camera
        /// (backlog: an ack can take 40 s or more), so it is long. The spike's `ackTimeout`.
        public var initAck: Duration
        /// The longest wait for the next bytes during a transaction, and for a send to complete (not the whole
        /// transaction: a 1 GB clip takes minutes). `perform(timeout:)` overrides it per call. The spike's
        /// `idleTimeout`.
        public var reply: Duration
        /// Opening a TCP connection while the system holds it for the Local Network prompt: once a channel reports
        /// `.waitingForLocalNetwork`, this replaces `connect` as the limit, counted from the start of the open, so
        /// the person has time to read the prompt. `unverified`: the spike measured only that the probe got through
        /// 1.53 s after it started with the prompt allowed in that time; how long people take is not measured.
        public var localNetworkPrompt: Duration
        /// The largest single read from a channel; bounds memory per receive. Also the Data packet size for an
        /// initiator data phase. The spike's `maxRead`.
        public var maxRead: Int

        public init(connect: Duration = .seconds(10), initAck: Duration = .seconds(60), reply: Duration = .seconds(30),
                    localNetworkPrompt: Duration = .seconds(60), maxRead: Int = 1 << 20) {
            self.connect = connect
            self.initAck = initAck
            self.reply = reply
            self.localNetworkPrompt = localNetworkPrompt
            self.maxRead = maxRead
        }
    }

    /// The end of one transaction: the Cmd_Response, and how the data phase went. The data itself went to the sink.
    public struct Reply: Sendable, Equatable {
        public var response: PTPIP.CmdResponse
        /// What Start_Data announced: nil when there was no data phase, or the camera said "unknown".
        public var announcedDataLength: UInt64?
        /// Data-phase bytes handed to the sink.
        public var receivedDataLength: UInt64
        /// Whether a data phase began (Start_Data arrived).
        public var hadDataPhase: Bool
        /// Cmd_Response came while the data phase was still open (no End_Data): with an unknown length, the only
        /// sign of a cut-off transfer.
        public var dataPhaseUnterminated: Bool

        public var code: PTPResponseCode { response.code }
        public var parameters: [UInt32] { response.parameters }

        /// False when the data phase is known to be short or unterminated; treat such a transfer as failed.
        public var dataIsComplete: Bool {
            !dataPhaseUnterminated && (announcedDataLength.map { $0 == receivedDataLength } ?? true)
        }
    }

    private enum Phase {
        case idle, connecting, connected, finished
    }

    /// One channel's framing state during the handshake and in the event loop.
    private struct Reader {
        var decoder = PTPIPStreamDecoder()
        var pending: [PTPIPStreamDecoder.Event] = []
    }

    public nonisolated let endpoint: PTPIPEndpoint
    public nonisolated let guid: UUID
    public nonisolated let friendlyName: String
    public nonisolated let timing: Timing
    private let channels: any ByteChannelFactory
    private let clock: any Clock<Duration>
    private let eventFanOut = EventFanOut<PTPIPEvent>()
    private let stateFanOut = EventFanOut<ByteChannelState>()

    private var phase = Phase.idle
    private var failure: PTPIPConnectionFailure?
    private var commandChannel: (any ByteChannel)?
    private var eventChannel: (any ByteChannel)?
    private var commandDecoder = PTPIPStreamDecoder()
    /// Command-channel decoder output not yet consumed (after a response, or after the handshake ack). The next
    /// transaction sees it first.
    private var leftover: [PTPIPStreamDecoder.Event] = []
    private var inFlight = false
    /// Ends the wait of the connect or transaction step in progress (set while one waits on a channel or a timer).
    private var wake: (@Sendable (PTPIPConnectionFailure) -> Void)?
    private var eventLoop: Task<Void, Never>?
    /// Closes the channels a failure took; `fail` waits for it, so no failing call returns with a channel still open.
    private var closing: Task<Void, Never>?

    /// What Init_Command_Ack said, once `connect()` has succeeded.
    public private(set) var initCommandAck: PTPIP.InitCommandAck?

    /// - Parameters:
    ///   - guid: The initiator GUID, stable per camera so the camera can recognise the phone (backlog section 1: a
    ///     new GUID connected without a prompt on the camera, and so did the same GUID after a power cycle).
    ///   - friendlyName: The initiator name the camera may show.
    ///   - channels: Opens the two TCP connections.
    ///   - clock: Every time limit runs on it, so tests drive them with a manual clock.
    public init(endpoint: PTPIPEndpoint, guid: UUID, friendlyName: String, timing: Timing = Timing(),
                channels: any ByteChannelFactory, clock: any Clock<Duration> = ContinuousClock()) {
        self.endpoint = endpoint
        self.guid = guid
        self.friendlyName = friendlyName
        self.timing = timing
        self.channels = channels
        self.clock = clock
    }

    /// Events from both channels, in arrival order per channel. Each read gives a new stream that gets only what
    /// arrives after it, so subscribe before `connect()`. Finishes when the connection is poisoned or closed.
    public nonisolated var events: AsyncStream<PTPIPEvent> { eventFanOut.subscribe() }

    /// The states the channels pass through while they open (`.waitingForLocalNetwork` in particular), passed
    /// through from the factory. Each read gives a new stream with no replay. Finishes with the connection.
    public nonisolated var states: AsyncStream<ByteChannelState> { stateFanOut.subscribe() }

    /// The failure that poisoned the connection, if any.
    public var linkFailure: PTPIPConnectionFailure? { failure }

    /// Whether the handshake is done and nothing has failed.
    public var isConnected: Bool { phase == .connected && failure == nil }

    // MARK: - Handshake

    /// Opens both channels and does the handshake. Returns the camera's Init_Command_Ack.
    ///
    /// - Throws: `.refused` for Init_Fail (its reason) or a refused port, `.timedOut(.connect)`,
    ///   `.timedOut(.initCommandAck)` or `.timedOut(.initEventAck)`, `.linkLost`, `.closed`, `.protocolViolation`,
    ///   `.cancelled`; `.alreadyUsed` on a second call; `.cancelledBeforeStart`, opening nothing and leaving the
    ///   connection unused, when the calling task was already cancelled. Any other failure closes whatever was opened.
    public func connect() async throws(PTPIPConnectionFailure) -> PTPIP.InitCommandAck {
        guard phase == .idle else { throw failure ?? .alreadyUsed }
        if Task.isCancelled { throw .cancelledBeforeStart }
        phase = .connecting
        do {
            let ack = try await handshake()
            initCommandAck = ack
            phase = .connected
            return ack
        } catch {
            throw await fail(error)
        }
    }

    private func handshake() async throws(PTPIPConnectionFailure) -> PTPIP.InitCommandAck {
        let command = try await openChannel()
        commandChannel = command
        try await send(PTPIP.initCommandRequest(guid: guid, friendlyName: friendlyName).encode(), on: command,
                       stage: .initCommandAck)
        var commandReader = Reader()
        let ackPacket = try await nextControlPacket(on: command, reader: &commandReader, stage: .initCommandAck)
        let ack: PTPIP.InitCommandAck
        switch ackPacket.type {
        case .initCommandAck:
            do {
                ack = try PTPIP.decodeInitCommandAck(ackPacket)
            } catch {
                throw .protocolViolation("Init_Command_Ack undecodable: \(error)")
            }
        case .initFail:
            throw .refused(initFailReason: PTPIP.decodeInitFail(ackPacket))
        default:
            throw .protocolViolation("\(ackPacket.type) instead of Init_Command_Ack")
        }
        commandDecoder = commandReader.decoder
        leftover = commandReader.pending

        let event = try await openChannel()
        eventChannel = event
        try await send(PTPIP.initEventRequest(connectionNumber: ack.connectionNumber).encode(), on: event,
                       stage: .initEventAck)
        var eventReader = Reader()
        let eventAck = try await nextControlPacket(on: event, reader: &eventReader, stage: .initEventAck)
        switch eventAck.type {
        case .initEventAck:
            break
        case .initFail:
            throw .refused(initFailReason: PTPIP.decodeInitFail(eventAck))
        default:
            throw .protocolViolation("\(eventAck.type) instead of Init_Event_Ack")
        }
        let reader = eventReader
        eventLoop = Task { await self.runEventChannel(event, reader: reader) }
        return ack
    }

    /// Opens one TCP connection, passing its states through. The limit is `timing.connect`, or
    /// `timing.localNetworkPrompt` once the channel has reported `.waitingForLocalNetwork`.
    private func openChannel() async throws(PTPIPConnectionFailure) -> any ByteChannel {
        let sawWaiting = Flag()
        let fanOut = stateFanOut
        let factory = channels
        let endpoint = endpoint
        let timing = timing
        let clock = clock
        let state: @Sendable (ByteChannelState) -> Void = { state in
            if state == .waitingForLocalNetwork { sawWaiting.set() }
            fanOut.send(state)
        }
        return try await run(.connect, timer: {
            try await clock.sleep(for: timing.connect)
            if sawWaiting.isSet, timing.localNetworkPrompt > timing.connect {
                try await clock.sleep(for: timing.localNetworkPrompt - timing.connect)
            }
        }, onLost: { channel in
            await channel.close()
        }) { () async throws(ByteChannelFailure) -> any ByteChannel in
            try await factory.open(endpoint, timeout: timing.connect, state: state)
        }
    }

    /// The next whole control packet on a channel during the handshake; answers pings on the way.
    private func nextControlPacket(on channel: any ByteChannel, reader: inout Reader,
                                   stage: PTPIPConnectionFailure.Stage) async throws(PTPIPConnectionFailure) -> PTPIP.Packet {
        while true {
            if !reader.pending.isEmpty {
                guard case let .packet(packet) = reader.pending.removeFirst() else {
                    throw .protocolViolation("data-phase bytes during the handshake")
                }
                switch packet.type {
                case .ping:
                    try await send(PTPIP.pong().encode(), on: channel, stage: stage)
                case .pong:
                    break
                default:
                    return packet
                }
                continue
            }
            let bytes = try await receive(on: channel, stage: stage, timeout: timing.initAck)
            do {
                reader.pending += try reader.decoder.feed(bytes)
            } catch {
                throw .protocolViolation("framing during the handshake: \(error)")
            }
        }
    }

    // MARK: - Transactions

    /// Sends `command` and runs its transaction to Cmd_Response. Data-phase bytes go to `sink` as they arrive and are
    /// not kept, so a 1 GB clip never sits in memory. Events that arrive meanwhile go to `events`; Pings are answered.
    ///
    /// - Parameters:
    ///   - command: A command container with its transaction ID (the link keeps the counter).
    ///   - dataOut: An initiator data phase, sent as Start_Data and Data/End_Data after the Cmd_Request.
    ///   - timeout: The longest wait for the next bytes in this transaction; `timing.reply` when nil (the spike used
    ///     5 s for CloseSession, 60 s for GetObjectHandles).
    /// - Returns: The response, whatever its code: a non-OK response leaves the connection usable.
    /// - Throws: `.busy` while another transaction runs, `.notConnected` before `connect()`, `.invalidCommand`,
    ///   `.cancelledBeforeStart` (nothing sent) when the calling task was already cancelled; and,
    ///   poisoning the connection, `.timedOut(.transaction)`, `.linkLost`, `.closed`, `.protocolViolation`,
    ///   `.sinkFailed`, `.aborted`, `.cancelled`, or the failure that poisoned it earlier.
    public func perform(_ command: PTPContainer, dataOut: Data? = nil, timeout: Duration? = nil,
                        into sink: @Sendable (Data) throws -> Void = { _ in }) async throws(PTPIPConnectionFailure) -> Reply {
        if let failure { throw failure }
        guard phase == .connected, let channel = commandChannel else { throw .notConnected }
        guard command.type == .command else { throw .invalidCommand }
        guard !inFlight else { throw .busy }
        if Task.isCancelled { throw .cancelledBeforeStart }
        inFlight = true
        defer { inFlight = false }
        do {
            return try await transact(command, dataOut: dataOut, timeout: timeout ?? timing.reply, on: channel, sink: sink)
        } catch {
            throw await fail(error)
        }
    }

    private func transact(_ command: PTPContainer, dataOut: Data?, timeout: Duration, on channel: any ByteChannel,
                          sink: @Sendable (Data) throws -> Void) async throws(PTPIPConnectionFailure) -> Reply {
        let tx = command.transactionID
        var request = PTPIP.cmdRequest(command, dataPhase: dataOut == nil ? .none : .initiatorToResponder).encode()
        if let dataOut {
            for packet in PTPIP.dataPhase(transactionID: tx, payload: dataOut, packetSize: readSize) {
                request.append(packet.encode())
            }
        }
        try await send(request, on: channel, stage: .transaction, timeout: timeout)

        var transaction = PTPIPTransaction(transactionID: tx)
        var queue = leftover
        leftover = []
        var index = 0
        while !transaction.isComplete {
            if index == queue.count {
                let bytes = try await receive(on: channel, stage: .transaction, timeout: timeout)
                queue = try feedCommandDecoder(bytes)
                index = 0
                continue
            }
            let item = queue[index]
            index += 1
            let outputs: [PTPIPTransaction.Output]
            do {
                outputs = try transaction.consume(item)
            } catch {
                throw .protocolViolation("\(command.operationCode) tx \(tx): \(error)")
            }
            for output in outputs {
                switch output {
                case let .data(bytes):
                    do {
                        try sink(bytes)
                    } catch {
                        throw .sinkFailed("\(command.operationCode): \(error)")
                    }
                case let .event(event):
                    eventFanOut.send(PTPIPEvent(event, on: .command))
                case .pingReceived:
                    try await send(PTPIP.pong().encode(), on: channel, stage: .transaction, timeout: timeout)
                case .dataStarted, .response:
                    break
                }
            }
        }
        try await keep(queue[index...], on: channel, timeout: timeout)

        guard let response = transaction.response else {
            throw .protocolViolation("\(command.operationCode) tx \(tx) ended without a response")
        }
        return Reply(response: response, announcedDataLength: transaction.expectedDataLength,
                     receivedDataLength: transaction.receivedDataLength, hadDataPhase: transaction.dataStarted,
                     dataPhaseUnterminated: transaction.dataPhaseUnterminated)
    }

    /// Decoder output that followed the response in the same read: events are forwarded and pings answered now;
    /// anything else waits for the next transaction.
    private func keep(_ rest: ArraySlice<PTPIPStreamDecoder.Event>, on channel: any ByteChannel,
                      timeout: Duration) async throws(PTPIPConnectionFailure) {
        for item in rest {
            if case let .packet(packet) = item {
                switch packet.type {
                case .event:
                    if let event = try? PTPIP.decodeEvent(packet) {
                        eventFanOut.send(PTPIPEvent(event, on: .command))
                        continue
                    }
                case .ping:
                    try await send(PTPIP.pong().encode(), on: channel, stage: .transaction, timeout: timeout)
                    continue
                case .pong:
                    continue
                default:
                    break
                }
            }
            leftover.append(item)
        }
    }

    private func feedCommandDecoder(_ bytes: Data) throws(PTPIPConnectionFailure) -> [PTPIPStreamDecoder.Event] {
        do {
            return try commandDecoder.feed(bytes)
        } catch {
            throw .protocolViolation("command channel framing: \(error)")
        }
    }

    // MARK: - Ending

    /// Cuts the connection off: a transaction in flight stops at once with `.aborted` (its data phase is left
    /// unread), both channels close, and every later call throws `.aborted`. For when the import must stop now, such
    /// as a continued task expiring (the spike's `TransferAbort`). Does nothing once the connection has failed or
    /// closed. The channels close in the background; the interrupted transaction, and `close()`, return only once
    /// they have.
    public func abortTransfer() {
        guard failure == nil else { return }
        _ = markFailed(.aborted)
    }

    /// Closes both channels and finishes `events` and `states`; a transaction in flight ends with `.closed`, and so
    /// does every later call. Sends nothing first: CloseSession is the session's business. Idempotent.
    public func close() async {
        await fail(.closed)
    }

    // MARK: - Private

    /// Records the first failure, ends any wait, closes both channels and finishes the streams, returning once both
    /// channels are closed (whichever failure, `abortTransfer()` included, began closing them). Returns the failure
    /// that poisoned the connection, which is `failure` unless an earlier one got there first.
    @discardableResult
    private func fail(_ failure: PTPIPConnectionFailure) async -> PTPIPConnectionFailure {
        guard failure.poisons else { return failure }
        let first = markFailed(failure)
        await closing?.value
        return first
    }

    /// Records the first failure, ends any wait and finishes the streams, and starts closing the channels in
    /// `closing` without waiting for it (so `abortTransfer()` can stay synchronous).
    private func markFailed(_ newFailure: PTPIPConnectionFailure) -> PTPIPConnectionFailure {
        let first = failure ?? newFailure
        failure = first
        phase = .finished
        wake?(first)
        wake = nil
        eventLoop?.cancel()
        eventLoop = nil
        leftover = []
        eventFanOut.finish()
        stateFanOut.finish()
        let open = takeChannels()
        if !open.isEmpty {
            let previous = closing
            closing = Task {
                await previous?.value
                for channel in open { await channel.close() }
            }
        }
        return first
    }

    private func takeChannels() -> [any ByteChannel] {
        defer {
            commandChannel = nil
            eventChannel = nil
        }
        return [commandChannel, eventChannel].compactMap { $0 }
    }

    private var readSize: Int { max(1, timing.maxRead) }

    private func send(_ data: Data, on channel: any ByteChannel, stage: PTPIPConnectionFailure.Stage,
                      timeout: Duration? = nil) async throws(PTPIPConnectionFailure) {
        let limit = timeout ?? timing.reply
        let clock = clock
        try await run(stage, timer: { try await clock.sleep(for: limit) }) { () async throws(ByteChannelFailure) in
            try await channel.send(data)
        }
    }

    private func receive(on channel: any ByteChannel, stage: PTPIPConnectionFailure.Stage,
                         timeout: Duration) async throws(PTPIPConnectionFailure) -> Data {
        let clock = clock
        let size = readSize
        return try await run(stage, timer: { try await clock.sleep(for: timeout) }) { () async throws(ByteChannelFailure) -> Data in
            let bytes = try await channel.receive(atMost: size)
            // The contract says never empty; treat a broken adapter's empty read as the end of the stream rather
            // than spin on it.
            guard !bytes.isEmpty else { throw .closed }
            return bytes
        }
    }

    /// Runs one channel operation against a timer, a cancellation of the calling task and `wake` (set by
    /// `abortTransfer()`, `close()` and the event loop's failure), whichever finishes first. A failure is returned,
    /// not recorded: the public entry points poison the connection.
    private func run<T: Sendable>(_ stage: PTPIPConnectionFailure.Stage,
                                  timer: @escaping @Sendable () async throws -> Void,
                                  onLost: (@Sendable (T) async -> Void)? = nil,
                                  _ operation: @escaping @Sendable () async throws(ByteChannelFailure) -> T)
        async throws(PTPIPConnectionFailure) -> T {
        if let failure { throw failure }
        let once = OnceResume<Result<T, PTPIPConnectionFailure>>()
        wake = { once.resume(.failure($0)) }
        defer { wake = nil }
        let result = await Self.race(stage, once: once, timer: timer, onLost: onLost, operation)
        if let failure {
            // The operation won just before `close()` or `abortTransfer()` ran: hand back what it produced (a channel
            // that has just opened), since no one else holds it to close it.
            if case let .success(value) = result { await onLost?(value) }
            throw failure
        }
        return try result.get()
    }

    /// The race itself, off the actor: the operation and the timer each run in their own task, and the first to
    /// finish (or the caller's cancellation) wins. The losing operation is left to finish on its own; the caller
    /// closes the channel, which ends it. A late result of a lost operation goes to `onLost`.
    private static func race<T: Sendable>(_ stage: PTPIPConnectionFailure.Stage,
                                          once: OnceResume<Result<T, PTPIPConnectionFailure>>,
                                          timer: @escaping @Sendable () async throws -> Void,
                                          onLost: (@Sendable (T) async -> Void)?,
                                          _ operation: @escaping @Sendable () async throws(ByteChannelFailure) -> T)
        async -> Result<T, PTPIPConnectionFailure> {
        // An unstructured task doesn't inherit cancellation: don't start an operation for a caller already cancelled.
        if Task.isCancelled { return .failure(.cancelled) }
        let work = Task {
            do throws(ByteChannelFailure) {
                let value = try await operation()
                if !once.resume(.success(value)) { await onLost?(value) }
            } catch {
                once.resume(.failure(PTPIPConnectionFailure(error, stage: stage)))
            }
        }
        let deadline = Task {
            do {
                try await timer()
            } catch {
                return  // cancelled: the operation won
            }
            once.resume(.failure(.timedOut(stage)))
        }
        let result = await withTaskCancellationHandler {
            await once.wait()
        } onCancel: {
            once.resume(.failure(.cancelled))
        }
        deadline.cancel()
        work.cancel()
        return result
    }

    /// The event channel after the handshake: forwards events, answers Pings, and poisons the connection when the
    /// channel fails. It waits for bytes with no time limit; `close()` and `fail` end the wait by closing the channel.
    private func runEventChannel(_ channel: any ByteChannel, reader: Reader) async {
        var reader = reader
        let size = readSize
        let clock = clock
        let limit = timing.reply
        while failure == nil {
            while !reader.pending.isEmpty {
                // The event channel carries no data phase; stray data-phase bytes are ignored, as the spike did.
                guard case let .packet(packet) = reader.pending.removeFirst() else { continue }
                switch packet.type {
                case .event:
                    if let event = try? PTPIP.decodeEvent(packet) {
                        eventFanOut.send(PTPIPEvent(event, on: .event))
                    }
                case .ping:
                    let once = OnceResume<Result<Void, PTPIPConnectionFailure>>()
                    let pong = PTPIP.pong().encode()
                    let sent = await Self.race(.eventChannel, once: once, timer: { try await clock.sleep(for: limit) },
                                               onLost: nil) { () async throws(ByteChannelFailure) in
                        try await channel.send(pong)
                    }
                    if case let .failure(f) = sent {
                        await fail(f)
                        return
                    }
                default:
                    break  // Pong, or anything out of place: ignored, as the spike did.
                }
            }
            let bytes: Data
            do {
                bytes = try await channel.receive(atMost: size)
            } catch {
                await fail(PTPIPConnectionFailure(error, stage: .eventChannel))
                return
            }
            if bytes.isEmpty {
                await fail(.closed)
                return
            }
            do {
                reader.pending = try reader.decoder.feed(bytes)
            } catch {
                await fail(.protocolViolation("event channel framing: \(error)"))
                return
            }
        }
    }
}

/// A flag set from any thread.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
