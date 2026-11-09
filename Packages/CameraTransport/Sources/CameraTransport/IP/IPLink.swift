import Foundation
import PTPKit
import Synchronization

/// What an `IPLink` has seen, for the log and the bench checks: how its sessions opened, the listing poll, the
/// keep-alive and the events it ignored. Holds no serial, address or hardware ID.
public struct IPLinkDiagnostics: Sendable, Equatable {
    /// Sessions that finished opening.
    public var sessionsOpened = 0
    /// Sessions that ended under the link (`.sessionLost`), and what ended the latest one.
    public var sessionsLost = 0
    public var lastLoss: String?
    /// Every answered step of the latest open, fallbacks included (`SonySessionRunner.Record`).
    public var steps: [SonySessionRunner.Record] = []
    /// Steps of the latest open left out because DeviceInfo doesn't list their operation (decision 6).
    public var skippedSteps: [SonySessionStep.Operation] = []
    /// Listing polls of the latest open (each GetStorageIDs plus GetObjectHandles per storage); 0 for a plain session,
    /// which doesn't poll.
    public var pollAttempts = 0
    /// The latest poll reached its limit (120 s fresh, 30 s reopening) without the card listing.
    public var pollTimedOut = false
    /// From the latest poll's first attempt to the card listing.
    public var timeToListing: Duration?
    /// Keep-alives answered, and failed, over the link's life.
    public var keepAlivesAnswered = 0
    public var keepAlivesFailed = 0
    /// The codes of the latest events ignored (0xC201, 0xC225 and the like), newest last, at most `ignoredEventLimit`.
    public var ignoredEvents: [PTPEventCode] = []

    public static let ignoredEventLimit = 64

    public init() {}

    mutating func ignored(_ code: PTPEventCode) {
        ignoredEvents.append(code)
        if ignoredEvents.count > Self.ignoredEventLimit { ignoredEvents.removeFirst() }
    }
}

/// The `CameraLink` over Wi-Fi: Sony's whole-card contents-transfer session over PTP/IP (backlog Iteration 3, sections
/// 1–4; wireless plan W6). It answers list, info, thumbnail, bytes and events like `USBLink`, through
/// `SonyContentsTransferPlan.wholeCard()` run by `SonySessionRunner`.
///
/// **Layers.** `IPSession` is the connection layer (the PTP/IP connection, transaction IDs, one transaction at a time,
/// the keep-alive, events); this actor is the contents session on top of it. Remote shoot and live view (later) are
/// to run their own session on the same layer. Both are written against `ByteChannelFactory`, so the whole link builds
/// and is tested on Linux against the simulated camera; only the Network.framework channel is Apple-only (decision 3).
///
/// **Open.** The PTP/IP handshake, then the plan: SDIO_OpenSession 0x9210 `[1, 1]` (falling back to OpenSession),
/// GetDeviceInfo (which must list 0x9210 and 0x9212), the init sequence, SDIO_SetContentsTransferMode `[2, 0, 0]` with a
/// 200 ms pause and `[2, 1, 0]` with 1.5 s, then the listing poll (attempts after 2, 3, 5 s, then every 5 s, for up
/// to 120 s, or 30 s for a reopen), which ends as soon as a storage lists a handle, or StoreAdded has come and the
/// card lists empty. Only operations DeviceInfo lists are sent once it is known, so GetDevicePropValue, which this
/// session never answers, is never sent (`SonyCapabilities.mayRead` is false for every property here). A DeviceInfo
/// whose serial differs from `knownSerial` (or from the first session's) fails the open as `identityChanged`. A plain
/// session (the fallback) lists nothing on this camera (measured), so it skips the poll and `list()` returns no files.
/// A failed handshake is tried once more on a new connection after 1 s (the spike's precaution), and a reopen waits
/// 500 ms after the old connection closed.
///
/// **Calls.** One transaction at a time (`IPSession`): a thumbnail, a listing or a Copy as JPEG asked for during a
/// download waits for that download (W6's interim answer to the single-transaction open point, B:102; the decision is
/// Shamil's), then goes ahead of downloads queued after it; a listing holds the turn from GetStorageIDs to its last
/// GetObjectInfo. Cancelling a call once its command is on the wire lets it finish, so a thumbnail scrolled away
/// doesn't end the session; cancelling a download cuts the connection off (`.sessionLost`, then a reopen).
/// `list()` asks GetObjectHandles and one GetObjectInfo per handle, newest first; `thumbnail` is GetThumb; `bytes` is
/// GetObject streamed to a file. A file name that isn't a plain name (a `/`, `..`) is never listed or written.
/// Every command has a time limit between reads (30 s, 60 s for GetObjectHandles); a download has none as a whole.
///
/// **Resume.** Not yet: this link reads whole files with GetObject, so it reports `resumesPartialFiles` false, ignores
/// `resuming` and never calls `checkpoint`. The 0x9211 resume, and reopening without relisting known handles, are W8.
///
/// **Events.** StoreRemoved becomes `.storeRemoved`, StoreAdded that brings the card back `.storeAdded`
/// (`IPEventMapper`); between them, and whenever a check of the storages finds the card gone, InvalidObjectHandle is
/// `cardUnavailable`, never `itemNotFound`. 0xC201, 0xC225 and other events are noted in `diagnostics` and ignored. A
/// channel waiting for the Local Network prompt is `.waitingForLocalNetwork`. A connection that ends under the link (the
/// camera's idle drop, iOS closing the sockets in the background, Wi-Fi gone) is `.sessionLost`: pending calls end as
/// `disconnected`, `events` stays open, and `open()` reopens a new session (as a reopen, with the serial held).
public actor IPLink: CameraLink {
    /// What this link can do: `.wifi` without resume until W8 brings 0x9211 (a link reports less than its carrier's
    /// baseline, never more than it does).
    public static let capabilitiesWithoutResume: CameraLinkCapabilities = {
        var capabilities = CameraLinkCapabilities.wifi
        capabilities.resumesPartialFiles = false
        return capabilities
    }()

    /// The largest data phase kept in memory for each kind of answer, so a broken reply can't fill the phone: DeviceInfo
    /// and ExtDeviceInfo (970 B on the α7C II), ObjectInfo, the handle list (4 B per file), and a thumbnail (the
    /// spike's 8 MiB limit; the camera's are 160 × 120 JPEGs of about 7 KB).
    static let datasetLimit = 1 << 20
    static let handlesLimit = 4 << 20
    static let thumbnailLimit = 8 << 20

    public nonisolated let descriptor: CameraDescriptor
    public nonisolated let configuration: Configuration
    private let channels: any ByteChannelFactory
    private let clock: any Clock<Duration>
    private let connectionClock: any Clock<Duration>
    private let fanOut = EventFanOut<CameraLinkEvent>()

    /// The camera's DeviceInfo from the latest open: what it lists, and the serial (the key material; never logged).
    public private(set) var deviceInfo: PTPDeviceInfo?
    /// Which session the latest open got: the whole card, or the plain fallback that lists nothing.
    public private(set) var sessionKind: SonySessionKind?

    /// The session being opened or open. Ready only once the open has finished.
    private var session: IPSession?
    private var sessionReady = false
    /// Counts sessions; signals from an older one are ignored.
    private var epoch = 0
    private var consumers: [Int: Task<Void, Never>] = [:]
    private var mapper = IPEventMapper()
    private var closed = false
    private var hadSession = false
    private var pinnedSerial: String?
    private var opening = false
    private var openWaiters: [CheckedContinuation<Result<Void, CameraLinkFailure>, Never>] = []
    /// From the latest listing: the folders, and each file's name (for `bytes`, which writes under the camera's name).
    private var folders: [PTPObjectHandle: IPListing.Folder] = [:]
    private var names: [PTPObjectHandle: String] = [:]
    private var recorded = IPLinkDiagnostics()
    private var retiredKeepAlives = (answered: 0, failed: 0)

    /// - Parameters:
    ///   - channels: Opens the TCP connections (Network.framework on the phone, in-memory pairs in tests).
    ///   - clock: The session's own waits run on it: the plan's pauses, the listing poll, the keep-alive, the retry and
    ///     reopen pauses.
    ///   - connectionClock: The PTP/IP connection's time limits (connect, Init acks, replies) run on it; `clock` when
    ///     nil. Tests drive the session's waits on a virtual clock and leave the transport's limits on a real one.
    public init(descriptor: CameraDescriptor, configuration: Configuration, channels: any ByteChannelFactory,
                clock: any Clock<Duration> = ContinuousClock(), connectionClock: (any Clock<Duration>)? = nil) {
        self.descriptor = descriptor
        self.configuration = configuration
        self.channels = channels
        self.clock = clock
        self.connectionClock = connectionClock ?? clock
    }

    public nonisolated var capabilities: CameraLinkCapabilities { Self.capabilitiesWithoutResume }

    public nonisolated var events: AsyncStream<CameraLinkEvent> { fanOut.subscribe() }

    /// What the link has seen so far.
    public var diagnostics: IPLinkDiagnostics {
        get async {
            var diagnostics = recorded
            var answered = retiredKeepAlives.answered
            var failed = retiredKeepAlives.failed
            if let session {
                let counts = await session.keepAliveCounts
                answered += counts.answered
                failed += counts.failed
            }
            diagnostics.keepAlivesAnswered = answered
            diagnostics.keepAlivesFailed = failed
            return diagnostics
        }
    }

    /// Whether a session is open and usable now.
    public var isOpen: Bool { sessionReady && session != nil && !closed }

    // MARK: - Open

    public func open() async throws(CameraLinkFailure) {
        if closed { throw CameraLinkFailure(.disconnected, detail: "open: the link is closed") }
        if sessionReady, session != nil { return }
        if opening {
            let result = await withCheckedContinuation { openWaiters.append($0) }
            try result.get()
            return
        }
        opening = true
        let result: Result<Void, CameraLinkFailure>
        do throws(CameraLinkFailure) {
            try await runOpen()
            result = .success(())
        } catch {
            result = .failure(error)
        }
        opening = false
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter.resume(returning: result) }
        try result.get()
    }

    private func runOpen() async throws(CameraLinkFailure) {
        let reopening = hadSession
        let plan = configuration.plan(reopening: reopening)
        if reopening { try await pause(plan.reconnectPause) }
        var retried = false
        while true {
            if closed { throw CameraLinkFailure(.disconnected, detail: "open: the link is closed") }
            let session = makeSession()
            do throws(PTPIPConnectionFailure) {
                _ = try await session.connect()
            } catch {
                await discard(session)
                if closed { throw CameraLinkFailure(.disconnected, detail: "open: the link is closed") }
                if !retried, Self.retriesHandshake(after: error), !Task.isCancelled {
                    retried = true
                    try await pause(plan.handshakeRetryDelay)
                    continue
                }
                throw IPFailureMapping.failure(error, during: .open)
            }
            do throws(CameraLinkFailure) {
                try await runPlan(plan, on: session)
                try requireCurrent(session)
            } catch {
                await discard(session)
                throw error
            }
            sessionReady = true
            hadSession = true
            recorded.sessionsOpened += 1
            await session.startKeepAlive()
            // A loss signalled before `sessionReady` was set was ignored as part of opening; the session says whether
            // it is still up. A loss signalled from now on is reported as `.sessionLost` by `handle(_:epoch:)`.
            if !(await session.isUsable) {
                await discard(session)
                throw CameraLinkFailure(.disconnected, detail: "open: the session ended as it opened")
            }
            return
        }
    }

    /// One more handshake on a new connection after any failure but the caller's own cancellation (the spike's and
    /// Imagedge's precaution, `unverified` as needed on the α7C II).
    static func retriesHandshake(after failure: PTPIPConnectionFailure) -> Bool {
        switch failure {
        case .cancelled, .cancelledBeforeStart: false
        default: true
        }
    }

    private func makeSession() -> IPSession {
        epoch += 1
        let epoch = epoch
        mapper = IPEventMapper()
        let session = IPSession(endpoint: configuration.endpoint, guid: configuration.guid,
                                friendlyName: configuration.friendlyName, timing: configuration.timing,
                                keepAlive: configuration.keepAlive, channels: channels, clock: clock,
                                connectionClock: connectionClock)
        let signals = session.signals
        consumers[epoch] = Task { [weak self] in
            for await signal in signals { await self?.handle(signal, epoch: epoch) }
            await self?.consumerEnded(epoch)
        }
        self.session = session
        sessionReady = false
        return session
    }

    private func consumerEnded(_ epoch: Int) {
        consumers[epoch] = nil
    }

    /// Drops a session that failed to open, or was lost: forgets it if it is current, and closes it.
    private func discard(_ session: IPSession) async {
        if self.session === session {
            self.session = nil
            sessionReady = false
            let counts = await session.keepAliveCounts
            retiredKeepAlives.answered += counts.answered
            retiredKeepAlives.failed += counts.failed
        }
        await session.close(sendingCloseSession: false)
    }

    /// Throws unless `session` is still the link's (not closed, not replaced).
    private func requireCurrent(_ session: IPSession) throws(CameraLinkFailure) {
        if closed { throw CameraLinkFailure(.disconnected, detail: "open: the link is closed") }
        guard self.session === session else {
            throw CameraLinkFailure(.disconnected, detail: "open: the session ended while it opened")
        }
    }

    private func pause(_ duration: Duration) async throws(CameraLinkFailure) {
        do {
            try await clock.sleep(for: duration)
        } catch {
            throw CameraLinkFailure(.disconnected, detail: "open: cancelled")
        }
    }

    /// Walks the plan with `SonySessionRunner`: sends what it says (or answers OperationNotSupported for it, without
    /// sending, when DeviceInfo doesn't list it), pins the serial at each DeviceInfo, waits its pauses, and runs the poll.
    private func runPlan(_ plan: SonyContentsTransferPlan, on session: IPSession) async throws(CameraLinkFailure) {
        var runner = SonySessionRunner(plan: plan)
        var action = runner.next(nil)
        var info: PTPDeviceInfo?
        var linkFailure: PTPIPConnectionFailure?
        var skipped: [SonySessionStep.Operation] = []
        defer {
            recorded.steps = runner.records
            recorded.skippedSteps = skipped
        }
        recorded.pollAttempts = 0
        recorded.pollTimedOut = false
        recorded.timeToListing = nil
        while true {
            try requireCurrent(session)
            switch action {
            case let .send(step):
                let operation = step.operation
                if let info, operation != .getDeviceInfo, !info.supports(operation.operationCode) {
                    skipped.append(operation)
                    action = runner.next(.response(.operationNotSupported))
                    continue
                }
                let collector = IPDataCollector(limit: Self.datasetLimit)
                let outcome: SonySessionRunner.Outcome
                do throws(PTPIPConnectionFailure) {
                    let reply = try await session.perform(timeout: plan.replyTimeout, sink: { collector.append($0) }) {
                        operation.command(using: &$0)
                    }
                    if operation == .getDeviceInfo, reply.code == .ok {
                        if reply.dataIsComplete, !collector.overflowed,
                           let decoded = try? PTPDeviceInfo.decode(collector.data) {
                            outcome = .deviceInfo(decoded)
                        } else {
                            outcome = .undecodable
                        }
                    } else {
                        outcome = .response(reply.code)
                    }
                } catch {
                    linkFailure = error
                    outcome = .linkFailed
                }
                if case let .deviceInfo(decoded) = outcome {
                    try pin(decoded)
                    info = decoded
                    deviceInfo = decoded
                }
                action = runner.next(outcome)
            case let .wait(duration):
                try await pause(duration)
                action = runner.next(nil)
            case let .list(poll):
                let kind = Self.sessionKind(of: runner.records)
                sessionKind = kind
                if kind == .wholeCardContentsTransfer { try await self.poll(poll, on: session) }
                return
            case let .stop(failure):
                throw IPFailureMapping.failure(failure, connectionFailure: linkFailure)
            }
        }
    }

    /// Whole-card when SDIO_OpenSession was accepted; plain when the OpenSession fallback opened the session.
    static func sessionKind(of records: [SonySessionRunner.Record]) -> SonySessionKind {
        let whole = records.contains { record in
            if case .sdioOpenSession = record.operation { record.accepted } else { false }
        }
        return whole ? .wholeCardContentsTransfer : .plain
    }

    /// Holds the session to the camera the app knows: `knownSerial`, or the serial of this link's first DeviceInfo.
    /// The detail gives lengths only: the serial never reaches a log.
    private func pin(_ info: PTPDeviceInfo) throws(CameraLinkFailure) {
        let known = configuration.knownSerial.flatMap { $0.isEmpty ? nil : $0 } ?? pinnedSerial
        if let known, info.serialNumber != known {
            throw CameraLinkFailure(.identityChanged, detail: "open: DeviceInfo shows another serial "
                + "(\(info.serialNumber.count) characters; the known one has \(known.count))")
        }
        if pinnedSerial == nil { pinnedSerial = info.serialNumber }
    }

    /// The listing poll: ends when a storage lists a handle, or StoreAdded has come and the card lists empty (an empty
    /// card), or at the plan's limit (then `list()` asks again whatever the poll saw). Early answers are empty while
    /// the camera indexes the card.
    private func poll(_ poll: SonyListingPoll, on session: IPSession) async throws(CameraLinkFailure) {
        let mark = ClockMark.now(on: clock)
        var attempt = 0
        while true {
            try requireCurrent(session)
            attempt += 1
            recorded.pollAttempts = attempt
            let found = try await pollOnce(poll, on: session)
            if found.handles > 0 || (mapper.storeAddedSeen && found.storages > 0) {
                recorded.timeToListing = mark.elapsed
                return
            }
            guard let wait = poll.wait(afterAttempt: attempt, elapsed: mark.elapsed) else {
                recorded.pollTimedOut = true
                return
            }
            try await pause(wait)
        }
    }

    /// One attempt: GetStorageIDs (StoreNotAvailable counts as no storage), then GetObjectHandles for each storage
    /// with a logical store. A non-OK answer counts as empty; a link failure ends the open.
    private func pollOnce(_ poll: SonyListingPoll, on session: IPSession) async throws(CameraLinkFailure)
        -> (storages: Int, handles: Int) {
        try requireListed(.getStorageIDs, during: .open)
        try requireListed(.getObjectHandles, during: .open)
        let ids = try await transact(.open, on: session, limit: Self.datasetLimit) { PTPCommand.getStorageIDs(tx: $0) }
        let storages = ids.reply.code == .ok
            ? SonyListingPoll.storagesToList((try? PTPStorageID.decodeArray(ids.data)) ?? []) : []
        var handles = 0
        for storage in storages {
            let answer = try await transact(.open, on: session, timeout: poll.handlesReplyTimeout, limit: Self.handlesLimit) {
                SonyListingPoll.handlesCommand(for: storage, tx: $0)
                    ?? PTPCommand.getObjectHandles(storage: storage, tx: $0)
            }
            if answer.reply.code == .ok, let list = try? PTPObjectHandle.decodeArray(answer.data) {
                handles += list.count
            }
        }
        return (storages.count, handles)
    }

    // MARK: - Calls

    public func list() async throws(CameraLinkFailure) -> [CameraItem] {
        let session = try readySession(.list)
        try requireListed(.getStorageIDs, during: .list)
        try requireListed(.getObjectHandles, during: .list)
        try requireListed(.getObjectInfo, during: .list)
        // One turn for the whole listing: queued, each GetObjectInfo would wait for a download of an import running
        // alongside (one per file, minutes for a full card).
        let hold: IPSession.Hold
        do throws(PTPIPConnectionFailure) {
            hold = try await session.hold()
        } catch {
            throw IPFailureMapping.failure(error, during: .list)
        }
        let result: Result<[CameraItem], CameraLinkFailure>
        do throws(CameraLinkFailure) {
            result = .success(try await listing(on: session, within: hold))
        } catch {
            result = .failure(error)
        }
        await session.release(hold)
        return try result.get()
    }

    private func listing(on session: IPSession, within hold: IPSession.Hold) async throws(CameraLinkFailure)
        -> [CameraItem] {
        let ids = try await transact(.list, on: session, within: hold, limit: Self.datasetLimit) {
            PTPCommand.getStorageIDs(tx: $0)
        }
        if ids.reply.code == .storeNotAvailable, sessionKind == .plain {
            // A plain session lists nothing on this camera (measured on both networks): no files, not a failure.
            folders = [:]
            names = [:]
            return []
        }
        guard ids.reply.code == .ok else {
            throw await failure(ids.reply.code, during: .list, on: session, within: hold)
        }
        guard let storageIDs = try? PTPStorageID.decodeArray(ids.data) else {
            throw CameraLinkFailure(.noAnswer, detail: "list: GetStorageIDs undecodable")
        }
        let listingTimeout = configuration.plan(reopening: false).listing.handlesReplyTimeout
        var handles: [PTPObjectHandle] = []
        var seen: Set<PTPObjectHandle> = []
        for storage in SonyListingPoll.storagesToList(storageIDs) {
            let answer = try await transact(.list, on: session, within: hold, timeout: listingTimeout,
                                            limit: Self.handlesLimit) {
                SonyListingPoll.handlesCommand(for: storage, tx: $0)
                    ?? PTPCommand.getObjectHandles(storage: storage, tx: $0)
            }
            guard answer.reply.code == .ok else {
                throw await failure(answer.reply.code, during: .list, on: session, within: hold)
            }
            guard answer.reply.dataIsComplete, !answer.overflowed,
                  let list = try? PTPObjectHandle.decodeArray(answer.data) else {
                throw CameraLinkFailure(.noAnswer, detail: "list: GetObjectHandles undecodable")
            }
            for handle in list where seen.insert(handle).inserted { handles.append(handle) }
        }
        var infos: [(handle: PTPObjectHandle, info: PTPObjectInfo)] = []
        for handle in handles {
            switch try await objectInfo(handle, during: .list, on: session, within: hold) {
            case let .some(info): infos.append((handle, info))
            case .none: continue  // gone between the two answers
            }
        }
        folders = IPListing.folders(in: infos)
        names = Dictionary(infos.filter { !$0.info.isFolder && IPListing.isSafeFileName($0.info.filename) }
                               .map { ($0.handle, $0.info.filename) },
                           uniquingKeysWith: { first, _ in first })
        return IPListing.items(from: infos, timeZone: configuration.timeZone)
    }

    public func info(of item: CameraItem.ID) async throws(CameraLinkFailure) -> CameraItem {
        let session = try readySession(.info)
        try requireListed(.getObjectInfo, during: .info)
        let handle = try Self.handle(of: item, during: .info)
        guard let info = try await objectInfo(handle, during: .info, on: session),
              let found = IPListing.item(handle: handle, info: info, folders: folders, timeZone: configuration.timeZone)
        else {
            throw CameraLinkFailure(.itemNotFound, detail: "info: not a file on the card")
        }
        names[handle] = found.name
        return found
    }

    public func thumbnail(of item: CameraItem.ID) async throws(CameraLinkFailure) -> Data {
        let session = try readySession(.thumbnail)
        try requireListed(.getThumb, during: .thumbnail)
        let handle = try Self.handle(of: item, during: .thumbnail)
        let answer = try await transact(.thumbnail, on: session, limit: Self.thumbnailLimit) {
            PTPCommand.getThumb(handle, tx: $0)
        }
        guard answer.reply.code == .ok else { throw await failure(answer.reply.code, during: .thumbnail, on: session) }
        if answer.overflowed { throw CameraLinkFailure(.unreadableItem, detail: "thumbnail: larger than 8 MiB") }
        guard answer.reply.dataIsComplete, !answer.data.isEmpty else {
            throw CameraLinkFailure(.noAnswer, detail: "thumbnail: short data phase")
        }
        return answer.data
    }

    /// GetObject, streamed into `directory` under the camera's file name (overwriting what was there), with `progress`
    /// called with the bytes written after each read. `resuming` is ignored and `checkpoint` never called: this link
    /// doesn't resume yet (see the type's notes). A failed copy leaves no file behind.
    public func bytes(
        of item: CameraItem.ID,
        into directory: URL,
        resuming: PartialDownload?,
        checkpoint: @escaping @Sendable (PartialDownload) -> Void,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL {
        let session = try readySession(.download)
        try requireListed(.getObject, during: .download)
        let handle = try Self.handle(of: item, during: .download)
        let name: String
        if let known = names[handle] {
            name = known
        } else {
            name = try await info(of: item).name
        }
        // The name comes from the camera (or whatever answers at its address): only a plain file name is written,
        // never a path that leads out of `directory`.
        guard IPListing.isSafeFileName(name) else {
            throw CameraLinkFailure(.unreadableItem, detail: "download: the camera's file name isn't a plain name")
        }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let file: IPFileSink
        do {
            file = try IPFileSink(url: url)
        } catch {
            throw Self.writeFailure(error)
        }
        let reply: PTPIPConnection.Reply
        do throws(PTPIPConnectionFailure) {
            reply = try await session.perform(.transfer, sink: { data in
                if let total = file.write(data) { progress(total) }
            }) { counter in
                PTPCommand.getObject(handle, tx: counter.take())
            }
        } catch {
            file.discard()
            throw IPFailureMapping.failure(error, during: .download)
        }
        let written = file.finish()
        if let writeError = written.failure {
            file.discard()
            throw Self.writeFailure(writeError)
        }
        guard reply.code == .ok else {
            file.discard()
            throw await failure(reply.code, during: .download, on: session)
        }
        guard reply.dataIsComplete, reply.hadDataPhase else {
            file.discard()
            throw CameraLinkFailure(.noAnswer, detail: "download: data phase short (\(written.bytes) bytes)")
        }
        return url
    }

    // MARK: - Close

    public func close() async {
        guard !closed else { return }
        closed = true
        let session = self.session
        self.session = nil
        sessionReady = false
        epoch += 1
        if let session {
            let counts = await session.keepAliveCounts
            retiredKeepAlives.answered += counts.answered
            retiredKeepAlives.failed += counts.failed
            await session.close(sendingCloseSession: true)
        }
        fanOut.finish()
    }

    // MARK: - Signals

    private func handle(_ signal: IPSession.Signal, epoch: Int) async {
        guard epoch == self.epoch, !closed else { return }
        switch signal {
        case let .event(event):
            switch mapper.map(event) {
            case let .forward(linkEvent): fanOut.send(linkEvent)
            case let .ignore(code): recorded.ignored(code)
            }
        case .waitingForLocalNetwork:
            fanOut.send(.waitingForLocalNetwork)
        case let .lost(failure):
            guard let session else { return }
            await lose(session, because: "\(failure)")
        }
    }

    /// The open session ended under the link: `.sessionLost`, and it is dropped so the next `open()` reopens. While
    /// opening, the open's own calls fail and say why; only the current, open session is reported lost.
    private func lose(_ session: IPSession, because reason: String) async {
        guard sessionReady, self.session === session, !closed else { return }
        recorded.sessionsLost += 1
        recorded.lastLoss = reason
        fanOut.send(.sessionLost)
        await discard(session)
    }

    // MARK: - Private

    private func readySession(_ operation: IPFailureMapping.Operation) throws(CameraLinkFailure) -> IPSession {
        if closed { throw CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the link is closed") }
        guard sessionReady, let session else {
            throw CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): no open session")
        }
        return session
    }

    /// Decision 6: once DeviceInfo is known, send only what it lists.
    private func requireListed(_ code: PTPOperationCode, during operation: IPFailureMapping.Operation)
        throws(CameraLinkFailure) {
        if let deviceInfo, !deviceInfo.supports(code) { throw IPFailureMapping.notListed(code, during: operation) }
    }

    static func handle(of item: CameraItem.ID, during operation: IPFailureMapping.Operation)
        throws(CameraLinkFailure) -> PTPObjectHandle {
        guard let handle = IPItemID.handle(of: item) else {
            throw CameraLinkFailure(.itemNotFound, detail: "\(operation.rawValue): not an item of this link")
        }
        return handle
    }

    /// One transaction whose data phase is small enough to keep.
    private func transact(_ operation: IPFailureMapping.Operation, on session: IPSession,
                          within hold: IPSession.Hold? = nil, timeout: Duration? = nil,
                          limit: Int, _ command: @escaping @Sendable (UInt32) -> PTPContainer)
        async throws(CameraLinkFailure) -> (reply: PTPIPConnection.Reply, data: Data, overflowed: Bool) {
        let collector = IPDataCollector(limit: limit)
        do throws(PTPIPConnectionFailure) {
            let reply = try await session.perform(within: hold, timeout: timeout, sink: { collector.append($0) }) {
                counter in command(counter.take())
            }
            return (reply, collector.data, collector.overflowed)
        } catch {
            throw IPFailureMapping.failure(error, during: operation)
        }
    }

    /// GetObjectInfo for one handle: the dataset, or nil when the camera says the handle is gone and the card is
    /// still there. Anything else non-OK throws.
    private func objectInfo(_ handle: PTPObjectHandle, during operation: IPFailureMapping.Operation,
                            on session: IPSession, within hold: IPSession.Hold? = nil)
        async throws(CameraLinkFailure) -> PTPObjectInfo? {
        let answer = try await transact(operation, on: session, within: hold, limit: Self.datasetLimit) {
            PTPCommand.getObjectInfo(handle, tx: $0)
        }
        guard answer.reply.code == .ok else {
            let failure = await failure(answer.reply.code, during: operation, on: session, within: hold)
            if failure.kind == .itemNotFound { return nil }
            throw failure
        }
        guard answer.reply.dataIsComplete, !answer.overflowed, let info = try? PTPObjectInfo.decode(answer.data) else {
            throw CameraLinkFailure(.noAnswer, detail: "\(operation.rawValue): ObjectInfo undecodable")
        }
        return info
    }

    /// A non-OK answer, classified. InvalidObjectHandle in a whole-card session is checked against the storages
    /// first, so a card the camera has dropped (whether or not its StoreRemoved has been read yet) pauses the job
    /// instead of skipping the file. SessionNotOpen means the camera has forgotten the session (it restarted its
    /// responder): the session is dropped as lost, so the next `open()` opens a new one instead of every call failing
    /// the same way.
    private func failure(_ code: PTPResponseCode, during operation: IPFailureMapping.Operation,
                         on session: IPSession, within hold: IPSession.Hold? = nil) async -> CameraLinkFailure {
        if code == .sessionNotOpen { await lose(session, because: "\(operation.rawValue): \(code)") }
        var removed = mapper.cardRemoved
        if code == .invalidObjectHandle, !removed, sessionKind == .wholeCardContentsTransfer {
            removed = await cardIsGone(on: session, within: hold)
        }
        return IPFailureMapping.failure(code, during: operation, cardRemoved: removed)
    }

    /// Whether the card is gone: GetStorageIDs lists no storage with a logical store, or doesn't answer OK. A failed
    /// check also counts as gone, so the file is paused on, never skipped, when in doubt.
    private func cardIsGone(on session: IPSession, within hold: IPSession.Hold?) async -> Bool {
        guard let answer = try? await transact(.list, on: session, within: hold, limit: Self.datasetLimit, {
            PTPCommand.getStorageIDs(tx: $0)
        }) else { return true }
        guard answer.reply.code == .ok, let ids = try? PTPStorageID.decodeArray(answer.data) else { return true }
        return SonyListingPoll.storagesToList(ids).isEmpty
    }

    /// A failure writing the file on the phone: a full phone stops the job; anything else skips the file.
    static func writeFailure(_ error: any Error) -> CameraLinkFailure {
        if USBFailureMapping.isOutOfSpace(error) {
            return CameraLinkFailure(.phoneStorageFull, detail: "download: the phone is full")
        }
        let ns = error as NSError
        return CameraLinkFailure(.unreadableItem, detail: "download: couldn't write the file (\(ns.domain) \(ns.code))")
    }
}

/// Collects a small data phase, up to a limit; beyond it the bytes are dropped and `overflowed` is set (the sink never
/// throws, which would cut off the connection for a reply that is merely too big).
final class IPDataCollector: Sendable {
    private struct State {
        var data = Data()
        var overflowed = false
    }

    private let state = Mutex(State())
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        state.withLock { s in
            if s.overflowed || s.data.count + chunk.count > limit {
                s.overflowed = true
            } else {
                s.data.append(chunk)
            }
        }
    }

    var data: Data { state.withLock { $0.data } }
    var overflowed: Bool { state.withLock { $0.overflowed } }
}

/// A file a download is written to, a read at a time, from the connection's context. A write error is kept, later
/// writes are dropped, and the transfer runs to its end, so a full phone doesn't cut off the session; `finish()`
/// reports it.
final class IPFileSink: Sendable {
    private struct State {
        var handle: FileHandle?
        var written: UInt64 = 0
        var failure: (any Error)?
    }

    let url: URL
    private let state: Mutex<State>

    /// Creates (or empties) the file, and its folder if need be.
    init(url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard files.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        self.url = url
        state = Mutex(State(handle: try FileHandle(forWritingTo: url)))
    }

    /// Appends `data`; returns the bytes written so far, or nil once a write has failed.
    func write(_ data: Data) -> UInt64? {
        state.withLock { s in
            guard let handle = s.handle, s.failure == nil else { return nil }
            do {
                try handle.write(contentsOf: data)
                s.written += UInt64(data.count)
                return s.written
            } catch {
                s.failure = error
                try? handle.close()
                s.handle = nil
                return nil
            }
        }
    }

    /// Closes the file: the bytes written, and the first write error (or the close's).
    func finish() -> (bytes: UInt64, failure: (any Error)?) {
        state.withLock { s in
            if let handle = s.handle {
                do {
                    try handle.close()
                } catch {
                    if s.failure == nil { s.failure = error }
                }
                s.handle = nil
            }
            return (s.written, s.failure)
        }
    }

    /// Closes and removes the file.
    func discard() {
        _ = finish()
        try? FileManager.default.removeItem(at: url)
    }
}
