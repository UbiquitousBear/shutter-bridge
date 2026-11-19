import CameraTransport
import Foundation
import Testing
@testable import AppUI

// Browse's run belongs to its model (Shamil, 19 Nov): the screen starts it as it appears and nothing stops it as it
// disappears, so another tab hiding Browse isn't leaving it. Only the camera leaving the navigation path (Back, the
// swipe back, or code replacing the path) stops it. The screen's part is played by the test, as `LiveApp` plays it: the
// path is set, the model made and `start()` called; "another tab" is the path staying as it is while `start()` is
// called again for the screen's reappearance. The Wi-Fi half (the connection Browse started) is in
// `WiFiModelsIntegrationTests`.

@MainActor
@Suite("Browse's run: kept across tabs, stopped by leaving Browse")
struct BrowseRunTests {
    let card = [item("DSC00001.ARW", at: 10), item("DSC00002.ARW", at: 20)]

    struct Rig {
        let cameras: CamerasModel
        let discovery: ScriptedDiscovery
        let link: FakeLink
        let leases: LinkLeases
        let log: RecordingLog
        var camera: CameraDescriptor { link.descriptor }
    }

    /// A USB camera in Image Transfer (MSC) whose link discovery hands out.
    func rig() async -> Rig {
        let link = FakeLink(items: card, id: "usb-a")
        let discovery = ScriptedDiscovery()
        await discovery.set(link: link, for: link.descriptor.id)
        let leases = LinkLeases()
        let log = RecordingLog()
        let cameras = CamerasModel(discovery: discovery, services: services(log: log), leases: leases)
        return Rig(cameras: cameras, discovery: discovery, link: link, leases: leases, log: log)
    }

    /// What `LiveApp` does when the person opens the camera: the path, then the screen's model, started as it appears.
    func open(_ r: Rig) -> BrowseModel {
        r.cameras.path = [r.camera]
        let browse = r.cameras.browseModel(for: r.camera)
        browse.start()
        return browse
    }

    @Test func startingAgainWhileTheRunIsUnderWayDoesNothing() async throws {
        let r = await rig()
        let browse = open(r)
        browse.start()
        #expect(await eventually { browse.phase == .listed })
        browse.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await r.link.listCount == 1)
        #expect(browse.isStarted)
        #expect(r.log.lines.filter { $0.hasPrefix("browse: listed") }.count == 1)
        r.cameras.path = []
        #expect(await eventually { await r.link.closed })
    }

    @Test func anotherTabKeepsTheUSBLinkAndTheListing() async throws {
        let r = await rig()
        let browse = open(r)
        #expect(await eventually { browse.phase == .listed })
        // Another tab, then back: the path is unchanged, and the screen appears again.
        try await Task.sleep(for: .milliseconds(200))
        browse.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(browse.isStarted)
        #expect(browse.phase == .listed)
        #expect(await !r.link.closed)
        #expect(await r.link.listCount == 1)   // the card isn't read again
        #expect(r.leases.holders(of: r.link) == 1)
    }

    @Test func leavingBrowseClosesTheUSBLink() async {
        let r = await rig()
        let browse = open(r)
        #expect(await eventually { browse.phase == .listed })
        r.cameras.path = []   // Back
        #expect(await eventually { await r.link.closed })
        #expect(await eventually { !browse.isStarted })
        #expect(r.leases.holders(of: r.link) == 0)
        #expect(r.log.lines.contains("browse: left; stopping"))
    }

    @Test func leavingBrowseWhileAnImportHoldsTheLinkReleasesOnlyBrowsesLease() async {
        let r = await rig()
        let browse = open(r)
        #expect(await eventually { browse.phase == .listed })
        r.leases.acquire(r.link)   // the import's
        r.cameras.path = []
        #expect(await eventually { r.leases.holders(of: r.link) == 1 })
        #expect(await eventually { !browse.isStarted })
        #expect(await !r.link.closed)
        await r.leases.release(r.link)
        #expect(await r.link.closed)
    }

    @Test func openingAnotherCameraStopsTheBrowseLeftBehind() async {
        let r = await rig()
        let browse = open(r)
        #expect(await eventually { browse.phase == .listed })
        let other = CameraDescriptor(id: .init(rawValue: "usb-b"), name: "Untitled", mode: .usb(.massStorage))
        r.cameras.path = [other]
        #expect(await eventually { await r.link.closed })
        #expect(!browse.isStarted)
    }

    @Test func aRenamedDescriptorOnThePathDoesntStopBrowse() async throws {
        let r = await rig()
        let browse = open(r)
        #expect(await eventually { browse.phase == .listed })
        var renamed = r.camera
        renamed.name = "ILCE-7CM2"
        r.cameras.path = [renamed]
        try await Task.sleep(for: .milliseconds(100))
        #expect(browse.isStarted)
        #expect(await !r.link.closed)
        r.cameras.path = []
        #expect(await eventually { await r.link.closed })
    }

    @Test func aRunThatEndedByItselfCanBeStartedAgain() async {
        let r = await rig()
        let browse = open(r)
        #expect(await eventually { browse.phase == .listed })
        // The USB link's events end under the screen: the run ends by itself, the card still shown.
        await r.link.close()
        #expect(await eventually { !browse.isStarted })
        #expect(browse.phase == .listed)
        // The screen appearing again starts it again, on the link discovery has now.
        let next = FakeLink(items: card, id: "usb-a")
        await r.discovery.set(link: next, for: r.camera.id)
        browse.start()
        #expect(browse.isStarted)
        #expect(await eventually { await next.listCount == 1 })
        #expect(await eventually { browse.phase == .listed })
        r.cameras.path = []
        #expect(await eventually { await next.closed })
    }

    /// `stop()` then `start()` straight away: the new run waits for the stopped one to let go, rather than being turned
    /// away by `run()`'s guard against a second run.
    @Test func startingStraightAfterStoppingRunsAgain() async {
        let r = await rig()
        let browse = open(r)
        #expect(await eventually { browse.phase == .listed })
        let next = FakeLink(items: card, id: "usb-a")
        await r.discovery.set(link: next, for: r.camera.id)
        browse.stop()
        browse.start()
        #expect(browse.isStarted)
        #expect(await eventually { await r.link.closed })
        #expect(await eventually { await next.listCount == 1 })
        #expect(browse.isStarted)
        #expect(await !next.closed)
        r.cameras.path = []
        #expect(await eventually { await next.closed })
    }

    @Test func aModelTheStackNeverShowedIsHarmless() async throws {
        let r = await rig()
        let unused = r.cameras.browseModel(for: r.camera)
        r.cameras.path = [r.camera]
        r.cameras.path = []
        unused.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!unused.isStarted)
        #expect(await r.discovery.linkRequests.isEmpty)
        #expect(await !r.link.isOpen)
    }

    /// The screen keeps its model while the camera stays on the path; if SwiftUI ever made Browse's screen again for
    /// it, the new model's start stops the old one, so two never run on one camera.
    @Test func aSecondBrowseStartedOnTheSameCameraStopsTheFirst() async {
        let r = await rig()
        let first = open(r)
        #expect(await eventually { first.phase == .listed })
        let next = FakeLink(items: card, id: "usb-a")
        await r.discovery.set(link: next, for: r.camera.id)
        let second = r.cameras.browseModel(for: r.camera)
        second.start()
        #expect(await eventually { !first.isStarted })
        #expect(await eventually { await r.link.closed })
        #expect(await eventually { second.phase == .listed })
        #expect(second.isStarted)
        r.cameras.path = []
        #expect(await eventually { await next.closed })
    }

    /// W6-absent: the offline Browse is replaced by the live one when its USB camera is listed. The path change stops
    /// the offline model; the live one the screen then makes and starts runs on.
    @Test func theOfflineToLiveSwapStopsOnlyTheOfflineBrowse() async throws {
        let r = await rig()
        let key = CameraKeys.key(for: r.camera, material: nil)
        await r.discovery.set(key: key, for: r.camera.id)
        await r.cameras.becameActive()
        let offlineCamera = await r.cameras.offlineCamera(for: key)
        r.cameras.path = [offlineCamera]
        let offline = r.cameras.browseModel(for: offlineCamera)
        offline.start()
        #expect(offline.offline != nil)
        await r.discovery.send(.appeared(r.camera))
        #expect(await eventually { r.cameras.path == [r.camera] })
        #expect(!offline.isStarted)
        let live = r.cameras.browseModel(for: r.camera)
        live.start()
        #expect(await eventually { live.phase == .listed })
        try await Task.sleep(for: .milliseconds(100))
        #expect(live.isStarted)
        #expect(await !r.link.closed)
        r.cameras.path = []
        #expect(await eventually { await r.link.closed })
    }
}
