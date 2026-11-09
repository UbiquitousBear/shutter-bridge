import Foundation
import Testing
@testable import CameraTransport

/// The camera's NOTIFYs as the spike logged them (findings, *SSDP discovery*; backlog section 5). The raw datagrams were
/// not saved, so these are put together from what the log and the findings record: the three NT values, LOCATION
/// `http://192.168.122.1:64321/dd.xml`, and the UDN of `Fixtures/a7c2/ptpip/ssdp-description.xml`, whose hardware ID is
/// zeroed (`uuid:00000000-0005-0010-8000-000000000000`). CACHE-CONTROL's 1800 s is UPnP's suggested minimum, not a
/// recorded value (`unverified`), and SERVER is left out (not recorded).
enum CameraNotify {
    static let udn = "uuid:00000000-0005-0010-8000-000000000000"
    static let location = "http://192.168.122.1:64321/dd.xml"

    static func text(nt: String, usn: String, nts: String = "ssdp:alive", location: String? = CameraNotify.location,
                     lineEnd: String = "\r\n") -> String {
        var lines = ["NOTIFY * HTTP/1.1", "HOST: 239.255.255.250:1900", "CACHE-CONTROL: max-age=1800"]
        if let location { lines.append("LOCATION: \(location)") }
        lines += ["NT: \(nt)", "NTS: \(nts)", "USN: \(usn)"]
        return lines.joined(separator: lineEnd) + lineEnd + lineEnd
    }

    static let rootDevice = text(nt: "upnp:rootdevice", usn: "\(udn)::upnp:rootdevice")
    static let basicDevice = text(nt: "urn:schemas-upnp-org:device:Basic:1",
                                  usn: "\(udn)::urn:schemas-upnp-org:device:Basic:1")
    static let sonyImaging = text(nt: "urn:schemas-sony-com:service:DigitalImaging:1",
                                  usn: "\(udn)::urn:schemas-sony-com:service:DigitalImaging:1")
    static let all = [rootDevice, basicDevice, sonyImaging]
}

@Suite("SSDP NOTIFY parser")
struct SSDPNotifyTests {
    @Test func parsesTheCamerasThreeAnnouncements() throws {
        let parsed = try CameraNotify.all.map { try SSDPNotify(Data($0.utf8)) }
        #expect(Set(parsed.map(\.notificationType)) == SSDPNotify.cameraNotificationTypes)
        for notify in parsed {
            #expect(notify.subtype == .alive)
            #expect(notify.location == CameraNotify.location)
            #expect(notify.locationHost == "192.168.122.1" && notify.locationPort == 64321)
            #expect(notify.maxAge == 1800)
            #expect(notify.server == nil)
            #expect(notify.uniqueServiceName.hasPrefix(CameraNotify.udn))
            #expect(notify.cameraAddress?.endpoint == .cameraNetwork)
            #expect(notify.isSent(from: "192.168.122.1"))
        }
        // Only Sony's imaging service identifies a camera; the other two come from every UPnP device.
        #expect(parsed.map(\.announcesSonyCamera) == [false, false, true])
    }

    @Test func theCamerasAddressCarriesPTPIPsPortNotTheDescriptions() throws {
        let notify = try SSDPNotify(CameraNotify.sonyImaging)
        #expect(notify.cameraAddress?.port == 15740)
        #expect(notify.cameraAddress?.isCameraNetwork == true)
    }

    @Test func theDescriptionLeavesOutTheHardwareIDAndOtherAddresses() throws {
        let own = try SSDPNotify(CameraNotify.sonyImaging)
        #expect(own.description.contains("192.168.122.1 (camera network)"))
        #expect(!own.description.contains("uuid"))
        // A camera on another network: the address is withheld (documentation range, RFC 5737).
        let other = try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "\(CameraNotify.udn)::x",
                                                     location: "http://198.51.100.7:64321/dd.xml"))
        #expect(other.locationHost == "198.51.100.7")
        #expect(!other.description.contains("198.51.100.7") && other.description.contains("withheld"))
        #expect(other.cameraAddress?.isCameraNetwork == false)
    }

    @Test func acceptsBareLineFeedsAndAnyHeaderCase() throws {
        let text = CameraNotify.sonyImaging.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "LOCATION:", with: "location:")
            .replacingOccurrences(of: "NTS:", with: "Nts:")
        let notify = try SSDPNotify(text)
        #expect(notify.announcesSonyCamera && notify.locationHost == "192.168.122.1")
    }

    @Test func aByebyeNeedsNoLocationAndAnnouncesNothing() throws {
        let notify = try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "\(CameraNotify.udn)::x",
                                                      nts: "ssdp:byebye", location: nil))
        #expect(notify.subtype == .byebye && notify.location == nil && notify.locationHost == nil)
        #expect(!notify.announcesSonyCamera && notify.cameraAddress == nil)
        #expect(notify.description.contains("no location"))
    }

    @Test func anUnknownSubtypeIsKeptAsSent() throws {
        let notify = try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "u", nts: "ssdp:propchange"))
        #expect(notify.subtype == .other("ssdp:propchange") && !notify.announcesSonyCamera)
        let update = try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "u", nts: "ssdp:update"))
        #expect(update.subtype == .update && update.announcesSonyCamera)
    }

    @Test func maxAgeIsReadAmongOtherDirectivesOrLeftNil() throws {
        func maxAge(_ value: String) throws -> Int? {
            try SSDPNotify(CameraNotify.sonyImaging.replacingOccurrences(of: "max-age=1800", with: value)).maxAge
        }
        #expect(try maxAge("no-cache, max-age = 900") == 900)
        #expect(try maxAge("MAX-AGE=60") == 60)
        #expect(try maxAge("max-age=soon") == nil)
        #expect(try maxAge("max-age=-5") == nil)
        #expect(try maxAge("no-cache") == nil)
    }

    @Test func theFirstOfARepeatedHeaderCounts() throws {
        let text = CameraNotify.sonyImaging.replacingOccurrences(
            of: "USN:", with: "LOCATION: http://203.0.113.9:1/x.xml\r\nUSN:")
        #expect(try SSDPNotify(text).locationHost == "192.168.122.1")
    }

    @Test func aDatagramFromAnotherHostThanItsLocationIsNotTheCameras() throws {
        let notify = try SSDPNotify(CameraNotify.sonyImaging)
        #expect(!notify.isSent(from: "192.168.122.2"))
    }

    // MARK: Refusals

    @Test func refusesWhatIsNotANotify() {
        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
            + "ST: urn:schemas-sony-com:service:DigitalImaging:1\r\n\r\n"
        #expect(throws: SSDPNotify.ParseError.notANotify("M-SEARCH * HTTP/1.1")) { try SSDPNotify(search) }
        let response = "HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\nUSN: u\r\nLOCATION: \(CameraNotify.location)\r\n\r\n"
        #expect(throws: SSDPNotify.ParseError.notANotify("HTTP/1.1 200 OK")) { try SSDPNotify(response) }
        #expect(throws: SSDPNotify.ParseError.notANotify("")) { try SSDPNotify("") }
        #expect(throws: SSDPNotify.ParseError.notANotify("notify * HTTP/1.1")) {
            try SSDPNotify(CameraNotify.sonyImaging.replacingOccurrences(of: "NOTIFY", with: "notify"))
        }
        #expect(throws: SSDPNotify.ParseError.notANotify("NOTIFY / HTTP/1.1")) {
            try SSDPNotify(CameraNotify.sonyImaging.replacingOccurrences(of: "NOTIFY *", with: "NOTIFY /"))
        }
    }

    @Test func refusesMissingHeaders() {
        for name in ["NT", "NTS", "USN", "LOCATION"] {
            let text = CameraNotify.sonyImaging.split(separator: "\r\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("\(name):") }.joined(separator: "\r\n")
            #expect(throws: SSDPNotify.ParseError.missingHeader(name)) { try SSDPNotify(text) }
        }
        #expect(throws: SSDPNotify.ParseError.missingHeader("USN")) {
            try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: ""))
        }
    }

    @Test func refusesMalformedHeaderLines() {
        let noColon = CameraNotify.sonyImaging.replacingOccurrences(of: "NTS: ssdp:alive", with: "NTS ssdp:alive")
        #expect(throws: SSDPNotify.ParseError.malformedHeader) { try SSDPNotify(noColon) }
        let noColonAtAll = CameraNotify.sonyImaging.replacingOccurrences(of: "CACHE-CONTROL:", with: "CACHE-CONTROL")
        #expect(throws: SSDPNotify.ParseError.malformedHeader) { try SSDPNotify(noColonAtAll) }
        let noName = CameraNotify.sonyImaging.replacingOccurrences(of: "HOST:", with: ":")
        #expect(throws: SSDPNotify.ParseError.malformedHeader) { try SSDPNotify(noName) }
    }

    @Test func refusesALocationThatIsNotAnHTTPURLWithAHost() {
        for location in ["https://192.168.122.1:64321/dd.xml", "ftp://192.168.122.1/dd.xml", "http:///dd.xml",
                         "dd.xml", "http://192.168.122.1:0/dd.xml", "http://192.168.122.1:70000/dd.xml"] {
            #expect(throws: SSDPNotify.ParseError.badLocation, "\(location)") {
                try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "u", location: location))
            }
        }
        // No port: HTTP's 80.
        let plain = try? SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "u",
                                                     location: "http://192.168.122.1/dd.xml"))
        #expect(plain?.locationPort == 80)
    }

    @Test func refusesOversizedAndNonTextDatagramsWithoutTrapping() {
        let big = Data(repeating: 0x41, count: SSDPNotify.maximumSize + 1)
        #expect(throws: SSDPNotify.ParseError.tooLarge(SSDPNotify.maximumSize + 1)) { try SSDPNotify(big) }
        #expect(throws: SSDPNotify.ParseError.notText) { try SSDPNotify(Data([0x4E, 0xFF, 0xFE, 0x00])) }
        // Every truncation of a real announcement either parses or throws; none traps.
        let bytes = Array(CameraNotify.sonyImaging.utf8)
        for length in 0 ... bytes.count {
            _ = try? SSDPNotify(Data(bytes.prefix(length)))
        }
    }
}
