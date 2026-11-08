import Foundation
import PTPKit

/// The simulated camera's PTP side, with no I/O: given a command container from an initiator, the reply a camera
/// would give, answered from a `ScriptedCard` with the captured α7C II datasets (backlog section 7). The PTP/IP
/// server (`PTPIPResponderCore`, and `PTPIPSimulatorServer` on Network.framework) carries these containers; tests can
/// also call it directly.
///
/// It answers GetDeviceInfo, OpenSession, CloseSession, GetStorageIDs, GetStorageInfo, GetObjectHandles,
/// GetObjectInfo, GetThumb, GetObject and GetPartialObject (0x101B, three parameters, as over USB in MTP), each only
/// if the flavour's DeviceInfo lists it. Anything else, listed or not (GetNumObjects, the MTP property operations,
/// Sony's SDIO operations), answers OperationNotSupported. Everything but GetDeviceInfo, OpenSession and CloseSession
/// needs an open session (SessionNotOpen otherwise), as ISO 15740 says.
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
        /// A response container (type `.response`) with the command's transaction ID.
        public var response: PTPContainer

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
        /// The simulator doesn't serve the slot itself (GetObjectInfo of 0xFFFFC001 answers InvalidObjectHandle);
        /// that comes with the Wi-Fi behaviour in Iteration 3.
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

    /// A responder with the captured α7C II datasets of `flavour` (default MTP over USB, the flavour Iteration 1
    /// imports through).
    public init(card: ScriptedCard, flavour: SimulatorFlavour = .usbMTP) throws(SimulatorFixtureError) {
        self.init(card: card, flavour: flavour, deviceInfo: try CapturedA7C2.deviceInfo(flavour),
                  storageInfo: try CapturedA7C2.storageInfo(flavour))
    }

    /// A responder with datasets of the caller's choosing, for a test that needs a camera unlike the α7C II.
    public init(card: ScriptedCard, flavour: SimulatorFlavour, deviceInfo: PTPDeviceInfo, storageInfo: PTPStorageInfo,
                objectAddedStyle: ObjectAddedStyle? = nil) {
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

    /// Ends the session without a CloseSession, as the camera does when the initiator's connection drops.
    public mutating func endSession() { sessionID = nil }

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
        if var queue = injected[op.rawValue], !queue.isEmpty {
            let code = queue.removeFirst()
            injected[op.rawValue] = queue.isEmpty ? nil : queue
            return reply(code, tx)
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
        case .closeSession:
            guard sessionID != nil else { return reply(.sessionNotOpen, tx) }
            sessionID = nil
            return reply(.ok, tx)
        default:
            break
        }

        guard sessionID != nil else { return reply(.sessionNotOpen, tx) }
        switch op {
        case .getStorageIDs:
            return reply(.ok, tx, data: .bytes(PTPStorageID.encodeArray([card.storageID])))

        case .getStorageInfo:
            guard p.first == card.storageID.rawValue else { return reply(.invalidStorageID, tx) }
            return reply(.ok, tx, data: .bytes(currentStorageInfo.encode()))

        case .getObjectHandles:
            let storage = p.count > 0 ? p[0] : PTPStorageID.all.rawValue
            let format = p.count > 1 ? p[1] : 0
            let parent = p.count > 2 ? p[2] : 0
            guard storage == PTPStorageID.all.rawValue || storage == card.storageID.rawValue else {
                return reply(.invalidStorageID, tx)
            }
            // No folder objects are served, so a parent filter (0xFFFFFFFF for the root, or a folder) can't be
            // answered honestly: ISO 15740's answer for an unsupported parameter.
            guard parent == 0 else { return reply(.parameterNotSupported, tx) }
            let handles = card.objects.filter { format == 0 || UInt32($0.format.rawValue) == format }.map(\.handle)
            return reply(.ok, tx, data: .bytes(PTPObjectHandle.encodeArray(handles)))

        case .getObjectInfo:
            guard let h = p.first.map(PTPObjectHandle.init(rawValue:)), let info = card.objectInfo(for: h) else {
                return reply(.invalidObjectHandle, tx)
            }
            return reply(.ok, tx, data: .bytes(info.encode()))

        case .getThumb:
            guard let h = p.first.map(PTPObjectHandle.init(rawValue:)), card.object(h) != nil else {
                return reply(.invalidObjectHandle, tx)
            }
            guard let thumb = card.thumbnail(for: h) else { return reply(.noThumbnailPresent, tx) }
            return reply(.ok, tx, data: .bytes(thumb))

        case .getObject:
            guard let h = p.first.map(PTPObjectHandle.init(rawValue:)), let o = card.object(h) else {
                return reply(.invalidObjectHandle, tx)
            }
            return reply(.ok, tx, data: .object(h, offset: 0, length: o.size))

        case .getPartialObject:
            // ISO 15740's three parameters: handle, offset, length (0xFFFFFFFF: to the end). The response's first
            // parameter is the number of bytes sent. Sony's four-parameter variant and the camera's PTP/IP refusal
            // in a contents-transfer session are Iteration 3's.
            guard p.count >= 3 else { return reply(.invalidParameter, tx) }
            guard let o = card.object(PTPObjectHandle(rawValue: p[0])) else { return reply(.invalidObjectHandle, tx) }
            let offset = UInt64(p[1])
            guard offset <= o.size else { return reply(.invalidParameter, tx) }
            let wanted = p[2] == UInt32.max ? o.size - offset : UInt64(p[2])
            let length = min(wanted, o.size - offset)
            return reply(.ok, tx, parameters: [UInt32(clamping: length)],
                         data: .object(o.handle, offset: offset, length: length))

        default:
            return reply(.operationNotSupported, tx)
        }
    }

    /// The operations the simulator implements.
    public static let served: Set<PTPOperationCode> = [
        .getDeviceInfo, .openSession, .closeSession, .getStorageIDs, .getStorageInfo, .getObjectHandles,
        .getObjectInfo, .getThumb, .getObject, .getPartialObject,
    ]

    /// The StorageInfo template with free space as the card leaves it, where the template has a capacity (the PTP/IP
    /// flavour reports 0 for both, as the camera does, and is sent unchanged).
    public var currentStorageInfo: PTPStorageInfo {
        var info = storageInfo
        guard info.maxCapacity > 0 else { return info }
        let used = card.objects.reduce(UInt64(0)) { $0 &+ $1.size }
        info.freeSpaceInBytes = used >= info.maxCapacity ? 0 : info.maxCapacity - used
        return info
    }

    private func reply(_ code: PTPResponseCode, _ tx: UInt32, parameters: [UInt32] = [],
                       data: DataPhase? = nil) -> Reply {
        Reply(data: data,
              response: PTPContainer(type: .response, code: code.rawValue, transactionID: tx, parameters: parameters))
    }
}
