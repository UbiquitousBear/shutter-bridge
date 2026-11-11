import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing
@testable import AppUI

// W13: the background run each import runs in, the pause on its early end, the pause notification and the
// notification permission (backlog Iteration 3, section 9; section 13). The model and the real engine against a fake
// run and a fake notifier, over a fake USB link and the simulated Wi-Fi link (`SimulatedCameraLink` playing the
// Wi-Fi contract: one transfer at a time, 0x9211-style resume, handles that survive a reopen).

// MARK: - Fakes

/// What happened, in order, across the engine's catalogue, the abort hook and the notifier.
final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

/// One background run: the updates it was given, how it was finished, and an expiry the test sends.
final class FakeBackgroundHandle: ImportBackgroundHandle, @unchecked Sendable {
    struct Update: Equatable {
        var completed: Int64
        var total: Int64
        var title: String?
        var subtitle: String?
    }

    let expired: AsyncStream<Void>
    private let sink: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var storedUpdates: [Update] = []
    private var storedFinishes: [Bool] = []
    private let trace: Trace?

    init(trace: Trace? = nil) {
        (expired, sink) = AsyncStream.makeStream(of: Void.self)
        self.trace = trace
    }

    var updates: [Update] { lock.withLock { storedUpdates } }
    var finishes: [Bool] { lock.withLock { storedFinishes } }

    /// iOS ends the run early (an expiry, or Stop).
    func expire() { sink.yield(()) }

    func update(completedBytes: Int64, totalBytes: Int64, title: String?, subtitle: String?) {
        lock.withLock { storedUpdates.append(Update(completed: completedBytes, total: totalBytes, title: title,
                                                    subtitle: subtitle)) }
    }

    func finish(success: Bool) {
        lock.withLock { storedFinishes.append(success) }
        trace?.add("finish \(success)")
        sink.finish()
    }
}

/// A gate a fake call waits at until the test opens it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { c in
            let ready = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if ready { c.resume() }
        }
    }

    func open() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for c in all { c.resume() }
    }
}

/// Background runs as scripted: started at once (or once `gate` opens), or refused.
final class FakeBackgroundRun: ImportBackgroundRun, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBegins: [(title: String, subtitle: String)] = []
    private var storedHandles: [FakeBackgroundHandle] = []
    private let refuses: Bool
    private let gate: Gate?
    private let trace: Trace?

    init(refuses: Bool = false, gate: Gate? = nil, trace: Trace? = nil) {
        self.refuses = refuses
        self.gate = gate
        self.trace = trace
    }

    var begins: [(title: String, subtitle: String)] { lock.withLock { storedBegins } }
    var handles: [FakeBackgroundHandle] { lock.withLock { storedHandles } }

    func begin(title: String, subtitle: String) async throws -> any ImportBackgroundHandle {
        lock.withLock { storedBegins.append((title, subtitle)) }
        if refuses { throw ImportBackgroundRunError.refused }
        await gate?.wait()
        let handle = FakeBackgroundHandle(trace: trace)
        lock.withLock { storedHandles.append(handle) }
        return handle
    }
}

/// Notification permission and posting as scripted: what reading gives, what the prompt answers.
final class FakeNotifier: LocalNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var status: NotificationAuthorisation
    private let answer: NotificationAuthorisation
    private var storedRequests = 0
    private var storedPosts: [AppNotification] = []
    private var storedWithdrawals: [AppNotification] = []
    private var storedRegistrations = 0
    private let trace: Trace?
    /// Runs as iOS's prompt comes up, before it is answered.
    var onRequest: (@Sendable () async -> Void)?

    init(_ status: NotificationAuthorisation = .authorised, answer: NotificationAuthorisation = .authorised,
         trace: Trace? = nil) {
        self.status = status
        self.answer = answer
        self.trace = trace
    }

    var requests: Int { lock.withLock { storedRequests } }
    var posts: [AppNotification] { lock.withLock { storedPosts } }
    var withdrawals: [AppNotification] { lock.withLock { storedWithdrawals } }
    var registrations: Int { lock.withLock { storedRegistrations } }

    func authorisation() async -> NotificationAuthorisation { lock.withLock { status } }

    func requestAuthorisation() async -> Bool {
        await onRequest?()
        return lock.withLock {
            storedRequests += 1
            if status == .notDetermined { status = answer }
            return status.allowsPosting
        }
    }

    func post(_ notification: AppNotification) async {
        lock.withLock { storedPosts.append(notification) }
        trace?.add("post")
    }

    func withdraw(_ notification: AppNotification) async {
        lock.withLock { storedWithdrawals.append(notification) }
        trace?.add("withdraw")
    }

    func registerCategories() async { lock.withLock { storedRegistrations += 1 } }
}

/// What the main actor saw at a moment.
@MainActor
final class Seen {
    var statusLine: String?
    var reasonLine: String?
    var isExplaining = false
}

// MARK: - The import model

@MainActor
@Suite("Continued task, pause notification and notification permission", .timeLimit(.minutes(1)))
struct ContinuedImportTests {
    struct Bench {
        let model: ImportModel
        let engine: ImportEngine
        let run: FakeBackgroundRun
        let notifier: FakeNotifier
        let destinations: FakeDestinations
        let camera: ImportCamera
        let link: any CameraLink
        /// Held here: the model's finder is weak.
        let finder: FakeFinder

        func importAll(_ items: [CameraItem]) async -> ImportRequestOutcome {
            await model.importItems(items, from: camera, link: link)
        }

        func state(_ expected: ImportJobState) async -> Bool {
            await eventually {
                await model.refresh()
                return model.state == expected
            }
        }

        func finished() async -> Bool {
            await eventually {
                await model.refresh()
                if case .finished = model.state { return true }
                return false
            }
        }

        /// The run iOS started for the `index`th begin.
        func handle(_ index: Int = 0) async -> FakeBackgroundHandle? {
            _ = await eventually { run.handles.count > index }
            let handles = run.handles
            return handles.count > index ? handles[index] : nil
        }
    }

    let usbCard = [
        item("DSC00001.ARW", at: 10, size: 4_000),
        item("DSC00001.JPG", at: 10, size: 2_000),
        item("DSC00002.JPG", at: 20, size: 3_000),
    ]

    private func bench(link: any CameraLink, catalogue: any CatalogueStore = InMemoryCatalogue(),
                       frozenClock: Bool = false, run: FakeBackgroundRun = FakeBackgroundRun(),
                       notifier: FakeNotifier = FakeNotifier(), asks: any NotificationAskRecord =
                           InMemoryNotificationAskRecord(),
                       abort: @escaping @Sendable (any CameraLink) async -> Void = { _ in },
                       choice: DestinationKind = .staging) -> Bench {
        let engine = frozenClock
            ? ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging(), clock: FrozenClock())
            : ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging())
        let destinations = FakeDestinations()
        let model = ImportModel(engine: engine,
                                settings: InMemoryDestinationSettingStore(DestinationSetting(preferred: choice)),
                                photos: FakePhotosAccess(), destinations: destinations, background: run,
                                notifier: notifier, notificationAsks: asks, abortTransfer: abort)
        let finder = FakeFinder()
        model.cameraFinder = finder
        let camera = ImportCamera(descriptor: link.descriptor, key: CameraKeys.key(for: link.descriptor, material: nil))
        return Bench(model: model, engine: engine, run: run, notifier: notifier, destinations: destinations,
                     camera: camera, link: link, finder: finder)
    }

    /// A USB link whose downloads hang until the job ends (looked at on a frozen clock, so no stall retries).
    private func hangingUSB() async -> FakeLink {
        let link = FakeLink(items: usbCard)
        await link.set(writesListedSize: true)
        await link.set(bytesHangs: true)
        return link
    }

    private func finishingUSB() async -> FakeLink {
        let link = FakeLink(items: usbCard)
        await link.set(writesListedSize: true)
        return link
    }

    // MARK: Wi-Fi

    private static let chunk: UInt64 = 64 * 1024

    /// Three files on the camera's network.
    private static let wifiCard = ScriptedCard(objects: [
        .init(handle: PTPObjectHandle(rawValue: 1), folder: "DCIM/100MSDCF", filename: "DSC00001.ARW",
              size: 20 * chunk + 123, captureDateRaw: "20261101T090000", format: .sonyARW),
        .init(handle: PTPObjectHandle(rawValue: 2), folder: "DCIM/100MSDCF", filename: "DSC00002.JPG",
              size: 5 * chunk + 7, captureDateRaw: "20261101T090002", format: .exifJPEG),
        .init(handle: PTPObjectHandle(rawValue: 3), folder: "DCIM/100MSDCF", filename: "DSC00003.ARW",
              size: 24 * chunk + 99, captureDateRaw: "20261101T090004", format: .sonyARW),
    ])
    private static let victim = "DSC00003.ARW"
    /// Where the victim's first read stops: 54 % of it, on a chunk boundary (the 2 Nov 23:10 cut).
    private static let cut: UInt64 = 13 * chunk
    private static var wifiTotal: UInt64 { wifiCard.objects.reduce(0) { $0 + $1.size } }

    private func wifiLink() async -> SimulatedCameraLink {
        let link = SimulatedCameraLink(card: Self.wifiCard, mode: .wifi(.cameraNetwork), honoursCancellation: true,
                                       chunkSize: Self.chunk)
        await link.script(Self.victim, .holdAfter(Self.cut))
        return link
    }

    private func wifiItems(_ link: SimulatedCameraLink) async throws -> [CameraItem] {
        try await link.open()
        return try await link.list()
    }

    // MARK: - Every import runs in a background run

    @Test func theImportTapBeginsARunThatFollowsTheBytesAndFinishesWithTheJob() async throws {
        let link = await wifiLink()
        let b = bench(link: link)
        let items = try await wifiItems(link)
        #expect(await b.importAll(items) == .started(3))
        let handle = try #require(await b.handle())
        #expect(b.run.begins.count == 1)
        // A Stage job (Shamil, 11 Nov): the system's UI says so.
        #expect(b.run.begins.first?.title == "Staging photos")
        await link.waitUntilHeld(Self.victim)
        // Progress in bytes (backlog section 9): the job's total, and the bytes copied so far.
        #expect(await eventually {
            await b.model.refresh()
            return handle.updates.last.map { $0.total == Int64(Self.wifiTotal) && $0.completed >= Int64(Self.cut) }
                ?? false
        })
        // The files in the subtitle, once the job has counted them (how many are done depends on the order it takes).
        #expect(handle.updates.contains { $0.subtitle?.hasSuffix(" of 3 files") == true }, "\(handle.updates)")
        #expect(handle.finishes.isEmpty)

        await link.release(Self.victim)
        #expect(await b.finished())
        #expect(b.model.state == .finished(.completed))
        // The read that lets the link go finishes the run once the link is released, after `finished()` may have seen
        // the outcome through another read.
        #expect(await eventually { handle.finishes == [true] })
        #expect(b.run.begins.count == 1)
    }

    @Test func aRefusedRunLeavesTheImportGoing() async {
        let b = bench(link: await finishingUSB(), run: FakeBackgroundRun(refuses: true))
        #expect(await b.importAll(usbCard) == .started(3))
        #expect(await b.finished())
        #expect(b.model.state == .finished(.completed))
        #expect(b.run.begins.count == 1)
        #expect(await b.destinations.files.names.sorted() == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
    }

    @Test func aRunIOSStartsAfterTheJobEndedIsFinishedAtOnce() async {
        let gate = Gate()
        let b = bench(link: await finishingUSB(), run: FakeBackgroundRun(gate: gate))
        #expect(await b.importAll(usbCard) == .started(3))
        #expect(await b.finished())
        gate.open()
        let handle = await b.handle()
        #expect(await eventually { handle?.finishes == [true] })
        #expect(handle?.updates.isEmpty == true)
    }

    @Test func anImportWhileAnEndedJobsRunIsStillBeingBegunWaitsForItThenBegins() async throws {
        let gate = Gate()
        let b = bench(link: await finishingUSB(), frozenClock: true, run: FakeBackgroundRun(gate: gate))
        #expect(await b.importAll(usbCard) == .started(3))
        #expect(await b.finished())
        // The first job ended inside iOS's start latency; the next Import comes before iOS answers. The live run takes
        // one request at a time, so the second waits for the first to come back.
        let card = [item("DSC00010.JPG", at: 30, size: 3_000)]
        let hanging = FakeLink(items: card, id: "second-camera")
        await hanging.set(writesListedSize: true)
        await hanging.set(bytesHangs: true)
        let second = ImportCamera(descriptor: hanging.descriptor,
                                  key: CameraKeys.key(for: hanging.descriptor, material: nil))
        #expect(await b.model.importItems(card, from: second, link: hanging) == .started(1))
        #expect(b.run.begins.count == 1)
        gate.open()
        let first = try #require(await b.handle(0))
        #expect(await eventually { first.finishes == [true] })
        let next = try #require(await b.handle(1))
        #expect(b.run.begins.count == 2)
        #expect(next.finishes.isEmpty)
        await b.model.cancel()
        #expect(await b.finished())
        #expect(await eventually { next.finishes == [false] })
    }

    @Test func continueWhileARunIsLiveBeginsNoOther() async throws {
        let b = bench(link: await hangingUSB(), frozenClock: true)
        #expect(await b.importAll(usbCard) == .started(3))
        let handle = try #require(await b.handle())
        await b.model.pause()
        await b.model.resume()
        #expect(b.run.begins.count == 1)
        #expect(handle.finishes.isEmpty)
        await b.model.cancel()
        #expect(await b.finished())
        #expect(handle.finishes == [false])
    }

    // MARK: - Expiry on Wi-Fi: flush, pause, abort, notify; Continue writes each file once

    @Test func anExpiryFlushesPausesNotifiesFinishesTheRunThenAbortsAndContinueWritesEachFileOnce() async throws {
        let trace = Trace()
        let link = await wifiLink()
        let catalogue = InMemoryCatalogue()
        let items = try await wifiItems(link)
        let key = CameraKeys.key(for: link.descriptor, material: nil)
        let identity = try #require(items.first { $0.name == Self.victim }?.identity(camera: key, timeZone: .current))
        let engineBox = EngineBox()
        let b = bench(link: link, catalogue: catalogue, run: FakeBackgroundRun(trace: trace),
                      notifier: FakeNotifier(.authorised, trace: trace),
                      abort: { aborted in
                          // What the abort finds: the checkpoint the flush wrote, and the job paused.
                          let offset = await catalogue.record(for: identity)?.resumeOffset
                          let state = await engineBox.engine?.state
                          trace.add("abort at \(offset.map { "\($0)" } ?? "none") "
                              + (state.map { String(describing: $0) } ?? "no engine"))
                          // As iOS does once the app is suspended: the transfer and the session go.
                          await (aborted as? SimulatedCameraLink)?.loseSession()
                      })
        engineBox.engine = b.engine
        #expect(await b.importAll(items) == .started(3))
        let first = try #require(await b.handle())
        await link.waitUntilHeld(Self.victim)
        // Away from the app, a Wi-Fi job keeps going inside its run.
        await b.model.scenePhaseChanged(.inactive)
        await b.model.scenePhaseChanged(.background)
        #expect(await b.engine.state == .running)
        #expect(trace.lines.isEmpty)

        first.expire()
        #expect(await b.state(.paused(.taskExpired)))
        #expect(await eventually { trace.lines.count == 3 })
        // The flush and the pause come first (the files are under 16 MiB, so only the flush writes a checkpoint before
        // the session goes), then the notification, then the run is finished, and only then the abort, which may wait
        // on a faded camera and so must hold neither the run past its end nor the notification back.
        #expect(trace.lines == [
            "post", "finish false", "abort at \(Self.cut) \(String(describing: ImportJobState.paused(.taskExpired)))",
        ])
        #expect(first.finishes == [false])
        #expect(b.notifier.posts == [.stagingPaused])
        #expect(await catalogue.record(for: identity)?.resumeOffset == Self.cut)
        #expect(await b.engine.currentProgress.filesFailed == 0)
        #expect(b.model.canResume)
        #expect(b.model.pauseControl == .resume)

        // Back in the app: the expiry waits for the person's Continue (a new run needs a tap).
        await b.model.scenePhaseChanged(.inactive)
        await b.model.scenePhaseChanged(.active)
        #expect(await b.engine.state == .paused(.taskExpired))
        #expect(b.run.begins.count == 1)

        await b.model.togglePause()   // Continue
        let second = try #require(await b.handle(1))
        #expect(b.run.begins.count == 2)
        #expect(await b.finished())
        #expect(b.model.state == .finished(.completed))
        #expect(await eventually { second.finishes == [true] })
        // Each file written once; the one in flight continued from the flushed offset.
        #expect(await b.destinations.files.names.sorted() == ["DSC00001.ARW", "DSC00002.JPG", "DSC00003.ARW"])
        #expect(await link.delivered.sorted() == ["DSC00001.ARW", "DSC00002.JPG", "DSC00003.ARW"])
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: Self.victim, offset: Self.cut)])
        #expect(b.notifier.posts == [.stagingPaused])
        // Taken back once Continue had the job going: "Import paused" no longer held.
        #expect(b.notifier.withdrawals == [.stagingPaused])
    }

    @Test func anExpiryAfterThePersonPausedAndTheSessionWentPostsNothing() async throws {
        let link = await wifiLink()
        let b = bench(link: link)
        let items = try await wifiItems(link)
        #expect(await b.importAll(items) == .started(3))
        let handle = try #require(await b.handle())
        await link.waitUntilHeld(Self.victim)
        await b.model.pause()
        // The session goes: `.cameraUnreachable` comes before the person's pause in the engine's state.
        try await b.engine.pause(.cameraUnreachable)
        #expect(await b.engine.state == .paused(.cameraUnreachable))
        await b.model.scenePhaseChanged(.background)
        handle.expire()
        #expect(await eventually { handle.finishes == [false] })
        #expect(await b.state(.paused(.taskExpired)))
        #expect(b.notifier.posts.isEmpty)
        await b.model.cancel()
    }

    @Test func anExpiryOfAJobThePersonPausedPostsNothingAndOneContinueLiftsBoth() async throws {
        let link = await wifiLink()
        let b = bench(link: link)
        let items = try await wifiItems(link)
        #expect(await b.importAll(items) == .started(3))
        let handle = try #require(await b.handle())
        await link.waitUntilHeld(Self.victim)
        await b.model.pause()
        await b.model.scenePhaseChanged(.background)
        handle.expire()
        #expect(await eventually { handle.finishes == [false] })
        #expect(await b.state(.paused(.taskExpired)))
        #expect(b.notifier.posts.isEmpty)

        await b.model.scenePhaseChanged(.active)
        // Continue before the held read is let go: a read let go first can finish the last file while the job is
        // paused (a call in flight across a pause still commits), and then there is nothing left to continue.
        await b.model.resume()
        // The run is begun without waiting, on another executor: polled, as the other tests wait for its handle.
        #expect(await eventually { b.run.begins.count == 2 })
        await link.release(Self.victim)
        #expect(await b.finished())
        #expect(b.model.state == .finished(.completed))
        #expect(await b.destinations.files.names.sorted() == ["DSC00001.ARW", "DSC00002.JPG", "DSC00003.ARW"])
    }

    @Test func anExpiryInFrontPausesWithoutANotification() async throws {
        let link = await wifiLink()
        let b = bench(link: link)
        let items = try await wifiItems(link)
        #expect(await b.importAll(items) == .started(3))
        let handle = try #require(await b.handle())
        await link.waitUntilHeld(Self.victim)
        handle.expire()
        #expect(await b.state(.paused(.taskExpired)))
        #expect(await eventually { handle.finishes == [false] })
        #expect(b.notifier.posts.isEmpty)
        await b.model.cancel()
    }

    // MARK: - USB

    @Test func aUSBExpiryKeepsToTheLeavingRule() async throws {
        let aborted = Trace()
        let b = bench(link: await hangingUSB(), frozenClock: true, abort: { _ in aborted.add("abort") })
        #expect(await b.importAll(usbCard) == .started(3))
        let handle = try #require(await b.handle())
        handle.expire()
        #expect(await eventually { handle.finishes == [false] })
        #expect(await b.engine.state == .running)
        #expect(aborted.lines.isEmpty)
        #expect(b.notifier.posts.isEmpty)
        await b.model.cancel()
    }

    @Test func aUSBImportPausedByLeavingPostsOneNotificationPerStayAway() async throws {
        let b = bench(link: await hangingUSB(), frozenClock: true, choice: .photos)
        #expect(await b.importAll(usbCard) == .started(3))
        await b.model.scenePhaseChanged(.inactive)
        await b.model.scenePhaseChanged(.background)
        #expect(await b.state(.paused(.appInBackground)))
        #expect(b.notifier.posts == [.importPaused])
        // Leaving again without coming back posts nothing more.
        await b.model.scenePhaseChanged(.background)
        #expect(b.notifier.posts == [.importPaused])
        #expect(b.notifier.withdrawals.isEmpty)
        // An import job's run says Importing.
        #expect(b.run.begins.first?.title == "Importing photos")
        // Back: the import goes on by itself, so the notification is taken back.
        await b.model.scenePhaseChanged(.inactive)
        await b.model.scenePhaseChanged(.active)
        #expect(await b.state(.running))
        #expect(b.notifier.withdrawals == [.importPaused])
        // Away again: one more, taken back when the job ends.
        await b.model.scenePhaseChanged(.inactive)
        await b.model.scenePhaseChanged(.background)
        #expect(await b.state(.paused(.appInBackground)))
        #expect(b.notifier.posts == [.importPaused, .importPaused])
        await b.model.cancel()
        #expect(await b.finished())
        #expect(b.notifier.withdrawals == [.importPaused, .importPaused])
    }

    @Test func aUSBImportThePersonPausedPostsNothingWhenTheCableGoesAndTheAppLeaves() async throws {
        let b = bench(link: await hangingUSB(), frozenClock: true)
        #expect(await b.importAll(usbCard) == .started(3))
        await b.model.pause()
        // The cable comes out: `.cameraRemoved` comes before the person's pause in the engine's state.
        try await b.engine.pause(.cameraRemoved)
        await b.model.refresh()
        #expect(b.model.state == .paused(.cameraRemoved))
        await b.model.scenePhaseChanged(.background)
        #expect(b.notifier.posts.isEmpty)
        await b.model.cancel()
    }

    @Test func aUSBImportThePersonPausedPostsNothingWhenTheAppLeaves() async {
        let b = bench(link: await hangingUSB(), frozenClock: true)
        #expect(await b.importAll(usbCard) == .started(3))
        await b.model.pause()
        await b.model.scenePhaseChanged(.background)
        #expect(b.notifier.posts.isEmpty)
        await b.model.cancel()
    }

    @Test func noPauseNotificationWithoutPermission() async {
        for status in [NotificationAuthorisation.denied, .notDetermined] {
            let notifier = FakeNotifier(status, answer: status)
            let b = bench(link: await hangingUSB(), frozenClock: true, notifier: notifier,
                          asks: InMemoryNotificationAskRecord(hasAsked: true))
            #expect(await b.importAll(usbCard) == .started(3))
            await b.model.scenePhaseChanged(.background)
            #expect(await b.state(.paused(.appInBackground)))
            #expect(notifier.posts.isEmpty, "\(status)")
            await b.model.cancel()
        }
    }

    // MARK: - The notification permission at the first Import

    @Test func theFirstImportAsksOnceWithTheReasonLineFirst() async {
        let notifier = FakeNotifier(.notDetermined, answer: .authorised)
        let asks = InMemoryNotificationAskRecord()
        let b = bench(link: await finishingUSB(), notifier: notifier, asks: asks)
        let seen = Seen()
        let model = b.model
        notifier.onRequest = { @MainActor in
            seen.statusLine = model.statusLine
            seen.reasonLine = model.notificationPermission.reasonLine
            seen.isExplaining = model.notificationPermission.isExplaining
        }
        #expect(model.notificationPermission.shouldExplainBeforeImport)
        #expect(await b.importAll(usbCard) == .started(3))
        #expect(notifier.requests == 1)
        #expect(seen.isExplaining)
        #expect(seen.reasonLine == NotificationWording.reason)
        #expect(seen.statusLine == NotificationWording.reason)
        #expect(model.notificationPermission.reasonLine == nil)
        #expect(model.notificationPermission.authorisation == .authorised)
        #expect(!model.notificationPermission.shouldExplainBeforeImport)
        #expect(asks.hasAsked)
        #expect(await b.finished())

        // The next Import, on either link, asks no more.
        let wifi = SimulatedCameraLink(card: Self.wifiCard, mode: .wifi(.cameraNetwork), chunkSize: Self.chunk)
        let items = (try? await wifiItems(wifi)) ?? []
        #expect(await model.importItems(items, from: ImportCamera(descriptor: wifi.descriptor,
                                                                  key: CameraKeys.key(for: wifi.descriptor,
                                                                                      material: nil)),
                                        link: wifi) == .started(3))
        #expect(notifier.requests == 1)
        #expect(await b.finished())
    }

    @Test func aDeclinedAnswerIsNeverAskedAgainAndTheImportGoesOn() async {
        let notifier = FakeNotifier(.notDetermined, answer: .denied)
        let b = bench(link: await finishingUSB(), notifier: notifier)
        #expect(await b.importAll(usbCard) == .started(3))
        #expect(notifier.requests == 1)
        #expect(await b.finished())
        #expect(b.model.state == .finished(.completed))
        #expect(b.model.notificationPermission.authorisation == .denied)
        // Another Import (the files are staged already, so no job starts) asks no more.
        #expect(await b.importAll(usbCard) == .nothingNew(staging: true))
        #expect(await b.finished())
        #expect(notifier.requests == 1)
    }

    @Test func aFirstImportWithPermissionSettledAsksNothing() async {
        for (status, asked) in [(NotificationAuthorisation.authorised, false), (.denied, false),
                                (.provisional, false), (.notDetermined, true)] {
            let notifier = FakeNotifier(status, answer: .authorised)
            let b = bench(link: await finishingUSB(), notifier: notifier,
                          asks: InMemoryNotificationAskRecord(hasAsked: asked))
            #expect(await b.importAll(usbCard) == .started(3))
            #expect(notifier.requests == 0, "\(status), asked before: \(asked)")
            #expect(await b.finished())
        }
    }
}

/// Lets the abort hook, made before the engine, read the engine's state.
final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ImportEngine?
    var engine: ImportEngine? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - The permission model and the copy on their own

@MainActor
@Suite("Notification permission model and copy")
struct NotificationPermissionModelTests {
    @Test func asksOnceRecordsTheAskBeforeThePromptAndClearsTheReason() async {
        let notifier = FakeNotifier(.notDetermined, answer: .authorised)
        let record = InMemoryNotificationAskRecord()
        let model = NotificationPermissionModel(notifier: notifier, record: record)
        final class Probe: @unchecked Sendable {
            var recordedBeforePrompt = false
            var reason: String?
        }
        let probe = Probe()
        notifier.onRequest = { @MainActor in
            probe.recordedBeforePrompt = record.hasAsked
            probe.reason = model.reasonLine
        }
        #expect(model.shouldExplainBeforeImport)
        #expect(await model.askAtImport())
        #expect(probe.recordedBeforePrompt)
        #expect(probe.reason == NotificationWording.reason)
        #expect(model.reasonLine == nil)
        #expect(!model.isExplaining)
        #expect(model.hasAsked)
        #expect(!(await model.askAtImport()))
        #expect(notifier.requests == 1)
        #expect(await model.allowsPosting())
    }

    @Test func anAskRecordedInAnEarlierLaunchIsKept() async throws {
        let suite = "ContinuedImportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = UserDefaultsNotificationAskRecord(defaults: defaults)
        #expect(!record.hasAsked)
        record.recordAsked()
        let notifier = FakeNotifier(.notDetermined)
        let model = NotificationPermissionModel(notifier: notifier,
                                                record: UserDefaultsNotificationAskRecord(defaults: defaults))
        #expect(model.hasAsked)
        #expect(!model.shouldExplainBeforeImport)
        #expect(!(await model.askAtImport()))
        #expect(notifier.requests == 0)
    }

    @Test func refreshReadsTheAnswerAgain() async {
        let notifier = FakeNotifier(.authorised)
        let model = NotificationPermissionModel(notifier: notifier)
        #expect(model.authorisation == nil)
        await model.refresh()
        #expect(model.authorisation == .authorised)
        #expect(!model.shouldExplainBeforeImport)
    }

    @Test func onlyAllowedStatusesPost() {
        #expect(NotificationAuthorisation.allCases.filter(\.allowsPosting) == [.authorised, .provisional, .ephemeral])
    }

    @Test func theCopyIsBritishAndNamesNoCamera() {
        #expect(AppNotification.importPaused.body == "Import paused. Open Shutter Bridge to continue.")
        #expect(AppNotification.stagingPaused.body == "Staging paused. Open Shutter Bridge to continue.")
        // One pause notification at a time: either replaces the other.
        #expect(AppNotification.stagingPaused.identifier == AppNotification.importPaused.identifier)
        #expect(AppNotification.stagingPaused.category == .importPaused)
        #expect(AppNotification.importPaused.title.isEmpty)
        #expect(AppNotification.importPaused.identifier == AppNotificationCategory.importPaused.identifier)
        #expect(AppNotificationCategory.all.contains(.importPaused))
        #expect(NotificationWording.reason.contains("tell you if an import pauses"))
        for text in [NotificationWording.importPaused, NotificationWording.stagingPaused, NotificationWording.reason,
                     ImportBackgroundWording.title, ImportBackgroundWording.stagingTitle] {
            #expect(!text.contains { $0.isNumber }, "\(text)")
            #expect(!text.contains("ILCE"), "\(text)")
        }
    }

    @Test func theRunsSubtitleCountsFiles() {
        var progress = ImportProgress.none
        #expect(ImportBackgroundWording.subtitle(progress) == "Getting ready…")
        progress.filesTotal = 1
        #expect(ImportBackgroundWording.subtitle(progress) == "0 of 1 file")
        progress.filesTotal = 360
        progress.filesDone = 12
        #expect(ImportBackgroundWording.subtitle(progress) == "12 of 360 files")
    }

    @Test func withoutARunBeginThrowsUnavailable() async {
        await #expect(throws: ImportBackgroundRunError.unavailable) {
            _ = try await NoImportBackgroundRun().begin(title: "t", subtitle: "s")
        }
    }

    @Test func theAppModelRegistersCategoriesOnceAndReadsThePermissionWhenActive() async {
        let notifier = FakeNotifier(.denied)
        let link = FakeLink(items: [item("DSC00001.JPG")])
        let app = AppModel(discovery: FakeDiscovery(link: link), services: services(),
                           catalogue: InMemoryCatalogue(),
                           engine: ImportEngine(catalogue: InMemoryCatalogue(), stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: { descriptor, _ in
                               CameraKeys.key(for: descriptor, material: nil)
                           }, notifier: notifier)
        await app.scenePhaseChanged(.active)
        await app.scenePhaseChanged(.background)
        await app.scenePhaseChanged(.active)
        #expect(notifier.registrations == 1)
        #expect(app.importer.notificationPermission.authorisation == .denied)
    }
}
