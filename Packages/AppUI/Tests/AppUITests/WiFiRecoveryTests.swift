import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing
@testable import AppUI

// W14: the Wi-Fi recovery as the Import model runs it (backlog Iteration 3, section 9; decision 3; Shamil, 9 Nov). The model,
// the real engine and the coordinator against the simulated Wi-Fi link (`SimulatedCameraLink` playing the camera dropping its
// card, `removeStore()`/`addStore()`, and the session, `loseSession()`), a scripted Wi-Fi session in place of
// `WirelessSession` (whose own order is tested in CameraTransport's WirelessRecoveryTests), and a manual clock for the
// 15 s wait for StoreAdded. Every wait is bounded: `eventually` polls for about two seconds, and the clock's sleepers end
// when their task is cancelled.

// MARK: - Fakes

/// A clock that moves only on `advance(by:)`. A sleep ends when its deadline is reached, or throws when its task is
/// cancelled.
final class RecoveryTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct State {
        var now: Swift.Duration = .zero
        var nextID = 0
        var sleepers: [Int: (deadline: Swift.Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
        var cancelledEarly: Set<Int> = []
    }

    private let state = Mutex(State())

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Swift.Duration { .zero }
    var elapsed: Swift.Duration { state.withLock { $0.now } }
    /// How many sleeps are waiting.
    var sleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case waiting, due, cancelled }
                let outcome = state.withLock { s -> Outcome in
                    if s.cancelledEarly.remove(id) != nil { return .cancelled }
                    if deadline.offset <= s.now { return .due }
                    s.sleepers[id] = (deadline.offset, continuation)
                    return .waiting
                }
                switch outcome {
                case .waiting: break
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> CheckedContinuation<Void, Error>? in
                guard let sleeper = s.sleepers.removeValue(forKey: id) else {
                    s.cancelledEarly.insert(id)
                    return nil
                }
                return sleeper.continuation
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Swift.Duration) {
        let due = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            s.now += duration
            let ids = s.sleepers.filter { $0.value.deadline <= s.now }.keys
            return ids.compactMap { s.sleepers.removeValue(forKey: $0)?.continuation }
        }
        for continuation in due { continuation.resume() }
    }
}

/// `WirelessSession` as scripted: each `prepareImport` takes the next answer.
actor FakeRecoverySession: WiFiRecoverySession {
    enum Answer: Sendable {
        /// Opens the link (a lost session is opened again) and gives it.
        case link(any CameraLink)
        /// Waits on the clock first, then as `.link`.
        case linkAfter(Swift.Duration, any CameraLink)
        case failure(WirelessFailure)
    }

    private let clock: RecoveryTestClock
    private var answers: [Answer] = []
    /// `bluetoothSwitchOnWhenAway` of each call, in order.
    private(set) var calls: [Bool] = []
    private(set) var callTimes: [Swift.Duration] = []
    private(set) var finishes = 0

    init(clock: RecoveryTestClock) { self.clock = clock }

    func script(_ answers: [Answer]) { self.answers = answers }

    func prepareImport(bluetoothSwitchOnWhenAway: Bool) async throws(WirelessFailure) -> any CameraLink {
        calls.append(bluetoothSwitchOnWhenAway)
        callTimes.append(clock.elapsed)
        guard !answers.isEmpty else { throw .cameraNotFound }
        let link: any CameraLink
        switch answers.removeFirst() {
        case .failure(let failure): throw failure
        case .link(let given): link = given
        case .linkAfter(let delay, let given):
            do { try await clock.sleep(for: delay) } catch { throw .cancelled }
            link = given
        }
        do throws(CameraLinkFailure) {
            try await link.open()
        } catch {
            throw .link(error)
        }
        return link
    }

    func importFinished() async { finishes += 1 }
}

/// The recovery's listing, recorded: which link, and how many items it was told were known.
final class RecordedListings: Sendable {
    private let state = Mutex<[(link: ObjectIdentifier, known: Int)]>([])
    var knownCounts: [Int] { state.withLock { $0.map(\.known) } }
    var links: [ObjectIdentifier] { state.withLock { $0.map(\.link) } }

    func list(_ link: any CameraLink, known: [CameraItem]) async throws(CameraLinkFailure) -> [CameraItem] {
        state.withLock { $0.append((ObjectIdentifier(link), known.count)) }
        return try await link.list()
    }
}

/// A Wi-Fi link that can list reusing known items, for the default listing.
actor ReusingRecordingLink: ReusingListing {
    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "reusing"), name: "Camera",
                                                  mode: .wifi(.cameraNetwork))
    nonisolated let capabilities = CameraLinkCapabilities.wifi
    nonisolated let events = AsyncStream<CameraLinkEvent> { $0.finish() }
    private(set) var reusedWith: [[CameraItem]] = []
    private(set) var plainLists = 0
    let card: [CameraItem]

    init(card: [CameraItem]) { self.card = card }

    func open() throws(CameraLinkFailure) {}
    func list() throws(CameraLinkFailure) -> [CameraItem] {
        plainLists += 1
        return card
    }
    func list(reusing known: [CameraItem]) throws(CameraLinkFailure) -> [CameraItem] {
        reusedWith.append(known)
        return card
    }
    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem { throw CameraLinkFailure(.itemNotFound) }
    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data() }
    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) throws(CameraLinkFailure) -> URL {
        throw CameraLinkFailure(.itemNotFound)
    }
    func close() {}
}

/// Polls `condition` on the main actor for about a quarter of a second and returns whether it held every time: for
/// "nothing more happens", bounded like `eventually`.
@MainActor
func holdsThroughout(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<50 {
        guard await condition() else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Set once a call for `filename` is held by `.holdAfter`; read with `eventually`, so the wait is bounded.
final class HeldFlag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

// MARK: - The recovery in the Import model

@MainActor
@Suite("Wi-Fi recovery in the Import model", .timeLimit(.minutes(1)))
struct WiFiRecoveryTests {
    struct Bench {
        let model: ImportModel
        let engine: ImportEngine
        let coordinator: WiFiRecoveryCoordinator
        let session: FakeRecoverySession
        let clock: RecoveryTestClock
        /// The progress ticks while the recovery waits; moves only when a test advances it.
        let tickClock: RecoveryTestClock
        let link: SimulatedCameraLink
        let listings: RecordedListings
        let notifier: FakeNotifier
        let run: FakeBackgroundRun
        let destinations: FakeDestinations
        let camera: ImportCamera
        /// Held here: the model's finder is weak.
        let finder: FakeFinder

        func importAll() async throws -> ImportRequestOutcome {
            try await link.open()
            let items = try await link.list()
            return await model.importItems(items, from: camera, link: link)
        }

        func state(_ expected: ImportJobState) async -> Bool {
            await eventually {
                await model.refresh()
                return model.state == expected
            }
        }

        func finished(_ outcome: JobOutcome = .completed) async -> Bool {
            await state(.finished(outcome))
        }

        /// Returns once the victim's download is held part-way (a bounded poll, not a bare wait).
        func victimHeld() async -> Bool {
            let flag = HeldFlag()
            let link = self.link
            Task { await link.waitUntilHeld(WiFiRecoveryTests.victim); flag.set() }
            return await eventually { flag.isSet }
        }

        func phase(_ expected: WiFiRecoveryPlan.Phase) async -> Bool {
            await eventually {
                await model.refresh()
                return coordinator.plan.phase == expected
            }
        }

        func sessionCalls(_ count: Int) async -> Bool {
            await eventually { await session.calls.count == count }
        }

        var importedNames: [String] {
            get async { await destinations.files.names.sorted() }
        }
    }

    private static let chunk: UInt64 = 64 * 1024
    private static let card = ScriptedCard(objects: [
        .init(handle: PTPObjectHandle(rawValue: 1), folder: "DCIM/100MSDCF", filename: "DSC00001.ARW",
              size: 20 * chunk + 123, captureDateRaw: "20261101T090000", format: .sonyARW),
        .init(handle: PTPObjectHandle(rawValue: 2), folder: "DCIM/100MSDCF", filename: "DSC00002.JPG",
              size: 5 * chunk + 7, captureDateRaw: "20261101T090002", format: .exifJPEG),
        .init(handle: PTPObjectHandle(rawValue: 3), folder: "DCIM/100MSDCF", filename: "DSC00003.ARW",
              size: 24 * chunk + 99, captureDateRaw: "20261101T090004", format: .sonyARW),
    ])
    static let victim = "DSC00003.ARW"
    /// Where the victim's first read stops: 54 % of it, on a chunk boundary (the 2 Nov 23:10 cut).
    private static let cut: UInt64 = 13 * chunk
    private static let allNames = ["DSC00001.ARW", "DSC00002.JPG", "DSC00003.ARW"]

    private func bench(bluetoothSwitchOnWhenAway: Bool = true,
                       recoveriesPerImport: Int = WiFiRecoveryTiming.recoveriesPerImport,
                       log: any BenchLog = SilentBenchLog()) async -> Bench {
        let clock = RecoveryTestClock()
        let tickClock = RecoveryTestClock()
        let link = SimulatedCameraLink(card: Self.card, mode: .wifi(.cameraNetwork), honoursCancellation: true,
                                       chunkSize: Self.chunk)
        await link.script(Self.victim, .holdAfter(Self.cut))
        let engine = ImportEngine(catalogue: InMemoryCatalogue(), stagingDirectory: temporaryStaging())
        let destinations = FakeDestinations()
        let notifier = FakeNotifier()
        let run = FakeBackgroundRun()
        let model = ImportModel(engine: engine,
                                settings: InMemoryDestinationSettingStore(DestinationSetting(preferred: .staging)),
                                photos: FakePhotosAccess(), destinations: destinations, background: run,
                                notifier: notifier)
        let finder = FakeFinder()
        model.cameraFinder = finder
        let listings = RecordedListings()
        let coordinator = WiFiRecoveryCoordinator(
            engine: engine, clock: clock, tickClock: tickClock, bluetoothSwitchOnWhenAway: bluetoothSwitchOnWhenAway,
            recoveriesPerImport: recoveriesPerImport,
            listing: { (link: any CameraLink, known: [CameraItem]) async throws(CameraLinkFailure) -> [CameraItem] in
                try await listings.list(link, known: known)
            },
            log: log)
        let session = FakeRecoverySession(clock: clock)
        coordinator.session = session
        model.attachWiFiRecovery(coordinator)
        let camera = ImportCamera(descriptor: link.descriptor, key: CameraKeys.key(for: link.descriptor, material: nil))
        return Bench(model: model, engine: engine, coordinator: coordinator, session: session, clock: clock,
                     tickClock: tickClock, link: link,
                     listings: listings, notifier: notifier, run: run, destinations: destinations, camera: camera,
                     finder: finder)
    }

    /// Starts the import and drops the camera's card under the victim's download: StoreRemoved, and the held read refused
    /// (the camera refuses the next GetObject with StoreNotAvailable).
    private func startAndDropTheCard(_ b: Bench) async throws {
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.link.removeStore()
        await b.link.release(Self.victim)
        #expect(await b.state(.paused(.cardUnavailable)))
    }

    private func startAndLoseTheSession(_ b: Bench) async throws {
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.link.loseSession()
    }

    // MARK: Card gone, session up

    @Test func aCardBackWithinFifteenSecondsCarriesOnWithNoReopen() async throws {
        let b = await bench()
        try await startAndDropTheCard(b)
        #expect(await b.phase(.waitingForCard))
        #expect(await eventually { b.clock.sleepers == 1 })
        b.clock.advance(by: .seconds(14))
        // `advance` takes due sleepers off at once: the 15 s wait is still there at 14 s.
        #expect(b.clock.sleepers == 1)
        #expect(b.coordinator.plan.phase == .waitingForCard)

        await b.link.addStore()
        // The engine lists the card again on StoreAdded and goes on; the wait is dropped.
        #expect(await b.phase(.idle))
        #expect(b.clock.sleepers == 0)
        #expect(await b.finished())
        #expect(await b.session.calls.isEmpty)
        #expect(b.listings.knownCounts.isEmpty)
        #expect(await b.importedNames == Self.allNames)
        #expect(await b.link.resumes == [.init(filename: Self.victim, offset: Self.cut)])
    }

    @Test func aCardNotBackInFifteenSecondsReopensListsTheNewHandlesAndResumes() async throws {
        let b = await bench()
        let reopened = await b.link.replugged() // the session's new link, as `openLink` makes one
        await b.session.script([.link(reopened)])
        try await startAndDropTheCard(b)
        #expect(await eventually { b.clock.sleepers == 1 })
        b.clock.advance(by: .seconds(14))
        #expect(b.clock.sleepers == 1)
        #expect(await b.session.calls.isEmpty)
        b.clock.advance(by: .seconds(1))

        #expect(await b.sessionCalls(1))
        #expect(await b.session.calls == [true])
        #expect(await b.session.callTimes == [WiFiRecoveryTiming.waitForStoreAdded])
        #expect(await b.finished())
        // Listed once on the new session, told the job's three files (so only new handles are asked), and the engine
        // took that listing rather than listing again.
        #expect(b.listings.knownCounts == [3])
        #expect(b.listings.links == [ObjectIdentifier(reopened)])
        #expect(await reopened.listCount == 1)
        // The file in flight continued from its checkpoint over 0x9211, each file written once.
        #expect(await reopened.resumes == [.init(filename: Self.victim, offset: Self.cut)])
        #expect(await b.importedNames == Self.allNames)
        #expect(b.coordinator.plan.phase == .idle)
        #expect(b.notifier.posts.isEmpty)
    }

    // MARK: Session lost

    @Test func aLostSessionReopensAtOnceAndResumes() async throws {
        let b = await bench()
        await b.session.script([.link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.sessionCalls(1))
        #expect(await b.session.callTimes == [.zero])
        #expect(await b.finished())
        #expect(await b.link.resumes == [.init(filename: Self.victim, offset: Self.cut)])
        #expect(await b.importedNames == Self.allNames)
    }

    @Test func theSwitchOnSettingIsPassedToTheSession() async throws {
        let b = await bench(bluetoothSwitchOnWhenAway: false)
        await b.session.script([.link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.finished())
        #expect(await b.session.calls == [false])
    }

    // MARK: With the app away

    @Test(arguments: [WirelessFailure.paused(.needsJoin), .cameraNotFound, .paused(.bluetoothOff)])
    func awayAJoinNeededPausesNotifiesOnceAndTheReturnJoins(_ failure: WirelessFailure) async throws {
        let b = await bench()
        await b.session.script([.failure(failure), .link(b.link)])
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.model.scenePhaseChanged(.background)
        #expect(b.model.state == .running) // Wi-Fi carries on with the app away (the continued task)
        await b.link.loseSession()

        #expect(await b.state(.paused(.needsJoin)))
        #expect(await eventually { b.notifier.posts == [.stagingPaused] })
        #expect(b.coordinator.plan.phase == .pausedForJoin)
        #expect(await b.session.calls == [true])
        // Nothing more happens while the app is away.
        #expect(await holdsThroughout {
            await b.model.refresh()
            let calls = await b.session.calls.count
            return b.coordinator.plan.phase == .pausedForJoin && calls == 1
        })

        await b.model.scenePhaseChanged(.active)
        #expect(await b.sessionCalls(2))
        #expect(await b.finished())
        #expect(await b.link.resumes == [.init(filename: Self.victim, offset: Self.cut)])
        #expect(await b.importedNames == Self.allNames)
        // "Import paused" no longer holds once the job goes again.
        #expect(b.notifier.withdrawals.contains(.stagingPaused))
        #expect(b.notifier.posts == [.stagingPaused])
    }

    @Test func awayNoNotificationWhenThePersonHadPaused() async throws {
        let b = await bench()
        await b.session.script([.failure(.paused(.needsJoin))])
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.model.pause()
        await b.model.scenePhaseChanged(.background)
        await b.link.loseSession()
        #expect(await b.state(.paused(.needsJoin)))
        #expect(await b.phase(.pausedForJoin))
        #expect(b.notifier.posts.isEmpty)
        await b.model.cancel()
    }

    /// With the app away, an import that has used its recoveries pauses for a join and says so (B:211).
    @Test func awayWithNoRecoveryLeftPausesForAJoinAndNotifies() async throws {
        // No recovery left (as after three).
        let b = await bench(recoveriesPerImport: 0)
        await b.session.script([.link(b.link)])
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.model.scenePhaseChanged(.background)
        await b.link.loseSession()
        #expect(await b.state(.paused(.needsJoin)))
        #expect(await b.phase(.pausedForJoin))
        #expect(await eventually { b.notifier.posts == [.stagingPaused] })
        #expect(await b.session.calls.isEmpty)

        await b.model.scenePhaseChanged(.active)
        #expect(await b.sessionCalls(1))
        #expect(await b.finished())
        #expect(await b.importedNames == Self.allNames)
    }

    /// iOS ends the continued task while the job waits for a join (the state shows the join, not the expiry). The
    /// return reopens, but the job keeps the expiry until Continue.
    @Test func anExpiryHiddenByAJoinWaitsForContinueAfterTheReturn() async throws {
        let b = await bench()
        let reopened = await b.link.replugged()
        await b.session.script([.failure(.paused(.needsJoin)), .link(reopened)])
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.model.scenePhaseChanged(.background)
        await b.link.loseSession()
        #expect(await b.state(.paused(.needsJoin)))
        #expect(await b.phase(.pausedForJoin))

        #expect(await eventually { !b.run.handles.isEmpty })
        b.run.handles.first?.expire()
        #expect(await eventually { await b.engine.isPaused(for: .taskExpired) })
        #expect(await b.engine.state == .paused(.needsJoin))

        await b.model.scenePhaseChanged(.active)
        #expect(await b.sessionCalls(2))
        #expect(await b.state(.paused(.taskExpired)))
        #expect(await b.phase(.idle))
        #expect(await holdsThroughout {
            await b.model.refresh()
            return b.model.state == .paused(.taskExpired)
        })
        #expect(await reopened.delivered.isEmpty)
        #expect(b.model.canResume)

        await b.model.resume()
        #expect(await b.finished())
        #expect(await reopened.resumes == [.init(filename: Self.victim, offset: Self.cut)])
        #expect(await b.importedNames == Self.allNames)
    }

    /// iOS ends the continued task during the wait for the card: no reopen follows.
    @Test func anExpiryDuringTheWaitForTheCardStopsIt() async throws {
        let b = await bench()
        await b.session.script([.link(b.link)])
        try await startAndDropTheCard(b)
        #expect(await b.phase(.waitingForCard))
        #expect(await eventually { b.clock.sleepers == 1 })
        #expect(await eventually { !b.run.handles.isEmpty })
        b.run.handles.first?.expire()
        #expect(await b.state(.paused(.taskExpired)))
        #expect(await b.phase(.idle))
        #expect(b.clock.sleepers == 0)
        b.clock.advance(by: .seconds(15))
        #expect(await holdsThroughout {
            let calls = await b.session.calls.count
            return calls == 0 && b.coordinator.plan.phase == .idle
        })
        await b.model.cancel()
    }

    /// While the recovery waits, the continued task's progress moves by made-up bytes, never up to the total.
    @Test func theContinuedTaskMovesWhileTheRecoveryWaits() async throws {
        let b = await bench()
        try await startAndDropTheCard(b)
        #expect(await b.phase(.waitingForCard))
        #expect(await eventually { !b.run.handles.isEmpty })
        let handle = try #require(b.run.handles.first)
        #expect(await eventually { !handle.updates.isEmpty })
        let before = handle.updates.last?.completed ?? 0
        #expect(await eventually { b.tickClock.sleepers == 1 })
        b.tickClock.advance(by: .seconds(1))
        #expect(await eventually { (handle.updates.last?.completed ?? 0) > before })
        // The card is about 3.2 MB, so two more ticks reach the cap: one byte short of the total.
        for _ in 1...2 {
            #expect(await eventually { b.tickClock.sleepers == 1 })
            b.tickClock.advance(by: .seconds(1))
        }
        let total = try #require(handle.updates.last?.total)
        #expect(await eventually { handle.updates.last?.completed == total - 1 })
        #expect(handle.updates.allSatisfy { $0.completed < $0.total })
        // Once the card is back the ticks stop.
        await b.link.addStore()
        #expect(await b.finished())
        #expect(b.tickClock.sleepers == 0)
    }

    // MARK: In front

    /// In front, a join the session still can't make (its scene signal not yet active, or the join refused while the
    /// scene is inactive) waits for the person rather than asking again at once.
    @Test func aJoinRefusedInFrontGivesUpAfterOneCall() async throws {
        let b = await bench()
        await b.session.script([.failure(.paused(.needsJoin)), .failure(.paused(.needsJoin)), .link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        #expect(await holdsThroughout {
            await b.model.refresh()
            let calls = await b.session.calls.count
            return b.coordinator.plan.phase == .gaveUp && calls == 1
        })
        #expect(b.notifier.posts.isEmpty)

        b.coordinator.tryAgain()
        #expect(await b.sessionCalls(2))
        #expect(await b.phase(.gaveUp))
        b.coordinator.tryAgain()
        #expect(await b.sessionCalls(3))
        #expect(await b.finished())
    }

    /// Giving up is a real failure (I8): its line goes out at error level, says how long the recovery had run, and holds no
    /// address or name; the lines before it are notices.
    @Test func givingUpIsAnErrorLine() async throws {
        let log = LeveledLog()
        let b = await bench(log: log)
        await b.session.script([.failure(.cameraNotFound), .link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        let errors = log.entries.filter { $0.level == .error }
        #expect(errors.count == 1)
        let line = try #require(errors.first?.line)
        #expect(line.hasPrefix("wifi recovery: gave up after "))
        #expect(line.hasSuffix(" s; waiting for the person"))
        #expect(log.entries.filter { $0.level == .notice }.allSatisfy { $0.line.hasPrefix("wifi recovery:") })
    }

    @Test func aFailedReopenInFrontGivesUpUntilThePersonTriesAgain() async throws {
        let b = await bench()
        await b.session.script([.failure(.cameraNotFound), .link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        #expect(b.model.state == .paused(.cameraUnreachable))
        #expect(b.coordinator.isRecovering)
        #expect(b.notifier.posts.isEmpty)
        #expect(await b.session.calls.count == 1)

        b.coordinator.tryAgain()
        #expect(await b.sessionCalls(2))
        #expect(await b.finished())
        #expect(await b.importedNames == Self.allNames)
    }

    @Test func aReturnToTheFrontAfterGivingUpTriesAgain() async throws {
        let b = await bench()
        await b.session.script([.failure(.cameraNotFound), .link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        await b.model.scenePhaseChanged(.background)
        await b.model.scenePhaseChanged(.active)
        #expect(await b.sessionCalls(2))
        #expect(await b.finished())
    }

    // MARK: What the recovery leaves alone

    @Test func aUSBJobIsLeftAlone() async throws {
        let b = await bench()
        let usb = FakeLink(items: [item("DSC00001.JPG", at: 10, size: 2_000)])
        await usb.set(writesListedSize: true)
        await usb.set(bytesHangs: true)
        let camera = ImportCamera(descriptor: usb.descriptor, key: CameraKeys.key(for: usb.descriptor, material: nil))
        #expect(await b.model.importItems([item("DSC00001.JPG", at: 10, size: 2_000)], from: camera, link: usb)
            == .started(1))
        try await b.engine.pause(.cameraUnreachable)
        #expect(await b.state(.paused(.cameraUnreachable)))
        #expect(b.coordinator.plan.phase == .idle)
        #expect(await b.session.calls.isEmpty)
        await b.model.cancel()
    }

    @Test func withoutASessionNothingHappens() async throws {
        let b = await bench()
        b.coordinator.session = nil
        try await startAndLoseTheSession(b)
        #expect(await b.state(.paused(.cameraUnreachable)))
        #expect(b.coordinator.plan.phase == .idle)
        #expect(await b.session.calls.isEmpty)
        await b.model.cancel()
    }

    /// A job left paused for its camera with no recovery under way (here: the session attached only afterwards) is
    /// taken up by Try again.
    @Test func tryAgainTakesUpAJobLeftPausedForItsCamera() async throws {
        let b = await bench()
        let session = b.coordinator.session
        b.coordinator.session = nil
        try await startAndLoseTheSession(b)
        #expect(await b.state(.paused(.cameraUnreachable)))
        await b.session.script([.link(b.link)])
        b.coordinator.session = session
        #expect(b.coordinator.plan.phase == .idle)
        b.coordinator.tryAgain()
        #expect(await b.sessionCalls(1))
        #expect(await b.finished())
        #expect(await b.importedNames == Self.allNames)
    }

    /// A new session (the next job's) forgets a recovery that waited for the person.
    @Test func settingTheSessionForgetsTheRecovery() async throws {
        let b = await bench()
        await b.session.script([.failure(.cameraNotFound)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        b.coordinator.session = b.session
        #expect(b.coordinator.plan == WiFiRecoveryPlan())
        await b.model.cancel()
    }

    @Test func aReopenThatEndsAfterTheJobWasCancelledFinishesTheSession() async throws {
        let b = await bench()
        let reopened = await b.link.replugged()
        await b.session.script([.linkAfter(.seconds(5), reopened)])
        try await startAndLoseTheSession(b)
        #expect(await b.sessionCalls(1))
        #expect(await eventually { b.clock.sleepers == 1 })
        await b.model.cancel()
        #expect(await b.finished(.cancelled))
        #expect(b.coordinator.plan.phase == .idle)
        b.clock.advance(by: .seconds(5))
        // The session opened for a job that has ended goes into its stay (or leaves).
        #expect(await eventually { await b.session.finishes == 1 })
        #expect(b.listings.knownCounts.isEmpty)
        #expect(b.model.state == .finished(.cancelled))
    }

    @Test func aReopenThatEndsAfterAnExpiryLeavesTheLinkForContinue() async throws {
        let b = await bench()
        let reopened = await b.link.replugged()
        await b.session.script([.linkAfter(.seconds(5), reopened)])
        try await startAndLoseTheSession(b)
        #expect(await b.sessionCalls(1))
        #expect(await eventually { b.clock.sleepers == 1 })
        // iOS ends the continued task while the session reopens.
        #expect(await eventually { !b.run.handles.isEmpty })
        b.run.handles.first?.expire()
        #expect(await b.state(.paused(.taskExpired)))

        b.clock.advance(by: .seconds(5))
        #expect(await eventually { b.listings.knownCounts.count == 1 })
        #expect(await b.phase(.idle))
        // No carrying on without a continued task: still paused for the expiry.
        #expect(b.model.state == .paused(.taskExpired))
        #expect(await reopened.delivered.isEmpty)

        // Continue reconnects through the link the recovery left with the job.
        await b.model.resume()
        #expect(await b.finished())
        #expect(await reopened.resumes == [.init(filename: Self.victim, offset: Self.cut)])
        #expect(await b.importedNames == Self.allNames)
    }

    // MARK: The default listing

    @Test func theDefaultListingReusesKnownItemsWhereTheLinkCan() async throws {
        let card = [item("DSC00001.JPG", at: 10), item("DSC00002.JPG", at: 20)]
        let reusing = ReusingRecordingLink(card: card)
        let listed = try await WiFiRecoveryCoordinator.listNewHandles(reusing, known: Array(card.prefix(1)))
        #expect(listed == card)
        #expect(await reusing.reusedWith == [Array(card.prefix(1))])
        #expect(await reusing.plainLists == 0)

        let plain = FakeLink(items: card)
        try await plain.open()
        #expect(try await WiFiRecoveryCoordinator.listNewHandles(plain, known: card) == card.newestFirst())
    }
}

// MARK: - What the Import screen offers (W16)

extension WiFiRecoveryTests {
    @Test func theScreenOffersTryAgainOnceTheRecoveryGivesUp() async throws {
        let b = await bench()
        #expect(b.model.wifiRecoveryControl == nil)
        await b.session.script([.failure(.cameraNotFound), .link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        #expect(b.model.wifiRecoveryPhase == .gaveUp)
        #expect(b.model.state == .paused(.cameraUnreachable))
        #expect(b.model.wifiRecoveryControl == .tryAgain)
        #expect(b.model.pauseControl == nil)   // Try Again takes the pause button's place, never beside it
        // Given up: the line names Try Again, not "resumes when it's back in reach".
        #expect(b.model.statusLine == ImportWording.pausedTryAgain(.cameraUnreachable))

        b.model.tryAgainWiFi()
        #expect(await b.sessionCalls(2))
        #expect(await b.finished())
        #expect(b.model.wifiRecoveryControl == nil)
        #expect(b.model.wifiRecoveryPhase == .idle)
    }

    @Test func whileTheRecoveryReachesTheCameraTheScreenShowsItWorking() async throws {
        let b = await bench()
        await b.session.script([.linkAfter(.seconds(10), b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.reopening))
        #expect(await eventually { b.model.wifiRecoveryControl == .reconnecting })
        // The camera's own line is right while the recovery reaches it by itself.
        #expect(b.model.statusLine == ImportWording.paused(.cameraUnreachable))
        #expect(await b.sessionCalls(1))
        b.model.tryAgainWiFi()   // not offered: does nothing
        #expect(await holdsThroughout { await b.session.calls.count == 1 })
        #expect(await eventually { b.clock.sleepers == 1 })
        b.clock.advance(by: .seconds(10))
        #expect(await b.finished())
        #expect(b.model.wifiRecoveryControl == nil)
    }

    @Test func aJoinRefusedInFrontSaysTryAgainNotOpenTheApp() async throws {
        let b = await bench()
        await b.session.script([.failure(.paused(.needsJoin)), .link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        #expect(b.model.state == .paused(.needsJoin))
        #expect(b.model.statusLine == ImportWording.needsJoinInFront)
        #expect(b.model.wifiRecoveryControl == .tryAgain)
        b.model.tryAgainWiFi()
        #expect(await b.sessionCalls(2))
        #expect(await b.finished())
    }

    /// B:211's return: the job paused for a join with the app away stays paused for it until the reopen from the front
    /// finishes, and meanwhile the line says the recovery is at work, not to tap a Try Again the screen doesn't show.
    @Test func backInFrontTheReopenForAJoinSaysItIsWorkingNotTryAgain() async throws {
        let b = await bench()
        await b.session.script([.failure(.paused(.needsJoin)), .linkAfter(.seconds(10), b.link)])
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.model.scenePhaseChanged(.background)
        await b.link.loseSession()
        #expect(await b.state(.paused(.needsJoin)))
        #expect(await b.phase(.pausedForJoin))

        await b.model.scenePhaseChanged(.active)
        #expect(await b.sessionCalls(2))
        #expect(await eventually { b.model.wifiRecoveryControl == .reconnecting })
        #expect(b.model.state == .paused(.needsJoin))
        #expect(b.model.statusLine == ImportWording.reconnecting)
        #expect(b.model.statusLine != ImportWording.needsJoinInFront)

        #expect(await eventually { b.clock.sleepers == 1 })
        b.clock.advance(by: .seconds(10))
        #expect(await b.finished())
        #expect(await b.importedNames == Self.allNames)
    }

    /// A job left paused for a join with the recovery forgotten (here: the session set again, as the app may) still
    /// offers Try Again, and Try Again takes it up.
    @Test func tryAgainTakesUpAJobLeftPausedForAJoin() async throws {
        let b = await bench()
        await b.session.script([.failure(.paused(.needsJoin)), .link(b.link)])
        try await startAndLoseTheSession(b)
        #expect(await b.phase(.gaveUp))
        #expect(b.model.state == .paused(.needsJoin))
        b.coordinator.session = b.session
        #expect(b.coordinator.plan.phase == .idle)
        #expect(b.model.wifiRecoveryPhase == .idle)
        #expect(b.model.wifiRecoveryControl == .tryAgain)
        #expect(b.model.statusLine == ImportWording.needsJoinInFront)

        b.model.tryAgainWiFi()
        #expect(await b.sessionCalls(2))
        #expect(await b.finished())
        #expect(await b.importedNames == Self.allNames)
    }

    @Test func awayTheNeededJoinStillSaysOpenTheApp() async throws {
        let b = await bench()
        await b.session.script([.failure(.paused(.needsJoin))])
        #expect(try await b.importAll() == .started(3))
        #expect(await b.victimHeld())
        await b.model.scenePhaseChanged(.background)
        await b.link.loseSession()
        #expect(await b.state(.paused(.needsJoin)))
        #expect(b.model.statusLine == ImportWording.status(b.model.progress, mode: nil))
        #expect(b.model.statusLine != ImportWording.needsJoinInFront)
        await b.model.cancel()
    }

    @Test func noTryAgainForAJobWithoutASession() async throws {
        let b = await bench()
        b.coordinator.session = nil
        try await startAndLoseTheSession(b)
        #expect(await b.state(.paused(.cameraUnreachable)))
        #expect(b.model.wifiRecoveryControl == nil)
        await b.model.cancel()
    }

    @Test func noTryAgainOverUSB() async throws {
        let b = await bench()
        let usb = FakeLink(items: [item("DSC00001.JPG", at: 10, size: 2_000)])
        await usb.set(writesListedSize: true)
        await usb.set(bytesHangs: true)
        let camera = ImportCamera(descriptor: usb.descriptor, key: CameraKeys.key(for: usb.descriptor, material: nil))
        #expect(await b.model.importItems([item("DSC00001.JPG", at: 10, size: 2_000)], from: camera, link: usb)
            == .started(1))
        try await b.engine.pause(.cameraUnreachable)
        #expect(await b.state(.paused(.cameraUnreachable)))
        #expect(b.model.wifiRecoveryControl == nil)
        await b.model.cancel()
    }
}
