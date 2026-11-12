import CameraTransport
import Foundation
import Testing
@testable import AppUI

/// The card's free space on the Cameras screen (I17): read once Browse has listed the card, over a link that can
/// (`CardFreeSpaceReading`; `USBLink` in MTP, CI-only), and shown through `CamerasWording.deviceStatus`. Unknown is
/// never shown, a Wi-Fi camera is never asked, and the value goes with the camera.
@MainActor
@Suite("Cameras: the card's free space")
struct CardFreeSpaceTests {
    let usb = CameraDescriptor(id: .init(rawValue: "usb"), name: "ILCE-7CM2", mode: .usb(.mtp))
    let wifi = CameraDescriptor(id: .init(rawValue: "wifi"), name: "ILCE-7CM2", mode: .wifi(.cameraNetwork))

    private func started(_ discovery: FreeSpaceDiscovery, log: RecordingLog = RecordingLog()) async -> CamerasModel {
        let model = CamerasModel(discovery: discovery, services: services(log: log))
        await model.becameActive()
        return model
    }

    @Test func theFreeSpaceShowsOnceBrowseHasListedTheCard() async {
        let link = FreeSpaceLink(descriptor: usb, freeSpace: 52_301_234_176)
        let discovery = FreeSpaceDiscovery(link: link)
        let log = RecordingLog()
        let model = await started(discovery, log: log)
        await discovery.send(.appeared(usb))
        #expect(await eventually { model.cameras == [usb] })
        // Not before the card is listed: the link isn't asked.
        #expect(model.deviceStatusLines(for: usb).isEmpty)
        #expect(await link.asked == 0)

        let browse = model.browseModel(for: usb)
        let run = Task { await browse.run() }
        #expect(await eventually { model.cardFreeBytes[usb.id] == 52_301_234_176 })
        #expect(model.deviceStatusLines(for: usb)
            == CamerasWording.deviceStatus(carrier: .usb, batteryPercent: nil, freeBytes: 52_301_234_176))
        #expect(model.deviceStatusLines(for: usb).count == 1)
        #expect(log.lines.contains("cameras: the card has 52301234176 bytes free"))
        run.cancel()
        await run.value
    }

    @Test func anUnknownFreeSpaceIsLeftOutAndKeepsTheLastOne() async {
        let link = FreeSpaceLink(descriptor: usb, freeSpace: nil)
        let discovery = FreeSpaceDiscovery(link: link)
        let model = await started(discovery)
        await discovery.send(.appeared(usb))
        #expect(await eventually { model.cameras == [usb] })
        await model.readCardFreeSpace(of: usb)
        #expect(await link.asked == 1)
        #expect(model.cardFreeBytes[usb.id] == nil)
        #expect(model.deviceStatusLines(for: usb).isEmpty)

        await link.set(freeSpace: 1_000_000_000)
        await model.readCardFreeSpace(of: usb)
        #expect(model.cardFreeBytes[usb.id] == 1_000_000_000)
        // A read that can't be made now (a download in flight, say) doesn't take the line away.
        await link.set(freeSpace: nil)
        await model.readCardFreeSpace(of: usb)
        #expect(model.cardFreeBytes[usb.id] == 1_000_000_000)
    }

    @Test func aWiFiCameraIsNeverAsked() async {
        let link = FreeSpaceLink(descriptor: wifi, freeSpace: 5_000_000_000)
        let discovery = FreeSpaceDiscovery(link: link)
        let model = await started(discovery)
        await discovery.send(.appeared(wifi))
        #expect(await eventually { model.cameras == [wifi] })
        await model.readCardFreeSpace(of: wifi)
        #expect(await discovery.linkRequests == 0)   // no join just to ask
        #expect(await link.asked == 0)
        #expect(model.deviceStatusLines(for: wifi).isEmpty)
    }

    @Test func aLinkThatCantReadItShowsNothing() async {
        let discovery = FreeSpaceDiscovery(link: FakeLink(items: [], mode: .usb(.mtp), id: "usb"))
        let model = await started(discovery)
        await discovery.send(.appeared(usb))
        #expect(await eventually { model.cameras == [usb] })
        await model.readCardFreeSpace(of: usb)
        #expect(await discovery.linkRequests == 1)
        #expect(model.cardFreeBytes.isEmpty)
        #expect(model.deviceStatusLines(for: usb).isEmpty)
    }

    @Test func theFreeSpaceGoesWithTheCamera() async {
        let link = FreeSpaceLink(descriptor: usb, freeSpace: 2_000_000_000)
        let discovery = FreeSpaceDiscovery(link: link)
        let model = await started(discovery)
        await discovery.send(.appeared(usb))
        #expect(await eventually { model.cameras == [usb] })
        await model.readCardFreeSpace(of: usb)
        #expect(model.cardFreeBytes[usb.id] == 2_000_000_000)
        await discovery.send(.disappeared(usb.id))
        #expect(await eventually { model.cameras.isEmpty })
        #expect(model.cardFreeBytes[usb.id] == nil)
        // Plugged in again: nothing shows until the card is listed and read again.
        await discovery.send(.appeared(usb))
        #expect(await eventually { model.cameras == [usb] })
        #expect(model.deviceStatusLines(for: usb).isEmpty)
    }
}

/// Discovery handing out one link, counting the requests for it.
private actor FreeSpaceDiscovery: CameraDiscovery {
    nonisolated let discoveries: AsyncStream<CameraDiscoveryEvent>
    private let sink: AsyncStream<CameraDiscoveryEvent>.Continuation
    private let link: any CameraLink
    private(set) var linkRequests = 0

    init(link: any CameraLink) {
        self.link = link
        (discoveries, sink) = AsyncStream.makeStream()
    }

    func send(_ event: CameraDiscoveryEvent) { sink.yield(event) }
    func start() throws(CameraLinkFailure) {}

    func cameraLink(for id: CameraDescriptor.ID) throws(CameraLinkFailure) -> any CameraLink {
        linkRequests += 1
        return link
    }
}

/// A camera link over an empty-but-listed card that can say its card's free space, as `USBLink` does in MTP.
private actor FreeSpaceLink: CameraLink, CardFreeSpaceReading {
    nonisolated let descriptor: CameraDescriptor
    nonisolated let capabilities: CameraLinkCapabilities
    nonisolated let events: AsyncStream<CameraLinkEvent>
    private let eventSink: AsyncStream<CameraLinkEvent>.Continuation
    private var freeSpace: UInt64?
    private(set) var asked = 0

    init(descriptor: CameraDescriptor, freeSpace: UInt64?) {
        self.descriptor = descriptor
        capabilities = .defaults(for: descriptor.carrier)
        self.freeSpace = freeSpace
        (events, eventSink) = AsyncStream.makeStream()
    }

    func set(freeSpace: UInt64?) { self.freeSpace = freeSpace }

    func cardFreeSpace() async -> UInt64? {
        asked += 1
        return freeSpace
    }

    func open() throws(CameraLinkFailure) {}
    func list() throws(CameraLinkFailure) -> [CameraItem] { [item("DSC00001.ARW")] }
    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem { throw CameraLinkFailure(.itemNotFound) }
    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data() }
    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) -> URL {
        throw CameraLinkFailure(.itemNotFound)
    }
    func close() { eventSink.finish() }
}
