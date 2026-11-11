import Foundation
import Testing
@testable import AppUI

// The redactor over a stream holding every kind of private value, and over what must stay.

@Suite("Diagnostics: the redactor")
struct DiagnosticsRedactorTests {
    private let serial = "7654321"
    private let network = "DIRECT-Qx7k:ILCE-7CM2"
    private let password = "Fake-Pass-8813"
    private let guid = "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A"
    private let peripheral = "5a4b3c2d-1e0f-4a1b-9c8d-7e6f5a4b3c2d"
    private let hardwareID = "A1B2C3D4E5F6"

    private var redactor: DiagnosticsRedactor {
        DiagnosticsRedactor(privateValues: [serial, network, password, guid, peripheral])
    }

    /// One line per kind of value, each in a different position, so a pattern that only works at the start or the end of a
    /// line fails.
    private var stream: [String] {
        [
            "serial \(serial) joined",
            "\(network)",
            "password=\(password);",
            "guid \(guid) and lower \(guid.lowercased())",
            "peripheral \(peripheral.uppercased())",
            "udn uuid:00000000-0000-1000-0000-\(hardwareID.lowercased())",
            "hardware \(hardwareID) end",
            "mac a1:b2:c3:d4:e5:f6, again A1-B2-C3-D4-E5-F6.",
            "home address 192.168.1.20 and 10.0.0.9, 172.20.10.3",
            "(203.0.113.77)",
            "v6 2001:db8:85a3:0:0:8a2e:370:7334 and fe80::1c2d:3e4f:5a6b:7c8d and ::1",
            "camera at \(DiagnosticsRedactor.cameraGateway) is fine, 192.168.122.10 is not",
            "network name inside a word: xx\(network.lowercased())yy and \(password.uppercased())",
        ]
    }

    @Test func everyKindOfPrivateValueIsRemoved() {
        let out = redactor.redact(stream.joined(separator: "\n"))
        for forbidden in [serial, network, network.lowercased(), password, password.uppercased(), guid, guid.lowercased(),
                          peripheral, peripheral.uppercased(), hardwareID, hardwareID.lowercased(), "a1:b2:c3", "A1-B2-C3",
                          "192.168.1.20", "10.0.0.9", "172.20.10.3", "203.0.113.77", "192.168.122.10", "2001:db8", "fe80",
                          "1c2d:3e4f", "DIRECT-", "Qx7k", "8813"] {
            #expect(!out.localizedCaseInsensitiveContains(forbidden), "\"\(forbidden)\" survived in:\n\(out)")
        }
        // Still one line per input line.
        #expect(out.split(separator: "\n", omittingEmptySubsequences: false).count == stream.count)
    }

    @Test func theCamerasGatewayStaysAndTheRestOfTheLineIsKept() {
        let out = redactor.redact("camera at 192.168.122.1 is fine, 192.168.122.10 is not")
        #expect(out == "camera at 192.168.122.1 is fine, \(DiagnosticsRedactor.addressMark) is not")
        // The gateway also at the ends and with punctuation.
        #expect(redactor.redact("192.168.122.1") == "192.168.122.1")
        #expect(redactor.redact("gateway=192.168.122.1.") == "gateway=192.168.122.1.")
        // A longer last group is another address, not the gateway.
        #expect(redactor.redact("192.168.122.100") == DiagnosticsRedactor.addressMark)
    }

    @Test func whatIsNotPrivateIsLeftAlone() {
        let lines = [
            "wifi link: card ready 4.1 s after the open began, 1 poll, listed 0.2 s after the first poll (fresh)",
            "wifi link: camera DeviceInfo read: firmware 2.01 (vendor extension 0x00000011)",
            "wifi join: CC09 Wi-Fi status 2 (on) at 1.0 s into the hand-off",
            "resuming a file with 0x9211 from 16.0 MiB (16777216 B) of 48.2 MiB",
            "2026-11-11T09:30:00.123Z notice [browse] imported DSC00001.ARW 48 MiB at 10:20:30",
            "version 1.0 (19), iOS 27.0, Camera: ILCE-7CM2, firmware 2.01",
            "123456 bytes in 12 files, 99.5 percent, 3.14159",
        ]
        for line in lines { #expect(redactor.redact(line) == line) }
    }

    @Test func matchingIsCaseInsensitiveAndKnownValuesGoWholeWhenOneHoldsAnother() {
        let r = DiagnosticsRedactor(privateValues: ["Home", "Home Wi-Fi 5G"])
        #expect(r.redact("joined home wi-fi 5g, then HOME") == "joined \(DiagnosticsRedactor.privateValueMark), then "
            + DiagnosticsRedactor.privateValueMark)
    }

    @Test func aKnownValueThatIsAWordInAMarkCannotBeFoundInsideTheMark() {
        let r = DiagnosticsRedactor(privateValues: ["serial1", "removed", "value"])
        let out = r.redact("serial1 and removed and value")
        #expect(out == "\(DiagnosticsRedactor.privateValueMark) and \(DiagnosticsRedactor.privateValueMark) and "
            + DiagnosticsRedactor.privateValueMark)
    }

    @Test func emptyAndBlankValuesAreIgnored() {
        let r = DiagnosticsRedactor(privateValues: ["", "  ", "\n"])
        #expect(r.redact("nothing to remove") == "nothing to remove")
    }

    @Test func redactingTwiceChangesNothingMore() {
        let once = redactor.redact(stream.joined(separator: "\n"))
        #expect(redactor.redact(once) == once)
    }
}
