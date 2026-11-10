import CameraTransport
import Catalogue
import Foundation
import Synchronization
import Testing
@testable import AppUI

// Fakes and helpers for the Wi-Fi models' tests (wireless plan W15). Every wait in them is bounded: nothing here waits on a
// continuation that ignores cancellation, and a condition that never comes fails after a fixed real-time limit instead of
// hanging.

/// The serial a fake camera reports. Not a real serial.
let fakeSerial = "TEST-SERIAL-0001"
let otherSerial = "TEST-SERIAL-0002"
/// A documentation address (RFC 5737), never a real one.
let typedHost = "192.0.2.20"

/// Every subscriber gets what is sent after it subscribed, and a finish ends them all: the semantics of a real link's
/// `events` (`IPLink`'s fan-out), so two readers of one fake link don't take events from each other.
final class TestFanOut<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [Int: AsyncStream<Element>.Continuation] = [:]
    private var nextID = 0
    private var finished = false

    func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let id = lock.withLock { () -> Int? in
                if finished { return nil }
                nextID += 1
                subscribers[nextID] = continuation
                return nextID
            }
            guard let id else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func send(_ element: Element) {
        let current = lock.withLock { Array(subscribers.values) }
        for subscriber in current { subscriber.yield(element) }
    }

    func finish() {
        let current = lock.withLock { () -> [AsyncStream<Element>.Continuation] in
            finished = true
            defer { subscribers = [:] }
            return Array(subscribers.values)
        }
        for subscriber in current { subscriber.finish() }
    }
}

/// A Wi-Fi link that identifies itself, as `IPLink` does once it has opened.
actor FakeWiFiLink: CameraIdentifying {
    nonisolated let descriptor: CameraDescriptor
    nonisolated let capabilities: CameraLinkCapabilities = .wifi
    nonisolated var events: AsyncStream<CameraLinkEvent> { fanOut.stream() }
    private let fanOut = TestFanOut<CameraLinkEvent>()
    private var serial: String?
    private var model: String?
    private let items: [CameraItem]
    private(set) var closed = false
    private(set) var fetched: [CameraItem.ID] = []

    init(serial: String? = fakeSerial, model: String? = "ILCE-7CM2", name: String = "Camera",
         items: [CameraItem] = [], id: String = "fake-wifi-link") {
        descriptor = CameraDescriptor(id: .init(rawValue: id), name: name, mode: .wifi(.cameraNetwork))
        self.serial = serial
        self.model = model
        self.items = items
    }

    func send(_ event: CameraLinkEvent) { fanOut.send(event) }
    func cameraKeyMaterial() -> String? { serial }
    func cameraModelName() -> String? { model }

    func open() throws(CameraLinkFailure) {}
    func list() throws(CameraLinkFailure) -> [CameraItem] { items.newestFirst() }

    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem {
        guard let found = items.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        return found
    }

    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data("thumb".utf8) }

    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) throws(CameraLinkFailure) -> URL {
        guard let found = items.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        let url = directory.appendingPathComponent(found.name)
        do { try Data(count: Int(found.size)).write(to: url) } catch { throw CameraLinkFailure(.phoneStorageFull) }
        fetched.append(item)
        progress(found.size)
        return url
    }

    func close() {
        closed = true
        fanOut.finish()
    }
}

/// A session that answers as scripted and records what it is asked.
final class FakeSession: WirelessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var results: [Result<any CameraLink, WirelessFailure>] = []
    private var stay: Duration?
    private var networkName: String? = "test-network"
    private var peripheralValue: PeripheralID?
    private var phaseValue: WirelessPhase = .ready
    private var gate: AsyncStream<Void>?
    /// `importFinished` closes the link `prepareImport` last handed out, as the real session does (it leaves, or stays
    /// and then leaves, either way closing the link it holds).
    private var closesLinkWhenFinished = false
    private var lastLink: (any CameraLink)?
    let phases: AsyncStream<WirelessPhase>
    private let phaseSink: AsyncStream<WirelessPhase>.Continuation

    init() {
        (phases, phaseSink) = AsyncStream.makeStream()
    }

    var calls: [String] { lock.withLock { recorded } }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    /// The results `prepareImport` gives in turn; the last one repeats.
    func script(_ results: Result<any CameraLink, WirelessFailure>...) { lock.withLock { self.results = results } }
    func send(_ phase: WirelessPhase) { phaseSink.yield(phase) }
    func set(stayRemaining: Duration?) { lock.withLock { stay = stayRemaining } }
    func set(peripheral: PeripheralID?) { lock.withLock { peripheralValue = peripheral } }
    /// Where the session says it is (`.ready` unless a test says otherwise).
    func set(phase: WirelessPhase) { lock.withLock { phaseValue = phase } }
    func set(closesLinkWhenFinished: Bool) { lock.withLock { self.closesLinkWhenFinished = closesLinkWhenFinished } }
    /// Makes `prepareImport` wait until `releasePrepare()` (or its task's cancellation), so a test can hold a connection
    /// in flight. Bounded: the wait ends when the task is cancelled.
    func holdPrepare() {
        let (stream, sink) = AsyncStream<Void>.makeStream()
        lock.withLock { gate = stream; release = sink }
    }
    func releasePrepare() { lock.withLock { release }?.finish() }
    private var release: AsyncStream<Void>.Continuation?
    var phase: WirelessPhase { get async { lock.withLock { phaseValue } } }

    var stayRemaining: Duration? { get async { lock.withLock { stay } } }
    var network: String? { get async { lock.withLock { networkName } } }
    var peripheral: PeripheralID? { get async { lock.withLock { peripheralValue } } }

    func prepareImport() async throws(WirelessFailure) -> any CameraLink {
        let held: AsyncStream<Void>? = lock.withLock { gate }
        if let held {
            var iterator = held.makeAsyncIterator()
            _ = await iterator.next()
        }
        let next: Result<any CameraLink, WirelessFailure>? = lock.withLock {
            recorded.append("prepare")
            return results.count > 1 ? results.removeFirst() : results.first
        }
        guard let next else { throw .cancelled }
        let link = try next.get()
        lock.withLock { lastLink = link }
        return link
    }

    func importFinished() async {
        let closing: (any CameraLink)? = lock.withLock {
            recorded.append("importFinished")
            return closesLinkWhenFinished ? lastLink : nil
        }
        await closing?.close()
    }
    func appMovedToBackground() async { lock.withLock { recorded.append("background") } }
    func appBecameActive() async { lock.withLock { recorded.append("active") } }
    func leave() async { lock.withLock { recorded.append("leave") } }
}

/// The app's connector, faked: one `FakeSession` per camera, and a scripted typed-address open.
final class FakeConnecting: WiFiConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var madeSessions: [CameraDescriptor.ID: FakeSession] = [:]
    private var typed: [TypedCameraAddress] = []
    private var typedResult: Result<any CameraLink, CameraLinkFailure> = .failure(CameraLinkFailure(.noAnswer))
    private var typedGate: AsyncStream<Void>?
    private var typedRelease: AsyncStream<Void>.Continuation?

    func session(for camera: WiFiCameraEntry) -> any WirelessControlling {
        lock.withLock {
            if let session = madeSessions[camera.id] { return session }
            let session = FakeSession()
            madeSessions[camera.id] = session
            return session
        }
    }

    /// The session made for a camera (made on first use).
    func fakeSession(_ id: CameraDescriptor.ID) -> FakeSession? { lock.withLock { madeSessions[id] } }
    var sessionCount: Int { lock.withLock { madeSessions.count } }
    var typedOpens: [TypedCameraAddress] { lock.withLock { typed } }
    func scriptTyped(_ result: Result<any CameraLink, CameraLinkFailure>) { lock.withLock { typedResult = result } }
    /// Makes the typed open wait until `releaseTyped()` (or its task's cancellation).
    func holdTyped() {
        let (stream, sink) = AsyncStream<Void>.makeStream()
        lock.withLock { typedGate = stream; typedRelease = sink }
    }
    func releaseTyped() { lock.withLock { typedRelease }?.finish() }

    func openTyped(_ address: TypedCameraAddress, for camera: WiFiCameraEntry) async throws(CameraLinkFailure)
        -> any CameraLink {
        let held: AsyncStream<Void>? = lock.withLock {
            typed.append(address)
            return typedGate
        }
        if let held {
            var iterator = held.makeAsyncIterator()
            _ = await iterator.next()
        }
        return try lock.withLock { typedResult }.get()
    }
}

/// Collects what a stream sends, so a test reads it without holding the stream.
final class Collector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                self.lock.withLock { self.items.append(element) }
            }
        }
    }

    deinit { task?.cancel() }

    var all: [Element] { lock.withLock { items } }
    func stop() { task?.cancel() }

    /// Waits (at most `seconds` of real time) for at least `count` elements.
    func wait(for count: Int, seconds: Double = 20) async -> Bool {
        await waitUntil(seconds: seconds) { self.all.count >= count }
    }
}

/// `waitUntil` for a condition that has to be asked of an actor.
func waitUntilAsync(seconds: Double = 20, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Polls `condition` until it holds or `seconds` of real time pass. Bounded, and quick when the condition already holds.
func waitUntil(seconds: Double = 20, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// Main-actor flavour of `waitUntil`, for model state.
@MainActor
func waitUntilOnMain(seconds: Double = 20, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// Resumes a continuation once, whichever caller comes first.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func give(_ value: T?) {
        let taken = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}

/// The value of `task`, or nil (and the task cancelled) if it hasn't finished in `seconds` of real time. Even a task that
/// ignores cancellation can't hang the test: the answer comes from whichever of the task and the timer is first.
func bounded<T: Sendable>(_ task: Task<T, Never>, seconds: Double = 20) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let first = FirstAnswer(continuation)
        Task { first.give(await task.value) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            task.cancel()
            first.give(nil)
        }
    }
}

/// A clock the test moves. `sleep` returns when `advance(by:)` passes its deadline, and throws when its task is cancelled.
final class WiFiTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Duration.zero
    private var nextID = 0
    private var sleepers: [Int: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]

    var now: Instant { Instant(offset: lock.withLock { current }) }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline.offset <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = (deadline.offset, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let taken = lock.withLock { sleepers.removeValue(forKey: id) }
            taken?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current += duration
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// A connection source the test drives.
final class FakeConnectionSource: WiFiConnectionSource, @unchecked Sendable {
    let connectionEvents: AsyncStream<WiFiConnectionEvent>
    private let sink: AsyncStream<WiFiConnectionEvent>.Continuation

    init() {
        (connectionEvents, sink) = AsyncStream.makeStream()
    }

    func send(_ event: WiFiConnectionEvent) { sink.yield(event) }
}

/// A discovery whose sources a test scripts: it lists what it is told, knows keys, and opens the links it is given.
actor ScriptedDiscovery: CameraDiscovery {
    nonisolated let discoveries: AsyncStream<CameraDiscoveryEvent>
    private let sink: AsyncStream<CameraDiscoveryEvent>.Continuation
    private var startFailure: CameraLinkFailure?
    private(set) var starts = 0
    private var keys: [CameraDescriptor.ID: CameraKey] = [:]
    private var links: [CameraDescriptor.ID: any CameraLink] = [:]
    private var failureTexts: [CameraDescriptor.ID: String] = [:]
    private var declinedIDs: Set<CameraDescriptor.ID> = []
    private(set) var linkRequests: [CameraDescriptor.ID] = []

    init(startFailure: CameraLinkFailure? = nil) {
        self.startFailure = startFailure
        (discoveries, sink) = AsyncStream.makeStream()
    }

    func send(_ event: CameraDiscoveryEvent) { sink.yield(event) }
    func set(startFailure: CameraLinkFailure?) { self.startFailure = startFailure }
    func set(key: CameraKey?, for id: CameraDescriptor.ID) { keys[id] = key }
    func set(link: (any CameraLink)?, for id: CameraDescriptor.ID) { links[id] = link }
    func set(failureText: String?, for id: CameraDescriptor.ID) { failureTexts[id] = failureText }
    func set(declined: Bool, for id: CameraDescriptor.ID) {
        if declined { declinedIDs.insert(id) } else { declinedIDs.remove(id) }
    }

    func start() throws(CameraLinkFailure) {
        starts += 1
        if let startFailure { throw startFailure }
    }

    func cameraLink(for id: CameraDescriptor.ID) throws(CameraLinkFailure) -> any CameraLink {
        linkRequests.append(id)
        guard let link = links[id] else { throw CameraLinkFailure(.disconnected) }
        return link
    }

    func knownKey(for id: CameraDescriptor.ID) -> CameraKey? { keys[id] }
    func openFailureText(for id: CameraDescriptor.ID) -> String? { failureTexts[id] }
    func openWasDeclined(for id: CameraDescriptor.ID) -> Bool { declinedIDs.contains(id) }
}

/// `eventually` with a limit that suits a loaded CI runner (the iOS Simulator with every suite in parallel): it returns as
/// soon as the condition holds, and gives up after about 20 s of real time.
@MainActor
func eventuallyLong(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
