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
    /// The latest listing: the handles GetObjectHandles gave, the GetObjectInfo it asked, and the files it took from
    /// the caller's known items without asking (`list(reusing:)`; 0 for `list()`). The time this saves against the
    /// spike's 8.3 s relist is unmeasured; these are for the bench run.
    public var listedHandles = 0
    public var objectInfosAsked = 0
    public var reusedHandles = 0
    /// Partial files whose continuation with 0x9211 began over the link's life, and the 0x9211 reads sent for them.
    public var resumes = 0
    public var partialReads = 0
    /// Resumes whose first 0x9211 read the camera refused (a non-OK answer, the session up and the card there), each
    /// file then copied again from 0 with GetObject into the same file. 0x9211 is `unverified` beyond one spike run.
    public var resumeFallbacks = 0
    /// Downloads refused because a handle known from an earlier listing or session now names another file (not to be
    /// confused with `reusedHandles`, the items a relist kept).
    public var staleHandlesRefused = 0
    /// Transfers cut off by `abortCurrentTransfer()`.
    public var transfersAborted = 0
    /// GetDevicePropValue commands sent over the link's life. Expected 0: the whole-card session never answers one, and
    /// decision 6 sends only what DeviceInfo lists (wireless plan section 4, check 9).
    public var devicePropValueReads = 0
    /// GetThumb over the link's life (bench 19.1: thumbnails that never loaded, with nothing logged).
    public var thumbnails = IPThumbnailDiagnostics()

    /// How many ignored event codes are kept for the log. A choice, `unverified`: no measurement or source gives 64; it
    /// only bounds the list, and the camera sent two 0xC225 events on a reopen in the whole spike.
    public static let ignoredEventLimit = 64

    public init() {}

    mutating func ignored(_ code: PTPEventCode) {
        ignoredEvents.append(code)
        if ignoredEvents.count > Self.ignoredEventLimit { ignoredEvents.removeFirst() }
    }
}

/// What `IPLink.thumbnail(of:)` met over the link's life, as counts, PTP response codes and times only: no handle, file
/// name or size of a particular file. GetThumb on the 1.0 route (PC Remote Function off) is `unverified`: the spike only
/// measured it with PC Remote on.
public struct IPThumbnailDiagnostics: Sendable, Equatable {
    /// GetThumb commands sent. A thumbnail cancelled while it waited for its turn, or still waiting when the session
    /// ended, sent nothing: it is counted in `notSent` only.
    public var asked = 0
    /// GetThumb answered OK with a complete, non-empty data phase.
    public var answered = 0
    /// GetThumb answered with a response code other than OK, counted by code.
    public var failuresByCode: [PTPResponseCode: Int] = [:]
    /// GetThumb that got no answer within the reply limit (the connection is then lost).
    public var timeouts = 0
    /// GetThumb that failed another way: the connection failed (not a timeout), the data phase was short or empty, or it
    /// was larger than the link keeps.
    public var otherFailures = 0
    /// Thumbnails asked for while the latest DeviceInfo didn't list GetThumb (0x100A), so nothing was sent.
    public var notListed = 0
    /// Thumbnails that never reached the wire: cancelled while they waited for their turn (a cell scrolled away), or
    /// still waiting when the session ended. Neither `asked` nor a failure.
    public var notSent = 0
    /// The data of every answered GetThumb, in bytes.
    public var bytesTotal: UInt64 = 0
    /// From the session opening to the first answered GetThumb over the link's life; nil until one is answered.
    public var firstAfterOpen: Duration?

    public init() {}

    /// The failures counted by code, in total.
    public var refused: Int { failuresByCode.values.reduce(0, +) }
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
/// doesn't end the session; cancelling a GetObject cuts the connection off (`.sessionLost`, then a reopen).
/// `list()` asks GetObjectHandles and one GetObjectInfo per handle, newest first; `thumbnail` is GetThumb; `bytes` is
/// GetObject streamed to a file. A file name that isn't a plain name (a `/`, `..`) is never listed or written.
/// Every command has a time limit between reads (30 s, 60 s for GetObjectHandles); a download has none as a whole.
///
/// **Resume (W8).** When the camera's DeviceInfo lists SDIO_GetPartialLargeObject (0x9211), `capabilities` reports
/// `resumesPartialFiles` (`.wifi`); before the first open, or for a camera that doesn't list it, it doesn't (never more
/// than the link can do; the engine reads capabilities once the link is open). Then:
/// - A new file is read with GetObject (the measured whole-file path; whether to read every file in 0x9211 chunks is
///   still open, B:106), and `checkpoint` is called each time the copy crosses a multiple of the chunk size (4 MiB),
///   and once more when the copy breaks off, with the bytes on disk; the partial file is kept for the resume.
/// - A `resuming` partial is cut back to its offset and continued with 0x9211 reads of 4 MiB from there (the variant
///   from `SonyCapabilities.partialReadVariant(objectSize:in: .wholeCardContentsTransfer)`: 0x101B and 0x9219 answer
///   InvalidObjectHandle in this session and are never sent), with `checkpoint` after each chunk but the last, and on
///   a break. Each chunk is a transfer of its own, so a thumbnail asked for meanwhile waits for one chunk, not the
///   file, and a cancelled resume (a pause) lets the chunk on the wire finish and stops at its boundary, keeping the
///   session. A first read the camera refuses with the session up and the card there is followed by a GetObject of
///   the whole file into the same file (`resumeFallbacks`). A partial the link can't continue (missing, shorter than its offset, past the object's end) is copied
///   again from 0 into the same file.
/// Without 0x9211 the link ignores `resuming`, copies from the start and never checkpoints, as `USBLink` does.
///
/// **Reopen without relisting (W8).** `list(reusing:)` asks GetObjectHandles and runs GetObjectInfo only for handles
/// the caller's items don't name (handles were stable across sessions on the bench, B:91). A handle known only from
/// such a list, or from an earlier session, is a hint: `bytes` reads its ObjectInfo first and refuses a file whose
/// name or size changed (`itemNotFound`), so a swapped card is never written under the old name (B:92); it keeps
/// refusing it until a listing asks GetObjectInfo for that handle again, and from then on the link relists in full.
///
/// **Abort.** `abortCurrentTransfer()` (`TransferAborting`) cuts the connection off under a download in flight, for
/// the continued task's expiry (W13).
///
/// **Events.** StoreRemoved becomes `.storeRemoved`, StoreAdded that brings the card back `.storeAdded`
/// (`IPEventMapper`); between them, and whenever a check of the storages finds the card gone, InvalidObjectHandle is
/// `cardUnavailable`, never `itemNotFound`. 0xC201, 0xC225 and other events are noted in `diagnostics` and ignored. A
/// channel waiting for the Local Network prompt is `.waitingForLocalNetwork`. A connection that ends under the link (the
/// camera's idle drop, iOS closing the sockets in the background, Wi-Fi gone) is `.sessionLost`: pending calls end as
/// `disconnected`, `events` stays open, and `open()` reopens a new session (as a reopen, with the serial held).
public actor IPLink: CameraLink, TransferAborting {
    /// What this link can do before DeviceInfo has shown 0x9211: `.wifi` without resume (a link reports less than its
    /// carrier's baseline, never more than it does).
    public static let capabilitiesWithoutResume: CameraLinkCapabilities = {
        var capabilities = CameraLinkCapabilities.wifi
        capabilities.resumesPartialFiles = false
        return capabilities
    }()

    /// What this link can do with a camera whose DeviceInfo is `deviceInfo` (nil: not opened yet): `.wifi`, with
    /// `resumesPartialFiles` only when the camera is a Sony body that lists 0x9211
    /// (`SonyCapabilities.largeObjectPartialRead`; the α7C II's PTP/IP DeviceInfo does).
    public static func capabilities(for deviceInfo: PTPDeviceInfo?) -> CameraLinkCapabilities {
        guard let deviceInfo, SonyCapabilities(deviceInfo: deviceInfo).largeObjectPartialRead else {
            return capabilitiesWithoutResume
        }
        return .wifi
    }

    /// The largest data phase kept in memory for each kind of answer, so a broken reply can't fill the phone: DeviceInfo
    /// and ExtDeviceInfo (970 B on the α7C II), ObjectInfo, the handle list (4 B per file), and a thumbnail (the
    /// spike's 8 MiB limit; the camera's are 160 × 120 JPEGs of about 7 KB). Only `thumbnailLimit` has a source. The 1 MiB
    /// and 4 MiB limits are choices, `unverified`: roughly a thousand times the 970 B ExtDeviceInfo, and a handle list of
    /// about a million files at 4 B each (the largest card listed was 741 handles).
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
    /// From the latest listing: the folders, and each file's name and size (for `bytes`, which writes under the
    /// camera's name and needs the size to resume), with whether this session's GetObjectInfo has confirmed it.
    private var folders: [PTPObjectHandle: IPListing.Folder] = [:]
    private var objects: [PTPObjectHandle: KnownObject] = [:]
    private var recorded = IPLinkDiagnostics()
    /// When the current session finished opening, for `IPThumbnailDiagnostics.firstAfterOpen`.
    private var sessionOpenedAt: ClockMark?
    private var retiredKeepAlives = (answered: 0, failed: 0)
    /// GetDevicePropValue commands sent by sessions already dropped.
    private var retiredDevicePropValueReads = 0
    /// The bench log's events (W20); `.none` records nothing.
    private let trace: TransportTrace
    /// `bytes` calls under way, for `abortCurrentTransfer()`.
    private var activeDownloads = 0
    /// A handle known from a caller's items or an earlier session has named another file (a swapped card): from then
    /// on `list(reusing:)` ignores known items and asks GetObjectInfo for every handle, for the link's life.
    private var knownItemsUntrusted = false
    /// `capabilities`, readable from outside the actor: set from each DeviceInfo.
    private nonisolated let capabilityState = CapabilityState()

    /// A file the link has seen: its name and size, and whether a GetObjectInfo of this session gave them (false for
    /// one taken from the caller's items by `list(reusing:)`, or listed in an earlier session: a hint).
    struct KnownObject: Sendable, Equatable {
        var name: String
        var size: UInt64
        var confirmed: Bool
    }

    final class CapabilityState: Sendable {
        private let value = Mutex(IPLink.capabilitiesWithoutResume)
        var current: CameraLinkCapabilities { value.withLock { $0 } }
        func set(_ capabilities: CameraLinkCapabilities) { value.withLock { $0 = capabilities } }
    }

    /// - Parameters:
    ///   - channels: Opens the TCP connections (Network.framework on the phone, in-memory pairs in tests).
    ///   - clock: The session's own waits run on it: the plan's pauses, the listing poll, the keep-alive, the retry and
    ///     reopen pauses.
    ///   - connectionClock: The PTP/IP connection's time limits (connect, Init acks, replies) run on it; `clock` when
    ///     nil. Tests drive the session's waits on a virtual clock and leave the transport's limits on a real one.
    ///   - trace: the bench log's events (W20): each open's times and listing poll, each keep-alive with its spacing, each
    ///     0x9211 resume and its offset, a lost session, and the diagnostics at close. Recording changes nothing the link
    ///     does or when.
    public init(descriptor: CameraDescriptor, configuration: Configuration, channels: any ByteChannelFactory,
                clock: any Clock<Duration> = ContinuousClock(), connectionClock: (any Clock<Duration>)? = nil,
                trace: TransportTrace = .none) {
        self.descriptor = descriptor
        self.configuration = configuration
        self.channels = channels
        self.clock = clock
        self.connectionClock = connectionClock ?? clock
        self.trace = trace
    }

    /// `capabilitiesWithoutResume` until the first DeviceInfo, then `capabilities(for:)` the latest one: resume is
    /// reported only once the camera has shown it lists 0x9211.
    public nonisolated var capabilities: CameraLinkCapabilities { capabilityState.current }

    public nonisolated var events: AsyncStream<CameraLinkEvent> { fanOut.subscribe() }

    /// What the link has seen so far.
    public var diagnostics: IPLinkDiagnostics {
        get async {
            var diagnostics = recorded
            var answered = retiredKeepAlives.answered
            var failed = retiredKeepAlives.failed
            var propReads = retiredDevicePropValueReads
            if let session {
                let counts = await session.keepAliveCounts
                answered += counts.answered
                failed += counts.failed
                propReads += await session.devicePropValueReads
            }
            diagnostics.keepAlivesAnswered = answered
            diagnostics.keepAlivesFailed = failed
            diagnostics.devicePropValueReads = propReads
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
        // The plan reopens on a session this link had or on one the caller says the camera had (a new link inside the
        // stay); the bench log labels both "reopening". Only the link's own earlier session earns the pause.
        let tracedReopening = reopening || configuration.reopening
        let started = ClockMark.now(on: clock)
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
            trace(.linkConnected(after: started.elapsed, reopening: tracedReopening))
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
            sessionOpenedAt = ClockMark.now(on: clock)
            // What an earlier session listed is a hint in this one: a download reads the ObjectInfo again first.
            for handle in objects.keys { objects[handle]?.confirmed = false }
            await session.startKeepAlive()
            // A loss signalled before `sessionReady` was set was ignored as part of opening; the session says whether
            // it is still up. A loss signalled from now on is reported as `.sessionLost` by `handle(_:epoch:)`.
            if !(await session.isUsable) {
                await discard(session)
                throw CameraLinkFailure(.disconnected, detail: "open: the session ended as it opened")
            }
            trace(.linkOpened(after: started.elapsed, reopening: tracedReopening,
                              wholeCard: sessionKind == .wholeCardContentsTransfer, polls: recorded.pollAttempts,
                              listedAfter: recorded.timeToListing, pollTimedOut: recorded.pollTimedOut))
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
                                connectionClock: connectionClock, trace: trace)
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
            retiredDevicePropValueReads += await session.devicePropValueReads
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
                    capabilityState.set(Self.capabilities(for: decoded))
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
        try await list(reusing: [])
    }

    /// The card, reopening without relisting what is known (backlog B:91, wireless plan W8): GetStorageIDs and
    /// GetObjectHandles as `list()` asks them, then GetObjectInfo only for the handles `known` doesn't name
    /// (`SonyHandleSet.unseen`); a known item whose handle is listed again is returned as it is, and one whose handle
    /// has gone is left out. Newest first, as `list()`. With no known items this is `list()`.
    ///
    /// A kept item is a hint (B:92): its name and size are checked when it is used. `bytes` reads its ObjectInfo first
    /// and refuses a file whose name or size changed (`itemNotFound`), and `info(of:)` always asks the camera, which is
    /// what the engine checks a partial file against before it resumes; neither turns a hint the camera contradicts
    /// into a confirmed entry, so the refusal holds for every later `bytes`. Once a handle has been found naming
    /// another file, `known` is ignored for the link's life and every handle's ObjectInfo is asked (the card was
    /// swapped; a relist that kept its old items would hide the new files). Thumbnails of kept items aren't checked
    /// (a wrong thumbnail writes nothing).
    ///
    /// - Parameter known: Items this link (or an earlier `IPLink` for the same camera) listed: the IDs carry the
    ///   handles. Items of another link are ignored.
    public func list(reusing known: [CameraItem]) async throws(CameraLinkFailure) -> [CameraItem] {
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
            result = .success(try await listing(on: session, within: hold, reusing: known))
        } catch {
            result = .failure(error)
        }
        await session.release(hold)
        return try result.get()
    }

    private func listing(on session: IPSession, within hold: IPSession.Hold, reusing known: [CameraItem])
        async throws(CameraLinkFailure) -> [CameraItem] {
        guard let handles = try await listedHandles(on: session, within: hold) else {
            // A plain session lists nothing on this camera (measured on both networks): no files, not a failure.
            folders = [:]
            objects = [:]
            recorded.listedHandles = 0
            recorded.objectInfosAsked = 0
            recorded.reusedHandles = 0
            return []
        }
        let (kept, unseen) = IPListing.reuse(knownItemsUntrusted ? [] : known, listed: handles)
        var infos: [(handle: PTPObjectHandle, info: PTPObjectInfo)] = []
        for handle in unseen {
            switch try await objectInfo(handle, during: .list, on: session, within: hold) {
            case let .some(info): infos.append((handle, info))
            case .none: continue  // gone between the two answers
            }
        }
        recorded.listedHandles = handles.count
        recorded.objectInfosAsked = unseen.count
        recorded.reusedHandles = kept.count
        // Folders are never kept items, so every folder of the card is among `infos`.
        folders = IPListing.folders(in: infos)
        var seen: [PTPObjectHandle: KnownObject] = [:]
        for (handle, item) in kept {
            // What this session's GetObjectInfo already confirmed stays confirmed when the kept item agrees with it.
            if let current = objects[handle], current.confirmed, current.name == item.name, current.size == item.size {
                seen[handle] = current
            } else {
                seen[handle] = KnownObject(name: item.name, size: item.size, confirmed: false)
            }
        }
        for (handle, info) in infos where !info.isFolder && IPListing.isSafeFileName(info.filename) {
            seen[handle] = KnownObject(name: info.filename, size: UInt64(info.objectCompressedSize), confirmed: true)
        }
        objects = seen
        return (Array(kept.values) + IPListing.items(from: infos, timeZone: configuration.timeZone)).newestFirst()
    }

    /// GetStorageIDs, then GetObjectHandles (all levels) for each storage with a logical store: every handle, each
    /// once, in listing order. Nil for a plain session's StoreNotAvailable, which means an empty card here.
    private func listedHandles(on session: IPSession, within hold: IPSession.Hold)
        async throws(CameraLinkFailure) -> [PTPObjectHandle]? {
        let ids = try await transact(.list, on: session, within: hold, limit: Self.datasetLimit) {
            PTPCommand.getStorageIDs(tx: $0)
        }
        if ids.reply.code == .storeNotAvailable, sessionKind == .plain { return nil }
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
        return handles
    }

    /// The camera's answer for the item's handle, always asked. A hint the answer contradicts stays an unconfirmed
    /// hint (see `record(_:for:)`), so `bytes` still refuses it.
    public func info(of item: CameraItem.ID) async throws(CameraLinkFailure) -> CameraItem {
        let session = try readySession(.info)
        let handle = try Self.handle(of: item, during: .info)
        let found = try await askInfo(handle, during: .info, on: session)
        record(found, for: handle)
        return found
    }

    /// GetObjectInfo for a file's handle, as an item; `itemNotFound` for a handle that is gone or names no file.
    private func askInfo(_ handle: PTPObjectHandle, during operation: IPFailureMapping.Operation,
                         on session: IPSession) async throws(CameraLinkFailure) -> CameraItem {
        try requireListed(.getObjectInfo, during: operation)
        guard let info = try await objectInfo(handle, during: operation, on: session),
              let found = IPListing.item(handle: handle, info: info, folders: folders, timeZone: configuration.timeZone)
        else {
            throw CameraLinkFailure(.itemNotFound, detail: "\(operation.rawValue): not a file on the card")
        }
        return found
    }

    /// Records the camera's answer for `handle` as confirmed, unless it contradicts a hint (an unconfirmed entry with
    /// another name or size, from `list(reusing:)` or an earlier session): the card was swapped or the file replaced.
    /// The hint is then left as it was, so `bytes` keeps refusing the caller's item until a listing asks GetObjectInfo
    /// for the handle again, and `list(reusing:)` stops trusting known items. Returns whether it was recorded.
    @discardableResult
    private func record(_ found: CameraItem, for handle: PTPObjectHandle) -> Bool {
        if let earlier = objects[handle], !earlier.confirmed, earlier.name != found.name || earlier.size != found.size {
            knownItemsUntrusted = true
            return false
        }
        objects[handle] = KnownObject(name: found.name, size: found.size, confirmed: true)
        return true
    }

    /// GetThumb for one file. Every outcome is counted in `diagnostics.thumbnails` (bench 19.1).
    public func thumbnail(of item: CameraItem.ID) async throws(CameraLinkFailure) -> Data {
        let session = try readySession(.thumbnail)
        do throws(CameraLinkFailure) {
            try requireListed(.getThumb, during: .thumbnail)
        } catch {
            recorded.thumbnails.notListed += 1
            throw error
        }
        let handle = try Self.handle(of: item, during: .thumbnail)
        // Set when the command is built, which `IPSession` does only once the turn has come and just before sending it:
        // a call cancelled in the queue, or still queued when the session ends, sent nothing and is counted apart.
        let sent = IPSentFlag()
        let answer: (reply: PTPIPConnection.Reply, data: Data, overflowed: Bool)
        do throws(PTPIPConnectionFailure) {
            answer = try await rawTransact(on: session, limit: Self.thumbnailLimit) {
                sent.mark()
                return PTPCommand.getThumb(handle, tx: $0)
            }
        } catch {
            if !sent.isSet {
                recorded.thumbnails.notSent += 1
            } else {
                recorded.thumbnails.asked += 1
                if case .timedOut = error { recorded.thumbnails.timeouts += 1 } else { recorded.thumbnails.otherFailures += 1 }
            }
            throw IPFailureMapping.failure(error, during: .thumbnail)
        }
        recorded.thumbnails.asked += 1
        guard answer.reply.code == .ok else {
            recorded.thumbnails.failuresByCode[answer.reply.code, default: 0] += 1
            throw await failure(answer.reply.code, during: .thumbnail, on: session)
        }
        if answer.overflowed {
            recorded.thumbnails.otherFailures += 1
            throw CameraLinkFailure(.unreadableItem, detail: "thumbnail: larger than 8 MiB")
        }
        guard answer.reply.dataIsComplete, !answer.data.isEmpty else {
            recorded.thumbnails.otherFailures += 1
            throw CameraLinkFailure(.noAnswer, detail: "thumbnail: short data phase")
        }
        recorded.thumbnails.answered += 1
        recorded.thumbnails.bytesTotal += UInt64(answer.data.count)
        if recorded.thumbnails.firstAfterOpen == nil { recorded.thumbnails.firstAfterOpen = sessionOpenedAt?.elapsed }
        return answer.data
    }

    /// Copies one file. A new file is GetObject, streamed into `directory` under the camera's file name (overwriting
    /// what was there), with `progress` called with the bytes written after each read; a partial file is continued
    /// with 0x9211 reads where the camera lists 0x9211 (see the type's notes, *Resume*), else ignored. A handle not
    /// confirmed by this session's GetObjectInfo (`list(reusing:)`, or an earlier session's listing) is confirmed
    /// first, and a file whose name or size changed is refused as `itemNotFound`. A failed fresh copy leaves no file
    /// behind unless the link resumes and some of it is on disk, which is kept and checkpointed.
    public func bytes(
        of item: CameraItem.ID,
        into directory: URL,
        resuming: PartialDownload?,
        checkpoint: @escaping @Sendable (PartialDownload) -> Void,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL {
        let session = try readySession(.download)
        let handle = try Self.handle(of: item, during: .download)
        activeDownloads += 1
        defer { activeDownloads -= 1 }
        let object = try await confirmedObject(handle, on: session)
        // The name comes from the camera (or whatever answers at its address): only a plain file name is written,
        // never a path that leads out of `directory`.
        guard IPListing.isSafeFileName(object.name) else {
            throw CameraLinkFailure(.unreadableItem, detail: "download: the camera's file name isn't a plain name")
        }
        let variant = partialReadVariant(objectSize: object.size)
        // Checkpoints only where a resume could start from them: 0x9211 listed and the object's end known.
        let checkpointing = variant != nil && IPPartialReader.canResume(objectSize: object.size) ? checkpoint : nil
        if let variant, let resuming {
            let start = IPPartialReader.start(offset: resuming.bytesWritten, fileLength: Self.length(of: resuming.file),
                                              objectSize: object.size)
            switch start {
            case let .resume(offset):
                if let url = try await continueFile(handle, at: resuming.file, from: offset, objectSize: object.size,
                                                    variant: variant, on: session, checkpoint: checkpoint,
                                                    progress: progress) {
                    return url
                }
                // The camera refused the first 0x9211 read with the session up and the card there: GetObject still
                // reads the file, so it is copied again from 0 into the same file, as `.restart` does.
                recorded.resumeFallbacks += 1
                trace(.resumeRefused(offset: offset))
                return try await getObject(handle, into: resuming.file, objectSize: object.size, on: session,
                                           checkpoint: checkpointing, progress: progress)
            case .complete:
                do {
                    let file = try FileHandle(forWritingTo: resuming.file)
                    defer { try? file.close() }
                    try file.truncate(atOffset: object.size)
                } catch {
                    throw Self.writeFailure(error)
                }
                progress(object.size)
                return resuming.file
            case .restart:
                // Copied again from 0 into the same file, as the contract says.
                return try await getObject(handle, into: resuming.file, objectSize: object.size, on: session,
                                           checkpoint: checkpointing, progress: progress)
            }
        }
        return try await getObject(handle, into: directory.appendingPathComponent(object.name, isDirectory: false),
                                   objectSize: object.size, on: session, checkpoint: checkpointing, progress: progress)
    }

    /// The file's name and size, from this session's GetObjectInfo: as recorded when confirmed, else asked now. A
    /// handle that names another file than the one recorded (another name or size) is refused: the card was swapped
    /// or the file replaced since the handle was learnt, and the file the caller meant isn't under it.
    private func confirmedObject(_ handle: PTPObjectHandle, on session: IPSession) async throws(CameraLinkFailure)
        -> KnownObject {
        if let known = objects[handle], known.confirmed { return known }
        let found = try await askInfo(handle, during: .download, on: session)
        guard record(found, for: handle) else {
            recorded.staleHandlesRefused += 1
            throw CameraLinkFailure(.itemNotFound, detail: "download: the handle names another file now")
        }
        return KnownObject(name: found.name, size: found.size, confirmed: true)
    }

    /// The byte-range variant for an object, from DeviceInfo: `.sonyLarge9211` when the camera lists 0x9211, else nil
    /// (`SonyCapabilities.partialReadVariant` for the whole-card session, never `PTPPartialRead.variant`, which would
    /// pick 0x101B: InvalidObjectHandle here).
    private func partialReadVariant(objectSize: UInt64) -> PTPPartialRead.Variant? {
        guard let deviceInfo,
              let variant = SonyCapabilities(deviceInfo: deviceInfo)
                  .partialReadVariant(objectSize: objectSize, in: .wholeCardContentsTransfer),
              deviceInfo.supports(PTPPartialRead.operationCode(for: variant)) else { return nil }
        return variant
    }

    /// GetObject into `url` (created or emptied). With `checkpoint` (the link resumes), a checkpoint each time the
    /// copy crosses a multiple of the chunk size, and on a break the bytes on disk are kept and checkpointed; without
    /// it, or with nothing on disk, a failed copy is removed.
    private func getObject(_ handle: PTPObjectHandle, into url: URL, objectSize: UInt64, on session: IPSession,
                           checkpoint: (@Sendable (PartialDownload) -> Void)?,
                           progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) -> URL {
        try requireListed(.getObject, during: .download)
        let file: IPFileSink
        do {
            file = try IPFileSink(url: url)
        } catch {
            throw Self.writeFailure(error)
        }
        let stride = UInt64(max(1, configuration.partialReadChunkSize))
        let reply: PTPIPConnection.Reply
        do throws(PTPIPConnectionFailure) {
            reply = try await session.perform(.transfer, sink: { data in
                guard let total = file.write(data) else { return }
                progress(total)
                if let checkpoint, file.reportCheckpoint(ifStreamCrosses: stride, objectSize: objectSize) {
                    checkpoint(PartialDownload(file: url, bytesWritten: total))
                }
            }) { counter in
                PTPCommand.getObject(handle, tx: counter.take())
            }
        } catch {
            keepOrDiscard(file, objectSize: objectSize, checkpoint: checkpoint)
            throw IPFailureMapping.failure(error, during: .download)
        }
        let written = file.finish()
        if let writeError = written.failure {
            keepOrDiscard(file, objectSize: objectSize, checkpoint: checkpoint)
            throw Self.writeFailure(writeError)
        }
        guard reply.code == .ok else {
            keepOrDiscard(file, objectSize: objectSize, checkpoint: checkpoint)
            throw await failure(reply.code, during: .download, on: session)
        }
        guard reply.dataIsComplete, reply.hadDataPhase else {
            keepOrDiscard(file, objectSize: objectSize, checkpoint: checkpoint)
            throw CameraLinkFailure(.noAnswer, detail: "download: data phase short (\(written.bytes) bytes)")
        }
        return url
    }

    /// A fresh copy broke off: on a link that resumes, the bytes on disk are kept and checkpointed (TCP delivers them
    /// in order, so they are the start of the file); otherwise, or with nothing written, the file is removed.
    private func keepOrDiscard(_ file: IPFileSink, objectSize: UInt64,
                               checkpoint: (@Sendable (PartialDownload) -> Void)?) {
        let written = file.finish().bytes
        guard let checkpoint, written > 0 else {
            file.discard()
            return
        }
        if file.reportCheckpoint(at: written, objectSize: objectSize) {
            checkpoint(PartialDownload(file: file.url, bytesWritten: written))
        }
    }

    /// Continues the partial file at `url` from `offset` with 0x9211 reads of the configured chunk size, each a
    /// transfer of its own that runs to its end if the caller is cancelled (`IPSession.Kind.chunk`), so a pause stops
    /// at a chunk boundary and keeps the session; `abortCurrentTransfer()` still cuts a chunk off. A checkpoint after
    /// each chunk but the last, and on a break (what arrived of the chunk). The file is kept whatever happens: what it
    /// holds up to the last checkpoint is good, and the next resume cuts it back to its offset.
    ///
    /// - Returns: The file, or nil when the camera refused the first read (a non-OK answer other than a missing card
    ///   or a lost session, `unverified` as possible): nothing was read, and the caller copies the file again.
    private func continueFile(_ handle: PTPObjectHandle, at url: URL, from offset: UInt64, objectSize: UInt64,
                              variant: PTPPartialRead.Variant, on session: IPSession,
                              checkpoint: @escaping @Sendable (PartialDownload) -> Void,
                              progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) -> URL? {
        let file: IPFileSink
        do {
            file = try IPFileSink(continuing: url, at: offset)
        } catch {
            throw Self.writeFailure(error)
        }
        recorded.resumes += 1
        trace(.resumeStarted(offset: offset, size: objectSize))
        var reads = 0
        var reader = IPPartialReader(offset: offset, objectSize: objectSize,
                                     chunkSize: configuration.partialReadChunkSize)
        /// Ends the copy on a failure, with a checkpoint at `resumable` if it is further than the last.
        func stop(at resumable: UInt64, _ failure: CameraLinkFailure) -> CameraLinkFailure {
            _ = file.finish()
            if file.reportCheckpoint(at: resumable, objectSize: objectSize) {
                checkpoint(PartialDownload(file: url, bytesWritten: resumable))
            }
            return failure
        }
        while let chunk = reader.nextChunk {
            recorded.partialReads += 1
            reads += 1
            let reply: PTPIPConnection.Reply
            do throws(PTPIPConnectionFailure) {
                reply = try await session.perform(.chunk, sink: { data in
                    if let total = file.write(data) { progress(total) }
                }) { counter in
                    Self.partialRead(handle, chunk: chunk, variant: variant, tx: counter.take())
                }
            } catch {
                let resumable = reader.checkpoint(afterBreakIn: chunk, written: file.written)
                throw stop(at: resumable, IPFailureMapping.failure(error, during: .download))
            }
            if let writeError = file.writeFailure {
                // Only bytes that were written count: `written` stops at the failed write.
                let resumable = reader.checkpoint(afterBreakIn: chunk, written: file.written)
                throw stop(at: resumable, Self.writeFailure(writeError))
            }
            guard reply.code == .ok else {
                let mapped = await failure(reply.code, during: .download, on: session)
                if reader.offset == offset, file.written == offset, Self.fallsBackToGetObject(after: mapped),
                   sessionReady, self.session === session, await session.isUsable {
                    _ = file.finish()
                    return nil
                }
                throw stop(at: reader.offset, mapped)
            }
            guard reply.dataIsComplete else {
                let resumable = reader.checkpoint(afterBreakIn: chunk, written: file.written)
                throw stop(at: resumable, CameraLinkFailure(
                    .noAnswer, detail: "download: 0x9211 data phase short at \(chunk.offset)"))
            }
            let arrived = file.written >= chunk.offset ? file.written - chunk.offset : 0
            switch reader.received(arrived, of: chunk) {
            case let .checkpoint(resumable):
                if file.reportCheckpoint(at: resumable, objectSize: objectSize) {
                    checkpoint(PartialDownload(file: url, bytesWritten: resumable))
                }
            case .complete:
                break
            case let .failed(reason):
                throw stop(at: reader.offset, CameraLinkFailure(.noAnswer, detail: "download: \(reason)"))
            }
        }
        if let closeError = file.finish().failure {
            throw stop(at: reader.offset, Self.writeFailure(closeError))
        }
        trace(.resumeFinished(reads: reads))
        return url
    }

    /// Whether a refused first 0x9211 read is worth a GetObject of the whole file: the camera refused the read itself
    /// (InvalidObjectHandle with the card there, OperationNotSupported, another error), not a missing card, a lost
    /// session, a busy camera or a short data phase, which the engine retries with the same partial.
    static func fallsBackToGetObject(after failure: CameraLinkFailure) -> Bool {
        switch failure.kind {
        case .itemNotFound, .unreadableItem, .modeListsNoFiles: true
        default: false
        }
    }

    /// The 0x9211 command for one chunk (`PTPPartialRead.command`, which throws only for the 32-bit variant, never
    /// chosen here; the five-parameter form is built directly should it ever).
    static func partialRead(_ handle: PTPObjectHandle, chunk: PTPPartialRead.Chunk, variant: PTPPartialRead.Variant,
                            tx: UInt32) -> PTPContainer {
        if let command = try? PTPPartialRead.command(handle, chunk: chunk, variant: variant, tx: tx) { return command }
        return PTPCommand.sonyGetPartialLargeObject(code: PTPOperationCode.sonySDIOGetPartialLargeObject.rawValue,
                                                    handle, offset: chunk.offset, length: UInt64(chunk.length), tx: tx)
    }

    /// The length of the file at `url`, or nil when there is none.
    static func length(of url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    // MARK: - Abort

    /// Cuts the connection off under the download in flight (the spike's `TransferAbort`, for the continued task's
    /// expiry, W13): its transaction stops at once, the call throws `disconnected` (a fresh copy's bytes on disk kept
    /// and checkpointed, a continued one's last chunk boundary or better), every other call waiting on the session
    /// fails the same way, and `.sessionLost` follows, so the next `open()` reopens. Does nothing when no download is
    /// under way, so an idle session survives.
    public func abortCurrentTransfer() async {
        guard activeDownloads > 0, sessionReady, let session, !closed else { return }
        recorded.transfersAborted += 1
        await session.abortTransfer()
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
            retiredDevicePropValueReads += await session.devicePropValueReads
            await session.close(sendingCloseSession: true)
        }
        fanOut.finish()
        if trace.isOn {
            let seen = await diagnostics
            trace(.linkClosed(seen))
        }
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
            await lose(session, because: "\(failure)", failure: failure)
        }
    }

    /// The open session ended under the link: `.sessionLost`, and it is dropped so the next `open()` reopens. While
    /// opening, the open's own calls fail and say why; only the current, open session is reported lost.
    private func lose(_ session: IPSession, because reason: String, failure: PTPIPConnectionFailure? = nil) async {
        guard sessionReady, self.session === session, !closed else { return }
        recorded.sessionsLost += 1
        recorded.lastLoss = reason
        trace(.linkLost(failure, thumbnails: recorded.thumbnails))
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
        do throws(PTPIPConnectionFailure) {
            return try await rawTransact(on: session, within: hold, timeout: timeout, limit: limit, command)
        } catch {
            throw IPFailureMapping.failure(error, during: operation)
        }
    }

    /// `transact`, with the connection's own failure.
    private func rawTransact(on session: IPSession, within hold: IPSession.Hold? = nil, timeout: Duration? = nil,
                             limit: Int, _ command: @escaping @Sendable (UInt32) -> PTPContainer)
        async throws(PTPIPConnectionFailure) -> (reply: PTPIPConnection.Reply, data: Data, overflowed: Bool) {
        let collector = IPDataCollector(limit: limit)
        let reply = try await session.perform(within: hold, timeout: timeout, sink: { collector.append($0) }) {
            counter in command(counter.take())
        }
        return (reply, collector.data, collector.overflowed)
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
/// Whether a transaction's command was built, so sent (`IPLink.thumbnail(of:)`'s counts).
final class IPSentFlag: Sendable {
    private let state = Mutex(false)

    func mark() { state.withLock { $0 = true } }

    var isSet: Bool { state.withLock { $0 } }
}

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
/// reports it. It also remembers the last checkpoint reported for the file, so each is reported once and in order.
final class IPFileSink: Sendable {
    private struct State {
        var handle: FileHandle?
        /// Bytes of the camera's file in this file: the offset continued from, plus what has been written since.
        var written: UInt64 = 0
        var failure: (any Error)?
        /// The last checkpoint reported (or the offset continued from).
        var reported: UInt64 = 0
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

    /// Opens an existing partial file to continue it: cut back to `offset` (whatever it held beyond is not trusted)
    /// and written from there.
    init(continuing url: URL, at offset: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: offset)
            try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw error
        }
        self.url = url
        state = Mutex(State(handle: handle, written: offset, reported: offset))
    }

    /// Appends `data`; returns the bytes in the file so far, or nil once a write has failed.
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

    /// The bytes in the file so far (only writes that succeeded).
    var written: UInt64 { state.withLock { $0.written } }

    /// The first write error, if any.
    var writeFailure: (any Error)? { state.withLock { $0.failure } }

    /// Whether a checkpoint at the bytes written so far is due during a whole-file copy
    /// (`IPPartialReader.streamCheckpointDue`); if so it counts as reported.
    func reportCheckpoint(ifStreamCrosses stride: UInt64, objectSize: UInt64) -> Bool {
        state.withLock { s in
            guard s.failure == nil,
                  IPPartialReader.streamCheckpointDue(previous: s.reported, current: s.written, objectSize: objectSize,
                                                      stride: stride) else { return false }
            s.reported = s.written
            return true
        }
    }

    /// Whether a checkpoint at `offset` is worth reporting: further than the last, inside the object, and on disk.
    /// If so it counts as reported.
    func reportCheckpoint(at offset: UInt64, objectSize: UInt64) -> Bool {
        state.withLock { s in
            guard offset > s.reported, offset < objectSize, offset <= s.written else { return false }
            s.reported = offset
            return true
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
