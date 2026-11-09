import CameraTransport
import Foundation
import Synchronization

/// A scripted camera link. Each `bytes` call takes the next step scripted for its file name (or `defaultStep`):
/// deliver the file, deliver only some bytes, fail, or hold until the test releases it. It ignores cancellation and
/// creates the target folder before writing, the worst case for a late write. Its events are live, as the `CameraLink`
/// contract says: each read of `events` gets only what is sent after it.
actor FakeCameraLink: CameraLink {
    enum Step: Sendable, Hashable {
        case deliver
        case deliverBytes(UInt64)
        case fail(CameraLinkFailure.Kind)
        case hold
    }

    /// A `bytes` call waiting for the test.
    final class HeldCall: Sendable {
        let filename: String
        let progress: @Sendable (UInt64) -> Void
        private let continuation: Mutex<CheckedContinuation<Step, Never>?>

        init(filename: String, progress: @escaping @Sendable (UInt64) -> Void,
             continuation: CheckedContinuation<Step, Never>) {
            self.filename = filename
            self.progress = progress
            self.continuation = Mutex(continuation)
        }

        /// Lets the call go on with `step`; only the first release counts.
        func release(_ step: Step = .deliver) {
            let c = continuation.withLock { c -> CheckedContinuation<Step, Never>? in
                defer { c = nil }
                return c
            }
            c?.resume(returning: step)
        }
    }

    nonisolated let descriptor: CameraDescriptor
    nonisolated let capabilities: CameraLinkCapabilities
    /// Live subscribers; nil once the stream has been finished.
    private nonisolated let subscribers = Mutex<[UUID: AsyncStream<CameraLinkEvent>.Continuation]?>([:])

    var card: [CameraItem]
    var openFailures: [CameraLinkFailure.Kind] = []
    var listFailures: [CameraLinkFailure.Kind] = []
    var defaultStep: Step = .deliver
    var writesPartialWhileHeld = false
    private var scripts: [String: [Step]] = [:]

    private(set) var openCount = 0
    private(set) var listCount = 0
    private(set) var bytesCalls: [String] = []
    private(set) var maxConcurrentBytes = 0
    private var concurrentBytes = 0

    private var heldQueue: [HeldCall] = []
    private var heldWaiters: [(name: String?, continuation: CheckedContinuation<HeldCall, Never>)] = []
    private var everHeld: [HeldCall] = []

    init(card: [CameraItem], mode: CameraMode = .usb(.massStorage), name: String = "Fake",
         capabilities: CameraLinkCapabilities? = nil) {
        self.card = card
        descriptor = CameraDescriptor(id: .init(rawValue: UUID().uuidString), name: name, mode: mode)
        self.capabilities = capabilities ?? .defaults(for: mode.carrier)
    }

    nonisolated var events: AsyncStream<CameraLinkEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraLinkEvent.self)
        let key = UUID()
        let added = subscribers.withLock { s -> Bool in
            guard s != nil else { return false }
            s?[key] = continuation
            return true
        }
        if added {
            continuation.onTermination = { [weak self] _ in self?.dropSubscriber(key) }
        } else {
            continuation.finish()
        }
        return stream
    }

    private nonisolated func dropSubscriber(_ key: UUID) {
        subscribers.withLock { _ = $0?.removeValue(forKey: key) }
    }

    /// Sends `event` to whoever is subscribed now; nobody else ever sees it.
    nonisolated func send(_ event: CameraLinkEvent) {
        for c in subscribers.withLock({ Array(($0 ?? [:]).values) }) { c.yield(event) }
    }

    private nonisolated func finishEvents() {
        let all = subscribers.withLock { s -> [AsyncStream<CameraLinkEvent>.Continuation] in
            defer { s = nil }
            return Array((s ?? [:]).values)
        }
        for c in all { c.finish() }
    }

    func script(_ filename: String, _ steps: Step...) { scripts[filename, default: []] += steps }
    func setDefaultStep(_ step: Step) { defaultStep = step }
    func setWritesPartialWhileHeld(_ on: Bool) { writesPartialWhileHeld = on }
    func setOpenFailures(_ kinds: [CameraLinkFailure.Kind]) { openFailures = kinds }
    func setListFailures(_ kinds: [CameraLinkFailure.Kind]) { listFailures = kinds }

    /// The deterministic bytes of a file of `count` bytes.
    static func payload(count: UInt64) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 % 251) })
    }

    func open() throws(CameraLinkFailure) {
        openCount += 1
        if !openFailures.isEmpty { throw CameraLinkFailure(openFailures.removeFirst()) }
    }

    func list() throws(CameraLinkFailure) -> [CameraItem] {
        listCount += 1
        if !listFailures.isEmpty { throw CameraLinkFailure(listFailures.removeFirst()) }
        return card
    }

    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem {
        guard let found = card.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        return found
    }

    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data() }

    func bytes(of id: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) -> URL {
        guard let item = card.first(where: { $0.id == id }) else { throw CameraLinkFailure(.itemNotFound) }
        bytesCalls.append(item.name)
        concurrentBytes += 1
        maxConcurrentBytes = max(maxConcurrentBytes, concurrentBytes)
        defer { concurrentBytes -= 1 }
        var step = scripts[item.name]?.isEmpty == false ? scripts[item.name]!.removeFirst() : defaultStep
        while true {
            switch step {
            case .deliver:
                return try write(item, count: item.size, into: directory)
            case let .deliverBytes(n):
                return try write(item, count: n, into: directory)
            case let .fail(kind):
                throw CameraLinkFailure(kind)
            case .hold:
                if writesPartialWhileHeld { _ = try? write(item, count: item.size / 2, into: directory) }
                step = await hold(item.name, progress: progress)
            }
        }
    }

    func close() { finishEvents() }

    private func write(_ item: CameraItem, count: UInt64, into directory: URL) throws(CameraLinkFailure) -> URL {
        let url = directory.appendingPathComponent(item.name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.payload(count: count).write(to: url)
        } catch {
            throw CameraLinkFailure(.unreadableItem, detail: "\(error)")
        }
        return url
    }

    private func hold(_ name: String, progress: @escaping @Sendable (UInt64) -> Void) async -> Step {
        await withCheckedContinuation { (c: CheckedContinuation<Step, Never>) in
            let call = HeldCall(filename: name, progress: progress, continuation: c)
            everHeld.append(call)
            if let i = heldWaiters.firstIndex(where: { $0.name == nil || $0.name == name }) {
                heldWaiters.remove(at: i).continuation.resume(returning: call)
            } else {
                heldQueue.append(call)
            }
        }
    }

    /// The next held call (for `name`, if given), waiting for one if there is none yet.
    func nextHeldCall(_ name: String? = nil) async -> HeldCall {
        if let i = heldQueue.firstIndex(where: { name == nil || $0.filename == name }) {
            return heldQueue.remove(at: i)
        }
        return await withCheckedContinuation { heldWaiters.append((name, $0)) }
    }

    /// Ends every held call and the events stream, so nothing is left waiting after a test.
    func shutdown() {
        for call in everHeld { call.release(.fail(.disconnected)) }
        finishEvents()
    }
}
