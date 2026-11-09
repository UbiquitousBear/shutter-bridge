// The confirmation after every wake (backlog section 11, decision 8): the stored identifier, or Sony's company ID with a
// camera's name; anything else advertising 1800 is ignored.

import BLEKit
import Foundation
import Testing
@testable import CameraTransport

private let sony = Data([0x2D, 0x01] + [UInt8](repeating: 0xA5, count: 20))   // company 0x012D, the observed 20-byte payload
private let apple = Data([0x4C, 0x00, 0x10, 0x05])
private let when = Date(timeIntervalSince1970: 1_794_000_000)

private func peripheral(_ n: UInt8) -> PeripheralID {
    PeripheralID(UUID(uuid: (n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)))
}

private func report(_ id: PeripheralID, data: Data?, name: String?, rssi: Int? = -60) -> ProximityReport {
    ProximityReport(peripheral: id, at: when, rssi: rssi, manufacturerData: data, name: name)
}

@Suite("Proximity confirmation")
struct ProximityConfirmerTests {
    let paired = KnownCamera(key: "paired", peripheral: peripheral(1), model: "ILCE-7CM2")
    let usbOnly = KnownCamera(key: "usb-only", peripheral: nil, model: "ILCE-7CM2")

    @Test func theStoredIdentifierConfirmsWhateverTheAdvertisementSays() {
        let confirmer = ProximityConfirmer(known: [usbOnly, paired])
        for data in [sony, apple, nil] as [Data?] {
            let confirmation = confirmer.confirm(report(peripheral(1), data: data, name: nil))
            #expect(confirmation == .init(camera: paired, match: .storedIdentifier))
        }
    }

    @Test func sonysCompanyIDWithACamerasNameConfirmsACameraWithoutAnIdentifier() {
        let confirmer = ProximityConfirmer(known: [paired, usbOnly])
        let confirmation = confirmer.confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2"))
        #expect(confirmation == .init(camera: usbOnly, match: .companyAndName))
    }

    @Test func theModelIsMatchedWhateverTheCase() {
        let confirmer = ProximityConfirmer(known: [usbOnly])
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: "ilce-7cm2"))?.camera == usbOnly)
    }

    @Test func anotherCompanysDataIsIgnoredEvenWithACamerasName() {
        let confirmer = ProximityConfirmer(known: [usbOnly])
        #expect(confirmer.confirm(report(peripheral(9), data: apple, name: "ILCE-7CM2")) == nil)
        #expect(confirmer.confirm(report(peripheral(9), data: nil, name: "ILCE-7CM2")) == nil)
        #expect(confirmer.confirm(report(peripheral(9), data: Data([0x2D]), name: "ILCE-7CM2")) == nil) // too short
    }

    @Test func sonyDataWithoutACamerasNameIsIgnored() {
        let confirmer = ProximityConfirmer(known: [KnownCamera(key: "k", peripheral: nil, model: "")])
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: "WH-1000XM5")) == nil)
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: nil)) == nil)
    }

    @Test func anotherModelIsIgnored() {
        let confirmer = ProximityConfirmer(known: [usbOnly])
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: "ILCE-7M4")) == nil)
    }

    @Test func theModelIsMatchedAsAWholeWordNotAPrefix() {
        // An α7C and an α7C II, both used only over USB: the α7C II's name is the α7C II, not both.
        let a7c = KnownCamera(key: "a7c", peripheral: nil, model: "ILCE-7C")
        let a7c2 = KnownCamera(key: "a7c2", peripheral: nil, model: "ILCE-7CM2")
        let both = ProximityConfirmer(known: [a7c, a7c2])
        #expect(both.confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2"))?.camera == a7c2)
        #expect(both.confirm(report(peripheral(9), data: sony, name: "ILCE-7C"))?.camera == a7c)
        // Only the α7C known: a nearby α7C II isn't taken for it.
        #expect(ProximityConfirmer(known: [a7c]).confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2")) == nil)
        #expect(ProximityConfirmer(known: [KnownCamera(key: "a7", peripheral: nil, model: "ILCE-7")])
            .confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2")) == nil)
    }

    @Test func aNameThatIsExactlyTheModelBeatsOneThatHasItAsAWord() {
        let exact = KnownCamera(key: "exact", peripheral: nil, model: "ILCE-7CM2")
        let word = KnownCamera(key: "word", peripheral: nil, model: "ILCE") // a whole word of "ILCE-7CM2" too
        let confirmer = ProximityConfirmer(known: [word, exact])
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2"))?.camera == exact)
        #expect(ProximityConfirmer(known: [exact]).confirm(report(peripheral(9), data: sony, name: "SONY ILCE-7CM2"))?.camera
            == exact)
    }

    @Test func wholeWordsAreFoundAnywhereInTheName() {
        #expect(ProximityConfirmer.name("ILCE-7CM2", hasWord: "ILCE-7CM2"))
        #expect(ProximityConfirmer.name("SONY ILCE-7CM2 (2)", hasWord: "ILCE-7CM2"))
        #expect(ProximityConfirmer.name("ILCE-7CX ILCE-7C", hasWord: "ILCE-7C"))
        #expect(!ProximityConfirmer.name("ILCE-7CM2", hasWord: "ILCE-7C"))
        #expect(!ProximityConfirmer.name("XILCE-7C", hasWord: "ILCE-7C"))
        #expect(!ProximityConfirmer.name("ILCE", hasWord: "ILCE-7C"))
    }

    @Test func aCameraWithAStoredIdentifierIsNeverMatchedByAnotherPeripheralsName() {
        // Another identifier is another camera body: a friend's α7C II next to Shamil's.
        let confirmer = ProximityConfirmer(known: [paired])
        #expect(confirmer.confirm(report(peripheral(2), data: sony, name: "ILCE-7CM2")) == nil)
    }

    @Test func aCameraWhoseModelIsUnknownTakesAnySonyCamerasName() {
        let unknownModel = KnownCamera(key: "new", peripheral: nil, model: "")
        let confirmer = ProximityConfirmer(known: [unknownModel])
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: "ILCE-7M4")) == .init(camera: unknownModel,
                                                                                               match: .companyAndName))
    }

    @Test func aMatchingModelBeatsAnUnknownOne() {
        let unknownModel = KnownCamera(key: "new", peripheral: nil, model: "")
        let confirmer = ProximityConfirmer(known: [unknownModel, usbOnly])
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2"))?.camera == usbOnly)
    }

    @Test func twoCamerasThatFitEquallyConfirmNeither() {
        let second = KnownCamera(key: "usb-only-2", peripheral: nil, model: "ILCE-7CM2")
        let confirmer = ProximityConfirmer(known: [usbOnly, second])
        #expect(confirmer.confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2")) == nil)
        let unknownA = KnownCamera(key: "a", peripheral: nil, model: "")
        let unknownB = KnownCamera(key: "b", peripheral: nil, model: "")
        #expect(ProximityConfirmer(known: [unknownA, unknownB]).confirm(report(peripheral(9), data: sony,
                                                                                name: "ILCE-7CM2")) == nil)
    }

    @Test func noKnownCamerasConfirmsNothing() {
        #expect(ProximityConfirmer(known: []).confirm(report(peripheral(1), data: sony, name: "ILCE-7CM2")) == nil)
    }

    @Test func aConnectionEventIsConfirmedByTheStoredIdentifierOnly() {
        let confirmer = ProximityConfirmer(known: [paired, usbOnly])
        let known = ProximityReport(peripheral: peripheral(1), at: when, rssi: nil, advertisement: nil, name: "ILCE-7CM2",
                                    source: .connectionEvent)
        let other = ProximityReport(peripheral: peripheral(9), at: when, rssi: nil, advertisement: nil, name: "ILCE-7CM2",
                                    source: .connectionEvent)
        #expect(confirmer.confirm(known)?.match == .storedIdentifier)
        #expect(confirmer.confirm(other) == nil)
    }

    @Test func theExplicitFormAgreesWithTheReportForm() throws {
        let confirmer = ProximityConfirmer(known: [usbOnly])
        let advertisement = try SonyAdvertisement(manufacturerData: sony)
        #expect(confirmer.confirm(peripheral: peripheral(9), advertisement: advertisement, name: "ILCE-7CM2")
            == confirmer.confirm(report(peripheral(9), data: sony, name: "ILCE-7CM2")))
    }
}

@Suite("Proximity values")
struct ProximityValueTests {
    @Test func aReportPrintsNoIdentifierNameOrManufacturerData() {
        let id = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!
        let r = ProximityReport(peripheral: PeripheralID(id), at: when, rssi: -83, manufacturerData: sony, name: "ILCE-7CM2")
        for text in [r.description, r.debugDescription, String(describing: r), String(reflecting: r), "\(r)"] {
            #expect(!text.contains("12345678"))
            #expect(!text.uppercased().contains("ILCE"))
            #expect(!text.contains("A5") && !text.contains("165"))  // the payload byte, in hex or decimal
            #expect(text.contains("-83"))
        }
        var dumped = ""
        dump(r, to: &dumped)
        #expect(!dumped.contains("12345678") && !dumped.uppercased().contains("ILCE"))
    }

    @Test func coreBluetooths127MeansNoRSSI() {
        #expect(ProximityReport.rssi(fromCoreBluetooth: 127) == nil)
        #expect(ProximityReport.rssi(fromCoreBluetooth: -83) == -83)
        #expect(ProximityReport.rssi(fromCoreBluetooth: 0) == 0)
    }

    @Test func manufacturerDataIsSplitOrDropped() {
        let parsed = ProximityReport(peripheral: peripheral(1), at: when, rssi: nil, manufacturerData: sony, name: nil)
        #expect(parsed.advertisement?.isSony == true)
        #expect(parsed.advertisement?.payload.count == SonyAdvertisement.observedPayloadLength)
        let short = ProximityReport(peripheral: peripheral(1), at: when, rssi: nil, manufacturerData: Data([1]), name: nil)
        #expect(short.advertisement == nil)
        #expect(short.source == .advertisement)
    }

    @Test func aRestoredStateKnowsTheProximityScan() {
        let scan = RestoredState(scanServices: [SonyBluetooth.advertisedService], peripherals: [])
        #expect(scan.includesProximityScan)
        // What Core Bluetooth hands back for 1800 is its short form; the bridge turns it into the full UUID.
        #expect(SonyBluetooth.uuid(bluetoothString: "1800") == SonyBluetooth.advertisedService)
        #expect(!RestoredState(scanServices: [], peripherals: [peripheral(1)]).includesProximityScan)
        #expect(!RestoredState(scanServices: [SonyService.cameraControl.uuid], peripherals: []).includesProximityScan)
        #expect(!RestoredState(scanServices: [], peripherals: [peripheral(1)]).description.contains("0100"))
    }

    @Test func aKnownCameraPrintsNoKeyOrIdentifier() {
        let camera = KnownCamera(key: "usb-device:abcdef", peripheral: peripheral(7), model: "ILCE-7CM2")
        #expect(!camera.description.contains("abcdef"))
        #expect(camera.description.contains("identifier stored"))
        for text in [camera.debugDescription, String(describing: camera), String(reflecting: camera), "\(camera)"] {
            #expect(!text.contains("abcdef") && !text.contains("07000000"))
        }
        var dumped = ""
        dump(camera, to: &dumped)
        #expect(!dumped.contains("abcdef") && !dumped.contains("07000000"))
        #expect(dumped.contains("identifier stored"))
    }
}
