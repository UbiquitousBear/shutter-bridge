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

    /// Sony SDIO_Connect (libgphoto2's three-phase handshake for PC Remote mode): phase 1, 2, 3. The code is listed in
    /// the α7C II's PTP/IP DeviceInfo; the parameters are `unverified` (a fixture holds replies, not requests), though
    /// the spike saw all three phases answer OK. Has a data phase (responder → initiator) that libgphoto2 discards.
    public static func sonySDIOConnect(phase: UInt32, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.sonySDIOConnect.rawValue, transactionID: tx, parameters: [phase, 0, 0])
    }

    /// Sony SDIO_GetExtDeviceInfo: `version` is the protocol version asked for (0xC8 = 2.00, 0x12C = 3.00); a
    /// camera that doesn't support it answers with its highest. The reply to 0x12C is a fixture (see
    /// `PTPOperationCode.sonySDIOGetExtDeviceInfo`); the parameters are `unverified` on the α7C II.
    public static func sonySDIOGetExtDeviceInfo(version: UInt32 = 0x12C, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.sonySDIOGetExtDeviceInfo.rawValue, transactionID: tx, parameters: [version, 1])
    }

    /// Sony SDIO_OpenSession (0x9210), sent instead of OpenSession (0x1002). `functionMode` 1 = contents transfer
    /// (whole card), 0 = remote control. No data phase. The code is listed in the α7C II's PTP/IP DeviceInfo; the
    /// parameters are `unverified` there (the spike's [1, 1] answered OK); source: mvpzac/Imagedge (field-tested on a ZV-E10).
    public static func sonySDIOOpenSession(sessionID: UInt32 = 1, functionMode: UInt32, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.sonySDIOOpenSession.rawValue, transactionID: tx, parameters: [sessionID, functionMode])
    }

    /// Sony SDIO_SetContentsTransferMode (0x9212), three parameters, no data phase. Known sets: `[2, 0, 0]` then
    /// `[2, 1, 0]` (with a 200 ms pause between) for the whole card; `[1, 0, 0]` for the set of photos selected on
    /// the camera. The code is listed in the α7C II's PTP/IP DeviceInfo; the parameters are `unverified` there (the
    /// spike's [2, 0, 0] then [2, 1, 0] answered OK); source: mvpzac/Imagedge (ZV-E10).
    public static func sonySetContentsTransferMode(_ p1: UInt32, _ p2: UInt32, _ p3: UInt32, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.sonySDIOSetContentsTransferMode.rawValue, transactionID: tx, parameters: [p1, p2, p3])
    }

    /// MTP GetObjectPropList (0x9805): five parameters in MTP's order, ObjectHandle, ObjectFormatCode,
    /// ObjectPropCode, ObjectPropGroupCode, Depth. The data phase is an `MTPObjectPropList`.
    ///
    /// Defaults follow what libmtp sends for "every object, every property": `get_all_metadata_fast` in
    /// libmtp.c calls `ptp_mtp_getobjectproplist(params, 0xffffffff, …)`, which in ptp.c expands to
    /// `ptp_mtp_getobjectproplist_generic(handle, 0x00000000 /* all formats */, 0xFFFFFFFF /* all properties */,
    /// 0 /* property group */, level)` with `level = 0xFFFFFFFF`. libgphoto2's ptp.c has identical wrappers but
    /// uses them with `level = 0` for one object at a time (`ptp_mtp_getobjectproplist_single`).
    /// - `handle`: `.allObjects` (0xFFFFFFFF); a real handle asks for that object (and children, per `depth`).
    /// - `format`: `nil` sends 0, "all formats".
    /// - `property`: `nil` sends 0xFFFFFFFF, "all properties" (a `UInt32` on the wire although property codes are
    ///   16-bit); a code asks for just that property, which should shrink the reply.
    /// - `group`: 0, none (only meaningful when `property` is 0; devices answer
    ///   Specification_By_Group_Unsupported otherwise).
    /// - `depth`: 0xFFFFFFFF as libmtp sends for the whole device; with the all-objects handle it should be
    ///   moot. For a real handle, 0 is "this object only" and 1 "its children too".
    ///
    /// `unverified` on the α7C II: its DeviceInfo advertises 0x9805, but no capture proves it answers this
    /// parameter combination, or answers it quickly (MTP property lists are kept out of the repository: their object
    /// IDs may carry the serial).
    public static func getObjectPropList(
        handle: PTPObjectHandle = .allObjects,
        format: PTPObjectFormat? = nil,
        property: MTPObjectPropertyCode? = nil,
        group: UInt32 = 0,
        depth: UInt32 = MTPObjectPropList.allDepths,
        tx: UInt32
    ) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getObjectPropList.rawValue, transactionID: tx,
                     parameters: [handle.rawValue, UInt32(format?.rawValue ?? 0),
                                  property.map { UInt32($0.rawValue) } ?? 0xFFFF_FFFF, group, depth])
    }

    /// "Every property of every object": `getObjectPropList` with all defaults, the libmtp
    /// `get_all_metadata_fast` request. `unverified` on the α7C II.
    public static func getAllObjectProps(tx: UInt32) -> PTPContainer {
        getObjectPropList(tx: tx)
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

    /// GetPartialObject (0x101B) with four parameters: handle, offset low, offset high, length. The layout
    /// mvpzac/Imagedge uses on a ZV-E10. `unverified` on the α7C II, where the three-parameter form answered
    /// InvalidObjectHandle (0x2009).
    public static func getPartialObjectSony(_ handle: PTPObjectHandle, offset: UInt64, length: UInt32, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: PTPOperationCode.getPartialObject.rawValue, transactionID: tx,
                     parameters: [handle.rawValue, UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32), length])
    }

    /// Sony's "SDIO_GetPartialLargeObject": five parameters, handle, offset low, offset high, length low, length
    /// high (length widened to u64). `code` is meant to be 0x9211 (libgphoto2's name for it) or 0x9219 (what
    /// mvpzac/Imagedge calls it) but any code builds. The layout is a guess from mvpzac/Imagedge's description
    /// (ZV-E10), `unverified` on the α7C II in tests (the spike's log: with 0x9211 it read byte ranges that matched GetObject by SHA-256; with 0x9219 it answered InvalidObjectHandle in a contents-transfer session).
    public static func sonyGetPartialLargeObject(code: UInt16, _ handle: PTPObjectHandle, offset: UInt64, length: UInt64, tx: UInt32) -> PTPContainer {
        PTPContainer(type: .command, code: code, transactionID: tx,
                     parameters: [handle.rawValue, UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32),
                                  UInt32(length & 0xFFFF_FFFF), UInt32(length >> 32)])
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
