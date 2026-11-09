import Foundation
import PTPKit

/// Which of the α7C II's two DeviceInfo flavours a simulated camera imitates (backlog section 7). They differ a lot:
/// MTP over USB lists 24 operations, no Sony extension, 5 properties and 3 events; PTP/IP lists 81 operations, Sony's
/// extension, no properties and 48 events.
public enum SimulatorFlavour: String, Sendable, Hashable, CaseIterable {
    /// *Image Transfer (MTP)* over USB (`Fixtures/a7c2/usb/deviceinfo.bin`, firmware string "2.0"). The default:
    /// Iteration 1 imports over USB, and `GetPartialObject` (0x101B) behaves here as it does over USB in MTP.
    case usbMTP
    /// The camera's PTP/IP answer (`Fixtures/a7c2/ptpip/deviceinfo.bin`, firmware string "2.01", from a run with PC
    /// Remote Function off). The DeviceInfo, StorageInfo and ObjectAdded style follow it, and so does Sony's
    /// whole-card session: a plain OpenSession lists nothing, SDIO_OpenSession (0x9210) with the contents-transfer
    /// steps (0x9212) offers the card, and 0x9211 reads byte ranges where 0x101B answers InvalidObjectHandle
    /// (`PTPResponder`, `WholeCardBehaviour`).
    case ptpIP
}

/// Why the simulator couldn't load one of its bundled fixture copies. Not expected outside a broken build.
public struct SimulatorFixtureError: Error, Sendable, Hashable, CustomStringConvertible {
    public var resource: String
    public var reason: String
    public var description: String { "\(resource): \(reason)" }
}

/// The captured α7C II datasets the simulator answers with: byte-for-byte copies of `Fixtures/a7c2/` bundled as
/// resources of this target (Sources/PTPSimulator/Fixtures/README.md names each source). PTPKit's copies are a
/// resource of its test target, which no other package can reach, so the simulator carries its own.
public enum CapturedA7C2 {
    /// The raw bytes of a bundled copy, such as "a7c2-usb-deviceinfo".
    public static func bytes(_ name: String) throws(SimulatorFixtureError) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "bin")
        else {
            throw SimulatorFixtureError(resource: name, reason: "not in the PTPSimulator bundle")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SimulatorFixtureError(resource: name, reason: "\(error)")
        }
    }

    /// The camera's DeviceInfo in `flavour`, decoded with PTPKit. The serial number is the zeroed one of the fixture.
    public static func deviceInfo(_ flavour: SimulatorFlavour) throws(SimulatorFixtureError) -> PTPDeviceInfo {
        try decode("a7c2-\(flavour.linkName)-deviceinfo", PTPDeviceInfo.decode)
    }

    /// The camera's StorageInfo in `flavour`, as captured: over USB 255.94 GB with 242.57 GB free; over PTP/IP
    /// capacity and free space 0, the camera's way of saying nothing.
    public static func storageInfo(_ flavour: SimulatorFlavour) throws(SimulatorFixtureError) -> PTPStorageInfo {
        try decode("a7c2-\(flavour.linkName)-storageinfo", PTPStorageInfo.decode)
    }

    /// The camera's SDIO_GetExtDeviceInfo reply (`Fixtures/a7c2/ptpip/sdio-extdeviceinfo.bin`), 970 bytes: the simulator
    /// answers 0x9202 with it. Over PTP/IP only; the USB flavour has no copy.
    public static func sdioExtDeviceInfo() throws(SimulatorFixtureError) -> Data {
        try bytes("a7c2-ptpip-sdio-extdeviceinfo")
    }

    /// The captured USB ObjectInfo of an ARW (`DSC02018.ARW`: a 160 × 120 JFIF thumbnail of 6,584 B, 7008 × 4672) or
    /// of a JPG (`DSC01997.JPG`: 7,376 B, the same sizes): the template for the simulator's thumbnail and pixel fields.
    public static func objectInfoTemplate(raw: Bool) throws(SimulatorFixtureError) -> PTPObjectInfo {
        try decode(raw ? "a7c2-usb-objectinfo-arw" : "a7c2-usb-objectinfo-jpg", PTPObjectInfo.decode)
    }

    private static func decode<T>(_ name: String, _ decoder: (Data) throws -> T) throws(SimulatorFixtureError) -> T {
        let data = try bytes(name)
        do {
            return try decoder(data)
        } catch {
            throw SimulatorFixtureError(resource: name, reason: "doesn't decode: \(error)")
        }
    }
}

extension SimulatorFlavour {
    /// The fixture folder's name for the link: "usb" or "ptpip".
    var linkName: String {
        switch self {
        case .usbMTP: "usb"
        case .ptpIP: "ptpip"
        }
    }
}
