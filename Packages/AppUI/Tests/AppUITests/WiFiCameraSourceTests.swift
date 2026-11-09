import CameraTransport
import Catalogue
import Foundation
import Synchronization
import Testing
@testable import AppUI

private let peripheral = PeripheralID(UUID(uuidString: "0E1D2C3B-4A59-6877-8695-A4B3C2D1E0F0")!)
private let anotherPeripheral = PeripheralID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
private let fixedNow = Date(timeIntervalSince1970: 1_794_000_000)

/// Counts and answers the Local Network gate.
private final class ExplanationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var answer = true
    private var asked = 0
    var asks: Int { lock.withLock { asked } }
    func set(_ answer: Bool) { lock.withLock { self.answer = answer } }
    func ask() -> Bool { lock.withLock { asked += 1; return answer } }
}

private struct Harness {
    let catalogue: InMemoryCatalogue
    let pending: InMemoryPendingWiFiCameraStore
    let connecting = FakeConnecting()
    let log = RecordingLog()
    let gate: ExplanationGate
    let source: WiFiCameraSource
    let discoveries: Collector<CameraDiscoveryEvent>
    let events: Collector<WiFiConnectionEvent>

    init(cameras: [CameraRecord] = [], pending: [PendingWiFiCamera] = [], catalogue: InMemoryCatalogue? = nil,
         pendingStore: InMemoryPendingWiFiCameraStore? = nil, withGate: Bool = false) {
        let catalogue = catalogue ?? InMemoryCatalogue(cameras: cameras)
        let store = pendingStore ?? InMemoryPendingWiFiCameraStore(pending)
        let gate = ExplanationGate()
        let connecting = self.connecting
        let log = self.log
        self.gate = gate
        self.catalogue = catalogue
        self.pending = store
        var ask: (@Sendable () async -> Bool)?
        if withGate { ask = { gate.ask() } }
        source = WiFiCameraSource(catalogue: catalogue, pending: store, connecting: connecting,
                                  beforeFirstConnection: ask, now: { fixedNow }, log: log)
        discoveries = Collector(source.discoveries)
        events = Collector(source.connectionEvents)
    }

    /// Pairs a camera and returns its ID with its session ready to script.
    func pair(_ id: PeripheralID = peripheral) async -> (id: CameraDescriptor.ID, session: FakeSession) {
        let descriptor = await source.registerPairedCamera(peripheral: id)
        return (descriptor.id, session(for: descriptor.id))
    }

    func session(for id: CameraDescriptor.ID) -> FakeSession {
        // The source asks the connector for the session on first use; asking first makes the same one.
        let entry = WiFiCameraEntry(descriptor: CameraDescriptor(id: id, name: "Camera", mode: .wifi(.cameraNetwork)),
                                    key: nil, peripheral: nil, guid: UUID())
        return connecting.session(for: entry) as! FakeSession
    }

    var key: CameraKey { CameraKeys.key(for: WiFiCameraEntry.placeholderDescriptor, material: fakeSerial) }
}

extension WiFiCameraEntry {
    fileprivate static var placeholderDescriptor: CameraDescriptor {
        CameraDescriptor(id: .init(rawValue: "x"), name: "Camera", mode: .wifi(.cameraNetwork))
    }
}

@Suite("Wi-Fi cameras as a discovery")
struct WiFiCameraSourceTests {
    // MARK: Listing

    @Test func itListsConnectedAndPairedCamerasWithoutRequiringReach() async throws {
        let guid = UUID()
        let record = CameraRecord(key: CameraKey(rawValue: "wifi-serial:abc"), model: "ILCE-7CM2",
                                  preferredCarrier: .wifi, ptpipGUID: guid, bluetoothPeripheralID: peripheral.uuid)
        let usbRecord = CameraRecord(key: CameraKey(rawValue: "usb-device:def"), preferredCarrier: .usb)
        let waiting = PendingWiFiCamera(guid: UUID(), peripheral: anotherPeripheral.uuid)
        let h = Harness(cameras: [record, usbRecord], pending: [waiting])
        try await h.source.start()
        #expect(await h.discoveries.wait(for: 2))
        let listed = h.discoveries.all.compactMap { event -> CameraDescriptor? in
            if case let .appeared(camera) = event { camera } else { nil }
        }
        #expect(listed.count == 2)   // the USB row isn't a Wi-Fi camera
        #expect(listed.allSatisfy { $0.mode == .wifi(.cameraNetwork) && $0.name == "Camera" })
        #expect(listed.map(\.id).contains(WiFiCameraEntry.id(forGUID: guid)))
        #expect(await h.source.knownKey(for: WiFiCameraEntry.id(forGUID: guid)) == record.key)
        #expect(await h.source.knownKey(for: WiFiCameraEntry.id(forGUID: waiting.guid)) == nil)
        #expect(h.connecting.sessionCount == 0)   // nothing is joined to be listed
    }

    @Test func startingTwiceListsOnce() async throws {
        let h = Harness(pending: [PendingWiFiCamera(guid: UUID(), peripheral: peripheral.uuid)])
        try await h.source.start()
        try await h.source.start()
        // Another camera listed after the second start: if the second start had listed the first camera again, its event
        // would sit between the two.
        let other = await h.source.registerPairedCamera(peripheral: anotherPeripheral)
        #expect(await h.discoveries.wait(for: 2))
        let first = await h.source.cameras.first { $0.id != other.id }?.descriptor
        #expect(first != nil)
        #expect(h.discoveries.all == [.appeared(first!), .appeared(other)])
        #expect(await h.source.cameras.count == 2)
    }

    @Test func aCatalogueThatCantBeReadStillListsThePairedCameras() async throws {
        let store = InMemoryPendingWiFiCameraStore([PendingWiFiCamera(guid: UUID(), peripheral: peripheral.uuid)])
        let log = RecordingLog()
        let source = WiFiCameraSource(catalogue: BrokenCatalogue(), pending: store, connecting: FakeConnecting(),
                                      log: log)
        let events = Collector(source.discoveries)
        try await source.start()
        #expect(await events.wait(for: 1))
        #expect(log.lines.contains { $0.contains("couldn't be read") })
    }

    @Test func aRowWithATypedAddressIsOnAnotherNetwork() async throws {
        let guid = UUID()
        let typed = CameraRecord(key: CameraKey(rawValue: "wifi-serial:t"), preferredCarrier: .wifi, lastIP: "\(typedHost):15741",
                                 ptpipGUID: guid)
        let own = CameraRecord(key: CameraKey(rawValue: "wifi-serial:o"), preferredCarrier: .wifi,
                               lastIP: WirelessCamera.cameraNetworkGateway, ptpipGUID: UUID())
        let h = Harness(cameras: [typed, own])
        try await h.source.start()
        #expect(await h.discoveries.wait(for: 2))
        let entries = await h.source.cameras
        let modes = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.descriptor.mode) })
        #expect(modes[WiFiCameraEntry.id(forGUID: guid)] == .wifi(.otherNetwork))
        #expect(modes.values.contains(.wifi(.cameraNetwork)))
    }

    @Test func aConnectedCameraWinsOverItsPendingEntry() async throws {
        let guid = UUID()
        let record = CameraRecord(key: CameraKey(rawValue: "wifi-serial:abc"), preferredCarrier: .wifi, ptpipGUID: guid)
        let h = Harness(cameras: [record], pending: [PendingWiFiCamera(guid: guid, peripheral: peripheral.uuid)])
        try await h.source.start()
        #expect(await h.discoveries.wait(for: 1))
        let entries = await h.source.cameras
        #expect(entries.count == 1)
        #expect(entries.first?.key == record.key)
    }

    // MARK: Setting up

    @Test func aPairedCameraIsListedKeptAndRegisteredOnce() async {
        let h = Harness()
        let first = await h.source.registerPairedCamera(peripheral: peripheral)
        let again = await h.source.registerPairedCamera(peripheral: peripheral)
        #expect(first == again)
        #expect(first.mode == .wifi(.cameraNetwork) && first.name == "Camera")
        #expect(await h.discoveries.wait(for: 1))
        #expect(h.discoveries.all == [.appeared(first)])
        #expect(h.pending.load().count == 1)
        #expect(h.pending.load().first?.peripheral == peripheral.uuid)
        #expect(await h.source.knownKey(for: first.id) == nil)   // no key until the first session has a serial
        #expect(await h.catalogue.cameras().isEmpty)   // and nothing in the catalogue under a key that will change
        // Another camera is another entry.
        let second = await h.source.registerPairedCamera(peripheral: anotherPeripheral)
        #expect(second.id != first.id)
    }

    @Test func aTypedCameraIsOnTheOtherNetworkAndRegisteredOnce() async throws {
        let h = Harness()
        let address = try #require(TypedCameraAddress("\(typedHost):15741"))
        let first = await h.source.addTypedCamera(address)
        let again = await h.source.addTypedCamera(address)
        #expect(first == again)
        #expect(first.mode == .wifi(.otherNetwork))
        #expect(h.pending.load().first?.typedAddress == "\(typedHost):15741")
        #expect(h.pending.load().first?.peripheral == nil)
        let other = try #require(TypedCameraAddress(typedHost))
        #expect(await h.source.addTypedCamera(other).id != first.id)   // another port is another camera
    }

    // MARK: Opening

    @Test func theFirstConnectionSavesTheCameraUnderItsSerialKey() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let link = FakeWiFiLink()
        session.script(.success(link))
        session.set(peripheral: anotherPeripheral)   // the scan found it under a new identifier
        let opened = try await h.source.cameraLink(for: id)
        #expect(ObjectIdentifier(opened) == ObjectIdentifier(link))
        let key = CameraKeys.key(for: opened.descriptor, material: fakeSerial)
        #expect(await h.source.knownKey(for: id) == key)
        let record = try #require(await h.catalogue.camera(key))
        #expect(record.preferredCarrier == .wifi)
        #expect(record.model == "ILCE-7CM2")
        let guid = await h.source.cameras.first?.guid
        #expect(record.ptpipGUID == guid && guid != nil)
        #expect(record.bluetoothPeripheralID == anotherPeripheral.uuid)
        #expect(record.wifiSSID == "test-network")
        #expect(record.lastSeen == fixedNow)
        #expect(record.lastIP == nil)
        #expect(h.pending.load().isEmpty)   // moved into the catalogue
        // The descriptor doesn't change, so a camera being browsed isn't dropped when its key becomes known: the entry
        // under the same ID now has the key, and no second camera was listed.
        #expect(await h.discoveries.wait(for: 1))
        let entries = await h.source.cameras
        #expect(entries.map(\.id) == [id] && entries.first?.key == key)
        let another = await h.source.registerPairedCamera(peripheral: anotherPeripheral)
        #expect(await h.discoveries.wait(for: 2))
        #expect(h.discoveries.all.count == 2 && h.discoveries.all.last == .appeared(another))
    }

    @Test func theNextLaunchKnowsTheKeyAndTheGUID() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: id)
        // A new source over the same catalogue and pending list.
        let next = Harness(catalogue: h.catalogue, pendingStore: h.pending)
        try await next.source.start()
        #expect(await next.discoveries.wait(for: 1))
        #expect(next.discoveries.all == h.discoveries.all)   // the same descriptor: the same ID
        let before = await h.source.knownKey(for: id)
        let after = await next.source.knownKey(for: id)
        #expect(after == before && after != nil)
    }

    @Test func aLiveLinkIsHandedOutAgainWithoutPreparingAnother() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        let first = try await h.source.cameraLink(for: id)
        let second = try await h.source.cameraLink(for: id)
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
        #expect(session.count("prepare") == 1)   // a second prepare would close the link under a running import
    }

    @Test func whenTheLastHolderLetsGoTheStayStartsAndTheNextOpenPreparesAgain() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let first = FakeWiFiLink()
        let second = FakeWiFiLink()
        session.script(.success(first), .success(second))
        let link = try await h.source.cameraLink(for: id)
        await h.source.linkClosed(FakeWiFiLink())   // some other link: nothing happens
        #expect(session.count("importFinished") == 0)
        await h.source.linkClosed(link)
        #expect(session.count("importFinished") == 1)
        let next = try await h.source.cameraLink(for: id)
        #expect(ObjectIdentifier(next) == ObjectIdentifier(second))
        #expect(session.count("prepare") == 2)
    }

    @Test func aLinkWithNoSerialLeavesTheCameraUnsaved() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink(serial: nil)))
        _ = try await h.source.cameraLink(for: id)
        #expect(await h.source.knownKey(for: id) == nil)
        #expect(await h.catalogue.cameras().isEmpty)
        #expect(h.pending.load().count == 1)
        #expect(h.log.lines.contains { $0.contains("reports no serial") })
    }

    @Test func aLinkThatDoesntIdentifyItselfIsTreatedAsHavingNoSerial() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeLink(items: [], mode: .wifi(.cameraNetwork))))
        _ = try await h.source.cameraLink(for: id)
        #expect(await h.source.knownKey(for: id) == nil)
        #expect(await h.catalogue.cameras().isEmpty)
    }

    @Test func anotherCameraAnsweringIsRefusedAndNothingIsImportedFromIt() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: id)
        await h.source.linkClosed(try await h.source.cameraLink(for: id))
        let wrong = FakeWiFiLink(serial: otherSerial)
        session.script(.success(wrong))
        do {
            _ = try await h.source.cameraLink(for: id)
            Issue.record("another camera's link was handed out")
        } catch {
            #expect(error.kind == .identityChanged)
            #expect(!"\(error)".contains(otherSerial) && !"\(error)".contains(fakeSerial))
        }
        #expect(await wrong.closed)
        #expect(session.count("leave") == 1)
        #expect(await h.source.openFailureText(for: id) == WiFiWording.failure(.link(CameraLinkFailure(.identityChanged))))
        let kept = await h.source.knownKey(for: id)
        #expect(kept == CameraKeys.key(for: WiFiCameraEntry.placeholderDescriptor, material: fakeSerial))
        // The catalogue still holds the one camera it knew.
        let rows = await h.catalogue.cameras()
        #expect(rows.count == 1)
    }

    @Test func theSameCameraAnsweringAgainIsAccepted() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()), .success(FakeWiFiLink()))
        let first = try await h.source.cameraLink(for: id)
        await h.source.linkClosed(first)
        _ = try await h.source.cameraLink(for: id)
        #expect(session.count("leave") == 0)
    }

    @Test func aFailureIsMappedKeptWithItsNextStepAndClearedBySuccess() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.failure(.paused(.joinDeclined)), .success(FakeWiFiLink()))
        do {
            _ = try await h.source.cameraLink(for: id)
            Issue.record("no failure")
        } catch {
            #expect(error.kind == .notAuthorised)
        }
        let text = await h.source.openFailureText(for: id)
        #expect(text == WiFiWording.paused(.joinDeclined))
        #expect(text?.contains("Join") == true)
        #expect(await h.events.wait(for: 2))
        #expect(h.events.all.contains(.failed(id, .paused(.joinDeclined))))
        _ = try await h.source.cameraLink(for: id)
        #expect(await h.source.openFailureText(for: id) == nil)
    }

    @Test func everyFailureMapsToAKindAndNothingPrivateReachesTheLog() async throws {
        let failures: [WirelessFailure] = [
            .paused(.needsJoin), .paused(.notPaired), .paused(.bluetoothOff), .paused(.bluetoothNotAllowed),
            .paused(.joinDeclined), .cameraNotFound, .bluetooth(.timedOut), .handoff(.notPaired), .join(.userDenied),
            .join(.other(3)), .noGateway, .cameraWiFiLapsed, .link(CameraLinkFailure(.refused, detail: "d")), .cancelled,
        ]
        let expected: [CameraLinkFailure.Kind] = [
            .noAnswer, .noAnswer, .noAnswer, .notAuthorised, .notAuthorised, .noAnswer, .noAnswer, .noAnswer,
            .notAuthorised, .noAnswer, .noAnswer, .noAnswer, .refused, .disconnected,
        ]
        #expect(failures.map { WiFiCameraSource.linkFailure(for: $0).kind } == expected)
        let h = Harness()
        let (id, session) = await h.pair()
        for failure in failures {
            session.script(.failure(failure))
            _ = try? await h.source.cameraLink(for: id)
        }
        for line in h.log.lines {
            #expect(!line.contains(fakeSerial) && !line.contains("test-network") && !line.contains(typedHost))
        }
    }

    @Test func aCancelHasNoTextSoTheCallerClosesTheScreen() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.failure(.cancelled))
        do {
            _ = try await h.source.cameraLink(for: id)
        } catch {
            #expect(error.kind == .disconnected)
        }
        #expect(await h.source.openFailureText(for: id) == nil)
    }

    @Test func anUnknownCameraIsDisconnected() async {
        let h = Harness()
        do {
            _ = try await h.source.cameraLink(for: .init(rawValue: "wifi-nope"))
            Issue.record("opened a camera nobody set up")
        } catch {
            #expect(error.kind == .disconnected)
        }
    }

    // MARK: The Local Network gate

    @Test func aDeclinedExplanationStartsNoConnection() async throws {
        let h = Harness(withGate: true)
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        h.gate.set(false)
        do {
            _ = try await h.source.cameraLink(for: id)
            Issue.record("connected after Not Now")
        } catch {
            #expect(error.kind == .disconnected)
        }
        #expect(session.count("prepare") == 0)
        #expect(h.events.all.isEmpty)   // not even a "connecting"
        h.gate.set(true)
        _ = try await h.source.cameraLink(for: id)
        #expect(session.count("prepare") == 1)
        #expect(h.gate.asks == 2)
    }

    @Test func aLiveLinkNeedsNoNewExplanation() async throws {
        let h = Harness(withGate: true)
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: id)
        _ = try await h.source.cameraLink(for: id)
        #expect(h.gate.asks == 1)
    }

    // MARK: Typed addresses

    @Test func aTypedCameraOpensOnThePhonesNetworkWithNoSessionAndNoStay() async throws {
        let h = Harness()
        let address = try #require(TypedCameraAddress("\(typedHost):15741"))
        let descriptor = await h.source.addTypedCamera(address)
        let link = FakeWiFiLink()
        h.connecting.scriptTyped(.success(link))
        let opened = try await h.source.cameraLink(for: descriptor.id)
        #expect(ObjectIdentifier(opened) == ObjectIdentifier(link))
        #expect(h.connecting.typedOpens.map(\.endpoint) == [address.endpoint])
        #expect(h.connecting.sessionCount == 0)
        let key = CameraKeys.key(for: descriptor, material: fakeSerial)
        let record = try #require(await h.catalogue.camera(key))
        #expect(record.lastIP == "\(typedHost):15741" && record.preferredCarrier == .wifi)
        await h.source.linkClosed(link)   // nothing was joined, so there is no stay to start
        #expect(h.connecting.sessionCount == 0)
        // It lists as the other network after a relaunch.
        let next = Harness(catalogue: h.catalogue, pendingStore: h.pending)
        try await next.source.start()
        #expect(await next.discoveries.wait(for: 1))
        #expect(next.discoveries.all == [.appeared(descriptor)])
    }

    @Test func aTypedOpenThatFailsIsAFailureOfThatLink() async throws {
        let h = Harness()
        let descriptor = await h.source.addTypedCamera(try #require(TypedCameraAddress(typedHost)))
        h.connecting.scriptTyped(.failure(CameraLinkFailure(.refused)))
        do {
            _ = try await h.source.cameraLink(for: descriptor.id)
            Issue.record("opened")
        } catch {
            #expect(error.kind == .refused)
        }
        #expect(await h.source.openFailureText(for: descriptor.id) == BrowseWording.listingFailed(.refused))
    }

    // MARK: Phases, link events, the scene

    @Test func aSessionsPhasesAreForwardedWithTheStayRemaining() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        session.set(stayRemaining: .seconds(180))
        _ = try await h.source.cameraLink(for: id)   // makes the source read the session's phases
        session.send(.joining)
        session.send(.staying)
        #expect(await waitUntil { h.events.all.contains(.phase(id, .staying, stayRemaining: .seconds(180))) })
        #expect(h.events.all.contains(.phase(id, .joining, stayRemaining: nil)))
        #expect(h.events.all.contains(.connecting(id)))
    }

    @Test func aLinksEventsAreForwardedOnceObserved() async throws {
        let h = Harness()
        let (id, _) = await h.pair()
        let link = FakeWiFiLink()
        await h.source.observe(link, for: id)
        await link.send(.waitingForLocalNetwork)
        await link.send(.sessionLost)
        #expect(await waitUntil { h.events.all.count == 2 })
        #expect(h.events.all == [.link(id, .waitingForLocalNetwork), .link(id, .sessionLost)])
    }

    @Test func theSceneReachesEverySession() async throws {
        let h = Harness()
        let (first, one) = await h.pair()
        let (second, two) = await h.pair(anotherPeripheral)
        one.script(.success(FakeWiFiLink()))
        two.script(.success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: first)
        _ = try await h.source.cameraLink(for: second)
        await h.source.scenePhaseChanged(.background)
        await h.source.scenePhaseChanged(.inactive)
        await h.source.scenePhaseChanged(.active)
        for session in [one, two] {
            // Nothing is being imported, so the background also lets each camera go.
            #expect(session.calls == ["prepare", "background", "importFinished", "active"])
        }
    }

    @Test func theSceneBeforeAnySessionDoesNothing() async {
        let h = Harness()
        await h.source.scenePhaseChanged(.background)
        await h.source.scenePhaseChanged(.active)
        #expect(h.connecting.sessionCount == 0)
    }

    @Test func theEntryDescriptionRevealsNothing() async throws {
        let entry = WiFiCameraEntry(
            descriptor: CameraDescriptor(id: .init(rawValue: "wifi-x"), name: "Camera", mode: .wifi(.otherNetwork)),
            key: CameraKey(rawValue: "k"), peripheral: peripheral, guid: UUID(),
            typed: TypedCameraAddress("\(typedHost):15741"))
        let text = "\(entry)"
        #expect(!text.contains(typedHost) && !text.contains(peripheral.uuid.uuidString))
        #expect(text.contains("typed address"))
    }
}

@Suite("The pending cameras' store")
struct PendingStoreTests {
    @Test func userDefaultsKeepsTheListAndEmptiesWhenItIsEmpty() throws {
        let suite = "pending-store-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPendingWiFiCameraStore(defaults: defaults)
        #expect(store.load().isEmpty)
        let camera = PendingWiFiCamera(guid: UUID(), peripheral: peripheral.uuid, typedAddress: nil)
        let typed = PendingWiFiCamera(guid: UUID(), typedAddress: "\(typedHost):15740")
        store.save([camera, typed])
        #expect(store.load() == [camera, typed])
        store.save([])
        #expect(defaults.data(forKey: UserDefaultsPendingWiFiCameraStore.key) == nil)
        defaults.set(Data("not json".utf8), forKey: UserDefaultsPendingWiFiCameraStore.key)
        #expect(store.load().isEmpty)   // pair again rather than crash
    }

    @Test func theLocalNetworkRecordIsKept() throws {
        let suite = "local-network-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = UserDefaultsLocalNetworkExplainedRecord(defaults: defaults)
        #expect(!record.hasExplained)
        record.recordExplained()
        #expect(UserDefaultsLocalNetworkExplainedRecord(defaults: defaults).hasExplained)
    }
}

@Suite("Wi-Fi cameras: connections that overlap, links that die, and leaving")
struct WiFiCameraConnectionTests {
    // MARK: A link that died is not handed out again

    @Test(arguments: [CameraLinkEvent.removed, CameraLinkEvent.sessionLost])
    func aLinkThatReportedItsEndIsReplacedByAFreshOne(event: CameraLinkEvent) async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let first = FakeWiFiLink()
        let second = FakeWiFiLink()
        session.script(.success(first), .success(second))
        _ = try await h.source.cameraLink(for: id)
        await first.send(event)
        #expect(await waitUntilAsync { await h.source.hasLiveLink(for: id) == false })
        // The job is paused and still holds the dead link; Continue asks for the camera's link again.
        let next = try await h.source.cameraLink(for: id)
        #expect(ObjectIdentifier(next) == ObjectIdentifier(second))
        #expect(session.count("prepare") == 2)
    }

    @Test func aLinkWhoseEventsEndIsReplacedByAFreshOne() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let first = FakeWiFiLink()
        let second = FakeWiFiLink()
        session.script(.success(first), .success(second))
        _ = try await h.source.cameraLink(for: id)
        await first.close()   // the stream ends
        #expect(await waitUntilAsync { await h.source.hasLiveLink(for: id) == false })
        let next = try await h.source.cameraLink(for: id)
        #expect(ObjectIdentifier(next) == ObjectIdentifier(second))
    }

    @Test func aDeadLinksLastHolderLettingGoStillEndsThatCamerasImport() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let first = FakeWiFiLink()
        let second = FakeWiFiLink()
        session.script(.success(first), .success(second))
        _ = try await h.source.cameraLink(for: id)
        await first.send(.removed)
        #expect(await waitUntilAsync { await h.source.hasLiveLink(for: id) == false })
        await h.source.linkClosed(first)   // the paused job was cancelled: its lease on the dead link goes
        #expect(session.count("importFinished") == 1)
        // A dead link let go after a newer one was opened is not the newer one's end.
        let next = try await h.source.cameraLink(for: id)
        await h.source.linkClosed(first)
        #expect(session.count("importFinished") == 1)
        await h.source.linkClosed(next)
        #expect(session.count("importFinished") == 2)
    }

    @Test func aLinkIsReusedOnlyWhileItsSessionIsReady() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let first = FakeWiFiLink()
        let second = FakeWiFiLink()
        session.script(.success(first), .success(second))
        let opened = try await h.source.cameraLink(for: id)
        #expect(ObjectIdentifier(opened) == ObjectIdentifier(first))
        for phase in [WirelessPhase.staying, .leaving, .idle, .paused(.needsJoin)] {
            session.set(phase: phase)
            session.script(.success(FakeWiFiLink()))
            let before = session.count("prepare")
            _ = try await h.source.cameraLink(for: id)
            #expect(session.count("prepare") == before + 1)   // not the cached one
            session.set(phase: .ready)
        }
    }

    @Test func aTypedLinkThatReportedItsEndIsReplaced() async throws {
        let h = Harness()
        let descriptor = await h.source.addTypedCamera(try #require(TypedCameraAddress("\(typedHost):15741")))
        let first = FakeWiFiLink()
        let second = FakeWiFiLink()
        h.connecting.scriptTyped(.success(first))
        _ = try await h.source.cameraLink(for: descriptor.id)
        await first.send(.removed)
        #expect(await waitUntilAsync { await h.source.hasLiveLink(for: descriptor.id) == false })
        h.connecting.scriptTyped(.success(second))
        let next = try await h.source.cameraLink(for: descriptor.id)
        #expect(ObjectIdentifier(next) == ObjectIdentifier(second))
        #expect(h.connecting.typedOpens.count == 2)
    }

    // MARK: Two callers, one connection

    @Test func twoCallersOpeningATypedCameraShareOneConnection() async throws {
        let h = Harness()
        let descriptor = await h.source.addTypedCamera(try #require(TypedCameraAddress("\(typedHost):15741")))
        let link = FakeWiFiLink()
        h.connecting.scriptTyped(.success(link))
        h.connecting.holdTyped()
        let source = h.source
        let id = descriptor.id
        let first = Task { try? await source.cameraLink(for: id) }
        #expect(await waitUntil { h.connecting.typedOpens.count == 1 })
        let second = Task { try? await source.cameraLink(for: id) }
        // The second caller is waiting on the first's connection (no second PTP/IP session was begun).
        #expect(await waitUntilAsync { await source.joinedConnections == 1 })
        h.connecting.releaseTyped()
        let a = await bounded(first)
        let b = await bounded(second)
        let one = try #require(a ?? nil)
        let two = try #require(b ?? nil)
        #expect(ObjectIdentifier(one) == ObjectIdentifier(link) && ObjectIdentifier(two) == ObjectIdentifier(link))
        #expect(h.connecting.typedOpens.count == 1)
        #expect(await !link.closed)
    }

    @Test func twoCallersOpeningAPairedCameraShareOneSessionOpen() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let link = FakeWiFiLink()
        session.script(.success(link), .success(FakeWiFiLink()))
        session.holdPrepare()
        let source = h.source
        let first = Task { try? await source.cameraLink(for: id) }
        let second = Task { try? await source.cameraLink(for: id) }
        #expect(await waitUntilAsync { await source.joinedConnections == 1 })
        session.releasePrepare()
        let a = await bounded(first)
        let b = await bounded(second)
        let one = try #require(a ?? nil)
        let two = try #require(b ?? nil)
        #expect(ObjectIdentifier(one) == ObjectIdentifier(link) && ObjectIdentifier(two) == ObjectIdentifier(link))
        #expect(session.count("prepare") == 1)   // a second prepare would close the link the first caller holds
        #expect(await !link.closed)
        // The connection's own bookkeeping is gone: the next failure or success starts a new one.
        let third = try await source.cameraLink(for: id)
        #expect(ObjectIdentifier(third) == ObjectIdentifier(link) && session.count("prepare") == 1)
    }

    @Test func aFailedConnectionFailsEveryCallerWaitingOnItAndTheNextTriesAgain() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.failure(.cameraNotFound), .success(FakeWiFiLink()))
        session.holdPrepare()
        let source = h.source
        let first = Task { () -> CameraLinkFailure.Kind? in
            do throws(CameraLinkFailure) { _ = try await source.cameraLink(for: id); return nil } catch { return error.kind }
        }
        let second = Task { () -> CameraLinkFailure.Kind? in
            do throws(CameraLinkFailure) { _ = try await source.cameraLink(for: id); return nil } catch { return error.kind }
        }
        #expect(await waitUntilAsync { await source.joinedConnections == 1 })
        session.releasePrepare()
        #expect(await bounded(first) == .some(.noAnswer))
        #expect(await bounded(second) == .some(.noAnswer))
        #expect(session.count("prepare") == 1)
        _ = try await source.cameraLink(for: id)
        #expect(session.count("prepare") == 2)
    }

    // MARK: The camera is let go in the background even while Browse is open

    @Test func goingToTheBackgroundLetsGoOfACameraWithALiveLinkAndNoImport() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()), .success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: id)   // Browse holds it; nothing is being imported
        await h.source.scenePhaseChanged(.background, activeImport: nil)
        #expect(session.calls == ["prepare", "background", "importFinished"])
        #expect(await !h.source.hasLiveLink(for: id))
        await h.source.scenePhaseChanged(.active)
        _ = try await h.source.cameraLink(for: id)   // a fresh link, not the one the session closed
        #expect(session.count("prepare") == 2)
    }

    @Test func goingToTheBackgroundLeavesARunningImportToItsContinuedTask() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: id)
        let key = try #require(await h.source.knownKey(for: id))
        // An import of another camera is running: this camera is let go. Of this one: it is not.
        await h.source.scenePhaseChanged(.background, activeImport: CameraKey(rawValue: "someone-else"))
        #expect(session.count("importFinished") == 1)
        let (id2, session2) = await h.pair(anotherPeripheral)
        session2.script(.success(FakeWiFiLink(serial: otherSerial)))
        let busy = try await h.source.cameraLink(for: id2)
        let busyKey = try #require(await h.source.knownKey(for: id2))
        await h.source.scenePhaseChanged(.active)
        await h.source.scenePhaseChanged(.background, activeImport: busyKey)
        #expect(session2.calls.contains("importFinished") == false)
        #expect(await h.source.hasLiveLink(for: id2))
        #expect(await (busy as? FakeWiFiLink)?.closed == false)
        #expect(key != busyKey)
    }

    @Test func theImportsLeaseGoingInTheBackgroundEndsItWhileBrowseStillHoldsTheLink() async throws {
        let h = Harness()
        let (id, session) = await h.pair()
        let link = FakeWiFiLink()
        session.script(.success(link))
        _ = try await h.source.cameraLink(for: id)
        // In front: someone else still holds the link, so nothing ends.
        await h.source.linkReleased(link, activeImport: nil)
        #expect(session.count("importFinished") == 0)
        await h.source.scenePhaseChanged(.inactive)
        await h.source.linkReleased(link, activeImport: nil)
        #expect(session.count("importFinished") == 0)
        // In the background, with an import still running over it: not yet. (The key is read on its own line: inside
        // `activeImport:`, a `CameraKey?`, `#require` would check the wrapped optional and let nil through.)
        let running = try #require(await h.source.knownKey(for: id))
        await h.source.scenePhaseChanged(.background, activeImport: running)
        await h.source.linkReleased(link, activeImport: running)
        #expect(session.count("importFinished") == 0)
        // In the background, the import over: the camera is let go although Browse holds the link.
        await h.source.linkReleased(link, activeImport: nil)
        #expect(session.count("importFinished") == 1)
        #expect(await !h.source.hasLiveLink(for: id))
        await h.source.linkReleased(link, activeImport: nil)   // a link that isn't live any more: nothing
        #expect(session.count("importFinished") == 1)
    }

    @Test func aTypedCameraIsForgottenInTheBackgroundWithNoSessionToTell() async throws {
        let h = Harness()
        let descriptor = await h.source.addTypedCamera(try #require(TypedCameraAddress("\(typedHost):15741")))
        h.connecting.scriptTyped(.success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: descriptor.id)
        await h.source.scenePhaseChanged(.background)
        #expect(await !h.source.hasLiveLink(for: descriptor.id))
        #expect(h.connecting.sessionCount == 0)
    }

    // MARK: A camera set up on both routes keeps both

    @Test(arguments: [true, false])
    func aCameraPairedAndTypedInListsOnceAfterARelaunchAndKeepsItsBluetoothRoute(pairedFirst: Bool) async throws {
        let h = Harness()
        let (pairedID, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        let address = try #require(TypedCameraAddress("\(typedHost):15741"))
        let typed = await h.source.addTypedCamera(address)
        h.connecting.scriptTyped(.success(FakeWiFiLink()))
        let pairedGUID = try #require(await h.source.cameras.first { $0.id == pairedID }?.guid)
        if pairedFirst {
            _ = try await h.source.cameraLink(for: pairedID)
            _ = try await h.source.cameraLink(for: typed.id)
        } else {
            _ = try await h.source.cameraLink(for: typed.id)
            _ = try await h.source.cameraLink(for: pairedID)
        }
        #expect(h.pending.load().isEmpty)
        let record = try #require(await h.catalogue.camera(h.key))
        #expect(record.bluetoothPeripheralID == peripheral.uuid)   // the typed connection didn't erase it
        #expect(record.lastIP == "\(typedHost):15741")             // nor the paired one the address
        #expect(record.ptpipGUID == pairedGUID)                    // the paired route owns the initiator GUID
        let next = Harness(catalogue: h.catalogue, pendingStore: h.pending)
        try await next.source.start()
        #expect(await next.discoveries.wait(for: 1))
        let entries = await next.source.cameras
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.descriptor.mode == .wifi(.cameraNetwork))   // still paired
        #expect(entry.peripheral == peripheral && entry.typed == nil && entry.guid == pairedGUID)
    }

    @Test func aTypedConnectionWritesOnlyItsAddressToARowThatIsntPaired() async throws {
        let h = Harness()
        let address = try #require(TypedCameraAddress("\(typedHost):15741"))
        let typed = await h.source.addTypedCamera(address)
        h.connecting.scriptTyped(.success(FakeWiFiLink()))
        _ = try await h.source.cameraLink(for: typed.id)
        let record = try #require(await h.catalogue.camera(h.key))
        #expect(record.lastIP == "\(typedHost):15741" && record.bluetoothPeripheralID == nil && record.ptpipGUID != nil)
    }

    // MARK: Declined, observed

    @Test func aDeclinedExplanationIsReportedAsDeclinedUntilTheNextOpen() async throws {
        let h = Harness(withGate: true)
        let (id, session) = await h.pair()
        session.script(.success(FakeWiFiLink()))
        #expect(await h.source.openWasDeclined(for: id) == false)
        h.gate.set(false)
        _ = try? await h.source.cameraLink(for: id)
        #expect(await h.source.openWasDeclined(for: id))
        #expect(await h.source.openFailureText(for: id) == nil)
        h.gate.set(true)
        _ = try await h.source.cameraLink(for: id)
        #expect(await h.source.openWasDeclined(for: id) == false)
    }

    @Test func aFailureThatIsntADeclineIsNotReportedAsOne() async throws {
        let h = Harness(withGate: true)
        let (id, session) = await h.pair()
        session.script(.failure(.paused(.joinDeclined)))
        _ = try? await h.source.cameraLink(for: id)
        #expect(await h.source.openWasDeclined(for: id) == false)
    }

    @Test func oneObserverPerCameraHoweverManyLinksItHasHad() async throws {
        let h = Harness()
        let (id, _) = await h.pair()
        let (other, _) = await h.pair(anotherPeripheral)
        var last = FakeWiFiLink()
        for _ in 0..<5 {
            last = FakeWiFiLink()
            await h.source.observe(last, for: id)
        }
        await h.source.observe(FakeWiFiLink(), for: other)
        #expect(await h.source.observerCount == 2)
        // The latest link's events are the ones forwarded.
        await last.send(.waitingForLocalNetwork)
        #expect(await waitUntil { h.events.all == [.link(id, .waitingForLocalNetwork)] })
    }
}
