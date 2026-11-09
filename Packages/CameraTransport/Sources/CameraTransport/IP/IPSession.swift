import Foundation
import PTPKit

/// The connection layer of a PTP/IP link: one `PTPIPConnection` with the session's transaction numbering, a queue
/// that runs one transaction at a time (brief ones ahead of queued transfers, see `Kind`), the keep-alive, and the connection's events, states and loss
/// as one ordered stream of `Signal`s. It knows nothing of Sony's contents-transfer session, the card or files: `IPLink`
/// runs the whole-card session on top of it, and a remote-control session (remote shoot and live view, later; Shamil,
/// 9 Nov) can run its own plan on the same layer.
///
/// One session per connection attempt: once `Signal.lost` has been sent, or `close()` called, every call fails, and
/// the owner makes a new session to reconnect. The owner must always call `close()` on a session it drops (the
/// connection's rule: an unclosed one keeps both sockets open, and the camera then refuses the next initiator as busy).
actor IPSession {
    /// What the session reports, in order: events from either channel as they arrive, the Local Network wait while a
    /// channel opens, and the end of the connection when the owner didn't ask for it.
    enum Signal: Sendable, Equatable {
        /// A camera event, from the event channel or from the command channel mid-transaction.
        case event(PTPIP.Event)
        /// A channel is waiting for the person to answer the Local Network prompt.
        case waitingForLocalNetwork
        /// The connection ended under the session (link lost, the camera closing, a timeout, an abort), with the
        /// failure that ended it. Sent at most once, never after `close()`.
        case lost(PTPIPConnectionFailure)
    }

    /// What a transaction is, for the queue and for its caller's cancellation.
    enum Kind: Sendable, Equatable {
        /// A short transaction: the plan's steps, the listing, ObjectInfo, a thumbnail, the keep-alive. It goes ahead
        /// of queued transfers (still behind the one on the wire), so a thumbnail asked for during an import waits for
        /// one download at most, not for every download queued after it. Once on the wire it finishes even if its
        /// caller is cancelled (the caller waits for it): PTP/IP can't withdraw a sent command without cutting the
        /// connection off, which would end the session under everything else, such as an import running alongside.
        case brief
        /// GetObject: queued behind brief transactions, and a caller cancelled mid-transfer cuts the connection off
        /// (the connection's rule), because stopping a long download at once is worth a reopen.
        case transfer
    }

    /// The turn held across several transactions (`hold()`), such as a listing's GetObjectInfo per handle, so no
    /// download is let in between them.
    struct Hold: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    /// Why a turn in the queue wasn't given.
    private enum Turn {
        case granted
        case cancelled
        case ended
    }

    private struct Waiter {
        var id: UInt64
        var kind: Kind
        var continuation: CheckedContinuation<Turn, Never>
    }

    /// The signals, for one reader; finishes when the session ends.
    nonisolated let signals: AsyncStream<Signal>
    private let signalSink: AsyncStream<Signal>.Continuation
    private let connection: PTPIPConnection
    private let clock: any Clock<Duration>

    private var counter = PTPTransactionCounter()
    private var running = false
    private var queue: [Waiter] = []
    private var nextWaiter: UInt64 = 0
    /// The hold that has the turn, if any.
    private var holder: UInt64?
    /// `close()` has begun: nothing new is let through, and the connection's end isn't reported as a loss.
    private var closing = false
    /// The connection has ended, by `close()` or under the session.
    private var ended = false
    private var keepAlive: IPKeepAlive
    private var keepAliveStarted = false
    private var monitors: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - keepAlive: The idle time before a GetDeviceInfo keep-alive, once `startKeepAlive()` is called; nil for none.
    ///   - clock: The keep-alive timer's clock.
    ///   - connectionClock: The clock the connection's own time limits run on.
    init(endpoint: PTPIPEndpoint, guid: UUID, friendlyName: String, timing: PTPIPConnection.Timing,
         keepAlive: Duration?, channels: any ByteChannelFactory, clock: any Clock<Duration>,
         connectionClock: any Clock<Duration>) {
        connection = PTPIPConnection(endpoint: endpoint, guid: guid, friendlyName: friendlyName, timing: timing,
                                     channels: channels, clock: connectionClock)
        self.clock = clock
        self.keepAlive = IPKeepAlive(interval: keepAlive)
        (signals, signalSink) = AsyncStream.makeStream(of: Signal.self, bufferingPolicy: .unbounded)
    }

    /// Keep-alives answered and failed so far.
    var keepAliveCounts: (answered: Int, failed: Int) { (keepAlive.answered, keepAlive.failed) }

    /// Whether the connection is still up and `close()` hasn't been called.
    var isUsable: Bool { !ended && !closing }

    // MARK: - Connecting

    /// Does the PTP/IP handshake on both channels. The signals are watched from before the first channel opens, so a
    /// Local Network wait during the handshake is reported. A failed handshake leaves the session ended; close it.
    func connect() async throws(PTPIPConnectionFailure) -> PTPIP.InitCommandAck {
        let events = connection.events
        let states = connection.states
        let sink = signalSink
        monitors.append(Task {
            for await state in states where state == .waitingForLocalNetwork {
                sink.yield(.waitingForLocalNetwork)
            }
        })
        monitors.append(Task {
            for await event in events { sink.yield(.event(event.event)) }
            await self.connectionEnded()
        })
        return try await connection.connect()
    }

    // MARK: - Transactions

    /// Runs one transaction when its turn comes: one at a time, first come first served among transactions of a kind,
    /// brief ones ahead of queued transfers (one transaction at a time on PTP/IP). The command is built only once the
    /// turn has come, with the session's counter, so transaction IDs go out in order.
    ///
    /// - Parameters:
    ///   - kind: Where it queues, and what the caller's cancellation does once it is on the wire (`Kind`).
    ///   - hold: The caller's held turn (`hold()`): the transaction runs in it, without queueing.
    ///   - timeout: The longest wait for the next bytes; the connection's `timing.reply` when nil.
    ///   - sink: Gets each piece of the data phase as it arrives.
    ///   - command: Builds the container from the counter (`SonySessionStep.Operation.command(using:)`, which
    ///     restarts it for OpenSession, or `PTPCommand` with `counter.take()`).
    /// - Throws: the connection's failure; `.cancelledBeforeStart` for a caller cancelled before its command was
    ///   sent; and `.closed` (or what ended the connection) once the session has ended.
    func perform(_ kind: Kind = .brief, within hold: Hold? = nil, timeout: Duration? = nil,
                 sink: @escaping @Sendable (Data) -> Void = { _ in },
                 _ command: @Sendable (inout PTPTransactionCounter) -> PTPContainer)
        async throws(PTPIPConnectionFailure) -> PTPIPConnection.Reply {
        if let hold {
            guard holder == hold.id, !ended, !closing else { throw await connection.linkFailure ?? .closed }
            return try await send(kind, timeout: timeout, sink: sink, command)
        }
        switch await takeTurn(kind) {
        case .granted: break
        case .cancelled: throw .cancelledBeforeStart
        case .ended: throw await connection.linkFailure ?? .closed
        }
        defer { passTurn() }
        return try await send(kind, timeout: timeout, sink: sink, command)
    }

    /// Takes the turn and keeps it until `release(_:)`, for transactions passed this hold; queued as a brief
    /// transaction. The holder must always release it.
    func hold() async throws(PTPIPConnectionFailure) -> Hold {
        switch await takeTurn(.brief) {
        case .granted: break
        case .cancelled: throw .cancelledBeforeStart
        case .ended: throw await connection.linkFailure ?? .closed
        }
        nextWaiter += 1
        holder = nextWaiter
        return Hold(id: nextWaiter)
    }

    /// Gives up a held turn. Does nothing for a hold already released.
    func release(_ hold: Hold) {
        guard holder == hold.id else { return }
        holder = nil
        passTurn()
    }

    /// Sends the transaction, the turn being the caller's.
    private func send(_ kind: Kind, timeout: Duration?, sink: @escaping @Sendable (Data) -> Void,
                      _ command: @Sendable (inout PTPTransactionCounter) -> PTPContainer)
        async throws(PTPIPConnectionFailure) -> PTPIPConnection.Reply {
        // Checked before the command takes a transaction ID; the unstructured task below wouldn't see it.
        if Task.isCancelled { throw .cancelledBeforeStart }
        let container = command(&counter)
        switch kind {
        case .transfer:
            return try await connection.perform(container, timeout: timeout, into: sink)
        case .brief:
            // An unstructured task doesn't inherit the caller's cancellation, so the transaction runs to its end; the
            // caller still waits for it, so the next one never starts while this one is on the wire.
            let connection = connection
            let transaction = Task { () async -> Result<PTPIPConnection.Reply, PTPIPConnectionFailure> in
                do throws(PTPIPConnectionFailure) {
                    return .success(try await connection.perform(container, timeout: timeout, into: sink))
                } catch {
                    return .failure(error)
                }
            }
            return try await transaction.value.get()
        }
    }

    /// Waits for the queue. Nothing is let through once the session is ending.
    private func takeTurn(_ kind: Kind) async -> Turn {
        if ended || closing { return .ended }
        if Task.isCancelled { return .cancelled }
        if !running {
            running = true
            return .granted
        }
        nextWaiter += 1
        let id = nextWaiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Turn, Never>) in
                queue.append(Waiter(id: id, kind: kind, continuation: continuation))
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    /// A waiter's task was cancelled: take it out of the queue. Does nothing if its turn has already come.
    private func withdraw(_ id: UInt64) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(returning: .cancelled)
    }

    /// The turn goes to the next waiter (`nextTurn(among:)`); with none, the session is idle and the keep-alive timer
    /// starts again.
    private func passTurn() {
        if !ended, !closing, let index = Self.nextTurn(among: queue.map(\.kind)) {
            queue.remove(at: index).continuation.resume(returning: .granted)
            return
        }
        running = false
        armKeepAlive()
    }

    /// Which waiter gets the turn: the first brief one, else the first transfer; nil for none. A steady stream of
    /// brief transactions could hold transfers back, but Browse asks for a screenful of thumbnails at a time.
    static func nextTurn(among kinds: [Kind]) -> Int? {
        kinds.firstIndex(of: .brief) ?? kinds.indices.first
    }

    // MARK: - Keep-alive

    /// Starts the keep-alive (once the session is open: the opening sequence never idles for 10 s). Idempotent.
    func startKeepAlive() {
        guard !keepAliveStarted else { return }
        keepAliveStarted = true
        if !running { armKeepAlive() }
    }

    private func armKeepAlive() {
        guard keepAliveStarted, !ended, !closing else { return }
        keepAlive.arm(on: clock) { [weak self] generation in
            await self?.keepAliveDue(generation)
        }
    }

    /// The timer fired: send GetDeviceInfo, unless the arming is stale or a transaction is running or waiting (then
    /// the end of that one re-arms the timer).
    private func keepAliveDue(_ generation: Int) async {
        guard keepAlive.isCurrent(generation), !running, queue.isEmpty, !ended, !closing else { return }
        keepAlive.firing()
        do {
            let reply = try await perform { counter in SonyContentsTransferPlan.keepAliveCommand(tx: counter.take()) }
            keepAlive.recordAnswer(ok: reply.code == .ok)
        } catch {
            keepAlive.recordFailure()
        }
    }

    // MARK: - Ending

    /// Ends the session: `close` CloseSession first when `sendingCloseSession` and nothing is running or waiting (the
    /// spike sent it only when no transaction had been cut off; a transfer in flight is cut off instead), then
    /// closes the connection. Waiting callers fail; no `Signal.lost` is sent. Idempotent.
    func close(sendingCloseSession: Bool) async {
        guard !closing else { return }
        closing = true
        keepAlive.stop()
        if sendingCloseSession, !ended, !running, queue.isEmpty {
            running = true
            // The spike gave CloseSession 5 s.
            _ = try? await connection.perform(PTPCommand.closeSession(tx: counter.take()), timeout: .seconds(5))
            running = false
        }
        drainQueue()
        await connection.close()
        signalSink.finish()
    }

    /// The connection's event stream finished: it has been poisoned or closed. Reported as `.lost` unless `close()`
    /// did it.
    private func connectionEnded() async {
        guard !ended else { return }
        ended = true
        keepAlive.stop()
        drainQueue()
        let failure = await connection.linkFailure ?? .closed
        if !closing { signalSink.yield(.lost(failure)) }
        signalSink.finish()
    }

    private func drainQueue() {
        let waiting = queue
        queue = []
        for waiter in waiting { waiter.continuation.resume(returning: .ended) }
    }
}
