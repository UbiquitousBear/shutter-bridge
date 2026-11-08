import Testing
import Foundation
@testable import BLEKit

@Suite("The CC08 write")
struct WriteTests {
    @Test func wifiOnIsCC08GetsOne() {
        #expect(CameraControlWrite.wifiOn.characteristic == .wifiOn)
        #expect(CameraControlWrite.wifiOn.characteristic.code == "CC08")
        #expect(CameraControlWrite.wifiOn.characteristic.uuid.uuidString == "0000CC08-CC00-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(CameraControlWrite.wifiOn.value == Data([0x01]))
    }

    @Test func theOnlyValueWriteIsNotASecretCharacteristic() {
        #expect(!CameraControlWrite.wifiOn.characteristic.isSecret)
        #expect(!CameraControlCharacteristic.sonyNotificationSet.contains(CameraControlWrite.wifiOn.characteristic))
        #expect(CameraControlWrite(characteristic: .wifiOn, value: Data([1])) == CameraControlWrite.wifiOn)
        #expect(CameraControlWrite(characteristic: .wifiOn, value: Data([0])) != CameraControlWrite.wifiOn)
    }
}

@Suite("The advertisement's manufacturer data")
struct AdvertisementTests {
    /// A synthetic payload of the measured length: no real advertisement bytes are recorded anywhere.
    let payload: [UInt8] = (0 ..< 20).map { UInt8(0xA0 + $0) }

    @Test func sonysDataSplitsIntoCompanyAndPayload() throws {
        let advert = try SonyAdvertisement(manufacturerData: Data([0x2D, 0x01] + payload))
        #expect(advert.companyID == 0x012D)
        #expect(advert.isSony)
        #expect(advert.payload == payload)
        #expect(advert.payload.count == SonyAdvertisement.observedPayloadLength)
    }

    @Test func otherCompaniesDecodeButAreNotSony() throws {
        let apple = try SonyAdvertisement(manufacturerData: Data([0x4C, 0x00, 0x10, 0x05]))
        #expect(apple.companyID == 0x004C)
        #expect(!apple.isSony)
        #expect(apple.payload == [0x10, 0x05])
        // Big-endian reading of Sony's bytes is a different company.
        #expect(try !SonyAdvertisement(manufacturerData: Data([0x01, 0x2D])).isSony)
    }

    @Test func shortDataThrows() throws {
        #expect(throws: SonyAdvertisementError.tooShort(byteCount: 0)) { try SonyAdvertisement(manufacturerData: Data()) }
        #expect(throws: SonyAdvertisementError.tooShort(byteCount: 1)) { try SonyAdvertisement(manufacturerData: Data([0x2D])) }
        let bare = try SonyAdvertisement(manufacturerData: Data([0x2D, 0x01]))
        #expect(bare.isSony)
        #expect(bare.payload.isEmpty)
    }

    @Test func slicesWithAnOffsetDecode() throws {
        let data = Data([0xFF, 0xFF, 0x2D, 0x01, 0x07])
        let slice = data[2...]
        #expect(slice.startIndex == 2)
        let advert = try SonyAdvertisement(manufacturerData: slice)
        #expect(advert.isSony)
        #expect(advert.payload == [0x07])
    }

    @Test func thePayloadIsNeverPrinted() throws {
        let advert = try SonyAdvertisement(manufacturerData: Data([0x2D, 0x01] + payload))
        let expected = "company 0x012D, 20 payload bytes (not shown)"
        var dumped = ""
        dump(advert, to: &dumped)
        for text in [advert.description, advert.debugDescription, "\(advert)", String(reflecting: advert), dumped] {
            #expect(text.contains(expected))
            for byte in payload {
                #expect(!text.uppercased().contains("0x" + String(byte, radix: 16, uppercase: true)))
            }
        }
        #expect(advert.description == expected)
        #expect(Mirror(reflecting: advert).children.map { $0.label } == ["redacted"])
    }

    @Test func nameRule() {
        #expect(SonyAdvertisement.nameLooksLikeCamera("ILCE-7CM2"))
        #expect(SonyAdvertisement.nameLooksLikeCamera("ilce-7cm2"))
        #expect(SonyAdvertisement.nameLooksLikeCamera("Sony Camera"))
        #expect(SonyAdvertisement.nameLooksLikeCamera("my SONY"))
        #expect(!SonyAdvertisement.nameLooksLikeCamera("Pixel 9"))
        #expect(!SonyAdvertisement.nameLooksLikeCamera(""))
        #expect(!SonyAdvertisement.nameLooksLikeCamera(nil))
    }
}

@Suite("Every public type is Sendable")
struct SendableTests {
    func requireSendable<T: Sendable>(_: T.Type) {}

    @Test func compileTimeCheck() {
        requireSendable(SonyService.self)
        requireSendable(CameraControlCharacteristic.self)
        requireSendable(CameraControlWrite.self)
        requireSendable(SonyStatusTag.self)
        requireSendable(SonyStatusEntry.self)
        requireSendable(SonyStatusError.self)
        requireSendable(SonyStatus.self)
        requireSendable(SonyStatusChange.self)
        requireSendable(WiFiStatus.self)
        requireSendable(SonyWiFiCredentials.self)
        requireSendable(SonyNetworkDetailsError.self)
        requireSendable(SonyNetworkDetailsError.Field.self)
        requireSendable(SonyAdvertisement.self)
        requireSendable(SonyAdvertisementError.self)
    }
}
