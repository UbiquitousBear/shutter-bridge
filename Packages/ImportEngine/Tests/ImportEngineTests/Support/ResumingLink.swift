import CameraTransport
import Foundation
import Synchronization

/// A scripted link that resumes, as `IPLink` does over Sony's 0x9211: by default `CameraLinkCapabilities.wifi` (one
/// transaction, resumes, IDs that survive a reopen). `bytes` writes the file a chunk at a time, reports progress and
/// a checkpoint after each chunk but the last, and, given a `PartialDownload`, cuts the file back to its offset and
/// writes the rest into it (from 0 into the same file if the file is shorter than the offset). It honours
/// cancellation, as `IPLink` does: a held call ends at once with `.noAnswer`. Its events are live.
actor ResumingLink: CameraLink {
    enum Step: Sendable, Hashable {
        case deliver
        /// Writes up to this many bytes of the file, then waits for `release(_:)` or a cancellation.
        case holdAfter(UInt64)
        case fail(CameraLinkFailure.Kind)
        /// Writes up to this many bytes, then throws.
        case failAfter(UInt64, CameraLinkFailure.Kind)
        /// As `holdAfter`, but the held call ignores cancellation, as ImageCaptureCore's can: only `release(_:)`
        /// ends it.
        case holdIgnoringCancellationAfter(UInt64)
        /// As `holdAfter`, once after each of these offsets in turn: each hold waits for its own `release(_:)`.
        case holdAfterEach([UInt64])
        /// Writes up to this many bytes, waits for `release(_:)` (or a cancellation, as `holdAfter`), then throws: the
        /// checkpoints written before the failure are settled while the call is held.
        case holdThenFail(UInt64, CameraLinkFailure.Kind)
    }

    /// A `bytes` call that continued a partial file.
    struct Resume: Sendable, Hashable {
        var name: String
        var offset: UInt64
    }

    nonisolated let descriptor: CameraDescriptor
    nonisolated let capabilities: CameraLinkCapabilities
    let chunk: UInt64
    private nonisolated let subscribers = Mutex<[UUID: AsyncStream<CameraLinkEvent>.Continuation]?>([:])

    var card: [CameraItem]
    /// What `info(of:)` answers for an ID instead of the card's item: the camera's facts changed under a handle.
    private var infoOverrides: [CameraItem.ID: CameraItem] = [:]
    /// Failures `info(of:)` throws for a file's name, one per call, before it answers.
    private var infoFailures: [String: [CameraLinkFailure.Kind]] = [:]
    private var scripts: [String: [Step]] = [:]
    private var held: [String: CheckedContinuation<Bool, Never>] = [:]
    private var heldWaiters: [(String, CheckedContinuation<Void, Never>)] = []

    private(set) var openCount = 0
    /// The session's generation (`CameraLink.sessionGeneration`): 0, no generations, unless a test sets one.
    private(set) var sessionGeneration = 0
    private(set) var listCount = 0
    private(set) var infoCalls: [String] = []
    private(set) var bytesCalls: [String] = []
    private(set) var resumes: [Resume] = []
    private(set) var maxConcurrentBytes = 0
    private var concurrentBytes = 0

    init(card: [CameraItem], chunk: UInt64 = 300, capabilities: CameraLinkCapabilities = .wifi) {
        self.card = card
        self.chunk = max(1, chunk)
        self.capabilities = capabilities
        descriptor = CameraDescriptor(id: .init(rawValue: UUID().uuidString), name: "Resuming",
                                      mode: .wifi(.cameraNetwork))
    }

    /// The bytes of a file at `offset`: deterministic, and different per name.
    static func byte(_ offset: UInt64, of name: String) -> UInt8 {
        let seed = name.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        return UInt8(truncatingIfNeeded: (offset &+ seed) % 251)
    }

    static func content(of name: String, count: UInt64) -> Data {
        Data((0 ..< count).map { byte($0, of: name) })
    }

    // MARK: Scripting

    func script(_ name: String, _ steps: Step...) { scripts[name, default: []] += steps }
    /// The session the link has open now, as a reopen gives it a new one.
    func setSessionGeneration(_ generation: Int) { sessionGeneration = generation }
    func setCard(_ items: [CameraItem]) { card = items }
    func overrideInfo(_ id: CameraItem.ID, with item: CameraItem) { infoOverrides[id] = item }
    func failInfo(_ name: String, _ kinds: CameraLinkFailure.Kind...) { infoFailures[name, default: []] += kinds }

    /// Lets the held call for `name` write the rest of its file.
    func release(_ name: String) { held.removeValue(forKey: name)?.resume(returning: true) }

    func waitUntilHeld(_ name: String) async {
        if held[name] != nil { return }
        await withCheckedContinuation { heldWaiters.append((name, $0)) }
    }

    nonisolated func send(_ event: CameraLinkEvent) {
        for c in subscribers.withLock({ Array(($0 ?? [:]).values) }) { c.yield(event) }
    }

    // MARK: CameraLink

    nonisolated var events: AsyncStream<CameraLinkEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraLinkEvent.self)
        let key = UUID()
        let added = subscribers.withLock { s -> Bool in
            guard s != nil else { return false }
            s?[key] = continuation
            return true
        }
        if added {
            continuation.onTermination = { [weak self] _ in self?.drop(key) }
        } else {
            continuation.finish()
        }
        return stream
    }

    private nonisolated func drop(_ key: UUID) { subscribers.withLock { _ = $0?.removeValue(forKey: key) } }

    func open() throws(CameraLinkFailure) { openCount += 1 }

    func list() throws(CameraLinkFailure) -> [CameraItem] {
        listCount += 1
        return card
    }

    func info(of id: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem {
        guard let item = infoOverrides[id] ?? card.first(where: { $0.id == id }) else {
            throw CameraLinkFailure(.itemNotFound)
        }
        infoCalls.append(item.name)
        if infoFailures[item.name]?.isEmpty == false {
            throw CameraLinkFailure(infoFailures[item.name]!.removeFirst())
        }
        return item
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
        let step = scripts[item.name]?.isEmpty == false ? scripts[item.name]!.removeFirst() : .deliver
        if case let .fail(kind) = step { throw CameraLinkFailure(kind) }

        var url = directory.appendingPathComponent(item.name)
        var offset: UInt64 = 0
        if let partial = resuming {
            url = partial.file
            let length = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .uint64Value ?? 0
            offset = length >= partial.bytesWritten ? partial.bytesWritten : 0
            resumes.append(Resume(name: item.name, offset: offset))
        }
        try prepare(url, at: offset)
        switch step {
        case .fail:
            break
        case .deliver:
            try write(item, &offset, to: item.size, at: url, checkpoint, progress)
        case let .failAfter(n, kind):
            try write(item, &offset, to: min(n, item.size), at: url, checkpoint, progress)
            throw CameraLinkFailure(kind)
        case let .holdAfter(n):
            try write(item, &offset, to: min(n, item.size), at: url, checkpoint, progress)
            guard await hold(item.name) else { throw CameraLinkFailure(.noAnswer, detail: "cancelled") }
            try write(item, &offset, to: item.size, at: url, checkpoint, progress)
        case let .holdAfterEach(offsets):
            for n in offsets {
                try write(item, &offset, to: min(n, item.size), at: url, checkpoint, progress)
                guard await hold(item.name) else { throw CameraLinkFailure(.noAnswer, detail: "cancelled") }
            }
            try write(item, &offset, to: item.size, at: url, checkpoint, progress)
        case let .holdThenFail(n, kind):
            try write(item, &offset, to: min(n, item.size), at: url, checkpoint, progress)
            guard await hold(item.name) else { throw CameraLinkFailure(.noAnswer, detail: "cancelled") }
            throw CameraLinkFailure(kind)
        case let .holdIgnoringCancellationAfter(n):
            try write(item, &offset, to: min(n, item.size), at: url, checkpoint, progress)
            _ = await holdIgnoringCancellation(item.name)
            try write(item, &offset, to: item.size, at: url, checkpoint, progress)
        }
        return url
    }

    func close() {
        let all = subscribers.withLock { s -> [AsyncStream<CameraLinkEvent>.Continuation] in
            defer { s = nil }
            return Array((s ?? [:]).values)
        }
        for c in all { c.finish() }
    }

    /// Ends held calls and the events, so nothing is left waiting after a test.
    func shutdown() {
        for (_, c) in held { c.resume(returning: false) }
        held = [:]
        close()
    }

    // MARK: Private

    private func prepare(_ url: URL, at offset: UInt64) throws(CameraLinkFailure) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if offset == 0 || !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else { throw CameraLinkFailure(.unreadableItem) }
            } else {
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: offset)
                try handle.close()
            }
        } catch let failure as CameraLinkFailure {
            throw failure
        } catch {
            throw CameraLinkFailure(.unreadableItem, detail: "\(error)")
        }
    }

    private func write(_ item: CameraItem, _ offset: inout UInt64, to end: UInt64, at url: URL,
                       _ checkpoint: @Sendable (PartialDownload) -> Void,
                       _ progress: @Sendable (UInt64) -> Void) throws(CameraLinkFailure) {
        guard offset < end else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            while offset < end {
                let n = min(chunk, end - offset)
                try handle.write(contentsOf: Data((offset ..< offset + n).map { Self.byte($0, of: item.name) }))
                offset += n
                progress(offset)
                if offset < item.size { checkpoint(PartialDownload(file: url, bytesWritten: offset)) }
            }
        } catch {
            throw CameraLinkFailure(.unreadableItem, detail: "\(error)")
        }
    }

    /// True when released, false when cancelled or shut down.
    private func hold(_ name: String) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    c.resume(returning: false)
                    return
                }
                held[name] = c
                let due = heldWaiters.filter { $0.0 == name }
                heldWaiters.removeAll { $0.0 == name }
                for (_, w) in due { w.resume() }
            }
        } onCancel: {
            Task { await self.cancelHold(name) }
        }
    }

    private func holdIgnoringCancellation(_ name: String) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            held[name] = c
            let due = heldWaiters.filter { $0.0 == name }
            heldWaiters.removeAll { $0.0 == name }
            for (_, w) in due { w.resume() }
        }
    }

    private func cancelHold(_ name: String) { held.removeValue(forKey: name)?.resume(returning: false) }
}
