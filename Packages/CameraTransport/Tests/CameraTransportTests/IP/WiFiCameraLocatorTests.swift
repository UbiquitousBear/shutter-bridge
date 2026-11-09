import Foundation
import PTPKit
import Testing
@testable import CameraTransport

// Addresses other than the camera network's come from the documentation ranges (RFC 5737: 192.0.2.0/24,
// 198.51.100.0/24, 203.0.113.0/24), never a real home network.

@Suite("Typed camera address")
struct TypedCameraAddressTests {
    @Test func acceptsAnIPv4AddressWithOrWithoutAPort() throws {
        let plain = try #require(TypedCameraAddress("192.168.122.1"))
        #expect(plain.host == "192.168.122.1" && plain.port == PTPIP.defaultPort && plain.isIPv4)
        #expect(plain.endpoint == .cameraNetwork && plain.isCameraNetwork)

        let withPort = try #require(TypedCameraAddress("198.51.100.20:15741"))
        #expect(withPort.host == "198.51.100.20" && withPort.port == 15741 && withPort.isIPv4)
        #expect(withPort.endpoint == PTPIPEndpoint(host: "198.51.100.20", port: 15741) && !withPort.isCameraNetwork)

        #expect(TypedCameraAddress("192.0.2.1:1")?.port == 1)
        #expect(TypedCameraAddress("192.0.2.1:65535")?.port == 65535)
        #expect(TypedCameraAddress("203.0.113.0")?.host == "203.0.113.0")  // a zero octet past the first is fine
    }

    @Test func acceptsAHostNameInAnyCaseAndDropsATrailingDot() throws {
        let name = try #require(TypedCameraAddress("ILCE-7CM2.local."))
        #expect(name.host == "ilce-7cm2.local" && !name.isIPv4 && name.port == 15740)
        #expect(TypedCameraAddress("camera:15740")?.host == "camera")
        #expect(TypedCameraAddress("a1.b-2.c3")?.host == "a1.b-2.c3")
        // A name with a numeric label is still a name if any label isn't all digits.
        #expect(TypedCameraAddress("192.0.2.camera")?.isIPv4 == false)
        #expect(TypedCameraAddress(String(repeating: "a", count: 63) + ".local") != nil)
    }

    @Test func trimsSpacesAroundTheAddress() {
        #expect(TypedCameraAddress("  192.168.122.1 \n")?.isCameraNetwork == true)
        #expect(TypedCameraAddress("\t198.51.100.20:15740\r\n")?.host == "198.51.100.20")
    }

    @Test(arguments: [
        "", "   ", ":15740", "192.168.122.1:", "192.168.122.1:0", "192.168.122.1:65536", "192.168.122.1:99999",
        "192.168.122.1:-1", "192.168.122.1:+80", "192.168.122.1:port", "192.168.122.1:15740:1",
        "192.168.122", "192.168.122.1.5", "300.1.1.1", "192.168.122.256", "192.168.010.1", "1.2.3.0004",
        "192..122.1", ".camera", "camera..local", "-camera.local", "camera-.local", "cam_era.local", "cam era",
        "http://192.168.122.1", "192.168.122.1/dd.xml", "user@camera.local", "[::1]", "[fe80::1]:15740", "fe80::1",
        "caméra.local", String(repeating: "a", count: 64) + ".local", String(repeating: "a.", count: 130) + "a",
        // Addresses no camera can be at: unspecified, "this network", loopback, multicast, reserved and broadcast.
        "0.0.0.0", "0.1.2.3:15740", "127.0.0.1", "127.1.2.3:15740", "224.0.0.251", "239.255.255.250:1900",
        "240.0.0.1", "255.255.255.255:1",
    ])
    func refuses(_ text: String) {
        #expect(TypedCameraAddress(text) == nil)
    }

    @Test func itsDescriptionWithholdsEveryAddressButTheCameraNetworks() throws {
        #expect(try #require(TypedCameraAddress("192.168.122.1")).description == "192.168.122.1:15740 (camera network)")
        let other = try #require(TypedCameraAddress("203.0.113.5:15740"))
        #expect(!other.description.contains("203.0.113.5") && other.description.contains("withheld"))
        let name = try #require(TypedCameraAddress("camera.local"))
        #expect(!name.description.contains("camera.local"))
    }

    @Test func equalAddressesAreEqualHoweverTyped() {
        #expect(TypedCameraAddress("Camera.Local.") == TypedCameraAddress(" camera.local:15740"))
        #expect(TypedCameraAddress("192.168.122.1") == TypedCameraAddress("192.168.122.1:15740"))
        #expect(TypedCameraAddress("192.168.122.1") != TypedCameraAddress("192.168.122.1:15741"))
    }
}

@Suite("Wi-Fi path snapshot")
struct WiFiPathSnapshotTests {
    @Test func theCameraNetworkIsTheSatisfiedPathWithTheCamerasGateway() {
        let camera = WiFiPathSnapshot(isSatisfied: true, ipv4Gateways: ["192.168.122.1"])
        #expect(camera.gateway == "192.168.122.1" && camera.isCameraNetwork)
        #expect(camera.hasGateway("192.168.122.1") && !camera.hasGateway("192.0.2.1"))

        // The camera's gateway listed second is still the gateway the locator and the session see.
        let second = WiFiPathSnapshot(isSatisfied: true, ipv4Gateways: ["192.0.2.1", "192.168.122.1"])
        #expect(second.gateway == "192.168.122.1" && second.isCameraNetwork)
        #expect(WiFiCameraLocator.isCameraNetwork(gateway: second.gateway))

        let other = WiFiPathSnapshot(isSatisfied: true, ipv4Gateways: ["192.0.2.1", "198.51.100.1"])
        #expect(other.gateway == "192.0.2.1" && !other.isCameraNetwork)

        let down = WiFiPathSnapshot(isSatisfied: false, ipv4Gateways: ["192.168.122.1"])
        #expect(down.gateway == nil && !down.isCameraNetwork && !down.hasGateway("192.168.122.1"))

        let none = WiFiPathSnapshot(isSatisfied: true, ipv4Gateways: [])
        #expect(none.gateway == nil && !none.isCameraNetwork)
    }
}

@Suite("Wi-Fi camera locator")
struct WiFiCameraLocatorTests {
    /// A camera announcing on another network; a throwing builder, so a parser change fails the tests that use it
    /// rather than the whole test process.
    static func announcement() throws -> SSDPNotify {
        try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "\(CameraNotify.udn)::x",
                                         location: "http://198.51.100.30:64321/dd.xml"))
    }

    @Test func onTheCamerasNetworkTheCameraIsTheGateway() {
        let location = WiFiCameraLocator.locate(gateway: "192.168.122.1", typed: nil)
        #expect(location == WiFiCameraLocation(endpoint: .cameraNetwork, route: .cameraNetwork,
                                               source: .cameraNetworkGateway))
        #expect(WiFiCameraLocator.isCameraNetwork(gateway: "192.168.122.1"))
        #expect(!WiFiCameraLocator.isCameraNetwork(gateway: "192.0.2.1") && !WiFiCameraLocator.isCameraNetwork(gateway: nil))
    }

    @Test func theCamerasNetworkWinsOverATypedAddressAndAnAnnouncement() throws {
        let location = WiFiCameraLocator.locate(gateway: "192.168.122.1", typed: TypedCameraAddress("198.51.100.9"),
                                                announced: try Self.announcement(), passiveSSDP: true)
        #expect(location?.source == .cameraNetworkGateway && location?.endpoint == .cameraNetwork)
    }

    @Test func elsewhereATypedAddressIsUsed() throws {
        let typed = try #require(TypedCameraAddress("198.51.100.9:15740"))
        let location = WiFiCameraLocator.locate(gateway: "192.0.2.1", typed: typed)
        #expect(location == WiFiCameraLocation(endpoint: typed.endpoint, route: .otherNetwork, source: .typed))
        // The typed address beats an announcement.
        let announcement = try Self.announcement()
        #expect(WiFiCameraLocator.locate(gateway: nil, typed: typed, announced: announcement,
                                         passiveSSDP: true)?.source == .typed)
        // Typing the camera network's address with no gateway yet (the path still settling) names that route.
        let own = WiFiCameraLocator.locate(gateway: nil, typed: TypedCameraAddress("192.168.122.1"))
        #expect(own?.route == .cameraNetwork && own?.source == .typed)
        // The route comes from the host alone: another port on the camera's address is still its network.
        let otherPort = try #require(TypedCameraAddress("192.168.122.1:15741"))
        let ownOtherPort = WiFiCameraLocator.locate(gateway: nil, typed: otherPort)
        #expect(ownOtherPort == WiFiCameraLocation(endpoint: otherPort.endpoint, route: .cameraNetwork, source: .typed))
    }

    @Test func anAnnouncementCountsOnlyWithPassiveDiscoveryOn() throws {
        #expect(WirelessFeatures.passiveSSDPDiscovery == false)  // this round: off
        let announcement = try Self.announcement()
        #expect(WiFiCameraLocator.locate(gateway: "192.0.2.1", typed: nil, announced: announcement) == nil)
        let found = WiFiCameraLocator.locate(gateway: "192.0.2.1", typed: nil, announced: announcement,
                                             passiveSSDP: true)
        #expect(found == WiFiCameraLocation(endpoint: PTPIPEndpoint(host: "198.51.100.30", port: 15740),
                                            route: .otherNetwork, source: .announced))
        #expect(found.map { !$0.description.contains("198.51.100.30") } == true)
    }

    @Test func onlyASonyImagingAnnouncementWithAnIPv4LocationLocatesTheCamera() throws {
        let root = try SSDPNotify(CameraNotify.rootDevice)
        #expect(WiFiCameraLocator.locate(gateway: nil, typed: nil, announced: root, passiveSSDP: true) == nil)
        let byName = try SSDPNotify(CameraNotify.text(nt: SSDPNotify.sonyImagingType, usn: "u",
                                                      location: "http://camera.local:64321/dd.xml"))
        #expect(byName.cameraAddress == nil)
        #expect(WiFiCameraLocator.locate(gateway: nil, typed: nil, announced: byName, passiveSSDP: true) == nil)
        let own = try SSDPNotify(CameraNotify.sonyImaging)
        #expect(WiFiCameraLocator.locate(gateway: nil, typed: nil, announced: own, passiveSSDP: true)?.route
            == .cameraNetwork)
    }

    @Test func withNothingToGoOnTheAppAsksForAnAddress() {
        #expect(WiFiCameraLocator.locate(gateway: nil, typed: nil) == nil)
        #expect(WiFiCameraLocator.locate(gateway: "192.0.2.1", typed: nil) == nil)
    }

    @Test func readsTheGatewayFromThePath() async {
        let path = FixedGatewayPath(gateway: "192.168.122.1")
        #expect(await WiFiCameraLocator.locate(path: path, typed: nil)?.source == .cameraNetworkGateway)
        let elsewhere = FixedGatewayPath(gateway: "192.0.2.1")
        #expect(await WiFiCameraLocator.locate(path: elsewhere, typed: nil) == nil)
        #expect(await WiFiCameraLocator.locate(path: elsewhere, typed: TypedCameraAddress("198.51.100.9"))?.source
            == .typed)
    }
}

/// A Wi-Fi path whose gateway never changes.
struct FixedGatewayPath: WiFiPathWatching {
    var current: String?
    init(gateway: String?) { current = gateway }
    func gateway() async -> String? { current }
    func waitForGateway(_ ip: String, timeout: Duration) async -> Bool { current == ip }
}
