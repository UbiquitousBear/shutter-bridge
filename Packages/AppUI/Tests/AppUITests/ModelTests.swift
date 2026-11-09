import CameraTransport
import Foundation
import Testing
@testable import AppUI

actor FakeDiscovery: CameraDiscovery {
    nonisolated let discoveries: AsyncStream<USBDiscoveryEvent>
    private let sink: AsyncStream<USBDiscoveryEvent>.Continuation
    var refuses = true
    /// Starting fails with this, for a reason other than access, while set.
    var failure: CameraLinkFailure.Kind?
    private(set) var starts = 0
    let link: FakeLink

    init(link: FakeLink) {
        self.link = link
        (discoveries, sink) = AsyncStream.makeStream()
    }

    func allow() { refuses = false }
    func set(failure: CameraLinkFailure.Kind?) { self.failure = failure }
    func send(_ event: USBDiscoveryEvent) { sink.yield(event) }

    func start() throws(CameraLinkFailure) {
        starts += 1
        if let failure { throw CameraLinkFailure(failure, detail: "browse: scripted") }
        if refuses { throw CameraLinkFailure(.notAuthorised, detail: "browse: contents access denied") }
    }

    func cameraLink(for id: CameraDescriptor.ID) throws(CameraLinkFailure) -> any CameraLink { link }
}

@MainActor
func services(maker: FakeMaker = FakeMaker(), clipboard: FakeClipboard = FakeClipboard(),
              scratch: JPEGScratch = temporaryScratch(), log: RecordingLog = RecordingLog()) -> BrowseServices {
    BrowseServices(maker: maker, clipboard: clipboard, scratch: scratch, log: log)
}

@MainActor
@Suite("Cameras screen model")
struct CamerasModelTests {
    let camera = CameraDescriptor(id: .init(rawValue: "a"), name: "Untitled", mode: .usb(.massStorage))

    @Test func refusedAccessIsSaidAndRetriedOnTheNextActivation() async {
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        #expect(model.access == .notAllowed)
        #expect(!model.isLooking)
        await discovery.allow()
        await model.becameActive()
        #expect(model.access == .allowed)
        #expect(model.isLooking)
        await model.becameActive()   // started: not asked again
        #expect(await discovery.starts == 2)
    }

    @Test func camerasAppearUpdateAndGo() async {
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        await discovery.allow()
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        await discovery.send(.appeared(camera))
        #expect(await eventually { model.cameras == [camera] })
        var renamed = camera
        renamed.name = "ILCE"
        await discovery.send(.appeared(renamed))
        #expect(await eventually { model.cameras.map(\.name) == ["ILCE"] })
        await discovery.send(.disappeared(camera.id))
        #expect(await eventually { model.cameras.isEmpty })
        #expect(model.notice == nil)   // not browsed, so no message
    }

    @Test func aBrowsedCameraGoingAwayReturnsToCamerasWithAMessage() async {
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        await discovery.allow()
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        await discovery.send(.appeared(camera))
        #expect(await eventually { !model.cameras.isEmpty })
        model.path = [camera]
        await discovery.send(.disappeared(camera.id))
        #expect(await eventually { model.path.isEmpty })
        #expect(model.notice == "The camera was disconnected. Connect it again to see its card.")
    }

    @Test func aSecondDisconnectWithTheSameTextIsANewNotice() {
        let model = CamerasModel(discovery: FakeDiscovery(link: FakeLink(items: [])), services: services())
        model.path = [camera]
        model.cameraWentAway(camera.id)
        let first = model.noticeStatus
        // The camera came back under a new ID and was browsed again while the first notice was still up.
        let again = CameraDescriptor(id: .init(rawValue: "again"), name: camera.name, mode: camera.mode)
        model.path = [again]
        model.cameraWentAway(again.id)
        let second = model.noticeStatus
        #expect(first?.text == "The camera was disconnected. Connect it again to see its card.")
        #expect(second?.text == first?.text)
        #expect(second != first)
        #expect(second?.announcement.priority == .high)
        model.notice = nil
        #expect(model.noticeStatus == nil)
    }

    @Test func theDisconnectedNoticeGoesWhenTheCameraComesBack() async {
        let other = CameraDescriptor(id: .init(rawValue: "b"), name: "Other", mode: .usb(.massStorage))
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        await discovery.allow()
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        await discovery.send(.appeared(camera))
        #expect(await eventually { !model.cameras.isEmpty })
        model.path = [camera]
        await discovery.send(.disappeared(camera.id))
        #expect(await eventually { model.notice != nil })
        await discovery.send(.appeared(other))   // another camera: the notice is still about this one
        #expect(await eventually { model.cameras == [other] })
        #expect(model.notice == "The camera was disconnected. Connect it again to see its card.")
        await discovery.send(.appeared(camera))
        #expect(await eventually { model.cameras == [other, camera] })
        #expect(model.notice == nil)
    }

    @Test func launchRemovesLeftoversOnce() throws {
        let scratch = temporaryScratch()
        _ = try scratch.makeActionFolder()
        let model = CamerasModel(discovery: FakeDiscovery(link: FakeLink(items: [])), services: services(scratch: scratch))
        model.launch()
        #expect(actionFolders(in: scratch).isEmpty)
        _ = try scratch.makeActionFolder()
        model.launch()   // once per launch: an action's folder made since is kept
        #expect(actionFolders(in: scratch).count == 1)
    }
}

@MainActor
@Suite("Browse model: listing, removal and Copy as JPEG")
struct BrowseModelTests {
    let card = [
        item("DSC00001.ARW", at: 10),
        item("DSC00001.JPG", at: 10),
        item("DSC00002.ARW", at: 20),
        item("DSC00003.JPG", at: 30),
        item("DSC00004.HIF", at: 40),
        item("C0001.MP4", at: 50),
    ]

    struct Harness {
        let model: BrowseModel
        let link: FakeLink
        let clipboard: FakeClipboard
        let scratch: JPEGScratch
        let log: RecordingLog
        let gone: GoneBox
        let run: Task<Void, Never>
    }

    @MainActor final class GoneBox {
        var ids: [CameraDescriptor.ID] = []
    }

    func start(maker: FakeMaker = FakeMaker(), items: [CameraItem]? = nil,
               listFailure: CameraLinkFailure? = nil, mode: CameraMode = .usb(.massStorage)) async -> Harness {
        let link = FakeLink(items: items ?? card, mode: mode)
        await link.set(listFailure: listFailure)
        let clipboard = FakeClipboard()
        let scratch = temporaryScratch()
        let log = RecordingLog()
        let gone = GoneBox()
        let model = BrowseModel(
            camera: link.descriptor,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in link },
            services: services(maker: maker, clipboard: clipboard, scratch: scratch, log: log),
            onGone: { gone.ids.append($0) }
        )
        let run = Task { await model.run() }
        return Harness(model: model, link: link, clipboard: clipboard, scratch: scratch, log: log, gone: gone, run: run)
    }

    func listed(_ h: Harness) async -> Bool {
        await eventually { h.model.phase == .listed }
    }

    func named(_ name: String) -> CameraItem { card.first { $0.name == name }! }

    @Test func listsNewestFirstByDayAndClosesTheLinkOnLeaving() async {
        let h = await start()
        #expect(await listed(h))
        #expect(h.model.sections.flatMap(\.items).map(\.name)
            == ["C0001.MP4", "DSC00004.HIF", "DSC00003.JPG", "DSC00002.ARW", "DSC00001.ARW", "DSC00001.JPG"])
        #expect(h.log.lines.contains { $0.hasPrefix("browse: listed 6 files in ") })
        #expect(await h.model.thumbnail(for: named("DSC00003.JPG").id) != nil)
        #expect(await !h.link.closed)
        h.run.cancel()
        await h.run.value
        #expect(await h.link.closed)
    }

    @Test func remoteShootListsNoFiles() async {
        let h = await start(listFailure: CameraLinkFailure(.modeListsNoFiles), mode: .usb(.mtp))
        #expect(await eventually { h.model.phase == .listsNoFiles })
        h.run.cancel()
        await h.run.value
    }

    @Test func aFailedListingCanBeRetried() async {
        let h = await start(listFailure: CameraLinkFailure(.noAnswer))
        #expect(await eventually { h.model.phase == .failed(BrowseWording.listingFailed(.noAnswer)) })
        #expect(h.model.canRetry)
        await h.link.set(listFailure: nil)
        h.model.retry()
        #expect(await listed(h))
        h.run.cancel()
        await h.run.value
    }

    @Test func removalReturnsToCameras() async {
        let h = await start()
        #expect(await listed(h))
        await h.link.remove()
        #expect(await eventually { h.model.phase == .gone })
        #expect(h.gone.ids == [h.link.descriptor.id])
        h.run.cancel()
        await h.run.value
        #expect(await h.link.closed)
    }

    @Test func copyALoneJPGPutsThatFileOnTheClipboardAndLeavesNoFiles() async {
        let h = await start()
        #expect(await listed(h))
        h.model.copyAsJPEG(named("DSC00003.JPG"))
        #expect(h.model.action.isWorking)
        await h.model.waitForAction()
        #expect(h.clipboard.copied == [Data("DSC00003.JPG".utf8)])   // the camera's own bytes, as they are
        #expect(h.model.action == .finished("Copied DSC00003 as a JPEG."))
        #expect(actionFolders(in: h.scratch).isEmpty)
        #expect(h.log.lines.contains { $0.contains("path=jpg-as-is") && $0.contains("output-px=7008x4672") })
        h.run.cancel()
        await h.run.value
    }

    @Test func copyARAWWithItsPairFetchesThePairsJPG() async {
        let h = await start()
        #expect(await listed(h))
        h.model.copyAsJPEG(named("DSC00001.ARW"))
        await h.model.waitForAction()
        #expect(await h.link.fetched == [named("DSC00001.JPG").id])
        #expect(h.clipboard.copied == [Data("DSC00001.JPG".utf8)])
        #expect(h.log.lines.contains { $0.contains("path=pair-jpg") && $0.contains("pressed=DSC00001.ARW") })
        #expect(actionFolders(in: h.scratch).isEmpty)
        h.run.cancel()
        await h.run.value
    }

    @Test func copyARAWAloneRendersIt() async {
        let h = await start()
        #expect(await listed(h))
        h.model.copyAsJPEG(named("DSC00002.ARW"))
        await h.model.waitForAction()
        #expect(h.clipboard.copied == [Data("JPEG from DSC00002.ARW by renderRAW".utf8)])
        #expect(h.model.action == .finished("Copied DSC00002 as a JPEG."))
        #expect(h.log.lines.contains { $0.contains("path=raw-render") && $0.contains("render-s=1.50") })
        h.run.cancel()
        await h.run.value
    }

    @Test func anUndecodableRAWSaysThePreviewWasCopied() async {
        let h = await start(maker: FakeMaker(fallback: true))
        #expect(await listed(h))
        h.model.copyAsJPEG(named("DSC00002.ARW"))
        await h.model.waitForAction()
        #expect(h.model.action == .finished(JPEGWording.copiedPreview))
        #expect(h.log.lines.contains {
            $0.contains("path=preview-fallback") && $0.contains("largest-preview-px=1616x1080")
        })
        h.run.cancel()
        await h.run.value
    }

    @Test func aHEIFIsReencoded() async {
        let h = await start()
        #expect(await listed(h))
        h.model.copyAsJPEG(named("DSC00004.HIF"))
        await h.model.waitForAction()
        #expect(h.clipboard.copied == [Data("JPEG from DSC00004.HIF by reencodeHEIF".utf8)])
        h.run.cancel()
        await h.run.value
    }

    @Test func shareKeepsTheJPEGUntilTheSheetCloses() async throws {
        let h = await start()
        #expect(await listed(h))
        h.model.shareAsJPEG(named("DSC00002.ARW"))
        await h.model.waitForAction()
        let share = try #require(h.model.share)
        #expect(share.url.lastPathComponent == "DSC00002.jpg")
        #expect(FileManager.default.fileExists(atPath: share.url.path))
        #expect(h.model.isBusy)
        h.model.copyAsJPEG(named("DSC00003.JPG"))   // refused while the sheet is up
        #expect(!h.model.action.isWorking)
        h.model.shareFinished()
        #expect(h.model.share == nil)
        #expect(actionFolders(in: h.scratch).isEmpty)
        #expect(h.clipboard.copied.isEmpty)   // sharing never touches the clipboard
        h.run.cancel()
        await h.run.value
    }

    @Test func cancelStopsTheFetchAndRemovesTheFolder() async {
        let h = await start()
        #expect(await listed(h))
        await h.link.set(bytesHangs: true)
        h.model.copyAsJPEG(named("DSC00002.ARW"))
        #expect(await eventually { await h.link.bytesStarted == 1 })
        #expect(actionFolders(in: h.scratch).count == 1)
        h.model.cancelAction()
        guard case let .working(work) = h.model.action else {
            Issue.record("expected the action to be working while it cancels, got \(h.model.action)")
            return
        }
        #expect(work.statusLine == JPEGWording.cancelling)
        await h.model.waitForAction()
        #expect(h.model.action == .idle)
        #expect(actionFolders(in: h.scratch).isEmpty)
        #expect(h.clipboard.copied.isEmpty)
        h.run.cancel()
        await h.run.value
    }

    @Test func aFailedFetchSaysWhyAndRemovesTheFolder() async {
        let h = await start()
        #expect(await listed(h))
        await h.link.set(bytesFailure: CameraLinkFailure(.unreadableItem))
        h.model.copyAsJPEG(named("DSC00003.JPG"))
        await h.model.waitForAction()
        #expect(h.model.action == .failed("The camera couldn't read this file. Check the card in the camera, then try again."))
        #expect(actionFolders(in: h.scratch).isEmpty)
        h.model.dismissMessage()
        #expect(h.model.action == .idle)
        h.run.cancel()
        await h.run.value
    }

    @Test func aConversionFailureSaysSo() async {
        let h = await start(maker: FakeMaker(fails: true))
        #expect(await listed(h))
        h.model.copyAsJPEG(named("DSC00002.ARW"))
        await h.model.waitForAction()
        #expect(h.model.action == .failed("This photo couldn't be made into a JPEG on this iPhone. Import it to keep the original."))
        #expect(actionFolders(in: h.scratch).isEmpty)
        h.run.cancel()
        await h.run.value
    }

    @Test func theSameFailureTwiceInARowIsANewNotice() async throws {
        let h = await start()
        #expect(await listed(h))
        // A file where the temporary folders go: the action's folder can't be made, so it fails before any work, and
        // the second tap goes from the first failure straight to the same one.
        let fm = FileManager.default
        try fm.createDirectory(at: h.scratch.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: h.scratch.root)
        try Data().write(to: h.scratch.root)
        defer { try? fm.removeItem(at: h.scratch.root.deletingLastPathComponent()) }
        h.model.copyAsJPEG(named("DSC00003.JPG"))
        let first = try #require(h.model.actionNotice)
        h.model.copyAsJPEG(named("DSC00003.JPG"))
        let second = try #require(h.model.actionNotice)
        #expect(first.tone == .problem)
        #expect(second.text == first.text)
        #expect(second != first)   // so the screen's onChange announces it again
        h.run.cancel()
        await h.run.value
    }

    @Test func aDisconnectDuringTheFetchReturnsToCameras() async {
        let h = await start()
        #expect(await listed(h))
        await h.link.set(bytesFailure: CameraLinkFailure(.disconnected))
        h.model.copyAsJPEG(named("DSC00003.JPG"))
        await h.model.waitForAction()
        #expect(h.model.phase == .gone)
        #expect(h.gone.ids == [h.link.descriptor.id])
        #expect(actionFolders(in: h.scratch).isEmpty)
        h.run.cancel()
        await h.run.value
    }

    @Test func videoOffersNothing() async {
        let h = await start()
        #expect(await listed(h))
        let video = named("C0001.MP4")
        #expect(!h.model.offersJPEGActions(video))
        h.model.copyAsJPEG(video)
        #expect(h.model.action == .idle)
        #expect(await h.link.bytesStarted == 0)
        h.run.cancel()
        await h.run.value
    }

    @Test func leavingDuringAnActionCancelsItAndCleansUp() async {
        let h = await start()
        #expect(await listed(h))
        await h.link.set(bytesHangs: true)
        h.model.copyAsJPEG(named("DSC00002.ARW"))
        #expect(await eventually { await h.link.bytesStarted == 1 })
        h.run.cancel()
        await h.run.value
        await h.model.waitForAction()
        // Cancelled, not failed: a missed cancel would end as the closed link's `disconnected` and return to Cameras.
        #expect(h.model.action == .idle)
        #expect(h.gone.ids.isEmpty)
        #expect(h.clipboard.copied.isEmpty)
        #expect(actionFolders(in: h.scratch).isEmpty)
        #expect(await h.link.closed)
    }

    @Test(arguments: JPEGPurpose.allCases)
    func aCancelAfterThePipelinesLastCheckStillWins(purpose: JPEGPurpose) async {
        let h = await start(maker: FakeMaker(cancelsWhileMeasuring: true))
        #expect(await listed(h))
        let jpg = named("DSC00003.JPG")
        if purpose == .copy { h.model.copyAsJPEG(jpg) } else { h.model.shareAsJPEG(jpg) }
        await h.model.waitForAction()
        #expect(h.model.action == .idle)
        #expect(h.model.share == nil)
        #expect(h.clipboard.copied.isEmpty)
        #expect(actionFolders(in: h.scratch).isEmpty)
        h.run.cancel()
        await h.run.value
    }

    @Test func leavingTheForegroundCancelsTheActionAndSaysWhy() async throws {
        let h = await start()
        #expect(await listed(h))
        await h.link.set(bytesHangs: true)
        h.model.copyAsJPEG(named("DSC00002.ARW"))
        #expect(await eventually { await h.link.bytesStarted == 1 })
        await h.link.send(.willSuspend)
        try #require(await eventually { !h.model.action.isWorking })   // else the fetch hangs until the link closes
        await h.model.waitForAction()
        #expect(h.model.action == .failed(JPEGWording.keepOpen))
        #expect(h.clipboard.copied.isEmpty)
        #expect(actionFolders(in: h.scratch).isEmpty)
        #expect(h.log.lines.contains("copy-as-jpeg copy cancelled: the app left the foreground"))
        // The next action starts clean, and a suspension with nothing running says nothing.
        await h.link.set(bytesHangs: false)
        h.model.dismissMessage()
        await h.link.send(.willSuspend)
        #expect(await eventually { h.log.lines.filter { $0 == "browse: link event willSuspend" }.count == 2 })
        #expect(h.model.action == .idle)
        h.model.copyAsJPEG(named("DSC00003.JPG"))
        await h.model.waitForAction()
        #expect(h.model.action == .finished("Copied DSC00003 as a JPEG."))
        h.run.cancel()
        await h.run.value
    }
}
