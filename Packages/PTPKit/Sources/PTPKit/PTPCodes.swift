// PTPKit — codes from ISO 15740 (PTP) plus the vendor values we expect to see on Sony bodies.
// Pure Swift, no I/O. Vendor codes marked `unverified` are to be confirmed against the camera's
// GetDeviceInfo on spike day 2 and recorded in Fixtures/a7c2/.

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
    /// MTP extension: 64-bit offset variant. Some bodies support only this one for large files.
    public static let getPartialObject64 = PTPOperationCode(rawValue: 0x95C1)

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
        case .getPartialObject64: "GetPartialObject64 (MTP)"
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
    /// MTP: MP4 container.
    public static let mp4         = PTPObjectFormat(rawValue: 0xB982)
    /// Sony vendor format code for ARW. `unverified` — read the real value from GetObjectInfo on day 2.
    public static let sonyRAWUnverified = PTPObjectFormat(rawValue: 0xB101)

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
        case .mp4: "MP4"
        case .sonyRAWUnverified: "Sony RAW (unverified code)"
        default: String(format: "Format(0x%04X)", rawValue)
        }
    }
}

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
