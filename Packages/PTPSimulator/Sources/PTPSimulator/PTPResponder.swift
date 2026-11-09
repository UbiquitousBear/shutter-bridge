import Foundation
import PTPKit

/// The simulated camera's PTP side, with no I/O: given a command container from an initiator, the reply a camera
/// would give, answered from a `ScriptedCard` with the captured α7C II datasets (backlog section 7). The PTP/IP
/// server (`PTPIPResponderCore`, and `PTPIPSimulatorServer` on Network.framework) carries these containers; tests can
/// also call it directly.
///
/// It answers GetDeviceInfo, OpenSession, CloseSession, GetStorageIDs, GetStorageInfo, GetObjectHandles,
/// GetObjectInfo, GetThumb, GetObject and GetPartialObject (0x101B, three parameters, as over USB in MTP), each only
/// if the flavour's DeviceInfo lists it. Anything else, listed or not (GetNumObjects, the MTP property operations),
/// answers OperationNotSupported, except Sony's SDIO operations in the PTP/IP flavour (below). Everything but
/// GetDeviceInfo, OpenSession, SDIO_OpenSession and CloseSession needs an open session (SessionNotOpen otherwise),
/// as ISO 15740 says.
///
/// **The PTP/IP flavour plays the camera's whole-card session** (Iteration 3, backlog section 2). Everything below is
/// `unverified` beyond what the spike measured, which is said where it applies: no fixture holds a 0x9210 to 0x9212
/// exchange, only the camera's answers (DeviceInfo, the 970-byte ExtDeviceInfo, the 0x4004 and 0x4005 events).
/// - A plain OpenSession lists nothing: GetStorageIDs answers StoreNotAvailable (measured), and so, unverified,
///   do GetStorageInfo and GetObjectHandles; the object operations answer InvalidObjectHandle.
/// - SDIO_OpenSession 0x9210 `[1, 1]` opens the whole-card session (`[sessionID, 1]`; function mode 0 opens a plain
///   one, unverified). Sending OpenSession as well answers SessionAlreadyOpen (0x201E), as the camera did.
/// - SDIO_Connect 0x9201 phases 1 to 3 answer OK with 8 zero bytes; SDIO_GetExtDeviceInfo 0x9202 answers the
///   captured 970 bytes (`Fixtures/a7c2/ptpip/sdio-extdeviceinfo.bin`) whatever version is asked, as a camera does
///   that falls back to its highest. Both work in a plain session too.
/// - SDIO_SetContentsTransferMode 0x9212 `[2, 0, 0]` then `[2, 1, 0]`: after `WholeCardBehaviour.readinessDelay` (300 ms, `unverified`) the
///   card appears (`advance(by:)`), announced by StoreAdded `[0x00010001]`; until then GetStorageIDs and
///   GetObjectHandles answer empty lists.
/// - 0x9211 takes five parameters (handle, offset low and high, length low and high) and reads a byte range.
///   Standard 0x101B and 0x9219 answer InvalidObjectHandle, as does GetObjectInfo of the buffer slot 0xFFFFC001
///   (measured, 2 Nov).
/// - GetDevicePropValue is never answered (`WholeCardBehaviour.getDevicePropValueNeverAnswers`).
/// - `dropCard()` and `restoreCard()` take the card away and bring it back; an idle session ends after
///   `WholeCardBehaviour.idleDropAfter`.
/// The USB flavour is unchanged.
public struct PTPResponder: Sendable {
    /// What a reply sends in its data phase (responder to initiator), produced on demand so a 40 MB object is never
    /// held in memory: the PTP/IP server reads it a packet at a time.
    public enum DataPhase: Sendable, Hashable {
        /// A dataset or array, already encoded.
        case bytes(Data)
        /// `length` bytes of an object's scripted content from `offset` (`ScriptedCard.content(of:in:)`).
        case object(PTPObjectHandle, offset: UInt64, length: UInt64)

        /// The data phase's length in bytes.
        public var length: UInt64 {
            switch self {
            case let .bytes(data): UInt64(data.count)
            case let .object(_, _, length): length
            }
        }

        /// Up to `count` bytes from `start`, counted from the start of the data phase; empty past the end.
        public func read(from start: UInt64, count: Int) -> Data {
            guard start < length, count > 0 else { return Data() }
            let end = min(length, start + UInt64(count))
            switch self {
            case let .bytes(data):
                return data.subdata(in: data.startIndex + Int(start) ..< data.startIndex + Int(end))
            case let .object(handle, offset, _):
                return ScriptedCard.content(of: handle, in: offset + start ..< offset + end)
            }
        }

        /// The whole data phase. For datasets and small objects; a server reads it in pieces with `read`.
        public var allBytes: Data { read(from: 0, count: Int(clamping: length)) }
    }

    /// The reply to one command: an optional data phase, then the response container.
    public struct Reply: Sendable, Equatable {
        public var data: DataPhase?
        /// A response container (type `.response`) with the command's transaction ID. Meaningless when `isSilent`.
        public var response: PTPContainer
        /// Events to send on the event channel after the response (StoreAdded when `[2, 1, 0]` makes the card
        /// appear at once).
        public var events: [PTPContainer] = []
        /// The camera sends no response at all (GetDevicePropValue in a whole-card session): the initiator's own
        /// timeout ends the wait.
        public var isSilent = false

        public var code: PTPResponseCode { response.responseCode }
    }

    /// How the simulator announces a new object.
    public enum ObjectAddedStyle: String, Sendable, Hashable, CaseIterable {
        /// ISO 15740's ObjectAdded (0x4002) with the new object's handle, transaction ID 0. The real camera sends no
        /// event over USB in either mode, and its MTP DeviceInfo doesn't list 0x4002; the simulator sends it so an
        /// initiator's handling of new objects can be tested.
        case standard
        /// What the α7C II sent over PTP/IP (`Fixtures/a7c2/ptpip/event-objectadded.bin`): Sony's 0xC201 with
        /// transaction ID 0xFFFFFFFF and one parameter, the buffer slot 0xFFFFC001, not the new object's handle.
        /// The simulator doesn't serve the slot itself: GetObjectInfo of 0xFFFFC001 answers InvalidObjectHandle (the
        /// camera's own answer in the whole-card session).
        case sonyBufferSlot
    }

    /// The buffer slot the α7C II named in its ObjectAdded over PTP/IP.
    public static let sonyBufferSlot = PTPObjectHandle(rawValue: 0xFFFF_C001)

    public let flavour: SimulatorFlavour
    public let deviceInfo: PTPDeviceInfo
    /// The StorageInfo template; free space is recomputed from the card where the template reports a capacity.
    public let storageInfo: PTPStorageInfo
    public var objectAddedStyle: ObjectAddedStyle
    public private(set) var card: ScriptedCard
    /// The open session's ID, nil without one.
    public private(set) var sessionID: UInt32?
    /// Every command answered, in order, for tests and logs.
    public private(set) var commandsAnswered: [PTPOperationCode] = []
    private var injected: [UInt16: [PTPResponseCode]] = [:]
    private var silenced: [UInt16: Int] = [:]
    /// How the PTP/IP flavour's whole-card session behaves and how long it takes (`WholeCardBehaviour`).
    public var wholeCard = WholeCardBehaviour()
    // Whole-card state, in WholeCardSession.swift (stored properties can't live in an extension).
    var wholeCardSession: WholeCardSession?
    /// Time since the last command of the open session.
    var idle: Duration = .zero

    /// A responder with the captured α7C II datasets of `flavour` (default MTP over USB, the flavour Iteration 1
    /// imports through).
    public init(card: ScriptedCard, flavour: SimulatorFlavour = .usbMTP,
                wholeCard: WholeCardBehaviour = WholeCardBehaviour()) throws(SimulatorFixtureError) {
        self.init(card: card, flavour: flavour, deviceInfo: try CapturedA7C2.deviceInfo(flavour),
                  storageInfo: try CapturedA7C2.storageInfo(flavour), wholeCard: wholeCard)
    }

    /// A responder with datasets of the caller's choosing, for a test that needs a camera unlike the α7C II.
    public init(card: ScriptedCard, flavour: SimulatorFlavour, deviceInfo: PTPDeviceInfo, storageInfo: PTPStorageInfo,
                objectAddedStyle: ObjectAddedStyle? = nil, wholeCard: WholeCardBehaviour = WholeCardBehaviour()) {
        self.wholeCard = wholeCard
        self.card = card
        self.flavour = flavour
        self.deviceInfo = deviceInfo
        self.storageInfo = storageInfo
        self.objectAddedStyle = objectAddedStyle ?? (flavour == .ptpIP ? .sonyBufferSlot : .standard)
    }

    // MARK: - Scripting

    /// The next `times` commands with this operation code answer `code` with no data phase, whatever they ask:
    /// DeviceBusy, an IncompleteTransfer, AccessDenied. Faults beyond these (drops, a slow link) are Iteration 2's.
    public mutating func inject(_ code: PTPResponseCode, forNext operation: PTPOperationCode, times: Int = 1) {
        injected[operation.rawValue, default: []] += Array(repeating: code, count: max(0, times))
    }

    /// The next `times` commands with this operation code get no response at all, as GetDevicePropValue gets in a
    /// whole-card session: the initiator's own reply limit ends the wait (a GetThumb the camera never answers, bench 19.1,
    /// `unverified` on the camera).
    public mutating func silence(forNext operation: PTPOperationCode, times: Int = 1) {
        silenced[operation.rawValue, default: 0] += max(0, times)
    }

    /// Shoots `frames` onto the card (`ScriptedCard.shootMore`) and returns the events to send, one per new object.
    public mutating func shoot(_ frames: [ScriptedCard.Frame], interval: Int = 2) -> [PTPContainer] {
        let added = card.shootMore(frames, interval: interval)
        return added.map(objectAddedEvent(for:))
    }

    /// Adds objects the caller made (their handles must be new) and returns the events to send.
    public mutating func add(_ objects: [ScriptedCard.Object]) -> [PTPContainer] {
        let fresh = objects.filter { card.object($0.handle) == nil }
        card.objects += fresh
        return fresh.map(objectAddedEvent(for:))
    }

    /// Puts another card in, with no event: the card swapped between sessions (the fault matrix's case). A new card
    /// numbers its handles from the same start, so a handle can name another file than it did. Do it with no session
    /// open, as a swap needs the camera off.
    public mutating func replaceCard(with card: ScriptedCard) {
        self.card = card
    }

    /// Ends the session without a CloseSession, as the camera does when the initiator's connection drops.
    public mutating func endSession() {
        sessionID = nil
        wholeCardSession = nil
        idle = .zero
    }

    private func objectAddedEvent(for object: ScriptedCard.Object) -> PTPContainer {
        switch objectAddedStyle {
        case .standard:
            PTPContainer(type: .event, code: PTPEventCode.objectAdded.rawValue, transactionID: 0,
                         parameters: [object.handle.rawValue])
        case .sonyBufferSlot:
            PTPContainer(type: .event, code: PTPEventCode.sonyObjectAdded.rawValue, transactionID: 0xFFFF_FFFF,
                         parameters: [Self.sonyBufferSlot.rawValue])
        }
    }

    // MARK: - Answering

    /// The reply to `command`. A container that isn't a command answers GeneralError; the transaction ID is echoed.
    public mutating func respond(to command: PTPContainer) -> Reply {
        let op = command.operationCode
        let tx = command.transactionID
        guard command.type == .command else { return reply(.generalError, tx) }
        commandsAnswered.append(op)
        idle = .zero
        if let left = silenced[op.rawValue], left > 0 {
            silenced[op.rawValue] = left > 1 ? left - 1 : nil
            var silent = reply(.ok, tx)
            silent.isSilent = true
            return silent
        }
        if var queue = injected[op.rawValue], !queue.isEmpty {
            let code = queue.removeFirst()
            injected[op.rawValue] = queue.isEmpty ? nil : queue
            return reply(code, tx)
        }
        // The camera never answers GetDevicePropValue in a whole-card session, though its DeviceInfo lists no
        // property and not the operation either (the spike's battery read hung the first download, B:69).
        if op == .getDevicePropValue, flavour == .ptpIP, wholeCardSession != nil, wholeCard.getDevicePropValueNeverAnswers {
            var silent = reply(.ok, tx)
            silent.isSilent = true
            return silent
        }
        guard Self.served.contains(op), deviceInfo.supports(op) else { return reply(.operationNotSupported, tx) }
        let p = command.parameters

        switch op {
        case .getDeviceInfo:
            return reply(.ok, tx, data: .bytes(deviceInfo.encode()))
        case .openSession:
            guard let id = p.first, id != 0 else { return reply(.invalidParameter, tx) }
            if let open = sessionID { return reply(.sessionAlreadyOpen, tx, parameters: [open]) }
            sessionID = id
            return reply(.ok, tx)
        case .sonySDIOOpenSession:
            // [session ID, function mode]: 1 is contents transfer (the whole card), 0 remote control, which lists
            // nothing (unverified). Answered SessionAlreadyOpen after an OpenSession, as the camera did.
            guard p.count >= 2, p[0] != 0, p[1] <= 1 else { return reply(.invalidParameter, tx) }
            if let open = sessionID { return reply(.sessionAlreadyOpen, tx, parameters: [open]) }
            sessionID = p[0]
            wholeCardSession = p[1] == 1 ? WholeCardSession() : nil
            return reply(.ok, tx)
        case .closeSession:
            guard sessionID != nil else { return reply(.sessionNotOpen, tx) }
            endSession()
            return reply(.ok, tx)
        default:
            break
        }

        guard sessionID != nil else { return reply(.sessionNotOpen, tx) }
        let access = cardAccess
        switch op {
        case .sonySDIOConnect:
            // [phase, 0, 0], phases 1 to 3: OK with 8 zero bytes each (measured).
            guard let phase = p.first, (1 ... 3).contains(phase) else { return reply(.invalidParameter, tx) }
            return reply(.ok, tx, data: .bytes(Data(count: 8)))

        case .sonySDIOGetExtDeviceInfo:
            // The camera's 970 bytes. Any version gets them: a camera that doesn't know the version answers with
            // its highest (unverified).
            guard let bytes = try? CapturedA7C2.sdioExtDeviceInfo() else {
                return reply(.generalError, tx)
            }
            return reply(.ok, tx, data: .bytes(bytes))

        case .sonySDIOSetContentsTransferMode:
            return setContentsTransferMode(p, tx: tx)

        case .getStorageIDs:
            switch access {
            case .listed: return reply(.ok, tx, data: .bytes(PTPStorageID.encodeArray([card.storageID])))
            case .notOffered: return reply(.storeNotAvailable, tx)
            case .indexing, .removed: return reply(.ok, tx, data: .bytes(PTPStorageID.encodeArray([])))
            }

        case .getStorageInfo:
            switch access {
            case .notOffered, .removed: return reply(.storeNotAvailable, tx)
            case .indexing: return reply(.invalidStorageID, tx)
            case .listed: break
            }
            guard p.first == card.storageID.rawValue else { return reply(.invalidStorageID, tx) }
            return reply(.ok, tx, data: .bytes(currentStorageInfo.encode()))

        case .getObjectHandles:
            let storage = p.count > 0 ? p[0] : PTPStorageID.all.rawValue
            let format = p.count > 1 ? p[1] : 0
            let parent = p.count > 2 ? p[2] : 0
            switch access {
            case .notOffered, .removed: return reply(.storeNotAvailable, tx)
            case .indexing, .listed: break
            }
            guard storage == PTPStorageID.all.rawValue || storage == card.storageID.rawValue else {
                return reply(.invalidStorageID, tx)
            }
            // No folder objects are served, so a parent filter (0xFFFFFFFF for the root, or a folder) can't be
            // answered honestly: ISO 15740's answer for an unsupported parameter.
            guard parent == 0 else { return reply(.parameterNotSupported, tx) }
            guard access == .listed else { return reply(.ok, tx, data: .bytes(PTPObjectHandle.encodeArray([]))) }
            let handles = card.objects.filter { format == 0 || UInt32($0.format.rawValue) == format }.map(\.handle)
            return reply(.ok, tx, data: .bytes(PTPObjectHandle.encodeArray(handles)))

        case .getObjectInfo:
            if let refusal = objectRefusal(access, tx) { return refusal }
            guard let h = p.first.map(PTPObjectHandle.init(rawValue:)), let info = card.objectInfo(for: h) else {
                return reply(.invalidObjectHandle, tx)
            }
            return reply(.ok, tx, data: .bytes(info.encode()))

        case .getThumb:
            if let refusal = objectRefusal(access, tx) { return refusal }
            guard let h = p.first.map(PTPObjectHandle.init(rawValue:)), card.object(h) != nil else {
                return reply(.invalidObjectHandle, tx)
            }
            guard let thumb = card.thumbnail(for: h) else { return reply(.noThumbnailPresent, tx) }
            return reply(.ok, tx, data: .bytes(thumb))

        case .getObject:
            if let refusal = objectRefusal(access, tx) { return refusal }
            guard let h = p.first.map(PTPObjectHandle.init(rawValue:)), let o = card.object(h) else {
                return reply(.invalidObjectHandle, tx)
            }
            return reply(.ok, tx, data: .object(h, offset: 0, length: o.size))

        case .getPartialObject:
            // The PTP/IP flavour refuses 0x101B whatever the parameters: InvalidObjectHandle in the whole-card
            // session (measured, 3 and 4 parameters); the same elsewhere is unverified.
            if flavour == .ptpIP { return reply(.invalidObjectHandle, tx) }
            // ISO 15740's three parameters: handle, offset, length (0xFFFFFFFF: to the end). The response's first
            // parameter is the number of bytes sent.
            guard p.count >= 3 else { return reply(.invalidParameter, tx) }
            guard let o = card.object(PTPObjectHandle(rawValue: p[0])) else { return reply(.invalidObjectHandle, tx) }
            let offset = UInt64(p[1])
            guard offset <= o.size else { return reply(.invalidParameter, tx) }
            let wanted = p[2] == UInt32.max ? o.size - offset : UInt64(p[2])
            let length = min(wanted, o.size - offset)
            return reply(.ok, tx, parameters: [UInt32(clamping: length)],
                         data: .object(o.handle, offset: offset, length: length))

        case .sonySDIOGetPartialLargeObject:
            // Five parameters: handle, offset low, offset high, length low, length high (length all ones: to the
            // end). The layout is the spike's; the reads matched GetObject byte for byte (measured). No parameter
            // comes back in the response (unverified): a short read is the data phase's length.
            if let refusal = objectRefusal(access, tx) { return refusal }
            guard p.count >= 5 else { return reply(.invalidParameter, tx) }
            guard let o = card.object(PTPObjectHandle(rawValue: p[0])) else { return reply(.invalidObjectHandle, tx) }
            let offset = UInt64(p[2]) << 32 | UInt64(p[1])
            let wanted = UInt64(p[4]) << 32 | UInt64(p[3])
            guard offset <= o.size else { return reply(.invalidParameter, tx) }
            let length = min(wanted, o.size - offset)
            return reply(.ok, tx, data: .object(o.handle, offset: offset, length: length))

        case .sonySDIO0x9219:
            // InvalidObjectHandle in a whole-card session (measured); the same in a plain one is unverified.
            return reply(.invalidObjectHandle, tx)

        default:
            return reply(.operationNotSupported, tx)
        }
    }

    /// The operations the simulator implements. Sony's SDIO operations answer only where the flavour's DeviceInfo
    /// lists them: the PTP/IP flavour, not USB.
    public static let served: Set<PTPOperationCode> = [
        .getDeviceInfo, .openSession, .closeSession, .getStorageIDs, .getStorageInfo, .getObjectHandles,
        .getObjectInfo, .getThumb, .getObject, .getPartialObject,
        .sonySDIOOpenSession, .sonySDIOConnect, .sonySDIOGetExtDeviceInfo, .sonySDIOSetContentsTransferMode,
        .sonySDIOGetPartialLargeObject, .sonySDIO0x9219,
    ]

    /// The refusal a card's object operation gets when the card isn't listing, nil when it is. After the card was
    /// dropped it is StoreNotAvailable: measured only for GetObject (B:208), and on 3 Nov the camera also answered
    /// InvalidObjectHandle after StoreRemoved, so which one a drop gives is not settled. For GetObjectInfo,
    /// GetThumb, 0x9211 and GetObjectHandles, and for GetStorageIDs answering an empty list after a drop, StoreNotAvailable
    /// is the simulator's choice (`unverified`). Where no handle has been offered it is InvalidObjectHandle
    /// (`unverified`).
    private func objectRefusal(_ access: CardAccess, _ tx: UInt32) -> Reply? {
        switch access {
        case .listed: nil
        case .removed: reply(.storeNotAvailable, tx)
        case .notOffered, .indexing: reply(.invalidObjectHandle, tx)
        }
    }

    /// The StorageInfo template with free space as the card leaves it, where the template has a capacity (the PTP/IP
    /// flavour reports 0 for both, as the camera does, and is sent unchanged).
    public var currentStorageInfo: PTPStorageInfo {
        var info = storageInfo
        guard info.maxCapacity > 0 else { return info }
        let used = card.objects.reduce(UInt64(0)) { $0 &+ $1.size }
        info.freeSpaceInBytes = used >= info.maxCapacity ? 0 : info.maxCapacity - used
        return info
    }

    func reply(_ code: PTPResponseCode, _ tx: UInt32, parameters: [UInt32] = [],
               data: DataPhase? = nil) -> Reply {
        Reply(data: data,
              response: PTPContainer(type: .response, code: code.rawValue, transactionID: tx, parameters: parameters))
    }
}
