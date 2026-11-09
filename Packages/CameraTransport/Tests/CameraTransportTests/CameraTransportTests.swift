import Foundation
import PTPKit
import Testing
@testable import CameraTransport

@Suite("Camera descriptors and modes")
struct CameraDescriptorTests {
    @Test func carrierFollowsMode() {
        for mode in USBMode.allCases {
            #expect(CameraMode.usb(mode).carrier == .usb)
        }
        for route in WiFiRoute.allCases {
            #expect(CameraMode.wifi(route).carrier == .wifi)
        }
        let d = CameraDescriptor(id: .init(rawValue: "x"), name: "Untitled", mode: .usb(.massStorage))
        #expect(d.carrier == .usb)
    }

    @Test func remoteShootListsNoFilesAndMSCIsRecommended() {
        #expect(USBMode.massStorage.listsFiles)
        #expect(USBMode.mtp.listsFiles)
        #expect(!USBMode.remoteShoot.listsFiles)
        #expect(USBMode.recommended == .massStorage)
    }

    @Test func modeWordingIsTheCameras() {
        #expect(USBMode.massStorage.cameraWording == "Image Transfer (MSC)")
        #expect(USBMode.mtp.cameraWording == "Image Transfer (MTP)")
        #expect(USBMode.remoteShoot.cameraWording == "Remote Shoot (PC Remote)")
    }

    @Test func aWiFiCameraKeepsItsRouteThroughCoding() throws {
        for mode in USBMode.allCases.map(CameraMode.usb) + WiFiRoute.allCases.map(CameraMode.wifi) {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(CameraMode.self, from: data) == mode)
        }
        #expect(CameraMode.wifi(.cameraNetwork) != CameraMode.wifi(.otherNetwork))
        #expect(WiFiRoute.allCases.map(\.rawValue) == ["cameraNetwork", "otherNetwork"])
    }

    @Test func linkIDNeverPrintsItsValue() {
        let id = CameraDescriptor.ID(rawValue: "00000000-0000-0000-0000-ABCDEF123456")
        #expect(!String(describing: id).contains("ABCDEF"))
        #expect(String(describing: id) == "camera-link(36 chars)")
    }
}

@Suite("Camera items")
struct CameraItemTests {
    func item(_ name: String, _ date: Date?, folder: String = "DCIM/100MSDCF") -> CameraItem {
        CameraItem(id: .init(rawValue: name), folder: folder, name: name, size: 1, captureDate: date)
    }

    @Test func formatFollowsPTPKitsTable() {
        #expect(CameraItem.format(ofFilename: "DSC04512.ARW") == .raw)
        #expect(CameraItem.format(ofFilename: "DSC04512.JPG") == .jpeg)
        #expect(CameraItem.format(ofFilename: "dsc04512.jpg") == .jpeg)
        #expect(CameraItem.format(ofFilename: "DSC04512.HIF") == .heif)
        #expect(CameraItem.format(ofFilename: "C0001.MP4") == .video)
        #expect(CameraItem.format(ofFilename: "C0001M01.XML") == .sidecar)
        #expect(CameraItem.format(ofFilename: "README") == .other)
        #expect(item("DSC00001.ARW", nil).format == .raw)
    }

    @Test func newestFirstPutsUndatedLastAndBreaksTiesByName() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let items = [
            item("B.JPG", t),
            item("NODATE.JPG", nil),
            item("NEW.ARW", t.addingTimeInterval(60)),
            item("A.ARW", t),
        ]
        #expect(items.newestFirst().map(\.name) == ["NEW.ARW", "A.ARW", "B.JPG", "NODATE.JPG"])
    }
}

@Suite("Link failures are classified")
struct CameraLinkFailureTests {
    @Test func everyKindHasTheProposalsOutcome() {
        let expected: [CameraLinkFailure.Kind: FailureOutcome] = [
            .busy: .retryNow, .noAnswer: .retryNow,
            .disconnected: .retryOnReconnect,
            .itemNotFound: .skipFile, .unreadableItem: .skipFile, .unsupportedFormat: .skipFile,
            .phoneStorageFull: .stopJob, .notAuthorised: .stopJob, .modeListsNoFiles: .stopJob,
            // Wi-Fi: a wrong camera or a refused session ends the job, a card that isn't offered only pauses it.
            .identityChanged: .stopJob, .refused: .stopJob, .cardUnavailable: .retryOnReconnect,
        ]
        #expect(Set(expected.keys) == Set(CameraLinkFailure.Kind.allCases))
        for (kind, outcome) in expected {
            #expect(CameraLinkFailure(kind).outcome == outcome, "\(kind)")
        }
    }

    @Test func aMissingCardPausesButNeverFailsAFile() {
        // `cardUnavailable` shares `disconnected`'s outcome, which the engine already pauses on without counting a
        // failure or a retry. That is half of the fix for the spike's 82-files bug (backlog Iteration 3 section 9);
        // the other half is the link's: from StoreRemoved until StoreAdded it reports InvalidObjectHandle as
        // `cardUnavailable` too, so no queued file is read as missing and skipped.
        #expect(CameraLinkFailure.Kind.cardUnavailable.outcome == CameraLinkFailure.Kind.disconnected.outcome)
        #expect(CameraLinkFailure(.cardUnavailable, detail: "StoreNotAvailable").description
                == "cardUnavailable → retryOnReconnect (StoreNotAvailable)")
    }

    @Test func everyOutcomeIsReachable() {
        #expect(Set(CameraLinkFailure.Kind.allCases.map(\.outcome)) == Set(FailureOutcome.allCases))
    }

    @Test func descriptionCarriesTheDetailForTheLog() {
        #expect(CameraLinkFailure(.disconnected, detail: "ImageCaptureCore -9934").description
                == "disconnected → retryOnReconnect (ImageCaptureCore -9934)")
    }
}

/// A link over a fixed list, to show the protocol can be met in Swift 6 strict mode with no Apple framework.
actor ListLink: CameraLink {
    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "fake"), name: "Fake", mode: .usb(.mtp))
    nonisolated let capabilities = CameraLinkCapabilities.usb
    private let fanOut = EventFanOut<CameraLinkEvent>()
    private let items: [CameraItem]
    private(set) var isOpen = false
    /// What each `bytes` call was offered to resume, in order.
    private(set) var offered: [PartialDownload?] = []

    init(items: [CameraItem]) {
        self.items = items
    }

    /// A new stream per read, which gets only what happens from now on.
    nonisolated var events: AsyncStream<CameraLinkEvent> { fanOut.subscribe() }

    func open() throws(CameraLinkFailure) { isOpen = true }

    func list() throws(CameraLinkFailure) -> [CameraItem] {
        guard isOpen else { throw CameraLinkFailure(.disconnected) }
        return items
    }

    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem {
        guard let found = items.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        return found
    }

    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data([0xFF, 0xD8]) }

    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) throws(CameraLinkFailure) -> URL {
        offered.append(resuming)
        let found = try info(of: item)
        progress(found.size)
        return directory.appendingPathComponent(found.name)
    }

    func send(_ event: CameraLinkEvent) { fanOut.send(event) }

    func close() {
        isOpen = false
        fanOut.finish()
    }
}

@Suite("A CameraLink without hardware")
struct CameraLinkContractTests {
    @Test func listBeforeOpenIsRetryOnReconnect() async throws {
        let link = ListLink(items: [])
        await #expect(throws: CameraLinkFailure(.disconnected)) { try await link.list() }
    }

    @Test func openListAndCopy() async throws {
        let file = CameraItem(id: .init(rawValue: "1"), folder: "DCIM/100MSDCF", name: "DSC00001.ARW",
                              size: 44_000_000, captureDate: nil)
        let link = ListLink(items: [file])
        try await link.open()
        #expect(try await link.list() == [file])
        let url = try await link.bytes(of: file.id, into: URL(fileURLWithPath: "/tmp"))
        #expect(url.lastPathComponent == "DSC00001.ARW")
        do {
            _ = try await link.info(of: .init(rawValue: "missing"))
            Issue.record("expected a failure")
        } catch {
            #expect(error.outcome == .skipFile)
        }
    }

    @Test func theOldCallsAreAFreshCopy() async throws {
        let file = CameraItem(id: .init(rawValue: "1"), folder: "DCIM/100MSDCF", name: "DSC00001.ARW",
                              size: 10, captureDate: nil)
        let link = ListLink(items: [file])
        let folder = URL(fileURLWithPath: "/tmp")
        _ = try await link.bytes(of: file.id, into: folder)
        _ = try await link.bytes(of: file.id, into: folder, progress: { _ in })
        let partial = PartialDownload(file: folder.appendingPathComponent("p"), bytesWritten: 4)
        _ = try await link.bytes(of: file.id, into: folder, resuming: partial, checkpoint: { _ in }, progress: { _ in })
        #expect(await link.offered == [nil, nil, partial])
        #expect(partial == PartialDownload(file: partial.file, bytesWritten: 4))
        #expect(partial != PartialDownload(file: partial.file, bytesWritten: 5))
    }

    @Test func wifiEventsArriveInOrderAndAreDistinct() async {
        let link = ListLink(items: [])
        let events = link.events
        let sent: [CameraLinkEvent] = [.waitingForLocalNetwork, .storeRemoved, .storeAdded, .sessionLost, .removed]
        for event in sent { await link.send(event) }
        await link.close()
        var seen: [CameraLinkEvent] = []
        for await e in events { seen.append(e) }
        #expect(seen == sent)
        #expect(Set(sent).count == sent.count)
    }

    @Test func eventsArriveInOrderAndFinishOnClose() async {
        let link = ListLink(items: [])
        await link.send(.removed) // before anyone listened: never delivered
        let events = link.events
        await link.send(.willSuspend)
        await link.send(.didSuspend)
        await link.send(.resumedOperations)
        await link.close()
        var seen: [CameraLinkEvent] = []
        for await e in events { seen.append(e) }
        #expect(seen == [.willSuspend, .didSuspend, .resumedOperations])
        var afterClose = 0
        for await _ in link.events { afterClose += 1 }
        #expect(afterClose == 0)
    }
}

@Suite("Link capabilities")
struct CameraLinkCapabilitiesTests {
    @Test func usbBaseline() {
        let usb = CameraLinkCapabilities.defaults(for: .usb)
        #expect(usb == .usb)
        #expect(usb.maxDownloadsInFlight == 2)
        #expect(!usb.resumesPartialFiles)
        #expect(usb.reportsBatteryAndFreeSpace)
        #expect(!usb.itemIDsSurviveReopen)
    }

    @Test func wifiBaseline() {
        let wifi = CameraLinkCapabilities.defaults(for: .wifi)
        #expect(wifi == .wifi)
        #expect(wifi.maxDownloadsInFlight == 1)       // one PTP/IP transaction at a time (backlog, Iteration 3)
        #expect(wifi.resumesPartialFiles)             // 0x9211
        #expect(!wifi.reportsBatteryAndFreeSpace)     // no device properties, capacity 0
        #expect(!wifi.deletes)                        // the session's storage is read-only
        #expect(wifi.itemIDsSurviveReopen)
    }

    @Test func everyCarrierHasABaselineAndTheyDiffer() {
        let baselines = CameraCarrier.allCases.map(CameraLinkCapabilities.defaults(for:))
        #expect(baselines.count == 2)
        #expect(Set(baselines).count == baselines.count)
    }

    @Test func modesFollowTheirCarrier() {
        for mode in USBMode.allCases { #expect(CameraLinkCapabilities.defaults(for: CameraMode.usb(mode).carrier) == .usb) }
        for route in WiFiRoute.allCases { #expect(CameraLinkCapabilities.defaults(for: CameraMode.wifi(route).carrier) == .wifi) }
    }

    @Test func aLimitAssignedLaterIsClampedToOneToo() {
        var c = CameraLinkCapabilities.wifi
        for assigned in [-3, 0] {
            c.maxDownloadsInFlight = assigned
            #expect(c.maxDownloadsInFlight == 1, "\(assigned)")
        }
        c.maxDownloadsInFlight = 2
        #expect(c.maxDownloadsInFlight == 2)
    }

    @Test func aLinkAlwaysAllowsOneDownload() {
        for requested in [-3, 0, 1] {
            let c = CameraLinkCapabilities(maxDownloadsInFlight: requested, resumesPartialFiles: false,
                                           reportsBatteryAndFreeSpace: false, deletes: false,
                                           itemIDsSurviveReopen: false)
            #expect(c.maxDownloadsInFlight == 1, "\(requested)")
        }
    }

    @Test func aLinkReportsItsCapabilitiesWithoutAwaiting() {
        let link = ListLink(items: [])
        let c: CameraLinkCapabilities = link.capabilities // nonisolated: no await
        #expect(c == .usb)
    }
}
