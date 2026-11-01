// PTPKit — codes from ISO 15740 (PTP) plus the vendor values we expect to see on Sony bodies.
// Pure Swift, no I/O. Sony vendor values come from libgphoto2's camlibs/ptp2/ptp.h (the best public record of
// Sony's PTP extension); they are `unverified` on the α7C II until the camera's own GetDeviceInfo and
// GetObjectInfo, captured into Fixtures/a7c2/ during the spike, confirm them. Vendor codes in the 0x9000,
// 0xB000 and 0xC000 ranges only mean what they say here when DeviceInfo.vendorExtensionID is Sony (0x11).

public enum PTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

public struct PTPOperationCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let getDeviceInfo     = PTPOperationCode(rawValue: 0x1001)
    public static let openSession       = PTPOperationCode(rawValue: 0x1002)
    public static let closeSession      = PTPOperationCode(rawValue: 0x1003)
    public static let getStorageIDs     = PTPOperationCode(rawValue: 0x1004)
    public static let getStorageInfo    = PTPOperationCode(rawValue: 0x1005)
    public static let getNumObjects     = PTPOperationCode(rawValue: 0x1006)
    public static let getObjectHandles  = PTPOperationCode(rawValue: 0x1007)
    public static let getObjectInfo     = PTPOperationCode(rawValue: 0x1008)
    public static let getObject         = PTPOperationCode(rawValue: 0x1009)
    public static let getThumb          = PTPOperationCode(rawValue: 0x100A)
    public static let deleteObject      = PTPOperationCode(rawValue: 0x100B)
    public static let getDevicePropDesc = PTPOperationCode(rawValue: 0x1014)
    public static let getDevicePropValue = PTPOperationCode(rawValue: 0x1015)
    public static let getPartialObject  = PTPOperationCode(rawValue: 0x101B)
    /// Android's MTP extension (libgphoto2 `PTP_OC_ANDROID_GetPartialObject64`): 64-bit offset variant.
    public static let getPartialObject64 = PTPOperationCode(rawValue: 0x95C1)

    // Sony SDIO extension (libgphoto2 names). `unverified` on the α7C II.
    /// Three-phase handshake (param 1 = phase 1, 2, 3) that PC Remote mode needs before vendor ops work.
    public static let sonySDIOConnect = PTPOperationCode(rawValue: 0x9201)
    /// Param 1 = protocol version (0xC8 = 2.00, 0x12C = 3.00), param 2 = 1. Data phase lists vendor codes.
    public static let sonySDIOGetExtDeviceInfo = PTPOperationCode(rawValue: 0x9202)
    /// Sony's own 64-bit partial read. Parameter layout undocumented; probe it in the spike.
    public static let sonySDIOGetPartialLargeObject = PTPOperationCode(rawValue: 0x9211)
    /// Switches the camera into its contents-transfer (card browsing) mode. Parameters undocumented.
    public static let sonySDIOSetContentsTransferMode = PTPOperationCode(rawValue: 0x9212)

    public var description: String {
        switch self {
        case .getDeviceInfo: "GetDeviceInfo"
        case .openSession: "OpenSession"
        case .closeSession: "CloseSession"
        case .getStorageIDs: "GetStorageIDs"
        case .getStorageInfo: "GetStorageInfo"
        case .getNumObjects: "GetNumObjects"
        case .getObjectHandles: "GetObjectHandles"
        case .getObjectInfo: "GetObjectInfo"
        case .getObject: "GetObject"
        case .getThumb: "GetThumb"
        case .deleteObject: "DeleteObject"
        case .getDevicePropDesc: "GetDevicePropDesc"
        case .getDevicePropValue: "GetDevicePropValue"
        case .getPartialObject: "GetPartialObject"
        case .getPartialObject64: "GetPartialObject64 (Android/MTP)"
        case .sonySDIOConnect: "Sony SDIO_Connect"
        case .sonySDIOGetExtDeviceInfo: "Sony SDIO_GetExtDeviceInfo"
        case .sonySDIOGetPartialLargeObject: "Sony SDIO_GetPartialLargeObject"
        case .sonySDIOSetContentsTransferMode: "Sony SDIO_SetContentsTransferMode"
        default: String(format: "Op(0x%04X)", rawValue)
        }
    }
}

public struct PTPResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let undefined               = PTPResponseCode(rawValue: 0x2000)
    public static let ok                      = PTPResponseCode(rawValue: 0x2001)
    public static let generalError            = PTPResponseCode(rawValue: 0x2002)
    public static let sessionNotOpen          = PTPResponseCode(rawValue: 0x2003)
    public static let invalidTransactionID    = PTPResponseCode(rawValue: 0x2004)
    public static let operationNotSupported   = PTPResponseCode(rawValue: 0x2005)
    public static let parameterNotSupported   = PTPResponseCode(rawValue: 0x2006)
    public static let incompleteTransfer      = PTPResponseCode(rawValue: 0x2007)
    public static let invalidStorageID        = PTPResponseCode(rawValue: 0x2008)
    public static let invalidObjectHandle     = PTPResponseCode(rawValue: 0x2009)
    public static let devicePropNotSupported  = PTPResponseCode(rawValue: 0x200A)
    public static let invalidObjectFormatCode = PTPResponseCode(rawValue: 0x200B)
    public static let storeFull               = PTPResponseCode(rawValue: 0x200C)
    public static let objectWriteProtected    = PTPResponseCode(rawValue: 0x200D)
    public static let storeReadOnly           = PTPResponseCode(rawValue: 0x200E)
    public static let accessDenied            = PTPResponseCode(rawValue: 0x200F)
    public static let noThumbnailPresent      = PTPResponseCode(rawValue: 0x2010)
    public static let partialDeletion         = PTPResponseCode(rawValue: 0x2012)
    public static let storeNotAvailable       = PTPResponseCode(rawValue: 0x2013)
    public static let invalidParentObject     = PTPResponseCode(rawValue: 0x201A)
    public static let invalidParameter        = PTPResponseCode(rawValue: 0x201D)
    public static let sessionAlreadyOpen      = PTPResponseCode(rawValue: 0x201E)
    public static let transactionCancelled    = PTPResponseCode(rawValue: 0x201F)
    public static let deviceBusy              = PTPResponseCode(rawValue: 0x2019)

    public var isOK: Bool { self == .ok }

    public var description: String {
        switch self {
        case .ok: "OK"
        case .generalError: "GeneralError"
        case .sessionNotOpen: "SessionNotOpen"
        case .invalidTransactionID: "InvalidTransactionID"
        case .operationNotSupported: "OperationNotSupported"
        case .parameterNotSupported: "ParameterNotSupported"
        case .incompleteTransfer: "IncompleteTransfer"
        case .invalidStorageID: "InvalidStorageID"
        case .invalidObjectHandle: "InvalidObjectHandle"
        case .accessDenied: "AccessDenied"
        case .noThumbnailPresent: "NoThumbnailPresent"
        case .storeNotAvailable: "StoreNotAvailable"
        case .invalidStorageID: "InvalidStorageID"
        case .devicePropNotSupported: "DevicePropNotSupported"
        case .invalidObjectFormatCode: "InvalidObjectFormatCode"
        case .storeFull: "StoreFull"
        case .storeReadOnly: "StoreReadOnly"
        case .invalidParentObject: "InvalidParentObject"
        case .invalidParameter: "InvalidParameter"
        case .sessionAlreadyOpen: "SessionAlreadyOpen"
        case .transactionCancelled: "TransactionCancelled"
        case .deviceBusy: "DeviceBusy"
        default: String(format: "Response(0x%04X)", rawValue)
        }
    }
}

public struct PTPEventCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let cancelTransaction  = PTPEventCode(rawValue: 0x4001)
    public static let objectAdded        = PTPEventCode(rawValue: 0x4002)
    public static let objectRemoved      = PTPEventCode(rawValue: 0x4003)
    public static let storeAdded         = PTPEventCode(rawValue: 0x4004)
    public static let storeRemoved       = PTPEventCode(rawValue: 0x4005)
    public static let devicePropChanged  = PTPEventCode(rawValue: 0x4006)
    public static let objectInfoChanged  = PTPEventCode(rawValue: 0x4007)
    public static let deviceInfoChanged  = PTPEventCode(rawValue: 0x4008)
    public static let requestObjectTransfer = PTPEventCode(rawValue: 0x4009)
    public static let storeFull          = PTPEventCode(rawValue: 0x400A)
    public static let deviceReset        = PTPEventCode(rawValue: 0x400B)
    public static let storageInfoChanged = PTPEventCode(rawValue: 0x400C)
    public static let captureComplete    = PTPEventCode(rawValue: 0x400D)
    /// Sony vendor ObjectAdded (libgphoto2 `PTP_EC_Sony_ObjectAdded`). Sony bodies in PC Remote mode report new
    /// shots with this rather than 0x4002. `unverified` on the α7C II.
    public static let sonyObjectAdded    = PTPEventCode(rawValue: 0xC201)
    public static let sonyObjectRemoved  = PTPEventCode(rawValue: 0xC202)

    /// True for the standard and the Sony vendor ObjectAdded: the event transfer-while-shooting would act on.
    public var signalsNewObject: Bool { self == .objectAdded || self == .sonyObjectAdded }

    public var description: String {
        switch self {
        case .objectAdded: "ObjectAdded"
        case .objectRemoved: "ObjectRemoved"
        case .storeAdded: "StoreAdded"
        case .storeRemoved: "StoreRemoved"
        case .devicePropChanged: "DevicePropChanged"
        case .objectInfoChanged: "ObjectInfoChanged"
        case .deviceInfoChanged: "DeviceInfoChanged"
        case .requestObjectTransfer: "RequestObjectTransfer"
        case .storeFull: "StoreFull"
        case .deviceReset: "DeviceReset"
        case .storageInfoChanged: "StorageInfoChanged"
        case .captureComplete: "CaptureComplete"
        case .cancelTransaction: "CancelTransaction"
        case .sonyObjectAdded: "Sony ObjectAdded"
        case .sonyObjectRemoved: "Sony ObjectRemoved"
        default: String(format: "Event(0x%04X)", rawValue)
        }
    }
}

public struct PTPObjectFormat: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let undefined   = PTPObjectFormat(rawValue: 0x3000)
    public static let association = PTPObjectFormat(rawValue: 0x3001)   // folder
    public static let text        = PTPObjectFormat(rawValue: 0x3004)
    public static let exifJPEG    = PTPObjectFormat(rawValue: 0x3801)
    public static let tiffEP      = PTPObjectFormat(rawValue: 0x3802)
    public static let jfif        = PTPObjectFormat(rawValue: 0x3808)
    public static let tiff        = PTPObjectFormat(rawValue: 0x380D)
    public static let dng         = PTPObjectFormat(rawValue: 0x3811)
    public static let quickTime   = PTPObjectFormat(rawValue: 0x300D)
    /// MTP: MP4 container.
    public static let mp4         = PTPObjectFormat(rawValue: 0xB982)
    /// MTP: XML document (the sidecars the camera writes beside video clips).
    public static let xmlDocument = PTPObjectFormat(rawValue: 0xBA82)
    /// Sony vendor format for ARW (libgphoto2 `PTP_OFC_SONY_RAW`). `unverified` on the α7C II.
    public static let sonyARW     = PTPObjectFormat(rawValue: 0xB101)
    /// Sony vendor format for HEIF / .HIF (libgphoto2 `PTP_OFC_SONY_HEIF`). `unverified` on the α7C II.
    public static let sonyHEIF    = PTPObjectFormat(rawValue: 0xB110)
    /// Sony vendor format for MPO (libgphoto2 `PTP_OFC_SONY_MPO`).
    public static let sonyMPO     = PTPObjectFormat(rawValue: 0xB301)

    public var description: String {
        switch self {
        case .undefined: "Undefined"
        case .association: "Association"
        case .text: "Text"
        case .exifJPEG: "EXIF/JPEG"
        case .tiffEP: "TIFF/EP"
        case .jfif: "JFIF"
        case .tiff: "TIFF"
        case .dng: "DNG"
        case .quickTime: "QuickTime"
        case .mp4: "MP4"
        case .xmlDocument: "XML"
        case .sonyARW: "Sony ARW"
        case .sonyHEIF: "Sony HEIF"
        case .sonyMPO: "Sony MPO"
        default: String(format: "Format(0x%04X)", rawValue)
        }
    }
}

/// PTP vendor extension IDs (DeviceInfo.vendorExtensionID). Sony is 0x11, as libgphoto2 also records.
public enum PTPVendorExtension: UInt32, Sendable {
    case none = 0x0000
    case kodak = 0x0001
    case canon = 0x000B
    case nikon = 0x000A
    case microsoftMTP = 0x0006
    case sony = 0x0011
    case fujifilm = 0x0012
}

public struct PTPStorageID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// Wildcard used by GetObjectHandles / GetNumObjects to mean "all stores".
    public static let all = PTPStorageID(rawValue: 0xFFFF_FFFF)
}

public struct PTPObjectHandle: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// Wildcard parent handle meaning "root".
    public static let root = PTPObjectHandle(rawValue: 0xFFFF_FFFF)
    public var description: String { String(format: "0x%08X", rawValue) }
}
