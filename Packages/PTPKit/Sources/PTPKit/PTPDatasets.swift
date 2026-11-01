// Datasets returned in the data phase of GetDeviceInfo, GetStorageInfo and GetObjectInfo
// (ISO 15740 §5.1.1, §5.2.2, §5.1.2 and §9.4). Field order is normative; everything is little-endian.

import Foundation

public struct PTPDeviceInfo: Equatable, Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDescription: String
    public var functionalMode: UInt16
    public var operationsSupported: [UInt16]
    public var eventsSupported: [UInt16]
    public var devicePropertiesSupported: [UInt16]
    public var captureFormats: [UInt16]
    public var imageFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(
        standardVersion: UInt16,
        vendorExtensionID: UInt32,
        vendorExtensionVersion: UInt16,
        vendorExtensionDescription: String,
        functionalMode: UInt16,
        operationsSupported: [UInt16],
        eventsSupported: [UInt16],
        devicePropertiesSupported: [UInt16],
        captureFormats: [UInt16],
        imageFormats: [UInt16],
        manufacturer: String,
        model: String,
        deviceVersion: String,
        serialNumber: String
    ) {
        self.standardVersion = standardVersion
        self.vendorExtensionID = vendorExtensionID
        self.vendorExtensionVersion = vendorExtensionVersion
        self.vendorExtensionDescription = vendorExtensionDescription
        self.functionalMode = functionalMode
        self.operationsSupported = operationsSupported
        self.eventsSupported = eventsSupported
        self.devicePropertiesSupported = devicePropertiesSupported
        self.captureFormats = captureFormats
        self.imageFormats = imageFormats
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        self.serialNumber = serialNumber
    }

    public var vendorExtension: PTPVendorExtension? { PTPVendorExtension(rawValue: vendorExtensionID) }

    public func supports(_ op: PTPOperationCode) -> Bool { operationsSupported.contains(op.rawValue) }
    public func emits(_ event: PTPEventCode) -> Bool { eventsSupported.contains(event.rawValue) }

    public static func decode(_ data: Data) throws -> PTPDeviceInfo {
        var r = PTPReader(data)
        return PTPDeviceInfo(
            standardVersion: try r.u16(),
            vendorExtensionID: try r.u32(),
            vendorExtensionVersion: try r.u16(),
            vendorExtensionDescription: try r.string(),
            functionalMode: try r.u16(),
            operationsSupported: try r.u16Array(),
            eventsSupported: try r.u16Array(),
            devicePropertiesSupported: try r.u16Array(),
            captureFormats: try r.u16Array(),
            imageFormats: try r.u16Array(),
            manufacturer: try r.string(),
            model: try r.string(),
            deviceVersion: try r.string(),
            serialNumber: try r.string()
        )
    }

    public func encode() -> Data {
        var w = PTPWriter()
        w.u16(standardVersion)
        w.u32(vendorExtensionID)
        w.u16(vendorExtensionVersion)
        w.string(vendorExtensionDescription)
        w.u16(functionalMode)
        w.u16Array(operationsSupported)
        w.u16Array(eventsSupported)
        w.u16Array(devicePropertiesSupported)
        w.u16Array(captureFormats)
        w.u16Array(imageFormats)
        w.string(manufacturer)
        w.string(model)
        w.string(deviceVersion)
        w.string(serialNumber)
        return w.data
    }
}

public struct PTPStorageInfo: Equatable, Sendable {
    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: UInt64
    public var freeSpaceInBytes: UInt64
    public var freeSpaceInImages: UInt32
    public var storageDescription: String
    public var volumeLabel: String

    public init(
        storageType: UInt16,
        filesystemType: UInt16,
        accessCapability: UInt16,
        maxCapacity: UInt64,
        freeSpaceInBytes: UInt64,
        freeSpaceInImages: UInt32,
        storageDescription: String,
        volumeLabel: String
    ) {
        self.storageType = storageType
        self.filesystemType = filesystemType
        self.accessCapability = accessCapability
        self.maxCapacity = maxCapacity
        self.freeSpaceInBytes = freeSpaceInBytes
        self.freeSpaceInImages = freeSpaceInImages
        self.storageDescription = storageDescription
        self.volumeLabel = volumeLabel
    }

    public static func decode(_ data: Data) throws -> PTPStorageInfo {
        var r = PTPReader(data)
        return PTPStorageInfo(
            storageType: try r.u16(),
            filesystemType: try r.u16(),
            accessCapability: try r.u16(),
            maxCapacity: try r.u64(),
            freeSpaceInBytes: try r.u64(),
            freeSpaceInImages: try r.u32(),
            storageDescription: try r.string(),
            volumeLabel: try r.string()
        )
    }

    public func encode() -> Data {
        var w = PTPWriter()
        w.u16(storageType)
        w.u16(filesystemType)
        w.u16(accessCapability)
        w.u64(maxCapacity)
        w.u64(freeSpaceInBytes)
        w.u32(freeSpaceInImages)
        w.string(storageDescription)
        w.string(volumeLabel)
        return w.data
    }
}

// MARK: - Array datasets (GetStorageIDs, GetObjectHandles)

extension PTPStorageID {
    /// Data phase of GetStorageIDs: a u32 count, then that many storage IDs.
    public static func decodeArray(_ data: Data) throws -> [PTPStorageID] {
        var r = PTPReader(data)
        return try r.u32Array().map(PTPStorageID.init(rawValue:))
    }

    public static func encodeArray(_ ids: [PTPStorageID]) -> Data {
        var w = PTPWriter()
        w.u32Array(ids.map(\.rawValue))
        return w.data
    }

    /// The physical-store half of the ID; ISO 15740 puts the physical store in the high 16 bits and the logical
    /// partition in the low 16. A low half of 0 means "no logical store", e.g. an empty card slot.
    public var hasLogicalStore: Bool { rawValue & 0xFFFF != 0 }
}

extension PTPObjectHandle {
    /// Data phase of GetObjectHandles: a u32 count, then that many handles.
    public static func decodeArray(_ data: Data) throws -> [PTPObjectHandle] {
        var r = PTPReader(data)
        return try r.u32Array().map(PTPObjectHandle.init(rawValue:))
    }

    public static func encodeArray(_ handles: [PTPObjectHandle]) -> Data {
        var w = PTPWriter()
        w.u32Array(handles.map(\.rawValue))
        return w.data
    }
}

public struct PTPObjectInfo: Equatable, Sendable {
    public var storageID: PTPStorageID
    public var objectFormat: PTPObjectFormat
    public var protectionStatus: UInt16
    public var objectCompressedSize: UInt32
    public var thumbFormat: PTPObjectFormat
    public var thumbCompressedSize: UInt32
    public var thumbPixWidth: UInt32
    public var thumbPixHeight: UInt32
    public var imagePixWidth: UInt32
    public var imagePixHeight: UInt32
    public var imageBitDepth: UInt32
    public var parentObject: PTPObjectHandle
    public var associationType: UInt16
    public var associationDescription: UInt32
    public var sequenceNumber: UInt32
    public var filename: String
    public var captureDateRaw: String
    public var modificationDateRaw: String
    public var keywords: String

    public init(
        storageID: PTPStorageID,
        objectFormat: PTPObjectFormat,
        protectionStatus: UInt16,
        objectCompressedSize: UInt32,
        thumbFormat: PTPObjectFormat,
        thumbCompressedSize: UInt32,
        thumbPixWidth: UInt32,
        thumbPixHeight: UInt32,
        imagePixWidth: UInt32,
        imagePixHeight: UInt32,
        imageBitDepth: UInt32,
        parentObject: PTPObjectHandle,
        associationType: UInt16,
        associationDescription: UInt32,
        sequenceNumber: UInt32,
        filename: String,
        captureDateRaw: String,
        modificationDateRaw: String,
        keywords: String
    ) {
        self.storageID = storageID
        self.objectFormat = objectFormat
        self.protectionStatus = protectionStatus
        self.objectCompressedSize = objectCompressedSize
        self.thumbFormat = thumbFormat
        self.thumbCompressedSize = thumbCompressedSize
        self.thumbPixWidth = thumbPixWidth
        self.thumbPixHeight = thumbPixHeight
        self.imagePixWidth = imagePixWidth
        self.imagePixHeight = imagePixHeight
        self.imageBitDepth = imageBitDepth
        self.parentObject = parentObject
        self.associationType = associationType
        self.associationDescription = associationDescription
        self.sequenceNumber = sequenceNumber
        self.filename = filename
        self.captureDateRaw = captureDateRaw
        self.modificationDateRaw = modificationDateRaw
        self.keywords = keywords
    }

    public var isFolder: Bool { objectFormat == .association }
    public var captureDate: Date? { PTPDateTime.parse(captureDateRaw) }
    public var modificationDate: Date? { PTPDateTime.parse(modificationDateRaw) }

    /// Filename stem used to pair an ARW with its JPG/HIF sibling: "DSC04512".
    public var pairStem: String {
        if let dot = filename.lastIndex(of: ".") { return String(filename[..<dot]) }
        return filename
    }

    public var fileExtension: String {
        if let dot = filename.lastIndex(of: ".") { return String(filename[filename.index(after: dot)...]).uppercased() }
        return ""
    }

    /// What the file is, for filtering and RAW+JPEG pairing. Vendor format codes vary by body and firmware, so the
    /// filename extension decides first and the format code is the fallback.
    public var mediaKind: PTPMediaKind {
        if isFolder { return .folder }
        switch fileExtension {
        case "ARW", "SRF", "SR2", "DNG": return .raw
        case "JPG", "JPEG": return .jpeg
        case "HIF", "HEIF", "HEIC": return .heif
        case "MP4", "MOV", "MTS", "M2TS": return .video
        case "XML": return .sidecar
        default: break
        }
        switch objectFormat {
        case .sonyARW, .dng: return .raw
        case .exifJPEG, .jfif: return .jpeg
        case .sonyHEIF: return .heif
        case .mp4, .quickTime: return .video
        case .xmlDocument, .text: return .sidecar
        default: return .other
        }
    }

    /// True when the 32-bit size field cannot hold the object's size: ISO 15740 has the responder report
    /// 0xFFFFFFFF for objects of 4 GiB or more (long video clips), and the real size must come from elsewhere
    /// (ImageCaptureCore's file size, or MTP's ObjectSize property).
    public var sizeExceeds32Bits: Bool { objectCompressedSize == UInt32.max }

    /// Identity of this object for diffing and resume: handles are not stable across sessions, and filenames
    /// alone collide after the camera's counter wraps (proposal § Import engine design, stage 3).
    /// Pass `size` when the true size is known from elsewhere; it is required when `sizeExceeds32Bits`, since
    /// 0xFFFFFFFF would make every large clip look the same size.
    public func identity(cameraSerial: String, size: UInt64? = nil) -> PTPObjectIdentity {
        PTPObjectIdentity(cameraSerial: cameraSerial, filename: filename, captureDateRaw: captureDateRaw,
                          size: size ?? UInt64(objectCompressedSize))
    }

    public static func decode(_ data: Data) throws -> PTPObjectInfo {
        var r = PTPReader(data)
        return PTPObjectInfo(
            storageID: PTPStorageID(rawValue: try r.u32()),
            objectFormat: PTPObjectFormat(rawValue: try r.u16()),
            protectionStatus: try r.u16(),
            objectCompressedSize: try r.u32(),
            thumbFormat: PTPObjectFormat(rawValue: try r.u16()),
            thumbCompressedSize: try r.u32(),
            thumbPixWidth: try r.u32(),
            thumbPixHeight: try r.u32(),
            imagePixWidth: try r.u32(),
            imagePixHeight: try r.u32(),
            imageBitDepth: try r.u32(),
            parentObject: PTPObjectHandle(rawValue: try r.u32()),
            associationType: try r.u16(),
            associationDescription: try r.u32(),
            sequenceNumber: try r.u32(),
            filename: try r.string(),
            captureDateRaw: try r.string(),
            modificationDateRaw: try r.string(),
            keywords: try r.string()
        )
    }

    public func encode() -> Data {
        var w = PTPWriter()
        w.u32(storageID.rawValue)
        w.u16(objectFormat.rawValue)
        w.u16(protectionStatus)
        w.u32(objectCompressedSize)
        w.u16(thumbFormat.rawValue)
        w.u32(thumbCompressedSize)
        w.u32(thumbPixWidth)
        w.u32(thumbPixHeight)
        w.u32(imagePixWidth)
        w.u32(imagePixHeight)
        w.u32(imageBitDepth)
        w.u32(parentObject.rawValue)
        w.u16(associationType)
        w.u32(associationDescription)
        w.u32(sequenceNumber)
        w.string(filename)
        w.string(captureDateRaw)
        w.string(modificationDateRaw)
        w.string(keywords)
        return w.data
    }
}

public enum PTPMediaKind: String, Sendable, Codable, CaseIterable {
    case raw, jpeg, heif, video, sidecar, folder, other

    /// Stills are what 1.0 imports; video and sidecars are hidden by the default filter until 1.1.
    public var isStill: Bool { self == .raw || self == .jpeg || self == .heif }
}

/// `(camera serial, filename, capture date, size)`: the key the catalogue diffs on. The capture date is kept as
/// the camera's raw string so identity never depends on the phone's time zone.
public struct PTPObjectIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    public var cameraSerial: String
    public var filename: String
    public var captureDateRaw: String
    public var size: UInt64

    public init(cameraSerial: String, filename: String, captureDateRaw: String, size: UInt64) {
        self.cameraSerial = cameraSerial
        self.filename = filename
        self.captureDateRaw = captureDateRaw
        self.size = size
    }

    public var description: String { "\(filename) \(captureDateRaw) \(size)B @\(cameraSerial)" }
}

/// PTP DateTime strings: "YYYYMMDDThhmmss", optionally ".s" tenths, optionally "Z" or "±hhmm".
/// Cameras without a zone report local wall-clock time; we treat that as the current zone, which is
/// what Photos does for the same EXIF value.
public enum PTPDateTime {
    public static func parse(_ s: String, defaultTimeZone: TimeZone = .current) -> Date? {
        let scalars = Array(s.utf8)
        guard scalars.count >= 15, scalars[8] == UInt8(ascii: "T") else { return nil }
        func num(_ range: Range<Int>) -> Int? {
            var v = 0
            for i in range {
                let c = scalars[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = num(0 ..< 4), let mo = num(4 ..< 6), let d = num(6 ..< 8),
              let h = num(9 ..< 11), let mi = num(11 ..< 13), let se = num(13 ..< 15) else { return nil }

        var idx = 15
        var nanos = 0
        if idx < scalars.count, scalars[idx] == UInt8(ascii: ".") {
            idx += 1
            if idx < scalars.count, let t = num(idx ..< idx + 1) { nanos = t * 100_000_000; idx += 1 }
        }
        var zone = defaultTimeZone
        if idx < scalars.count {
            switch scalars[idx] {
            case UInt8(ascii: "Z"):
                zone = TimeZone(secondsFromGMT: 0)!
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                let sign = scalars[idx] == UInt8(ascii: "+") ? 1 : -1
                guard scalars.count >= idx + 5, let zh = num(idx + 1 ..< idx + 3), let zm = num(idx + 3 ..< idx + 5) else { return nil }
                zone = TimeZone(secondsFromGMT: sign * (zh * 3600 + zm * 60)) ?? zone
            default:
                break
            }
        }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = zone
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = se
        comps.nanosecond = nanos
        return comps.date
    }
}
