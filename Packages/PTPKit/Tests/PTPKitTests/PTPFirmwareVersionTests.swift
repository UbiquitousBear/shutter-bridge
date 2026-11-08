import Testing
import Foundation
@testable import PTPKit

@Suite("Firmware versions compare like with like")
struct PTPFirmwareVersionTests {
    let pcRemote: PTPDeviceInfo = {
        var i = PTPDatasetTests.syntheticSonyDeviceInfo
        i.deviceVersion = "2.01"
        return i
    }()

    @Test func deviceInfoCarriesItsMode() {
        #expect(PTPDatasetTests.syntheticMTPDeviceInfo.firmwareVersion
                == PTPFirmwareVersion("2.0", source: .deviceInfo(vendorExtensionID: 0xFFFF_FFFF)))
        #expect(pcRemote.firmwareVersion == PTPFirmwareVersion("2.01", source: .deviceInfo(vendorExtensionID: 0x11)))
        #expect(pcRemote.firmwareVersion.description == "2.01 (DeviceInfo, vendor extension 0x00000011)")
        #expect(PTPFirmwareVersion("2.01", source: .other("ble-CC0A")).description == "2.01 (ble-CC0A)")
    }

    @Test func crossModeComparisonIsNil() {
        let mtp = PTPDatasetTests.syntheticMTPDeviceInfo.firmwareVersion
        let pc = pcRemote.firmwareVersion
        let ble = PTPFirmwareVersion("2.01", source: .other("ble-CC0A"))
        #expect(mtp.compare(pc) == nil)
        #expect(pc.compare(mtp) == nil)
        #expect(pc.compare(ble) == nil)
        #expect(ble.compare(pc) == nil)
        #expect(mtp.compare(ble) == nil)
        #expect(mtp != pc)
        #expect(pc != ble)
        #expect(mtp.compare(mtp) == .orderedSame)
    }

    @Test func sameSourceOrders() {
        let source = PTPFirmwareVersion.Source.deviceInfo(vendorExtensionID: 0x11)
        let cases: [(String, String, ComparisonResult)] = [
            ("2.01", "2.01", .orderedSame),
            ("2.00", "2.01", .orderedAscending),
            ("2.0", "2.01", .orderedAscending),
            ("2.01", "2.1", .orderedAscending),
            ("2.1", "2.10", .orderedSame),
            ("2", "2.0", .orderedSame),
            ("10.00", "9.99", .orderedDescending),
            ("02.01", "2.01", .orderedSame),
            (" 2.01 ", "2.01", .orderedSame),
            ("99999999999999999999999.1", "1.0", .orderedDescending),
        ]
        for (a, b, expected) in cases {
            let va = PTPFirmwareVersion(a, source: source), vb = PTPFirmwareVersion(b, source: source)
            #expect(va.compare(vb) == expected, "\(a) vs \(b)")
            let inverse: ComparisonResult = expected == .orderedAscending ? .orderedDescending
                : expected == .orderedDescending ? .orderedAscending : .orderedSame
            #expect(vb.compare(va) == inverse, "\(b) vs \(a)")
        }
    }

    @Test func unparseableIsNil() {
        let source = PTPFirmwareVersion.Source.deviceInfo(vendorExtensionID: 0x11)
        let good = PTPFirmwareVersion("2.01", source: source)
        for bad in ["", ".", "2.", ".1", "2.0.1", "v2.01", "2,01", "2.0a", "\u{0662}.\u{0660}"] {
            let v = PTPFirmwareVersion(bad, source: source)
            #expect(v.compare(good) == nil, "\(bad)")
            #expect(good.compare(v) == nil, "\(bad)")
        }
    }
}
