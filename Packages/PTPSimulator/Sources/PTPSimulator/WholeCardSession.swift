import Foundation
import PTPKit

/// How the simulated α7C II behaves in Sony's whole-card session over PTP/IP, with the timings the spike measured on
/// the real camera (docs/iteration-3-4-backlog.md, sections 2, 4 and 9). Time never passes by itself: a test or the
/// server calls `PTPResponder.advance(by:)` (`PTPIPResponderCore.advance(by:)`, `PTPIPSimulatorServer.advance(by:)`)
/// with however much time has gone by, so a suite on a loaded runner doesn't race a clock.
///
/// Everything here follows the PTP/IP flavour (`SimulatorFlavour.ptpIP`); the responder in the USB flavour ignores it,
/// as the real camera's MTP mode has no whole-card session. `firstInitAckDelay` belongs to the PTP/IP transport, not
/// to a flavour: `PTPIPResponderCore` applies it to whatever responder it serves.
public struct WholeCardBehaviour: Sendable, Equatable {
    /// From the second `SDIO_SetContentsTransferMode` (`[2, 1, 0]`) to the card appearing: StoreAdded
    /// `[0x00010001]` is sent and the handles list; until then GetObjectHandles answers an empty list, as the camera
    /// did while it indexed the card. `unverified` as a time from `[2, 1, 0]`. What was measured is the span from
    /// SDIO_OpenSession to the first poll, 1.96 to 2.61 s over Wi-Fi (2 to 4 Nov, backlog section 2), mostly the
    /// sequence's own waits (200 ms and 1.5 s, 1.7 s in all), and every fresh session was ready at that first poll:
    /// StoreAdded arrived during the 1.5 s pause. So the default is shorter than that pause, and the simulator's
    /// operations take no time of their own; a test of the empty first poll sets a longer delay. A reopen was not
    /// shown to be quicker (spike-findings.md), so there is no second delay for one. The time at a larger card is
    /// unmeasured.
    public var readinessDelay: Duration = .milliseconds(300)
    /// How long the camera holds back its Init_Command_Ack for a connection (a property of the PTP/IP transport,
    /// whatever the responder's flavour). Zero by default. The only measurement is a recovery on the camera's own
    /// network after a Wi-Fi restart (4 Nov 01:08: camera off and on, Bluetooth switch-on, join): the camera started
    /// answering 40.7 s after the Bluetooth status turned 2. Whether that was a held ack or the port not being
    /// reachable until then is unknown. A test of a slow connection sets 40 s. Only the first Init_Command_Request
    /// after the core is made, or after `PTPIPResponderCore.dropAll()` (a Wi-Fi restart), is held, or the next one
    /// that `PTPIPResponderCore.holdNextInitAck(for:)` names; any other is answered at once.
    public var firstInitAckDelay: Duration = .zero
    /// An open PTP/IP session with no command for this long is dropped, both channels closed. `unverified`: the
    /// Imagedge code reports about 30 s on a ZV-E10 and the spike's keep-alive (GetDeviceInfo every 10 s) kept
    /// sessions up, but the α7C II's own drop has not been separated from iOS closing a suspended app's sockets
    /// (backlog B:117). Nil turns the drop off.
    public var idleDropAfter: Duration? = .seconds(30)
    /// GetDevicePropValue is never answered in a whole-card session: the spike's first download hung on a battery read
    /// (0x5001) and the camera lists no properties (the build-9 trap, backlog B:69). When true the responder's reply
    /// is silent (`PTPResponder.Reply.isSilent`) and an initiator's own timeout is what ends the wait.
    public var getDevicePropValueNeverAnswers = true

    public init() {}
}

/// The state of an open whole-card session (SDIO_OpenSession 0x9210 `[1, 1]`), kept by `PTPResponder`.
struct WholeCardSession: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// 0x9210 answered. GetStorageIDs answers StoreNotAvailable, as in the spike's init sequence.
        case opened
        /// SDIO_SetContentsTransferMode `[2, 0, 0]` answered; the card is not offered yet.
        case armed
        /// `[2, 1, 0]` answered; the card appears when `remaining` has gone by.
        case indexing(remaining: Duration)
        /// StoreAdded has been sent: the card lists.
        case ready
        /// `dropCard()`: StoreRemoved has been sent, the card's operations answer StoreNotAvailable.
        case cardRemoved
    }

    var phase: Phase = .opened
}

/// What a flavour's session shows of the card to an operation that needs it.
enum CardAccess: Sendable, Equatable {
    /// The card lists and is read (USB, and a ready whole-card session).
    case listed
    /// A plain PTP/IP session, or a whole-card one before `[2, 1, 0]`: GetStorageIDs answers StoreNotAvailable
    /// (measured for a plain session, with or without the init sequence).
    case notOffered
    /// After `[2, 1, 0]`, before StoreAdded: empty lists (unverified: the spike saw empty early replies).
    case indexing
    /// After `dropCard()`.
    case removed
}

extension PTPResponder {
    /// The storage whose arrival and removal the camera's events name (fixture `event-4004.bin`, `event-4005.bin`:
    /// transaction ID 0xFFFFFFFF, one parameter).
    private func storeEvent(_ code: PTPEventCode) -> PTPContainer {
        PTPContainer(type: .event, code: code.rawValue, transactionID: 0xFFFF_FFFF, parameters: [card.storageID.rawValue])
    }

    func storeAddedEvent() -> PTPContainer { storeEvent(.storeAdded) }

    /// The camera drops its card, as on 3 Nov and 4 Nov: StoreRemoved is sent (returned here, for the caller to
    /// put on the event channel), and from then on every operation that needs the card answers StoreNotAvailable,
    /// GetObject included (backlog B:208). Acts only in a whole-card session whose card is offered; elsewhere it
    /// does nothing and returns no events. The real camera also switched its Wi-Fi off about 6 s later; call
    /// `PTPIPResponderCore.dropAll()` for that. A new session starts with the card back (the spike's reopen found
    /// all 298 files under the same handles).
    public mutating func dropCard() -> [PTPContainer] {
        guard var session = wholeCardSession else { return [] }
        switch session.phase {
        case .opened, .armed, .cardRemoved:
            return []
        case .indexing, .ready:
            session.phase = .cardRemoved
            wholeCardSession = session
            return [storeEvent(.storeRemoved)]
        }
    }

    /// The card comes back after `dropCard()`: StoreAdded `[0x00010001]` (returned, for the event channel) and the
    /// card lists again. Does nothing when the card hasn't been dropped.
    public mutating func restoreCard() -> [PTPContainer] {
        guard var session = wholeCardSession, session.phase == .cardRemoved else { return [] }
        session.phase = .ready
        wholeCardSession = session
        return [storeAddedEvent()]
    }

    /// Lets `elapsed` time go by: the card appears once the readiness delay is over (StoreAdded in the result), and
    /// a PTP/IP session that has been idle for `wholeCard.idleDropAfter` ends (`sessionDropped`; the caller closes
    /// its connections). The idle time counts from the last command and starts again with every one.
    public mutating func advance(by elapsed: Duration) -> Advance {
        var result = Advance()
        guard elapsed > .zero, sessionID != nil else { return result }
        var usable = elapsed
        var drops = false
        if flavour == .ptpIP, let limit = wholeCard.idleDropAfter {
            let untilDrop = max(.zero, limit - idle)
            if untilDrop <= elapsed {
                usable = untilDrop
                drops = true
            }
        }
        idle += usable
        if var session = wholeCardSession, case let .indexing(remaining) = session.phase {
            if remaining <= usable {
                session.phase = .ready
                result.events.append(storeAddedEvent())
            } else {
                session.phase = .indexing(remaining: remaining - usable)
            }
            wholeCardSession = session
        }
        if drops {
            endSession()
            result.sessionDropped = true
        }
        return result
    }

    /// What happened while time passed.
    public struct Advance: Sendable, Equatable {
        /// Events to send on the event channel, in order.
        public var events: [PTPContainer] = []
        /// The idle drop ended the session: close both channels.
        public var sessionDropped = false
    }

    /// Whether the open session is a whole-card one (opened with SDIO_OpenSession `[1, 1]`).
    public var isWholeCardSession: Bool { wholeCardSession != nil }

    /// Whether the card is listing now: always in the USB flavour, in the PTP/IP flavour only in a whole-card session
    /// that has had StoreAdded and not lost the card since.
    public var cardIsListed: Bool { cardAccess == .listed }

    var cardAccess: CardAccess {
        guard flavour == .ptpIP else { return .listed }
        guard let session = wholeCardSession else { return .notOffered }
        switch session.phase {
        case .opened, .armed: return .notOffered
        case .indexing: return .indexing
        case .ready: return .listed
        case .cardRemoved: return .removed
        }
    }

    /// SDIO_SetContentsTransferMode in a whole-card session. `[2, 0, 0]` then `[2, 1, 0]` are the whole-card steps
    /// (the spike's, 200 ms apart); `[2, 1, 0]` starts the card's arrival. `[1, 0, 0]`, Sony's set of photos
    /// selected on the camera, is not simulated. A non-whole-card session answers OperationNotSupported
    /// (`unverified`: the real answer is not recorded).
    mutating func setContentsTransferMode(_ p: [UInt32], tx: UInt32) -> Reply {
        guard var session = wholeCardSession else { return reply(.operationNotSupported, tx) }
        guard p.count >= 3 else { return reply(.invalidParameter, tx) }
        switch (p[0], p[1], p[2]) {
        case (2, 0, 0):
            if session.phase == .opened { session.phase = .armed }
            wholeCardSession = session
            return reply(.ok, tx)
        case (2, 1, 0):
            switch session.phase {
            case .opened, .armed:
                let delay = wholeCard.readinessDelay
                var response = reply(.ok, tx)
                if delay <= .zero {
                    session.phase = .ready
                    response.events = [storeAddedEvent()]
                } else {
                    session.phase = .indexing(remaining: delay)
                }
                wholeCardSession = session
                return response
            case .indexing, .ready, .cardRemoved:
                // Asked again: nothing changes.
                return reply(.ok, tx)
            }
        case (1, _, _):
            return reply(.parameterNotSupported, tx)
        default:
            return reply(.invalidParameter, tx)
        }
    }
}
