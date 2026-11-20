import CameraTransport
import Catalogue
import Foundation
import Testing
@testable import AppUI

// Auto-import's setting over the catalogue's Camera rows (backlog section 14; D11): written on one-body keys, read by the
// camera's one name.

let autoImportModel = "ILCE-7CM2"
let bodyMTPKey = CameraKey(rawValue: "usb-device:body-a")
let bodyWiFiKey = CameraKey(rawValue: "wifi-serial:body-a")
let mscSharedKey = CameraKey(rawValue: "usb-msc-name:untitled")

func bodyRow(_ key: CameraKey, _ name: String = autoImportModel, on: Bool = false, seen: TimeInterval = 0,
             carrier: CameraRecord.Carrier = .usb) -> CameraRecord {
    CameraRecord(key: key, model: name, friendlyName: name, lastSeen: Date(timeIntervalSince1970: 1_794_000_000 + seen),
                 preferredCarrier: carrier, autoImport: on)
}

@Suite("Auto-import: the rule, by one name per body")
struct AutoImportRuleTests {
    let mtp = CameraDescriptor(id: .init(rawValue: "usb-1"), name: autoImportModel, mode: .usb(.mtp))
    let msc = CameraDescriptor(id: .init(rawValue: "usb-2"), name: "Untitled", mode: .usb(.massStorage))
    let wifi = CameraDescriptor(id: .init(rawValue: "wifi-1"), name: autoImportModel, mode: .wifi(.cameraNetwork))

    @Test func offByDefault() {
        #expect(AutoImportRule.decision(for: mtp, key: bodyMTPKey, records: [bodyRow(bodyMTPKey)]) == .off)
        #expect(AutoImportRule.decision(for: mtp, key: bodyMTPKey, records: []) == .off)
    }

    @Test func onForTheBodyByItsName() {
        #expect(AutoImportRule.decision(for: mtp, key: bodyMTPKey, records: [bodyRow(bodyMTPKey, on: true)]) == .on)
        // Another body's switch doesn't turn this one on.
        let other = bodyRow(CameraKey(rawValue: "usb-device:other"), "ILCE-7M4", on: true)
        #expect(AutoImportRule.decision(for: mtp, key: bodyMTPKey, records: [bodyRow(bodyMTPKey), other]) == .off)
    }

    @Test func aBodysNewWiFiKeyFollowsItsMTPRow() {
        let records = [bodyRow(bodyMTPKey, on: true)]
        #expect(AutoImportRule.decision(for: wifi, key: bodyWiFiKey, records: records) == .on)
        // A descriptor listed before the camera's first connection says "Camera": its own row names it.
        let unnamed = CameraDescriptor(id: .init(rawValue: "wifi-2"), name: "Camera", mode: .wifi(.cameraNetwork))
        #expect(AutoImportRule.decision(for: unnamed, key: bodyWiFiKey,
                                        records: records + [bodyRow(bodyWiFiKey, carrier: .wifi)]) == .on)
    }

    @Test func anMTPNameHashKeyReadsByName() {
        let nameHash = CameraKeys.key(for: mtp, material: nil)
        #expect(nameHash.rawValue.hasPrefix("usb-mtp-name:"))
        #expect(AutoImportRule.decision(for: mtp, key: nameHash, records: [bodyRow(bodyWiFiKey, on: true)]) == .on)
        #expect(AutoImportRule.decision(for: mtp, key: nil, records: [bodyRow(bodyWiFiKey, on: true)]) == .on)
    }

    @Test func mscFollowsTheOneNamedBody() {
        let records = [bodyRow(bodyMTPKey, on: true), bodyRow(bodyWiFiKey), bodyRow(mscSharedKey, "Untitled")]
        #expect(AutoImportRule.decision(for: msc, key: mscSharedKey, records: records) == .on)
        #expect(AutoImportRule.decision(for: msc, key: mscSharedKey, records: [bodyRow(bodyMTPKey)]) == .off)
    }

    @Test func mscWithTwoNamedBodiesHasNoName() {
        let records = [bodyRow(bodyMTPKey, on: true), bodyRow(CameraKey(rawValue: "usb-device:b"), "ILCE-7M4", on: true)]
        #expect(AutoImportRule.decision(for: msc, key: mscSharedKey, records: records) == .noName)
        #expect(AutoImportRule.decision(for: msc, key: mscSharedKey, records: []) == .noName)
    }

    @Test func aSharedKeysRowNeverHoldsTheSetting() {
        // `CameraNaming.learn` names the shared MSC row after the one body at each listing: it must not switch MSC on.
        let shared = bodyRow(mscSharedKey, on: true)
        #expect(AutoImportRule.decision(for: msc, key: mscSharedKey, records: [shared, bodyRow(bodyMTPKey)]) == .off)
        #expect(AutoImportRule.decision(for: mtp, key: bodyMTPKey, records: [shared, bodyRow(bodyMTPKey)]) == .off)
    }

    @Test func unidentifiedWiFiRemoteShootAndGenericAreNeverOn() {
        let records = [bodyRow(bodyMTPKey, on: true)]
        let nameHash = CameraKeys.key(for: wifi, material: nil)
        #expect(AutoImportRule.decision(for: wifi, key: nameHash, records: records) == .unidentified)
        let remote = CameraDescriptor(id: .init(rawValue: "usb-3"), name: autoImportModel, mode: .usb(.remoteShoot))
        #expect(AutoImportRule.decision(for: remote, key: bodyMTPKey, records: records) == .remoteShoot)
        let generic = CameraDescriptor(id: .init(rawValue: "usb-4"), name: "Untitled", mode: .usb(.mtp))
        #expect(AutoImportRule.decision(for: generic, key: nil, records: records) == .noName)
        // A one-body row with no name never counts as "Camera"'s switch.
        let unnamed = CameraRecord(key: CameraKey(rawValue: "usb-device:unnamed"), autoImport: true)
        #expect(AutoImportRule.decision(for: generic, key: unnamed.key, records: [unnamed]) == .noName)
    }

    @Test func choicesAreOnePerBodyNameMostRecentFirst() {
        let records = [
            bodyRow(CameraKey(rawValue: "usb-device:b"), "ILCE-7M4", seen: 30),
            bodyRow(bodyWiFiKey, on: true, seen: 20, carrier: .wifi),
            bodyRow(mscSharedKey, "ILCE-9", on: true, seen: 15),
            bodyRow(bodyMTPKey, seen: 10),
            CameraRecord(key: CameraKey(rawValue: "usb-device:unnamed"), autoImport: true),
        ]
        #expect(AutoImportRule.choices(among: records) == [
            AutoImportChoice(name: "ILCE-7M4", isOn: false),
            AutoImportChoice(name: autoImportModel, isOn: true),
        ])
        #expect(AutoImportRule.choices(among: []).isEmpty)
        #expect(AutoImportChoice(name: autoImportModel, isOn: false).id == autoImportModel)
    }

    @Test func keysNamedAreOneBodyKeysOnly() {
        let records = [bodyRow(bodyMTPKey), bodyRow(bodyWiFiKey), bodyRow(mscSharedKey),
                       bodyRow(CameraKey(rawValue: "usb-mtp-name:x")), bodyRow(CameraKey(rawValue: "wifi-name:x")),
                       bodyRow(CameraKey(rawValue: "usb-device:b"), "ILCE-7M4")]
        #expect(AutoImportRule.keys(named: autoImportModel, among: records) == [bodyMTPKey, bodyWiFiKey])
        #expect(AutoImportRule.keys(named: "ILCE-9", among: records).isEmpty)
    }
}
