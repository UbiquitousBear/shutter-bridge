// The generic PTP container (ISO 15740 §9.3.1) used on USB and, with PTP/IP framing stripped,
// as the unit `ICCameraDevice.requestSendPTPCommand` exchanges on iOS.
//
//   u32 length   (whole container, header included)
//   u16 type     (1 command, 2 data, 3 response, 4 event)
//   u16 code     (operation / response / event code)
//   u32 transactionID
//   payload      (up to 5 × u32 parameters for command/response/event; raw bytes for data)

import Foundation

public struct PTPContainer: Equatable, Sendable {
    public static let headerLength = 12

    public var type: PTPContainerType
    public var code: UInt16
    public var transactionID: UInt32
    public var payload: Data

    public init(type: PTPContainerType, code: UInt16, transactionID: UInt32, payload: Data = Data()) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    public init(type: PTPContainerType, code: UInt16, transactionID: UInt32, parameters: [UInt32]) {
        var w = PTPWriter()
        for p in parameters { w.u32(p) }
        self.init(type: type, code: code, transactionID: transactionID, payload: w.data)
    }

    public var length: UInt32 { UInt32(Self.headerLength + payload.count) }

    /// Parameters, for command/response/event containers. Ignores a trailing partial word.
    public var parameters: [UInt32] {
        var r = PTPReader(payload)
        var out: [UInt32] = []
        while r.remaining >= 4, let v = try? r.u32() { out.append(v) }
        return out
    }

    public var operationCode: PTPOperationCode { PTPOperationCode(rawValue: code) }
    public var responseCode: PTPResponseCode { PTPResponseCode(rawValue: code) }
    public var eventCode: PTPEventCode { PTPEventCode(rawValue: code) }

    public func encode() -> Data {
        var w = PTPWriter()
        w.u32(length)
        w.u16(type.rawValue)
        w.u16(code)
        w.u32(transactionID)
        w.bytes(payload)
        return w.data
    }

    /// Decodes one container from the start of `data`. Tolerates trailing bytes (returns the consumed length).
    public static func decode(_ data: Data) throws -> (container: PTPContainer, consumed: Int) {
        var r = PTPReader(data)
        let length = try r.u32()
        guard length >= UInt32(headerLength), Int(length) <= data.count else {
            throw PTPDecodingError.badContainerLength(length)
        }
        let rawType = try r.u16()
        guard let type = PTPContainerType(rawValue: rawType) else {
            throw PTPDecodingError.unknownContainerType(rawType)
        }
        let code = try r.u16()
        let tx = try r.u32()
        let payload = try r.bytes(Int(length) - headerLength)
        return (PTPContainer(type: type, code: code, transactionID: tx, payload: payload), Int(length))
    }

    /// Decodes a buffer that may hold several containers back to back (as a USB pass-through reply can).
    public static func decodeAll(_ data: Data) throws -> [PTPContainer] {
        var out: [PTPContainer] = []
        var cursor = data
        while !cursor.isEmpty {
            let (c, n) = try decode(cursor)
            out.append(c)
            cursor = cursor.subdata(in: cursor.startIndex + n ..< cursor.endIndex)
        }
        return out
    }
}

// MARK: - Command builders

public enum PTPCommand {
    public static func getDeviceInfo(tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getDeviceInfo.rawValue, transactionID: tx, parameters: [])
    }

    public static func openSession(sessionID: UInt32, tx: UInt32 = 0) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.openSession.rawValue, transactionID: tx, parameters: [sessionID])
    }

    public static func closeSession(tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.closeSession.rawValue, transactionID: tx, parameters: [])
    }

    public static func getStorageIDs(tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getStorageIDs.rawValue, transactionID: tx, parameters: [])
    }

    public static func getStorageInfo(_ storage: PTPStorageID, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getStorageInfo.rawValue, transactionID: tx, parameters: [storage.rawValue])
    }

    public static func getNumObjects(storage: PTPStorageID = .all, format: PTPObjectFormat? = nil, parent: PTPObjectHandle? = nil, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getNumObjects.rawValue, transactionID: tx,
                     parameters: [storage.rawValue, UInt32(format?.rawValue ?? 0), parent?.rawValue ?? 0])
    }

    /// `parent == nil` means all objects in the store; `.root` means the root folder only.
    public static func getObjectHandles(storage: PTPStorageID = .all, format: PTPObjectFormat? = nil, parent: PTPObjectHandle? = nil, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getObjectHandles.rawValue, transactionID: tx,
                     parameters: [storage.rawValue, UInt32(format?.rawValue ?? 0), parent?.rawValue ?? 0])
    }

    public static func getObjectInfo(_ handle: PTPObjectHandle, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getObjectInfo.rawValue, transactionID: tx, parameters: [handle.rawValue])
    }

    public static func getObject(_ handle: PTPObjectHandle, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getObject.rawValue, transactionID: tx, parameters: [handle.rawValue])
    }

    public static func getThumb(_ handle: PTPObjectHandle, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getThumb.rawValue, transactionID: tx, parameters: [handle.rawValue])
    }

    public static func getDevicePropValue(_ prop: PTPDevicePropCode, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getDevicePropValue.rawValue, transactionID: tx, parameters: [UInt32(prop.rawValue)])
    }

    public static func getDevicePropDesc(_ prop: PTPDevicePropCode, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getDevicePropDesc.rawValue, transactionID: tx, parameters: [UInt32(prop.rawValue)])
    }

    /// Sony SDIO_Connect (libgphoto2's three-phase handshake for PC Remote mode): phase 1, 2, 3. `unverified` on
    /// the α7C II. Has a data phase (responder → initiator) that libgphoto2 discards.
    public static func sonySDIOConnect(phase: UInt32, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.sonySDIOConnect.rawValue, transactionID: tx, parameters: [phase, 0, 0])
    }

    /// Sony SDIO_GetExtDeviceInfo: `version` is the protocol version asked for (0xC8 = 2.00, 0x12C = 3.00); a
    /// camera that doesn't support it answers with its highest. `unverified` on the α7C II.
    public static func sonySDIOGetExtDeviceInfo(version: UInt32 = 0x12C, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.sonySDIOGetExtDeviceInfo.rawValue, transactionID: tx, parameters: [version, 1])
    }

    /// ISO 15740 GetPartialObject: 32-bit offset and length. `length == 0xFFFFFFFF` means "to the end".
    public static func getPartialObject(_ handle: PTPObjectHandle, offset: UInt32, length: UInt32, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getPartialObject.rawValue, transactionID: tx,
                     parameters: [handle.rawValue, offset, length])
    }

    /// MTP GetPartialObject64: 64-bit offset split low/high, 32-bit length.
    public static func getPartialObject64(_ handle: PTPObjectHandle, offset: UInt64, length: UInt32, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getPartialObject64.rawValue, transactionID: tx,
                     parameters: [handle.rawValue, UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32), length])
    }
}

/// Monotonic transaction IDs for one session. PTP requires them to start at 1 after OpenSession
/// (which itself is sent with 0) and increase by one per operation.
public struct PTPTransactionCounter: Sendable {
    private var next: UInt32
    public init() { next = 1 }
    /// For tests and for resuming a counter; 0 is reserved for OpenSession and becomes 1.
    public init(next: UInt32) { self.next = next == 0 ? 1 : next }
    /// The ID the next `take()` will return.
    public var peek: UInt32 { next }
    public mutating func take() -> UInt32 {
        defer { next = next == UInt32.max ? 1 : next + 1 }
        return next
    }
}
