import Testing
import Foundation
@testable import BLEKit

@Suite("Sony's identifiers")
struct IdentifierTests {
    @Test func companyIDIsSonysAndLittleEndianOnTheWire() throws {
        #expect(SonyBluetooth.companyID == 0x012D)
        #expect(try SonyAdvertisement(manufacturerData: Data([0x2D, 0x01])).companyID == SonyBluetooth.companyID)
    }

    @Test func advertisedServiceIsGenericAccess() {
        #expect(SonyBluetooth.advertisedServiceCode == 0x1800)
        #expect(SonyBluetooth.advertisedService.uuidString == "00001800-0000-1000-8000-00805F9B34FB")
        #expect(SonyBluetooth.shortCode(of: SonyBluetooth.advertisedService) == 0x1800)
    }

    @Test func coreBluetoothStringsParseInEveryForm() {
        // CoreBluetooth reports 16-bit UUIDs in their short form, which UUID(uuidString:) refuses.
        #expect(UUID(uuidString: "1800") == nil)
        #expect(SonyBluetooth.uuid(bluetoothString: "1800") == SonyBluetooth.advertisedService)
        #expect(SonyBluetooth.uuid(bluetoothString: "1800").flatMap(SonyBluetooth.shortCode(of:)) == 0x1800)
        let ssid = SonyBluetooth.uuid(bluetoothString: "cc06")
        #expect(ssid?.uuidString == "0000CC06-0000-1000-8000-00805F9B34FB")
        #expect(ssid.flatMap { CameraControlCharacteristic(uuid: $0) } == .ssid)
        #expect(SonyBluetooth.uuid(bluetoothString: "CC06") == ssid)
        // Eight digits: a 32-bit code on the same base.
        #expect(SonyBluetooth.uuid(bluetoothString: "0000CC06") == ssid)
        #expect(SonyBluetooth.uuid(bluetoothString: "12345678")?.uuidString == "12345678-0000-1000-8000-00805F9B34FB")
        // The long forms parse as they are, and the Sony form round-trips.
        for service in SonyService.allCases {
            #expect(SonyBluetooth.uuid(bluetoothString: service.uuid.uuidString) == service.uuid)
            #expect(SonyBluetooth.uuid(bluetoothString: service.uuid.uuidString.lowercased()) == service.uuid)
        }
        for c in CameraControlCharacteristic.allCases {
            #expect(SonyBluetooth.uuid(bluetoothString: c.uuid.uuidString) == c.uuid)
        }
    }

    @Test func malformedCoreBluetoothStringsGiveNil() {
        let valid = "0000CC06-CC00-FFFF-FFFF-FFFFFFFFFFFF"
        let bad = [
            "", "18", "180", "18000", "1800000", "123456789", "+800", "-800", "+0000800", "18 0", " 180", "180 ", "180G", "0x18",
            "ＣＣ０６", "18é", "180\u{0}", "1800\n",
            valid + "0",                                        // 37 characters
            String(valid.dropLast()),                           // 35 characters
            valid.replacingOccurrences(of: "-", with: "_"),
            valid.replacingOccurrences(of: "F", with: "G"),
            "+" + String(valid.dropFirst()),
            String(repeating: "0", count: 36),                  // right length, no dashes
        ]
        for text in bad {
            #expect(SonyBluetooth.uuid(bluetoothString: text) == nil, "\(text.debugDescription)")
        }
    }

    @Test func servicesHaveTheUUIDsTheSpikeListed() {
        let expected: [SonyService: String] = [
            .remoteShutter: "8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF",
            .cameraControl: "8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF",
            .locationAndTime: "8000DD00-DD00-FFFF-FFFF-FFFFFFFFFFFF",
            .pairing: "8000EE00-EE00-FFFF-FFFF-FFFFFFFFFFFF",
            .unidentifiedBB: "8000BB00-BB00-FFFF-FFFF-FFFFFFFFFFFF",
        ]
        #expect(SonyService.allCases.count == 5)
        for service in SonyService.allCases {
            #expect(service.uuid.uuidString == expected[service], "\(service)")
            #expect(SonyService(uuid: service.uuid) == service)
        }
        #expect(Set(SonyService.allCases.map(\.uuid)).count == 5)
        #expect(SonyService(uuid: UUID(uuidString: "8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFE")!) == nil)
        #expect(SonyService(uuid: SonyBluetooth.advertisedService) == nil)
    }

    @Test func characteristicsHaveSonysLongForm() {
        #expect(CameraControlCharacteristic.ssid.uuid.uuidString == "0000CC06-CC00-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(CameraControlCharacteristic.passphrase.uuid.uuidString == "0000CC07-CC00-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(CameraControlCharacteristic.wifiOn.uuid.uuidString == "0000CC08-CC00-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(CameraControlCharacteristic.status.uuid.uuidString == "0000CC09-CC00-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(CameraControlCharacteristic.wifiBand.uuid.uuidString == "0000CCAB-CC00-FFFF-FFFF-FFFFFFFFFFFF")
        let codes = Dictionary(uniqueKeysWithValues: CameraControlCharacteristic.allCases.map { ($0.code, $0) })
        #expect(codes.count == CameraControlCharacteristic.allCases.count)
        #expect(CameraControlCharacteristic.ssid.code == "CC06")
        #expect(CameraControlCharacteristic.firmware.code == "CC0A")
        #expect(CameraControlCharacteristic.modelName.code == "CC0B")
        #expect(CameraControlCharacteristic.bssid.code == "CC0C")
    }

    @Test func everyCharacteristicRoundTrips() {
        for c in CameraControlCharacteristic.allCases {
            #expect(CameraControlCharacteristic(uuid: c.uuid) == c)
            #expect(CameraControlCharacteristic(code: c.code) == c)
            #expect(CameraControlCharacteristic(code: c.code.lowercased()) == c)
            #expect(SonyBluetooth.shortCode(of: c.uuid) == c.rawValue)
            // The Bluetooth base form names the same characteristic.
            let base = SonyBluetooth.bluetoothBaseUUID(code: c.rawValue)
            #expect(CameraControlCharacteristic(uuid: base) == c)
        }
        #expect(CameraControlCharacteristic(uuid: UUID(uuidString: "0000CC06-0000-1000-8000-00805F9B34FB")!) == .ssid)
    }

    @Test func otherUUIDsHaveNoShortCode() {
        let others = [
            "0000CC06-CC00-FFFF-FFFF-FFFFFFFFFFFE",   // one byte off
            "0001CC06-CC00-FFFF-FFFF-FFFFFFFFFFFF",   // the prefix isn't 0000
            "0000CC06-DD00-FFFF-FFFF-FFFFFFFFFFFF",   // another service's group
            "8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF",   // a service, not a characteristic
            "00000000-0000-0000-0000-000000000000",
            "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
        ]
        for text in others {
            #expect(SonyBluetooth.shortCode(of: UUID(uuidString: text)!) == nil, "\(text)")
        }
        // A well-formed code of a characteristic this package doesn't list names none of them.
        let unlisted = SonyBluetooth.uuid(prefix: [0x00, 0x00, 0xCC, 0x19], tail: SonyBluetooth.sonyTail)
        #expect(SonyBluetooth.shortCode(of: unlisted) == 0xCC19)
        #expect(CameraControlCharacteristic(uuid: unlisted) == nil)
    }

    @Test func codeStringsAreStrict() {
        #expect(CameraControlCharacteristic(code: "cc09") == .status)
        for bad in ["", "CC9", "CC090", " CC09", "CC09 ", "+C09", "-C09", "0xCC09", "CC0G", "ＣＣ０９", "CC0\u{0}", "CC0A\n", "CC06é"] {
            #expect(CameraControlCharacteristic(code: bad) == nil, "\(bad.debugDescription)")
        }
        // Valid hex, but not a characteristic the package lists.
        #expect(CameraControlCharacteristic(code: "CC19") == nil)
        #expect(CameraControlCharacteristic(code: "0000") == nil)
    }

    @Test func secretsAreCC06CC07AndCC0C() {
        #expect(CameraControlCharacteristic.secret == [.ssid, .passphrase, .bssid])
        for c in CameraControlCharacteristic.allCases {
            #expect(c.isSecret == (["CC06", "CC07", "CC0C"].contains(c.code)), "\(c.code)")
        }
    }

    @Test func sonysFiveNotifications() {
        #expect(CameraControlCharacteristic.sonyNotificationSet.map(\.code) == ["CC09", "CC10", "CC0F", "CC03", "CC0E"])
        #expect(Set(CameraControlCharacteristic.sonyNotificationSet).count == 5)
        #expect(CameraControlCharacteristic.sonyNotificationSet.allSatisfy { !$0.isSecret })
    }
}
