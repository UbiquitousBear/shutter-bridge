import CameraTransport
import Foundation
import Synchronization

/// A link whose every `bytes` call waits until the test releases it or its task is cancelled, as `IPLink` will
/// honour cancellation. It counts the cancellations, the calls that ended and the most calls in flight at once.
actor CancellableLink: CameraLink {
    private final class Call: Sendable {
        let continuation: Mutex<CheckedContinuation<Bool, Never>?> = Mutex(nil)
        let cancelled = Mutex(false)

        /// Ends the call: true to deliver, false when cancelled. Only the first answer counts.
        func finish(_ deliver: Bool) {
            let c = continuation.withLock { c -> CheckedContinuation<Bool, Never>? in
                defer { c = nil }
                return c
            }
            c?.resume(returning: deliver)
        }
    }

    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "cancellable"), name: "Cancellable",
                                                  mode: .usb(.massStorage))
    nonisolated let capabilities = CameraLinkCapabilities.usb
    nonisolated var events: AsyncStream<CameraLinkEvent> { AsyncStream { $0.finish() } }

    private let card: [CameraItem]
    private var calls: [Call] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var endWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var ended = 0
    private(set) var cancellations = 0

    init(card: [CameraItem]) { self.card = card }

    func open() throws(CameraLinkFailure) {}
    func list() throws(CameraLinkFailure) -> [CameraItem] { card }
    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem {
        guard let found = card.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        return found
    }
    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data() }
    func close() {}

    func bytes(of id: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) -> URL {
        let item = try info(of: id)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        let call = Call()
        calls.append(call)
        let deliver = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                call.continuation.withLock { $0 = c }
                if Task.isCancelled { call.finish(false) }
                let n = calls.count
                for (_, w) in callWaiters.filter({ $0.0 <= n }) { w.resume() }
                callWaiters.removeAll { $0.0 <= n }
            }
        } onCancel: {
            call.cancelled.withLock { $0 = true }
            call.finish(false)
        }
        if call.cancelled.withLock({ $0 }) { cancellations += 1 }
        inFlight -= 1
        ended += 1
        let e = ended
        for (_, w) in endWaiters.filter({ $0.0 <= e }) { w.resume() }
        endWaiters.removeAll { $0.0 <= e }
        guard deliver else { throw CameraLinkFailure(.noAnswer, detail: "cancelled") }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(item.name)
        try? FakeCameraLink.payload(count: item.size).write(to: url)
        return url
    }

    /// Returns once `n` calls have been made.
    func waitCalls(_ n: Int) async {
        if calls.count >= n { return }
        await withCheckedContinuation { callWaiters.append((n, $0)) }
    }

    /// Returns once `n` calls have ended.
    func waitEnded(_ n: Int) async {
        if ended >= n { return }
        await withCheckedContinuation { endWaiters.append((n, $0)) }
    }

    /// Lets every call still waiting deliver its file.
    func releaseAll() {
        for c in calls { c.finish(true) }
    }
}
