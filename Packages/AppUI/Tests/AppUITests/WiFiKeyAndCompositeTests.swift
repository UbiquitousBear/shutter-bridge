import CameraTransport
import Catalogue
import Foundation
import Testing
@testable import AppUI

private func wifi(_ route: WiFiRoute = .cameraNetwork, name: String = "Camera") -> CameraDescriptor {
    CameraDescriptor(id: .init(rawValue: "w"), name: name, mode: .wifi(route))
}

private func usb(_ mode: USBMode = .mtp, name: String = "ILCE-7CM2") -> CameraDescriptor {
    CameraDescriptor(id: .init(rawValue: "u"), name: name, mode: .usb(mode))
}

@Suite("The Wi-Fi camera key")
struct WiFiCameraKeyTests {
    @Test func theKeyComesFromTheSerialAndHidesIt() {
        let key = CameraKeys.key(for: wifi(), material: fakeSerial)
        #expect(key.rawValue.hasPrefix("wifi-serial:"))
        #expect(key.rawValue.count == "wifi-serial:".count + 64)
        #expect(!key.rawValue.contains(fakeSerial))
        #expect(!"\(key)".contains("wifi-serial"))   // its description is only its length
        #expect(key != CameraKeys.key(for: wifi(), material: otherSerial))
        #expect(key == CameraKeys.key(for: wifi(), material: fakeSerial))
    }

    @Test func bothRoutesKeyAlikeAndTheNameDoesNotMatter() {
        let own = CameraKeys.key(for: wifi(.cameraNetwork), material: fakeSerial)
        #expect(own == CameraKeys.key(for: wifi(.otherNetwork), material: fakeSerial))
        #expect(own == CameraKeys.key(for: wifi(name: "ILCE-7CM2"), material: fakeSerial))
    }

    @Test func theSameSerialOverUSBIsAnotherKey() {
        // The USB key is the MTP device's UUID string, never the serial: a Wi-Fi key doesn't collide with one even if the
        // material were the same text.
        #expect(CameraKeys.key(for: wifi(), material: "x") != CameraKeys.key(for: usb(), material: "x"))
        #expect(CameraKeys.key(for: usb(), material: "x").rawValue.hasPrefix("usb-device:"))
    }

    @Test func withoutASerialItFallsBackToAnameHash() {
        for material in [nil, ""] as [String?] {
            let key = CameraKeys.key(for: wifi(), material: material)
            #expect(key.rawValue.hasPrefix("wifi-name:"))
        }
    }

    @Test func theLogNamesTheKeyByItsKindOnly() {
        let tags = CameraKeyTags()
        let key = CameraKeys.key(for: wifi(), material: fakeSerial)
        let tag = tags.tag(for: key)
        #expect(tag == "k1 (wifi-serial)")
        #expect(!tag.contains(key.rawValue.suffix(8)))
        #expect(tags.tag(for: CameraKeys.key(for: wifi(), material: nil)) == "k2 (wifi-name)")
    }

    @Test func aLinkThatIdentifiesItselfGivesItsOwnMaterial() async {
        let keying = CameraKeys.keying(material: { _ in "usb-material" })
        let link = FakeWiFiLink()
        #expect(await keying(wifi(), link) == CameraKeys.key(for: wifi(), material: fakeSerial))
        // A link with no serial yet is the name fallback, not the closure's material.
        let silent = FakeWiFiLink(serial: nil)
        #expect(await keying(wifi(), silent) == CameraKeys.key(for: wifi(), material: nil))
    }

    @Test func otherLinksStillUseTheClosure() async {
        let keying = CameraKeys.keying(material: { _ in "usb-material" })
        let key = await keying(usb(), FakeLink(items: []))
        #expect(key == CameraKeys.key(for: usb(), material: "usb-material"))
    }
}

@Suite("CompositeDiscovery")
struct CompositeDiscoveryTests {
    let usbCamera = CameraDescriptor(id: .init(rawValue: "usb-1"), name: "Untitled", mode: .usb(.massStorage))
    let wifiCamera = CameraDescriptor(id: .init(rawValue: "wifi-1"), name: "Camera", mode: .wifi(.cameraNetwork))

    @Test func eventsFromEverySourceArriveInOneStream() async {
        let a = ScriptedDiscovery()
        let b = ScriptedDiscovery()
        let composite = CompositeDiscovery(sources: [a, b])
        let events = Collector(composite.discoveries)
        try? await composite.start()
        await a.send(.appeared(usbCamera))
        await b.send(.appeared(wifiCamera))
        #expect(await events.wait(for: 2))
        #expect(Set(events.all) == [.appeared(usbCamera), .appeared(wifiCamera)])
        await b.send(.disappeared(wifiCamera.id))
        #expect(await events.wait(for: 3))
        #expect(events.all.last == .disappeared(wifiCamera.id))
    }

    @Test func aLinkComesFromTheSourceThatListedTheCamera() async throws {
        let a = ScriptedDiscovery()
        let b = ScriptedDiscovery()
        let usbLink = FakeLink(items: [])
        let wifiLink = FakeWiFiLink()
        await a.set(link: usbLink, for: usbCamera.id)
        await b.set(link: wifiLink, for: wifiCamera.id)
        let composite = CompositeDiscovery(sources: [a, b])
        let events = Collector(composite.discoveries)
        try await composite.start()
        await a.send(.appeared(usbCamera))
        await b.send(.appeared(wifiCamera))
        #expect(await events.wait(for: 2))
        let gotUSB = try await composite.cameraLink(for: usbCamera.id)
        let gotWiFi = try await composite.cameraLink(for: wifiCamera.id)
        #expect(ObjectIdentifier(gotUSB) == ObjectIdentifier(usbLink))
        #expect(ObjectIdentifier(gotWiFi) == ObjectIdentifier(wifiLink))
        let fromA = await a.linkRequests
        let fromB = await b.linkRequests
        #expect(fromA == [usbCamera.id])
        #expect(fromB == [wifiCamera.id])
    }

    @Test func aCameraNoSourceListsIsDisconnectedAndAGoneOneToo() async throws {
        let a = ScriptedDiscovery()
        await a.set(link: FakeLink(items: []), for: usbCamera.id)
        let composite = CompositeDiscovery(sources: [a])
        let events = Collector(composite.discoveries)
        try await composite.start()
        await #expect(throws: CameraLinkFailure.self) { try await composite.cameraLink(for: usbCamera.id) }
        await a.send(.appeared(usbCamera))
        #expect(await events.wait(for: 1))
        _ = try await composite.cameraLink(for: usbCamera.id)
        await a.send(.disappeared(usbCamera.id))
        #expect(await events.wait(for: 2))
        do {
            _ = try await composite.cameraLink(for: usbCamera.id)
            Issue.record("a camera that went away still had a link")
        } catch {
            #expect(error.kind == .disconnected)
        }
    }

    @Test func keysAndFailureTextsAreTheOwningSources() async throws {
        let a = ScriptedDiscovery()
        let b = ScriptedDiscovery()
        let key = CameraKey(rawValue: "k")
        await b.set(key: key, for: wifiCamera.id)
        await b.set(failureText: "Open the camera again.", for: wifiCamera.id)
        let composite = CompositeDiscovery(sources: [a, b])
        let events = Collector(composite.discoveries)
        try await composite.start()
        #expect(await composite.knownKey(for: wifiCamera.id) == nil)   // not listed yet
        await b.send(.appeared(wifiCamera))
        await a.send(.appeared(usbCamera))
        #expect(await events.wait(for: 2))
        #expect(await composite.knownKey(for: wifiCamera.id) == key)
        #expect(await composite.knownKey(for: usbCamera.id) == nil)
        #expect(await composite.openFailureText(for: wifiCamera.id) == "Open the camera again.")
        #expect(await composite.openFailureText(for: usbCamera.id) == nil)
    }

    @Test func whetherACameraIsConnectedIsTheOwningSourcesAndNoSourceMeansNot() async throws {
        let a = ScriptedDiscovery()
        let b = ScriptedDiscovery()
        await b.set(connected: false, for: wifiCamera.id)
        let composite = CompositeDiscovery(sources: [a, b])
        let events = Collector(composite.discoveries)
        try await composite.start()
        #expect(await !composite.isConnected(usbCamera.id))   // no source lists it yet
        await b.send(.appeared(wifiCamera))
        await a.send(.appeared(usbCamera))
        #expect(await events.wait(for: 2))
        #expect(await composite.isConnected(usbCamera.id))
        #expect(await !composite.isConnected(wifiCamera.id))
        await b.set(connected: true, for: wifiCamera.id)
        #expect(await composite.isConnected(wifiCamera.id))
    }

    @Test func aSourceThatFailsDoesNotStopTheOthersAndTheFirstFailureIsThrown() async {
        let denied = CameraLinkFailure(.notAuthorised, detail: "usb")
        let other = CameraLinkFailure(.noAnswer, detail: "wifi")
        let a = ScriptedDiscovery(startFailure: denied)
        let b = ScriptedDiscovery(startFailure: other)
        let c = ScriptedDiscovery()
        let composite = CompositeDiscovery(sources: [a, b, c])
        do {
            try await composite.start()
            Issue.record("start didn't throw")
        } catch {
            #expect(error == denied)   // the first source's, so USB keeps its Camera Access message
        }
        let starts = [await a.starts, await b.starts, await c.starts]
        #expect(starts == [1, 1, 1])
    }

    @Test func aLaterSourceFailingIsThrownWhenTheFirstIsFine() async {
        let failure = CameraLinkFailure(.noAnswer, detail: "wifi")
        let composite = CompositeDiscovery(sources: [ScriptedDiscovery(), ScriptedDiscovery(startFailure: failure)])
        do {
            try await composite.start()
            Issue.record("start didn't throw")
        } catch {
            #expect(error == failure)
        }
    }

    @Test func startingAgainStartsEverySourceAgain() async throws {
        let a = ScriptedDiscovery(startFailure: CameraLinkFailure(.notAuthorised))
        let b = ScriptedDiscovery()
        let composite = CompositeDiscovery(sources: [a, b])
        _ = try? await composite.start()
        await a.set(startFailure: nil)
        try await composite.start()   // Try Again after access was granted
        let starts = [await a.starts, await b.starts]
        #expect(starts == [2, 2])
    }

    @Test func theCamerasModelReadsUSBAndWiFiThroughIt() async {
        let a = ScriptedDiscovery()
        let b = ScriptedDiscovery()
        let composite = CompositeDiscovery(sources: [a, b])
        let model = await CamerasModel(discovery: composite, services: services())
        await model.becameActive()
        #expect(await model.access == .allowed)
        await a.send(.appeared(usbCamera))
        await b.send(.appeared(wifiCamera))
        #expect(await eventuallyLong { Set(model.cameras) == [usbCamera, wifiCamera] })
        await b.send(.disappeared(wifiCamera.id))
        #expect(await eventuallyLong { model.cameras == [usbCamera] })
    }

    @Test func aDeniedUSBSourceStillShowsTheWiFiCameras() async {
        let a = ScriptedDiscovery(startFailure: CameraLinkFailure(.notAuthorised))
        let b = ScriptedDiscovery()
        let model = await CamerasModel(discovery: CompositeDiscovery(sources: [a, b]), services: services())
        await model.becameActive()
        #expect(await model.access == .notAllowed)   // USB's message, unchanged
        await b.send(.appeared(wifiCamera))
        #expect(await eventuallyLong { model.cameras == [wifiCamera] })
    }
}
