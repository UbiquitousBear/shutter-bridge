import CameraTransport
import Foundation
import PTPKit
import PTPSimulator

/// An in-process `CameraLink` over a `ScriptedCard` that behaves the way ImageCaptureCore does over USB, so the
/// engine's pause, continue, stall and retry rules can be tested without hardware or sockets (backlog section 7,
/// the open point). The behaviours it scripts are the ones the findings say the engine must handle, which a PTP/IP
/// link can't reproduce:
///
/// - **A slow catalogue:** with `holdCatalogue()`, `list()` waits until `releaseCatalogue()` (ImageCaptureCore lists
///   nothing until its catalogue ends: 7–12 s in MSC, 65–123 s in MTP on the bench).
/// - **Suspension:** `appLeavesForeground()` sends *will suspend*; `suspend()` sends *did suspend* and holds every
///   call but `info(of:)` (which reads the cached catalogue, as `USBLink`'s does), and every download between chunks,
///   until `resumeOperations()`, as the session's suspension does (the request in flight survived a 632 s
///   suspension in the spike and finished after the return);
///   `cancelSuspending()` sends *cancelled suspending*.
/// - **Removal:** `remove()` sends `.removed`, ends every pending call with `.disconnected` (leaving a partial file
///   where a download had started) and finishes the events: the link can't be used again, as `USBLink` can't.
///   `replugged()` is the camera coming back: a new link over the card as it is then, with new item IDs.
/// - **Downloads** write the object's scripted bytes (`ScriptedCard.content(of:in:)`) into the folder given, under
///   the camera's file name, a chunk at a time with progress after each. `script(_:_:)` makes a file's next call
///   fail, deliver short, or hold part-way until `release(_:)`.
/// - **Failures** for any operation, `fail(_:with:times:)`, each with the kind (and so the outcome) the engine sees.
/// - **Cancellation** is ignored by default, as ImageCaptureCore ignores it (an abandoned call can still be in flight
///   beside the retry); `honoursCancellation` makes a waiting call (held by `.holdAfter`, waiting out a suspension
///   or a held catalogue) end at once with `.noAnswer`, and a download stop at its next chunk, as `IPLink` will.
/// - **Closing** is final, as `USBLink`'s is: `open()` on a closed link throws `.disconnected`.
///
/// Remote Shoot (PC Remote) lists no files (`.modeListsNoFiles`), as `USBLink` reports it. Drops, a slow link and
/// duplicate file names are Iteration 2's fault matrix; the Wi-Fi behaviours (Sony's whole-card session, 0xC201)
/// come in Iteration 3.
public actor SimulatedCameraLink: CameraLink {
    /// An operation a failure can be injected into.
    public enum Operation: String, Sendable, Hashable, CaseIterable {
        case open, list, info, thumbnail, bytes
    }

    /// What one `bytes` call for a file does.
    public enum BytesStep: Sendable, Hashable {
        /// Writes the whole file.
        case deliver
        /// Throws this failure without writing anything.
        case fail(CameraLinkFailure.Kind)
        /// Writes only this many bytes and returns as if it had finished: a file whose size doesn't match the
        /// listing (the engine checks every size).
        case deliverShort(UInt64)
        /// Writes this many bytes, reports them, then waits for `release(_:)` (or a removal, or a cancellation when
        /// honoured) before writing the rest.
        case holdAfter(UInt64)
    }

    private enum HoldOutcome: Sendable {
        case released, removed, cancelled
    }

    public nonisolated let descriptor: CameraDescriptor
    /// Which plugging-in this is: item IDs carry it, so they don't survive a replug, as ImageCaptureCore's don't.
    public nonisolated let generation: Int
    /// The zone capture dates are made in, as ImageCaptureCore makes them in the phone's zone.
    public nonisolated let timeZone: TimeZone
    public nonisolated let honoursCancellation: Bool
    /// The bytes written between progress reports and suspension checks.
    public nonisolated let chunkSize: UInt64

    private let fanOut = LiveEvents<CameraLinkEvent>()

    /// The card as the camera has it now.
    public private(set) var card: ScriptedCard
    public private(set) var isOpen = false
    public private(set) var isRemoved = false
    public private(set) var isSuspended = false
    public private(set) var isCatalogueHeld = false
    /// Opens that succeeded.
    public private(set) var openCount = 0
    /// Every `list()` call that got past a suspension, failed ones included.
    public private(set) var listCount = 0
    /// The file name of every `bytes` call that found its file, in order.
    public private(set) var bytesCalls: [String] = []
    /// Files whose `bytes` call returned, in order.
    public private(set) var delivered: [String] = []
    public private(set) var maxBytesInFlight = 0
    private var bytesInFlight = 0
    private var closed = false

    private var injected: [Operation: [CameraLinkFailure.Kind]] = [:]
    private var scripts: [String: [BytesStep]] = [:]
    private var catalogueWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var suspensionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var listWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var held: [Int: (name: String, continuation: CheckedContinuation<HoldOutcome, Never>)] = [:]
    private var heldWaiters: [(name: String?, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextToken = 0

    /// - Parameters:
    ///   - mode: MTP by default, the mode whose catalogue is slow; MSC behaves the same here; Remote Shoot lists
    ///     no files.
    ///   - name: What the camera calls itself (in MSC the card's volume name, "Untitled", would be truer).
    ///   - descriptorID: The discovery handle; kept across `replugged()`.
    public init(
        card: ScriptedCard,
        mode: CameraMode = .usb(.mtp),
        name: String = "ILCE-7CM2",
        descriptorID: String = "simulated-camera",
        timeZone: TimeZone = .current,
        generation: Int = 1,
        honoursCancellation: Bool = false,
        chunkSize: UInt64 = 256 * 1024
    ) {
        self.card = card
        descriptor = CameraDescriptor(id: .init(rawValue: descriptorID), name: name, mode: mode)
        self.timeZone = timeZone
        self.generation = generation
        self.honoursCancellation = honoursCancellation
        self.chunkSize = max(1, chunkSize)
    }

    // MARK: - CameraLink

    public nonisolated var events: AsyncStream<CameraLinkEvent> { fanOut.subscribe() }

    public func open() async throws(CameraLinkFailure) {
        if isRemoved { throw CameraLinkFailure(.disconnected, detail: "open: the camera has gone") }
        try requireNotClosed(.open)
        try await waitWhileSuspended(.open)
        try requireNotClosed(.open)
        try takeInjected(.open)
        openCount += 1
        isOpen = true
    }

    public func list() async throws(CameraLinkFailure) -> [CameraItem] {
        try requireOpen(.list)
        try await waitWhileSuspended(.list)
        listCount += 1
        let due = listWaiters.filter { $0.count <= listCount }
        listWaiters.removeAll { $0.count <= listCount }
        for waiter in due { waiter.continuation.resume() }
        try takeInjected(.list)
        while isCatalogueHeld && isUsable {
            await park(.catalogue)
            try throwIfCancelled(.list)
        }
        try requireOpen(.list)
        guard descriptor.mode != .usb(.remoteShoot) else {
            throw CameraLinkFailure(.modeListsNoFiles, detail: "list: the catalogue completed at once with no files")
        }
        return card.objects.map(item(for:))
    }

    public func info(of id: CameraItem.ID) async throws(CameraLinkFailure) -> CameraItem {
        try requireOpen(.info)
        try takeInjected(.info)
        guard let object = object(for: id) else {
            throw CameraLinkFailure(.itemNotFound, detail: "info: not on the card")
        }
        return item(for: object)
    }

    public func thumbnail(of id: CameraItem.ID) async throws(CameraLinkFailure) -> Data {
        try requireOpen(.thumbnail)
        try await waitWhileSuspended(.thumbnail)
        try takeInjected(.thumbnail)
        guard let object = object(for: id) else {
            throw CameraLinkFailure(.itemNotFound, detail: "thumbnail: not on the card")
        }
        guard let thumbnail = card.thumbnail(for: object.handle) else {
            throw CameraLinkFailure(.unreadableItem, detail: "thumbnail: none for this format")
        }
        return thumbnail
    }

    public func bytes(
        of id: CameraItem.ID,
        into directory: URL,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL {
        try requireOpen(.bytes)
        try await waitWhileSuspended(.bytes)
        try takeInjected(.bytes)
        guard let object = object(for: id) else {
            throw CameraLinkFailure(.itemNotFound, detail: "bytes: not on the card")
        }
        bytesCalls.append(object.filename)
        bytesInFlight += 1
        maxBytesInFlight = max(maxBytesInFlight, bytesInFlight)
        defer { bytesInFlight -= 1 }

        let url = directory.appendingPathComponent(object.filename, isDirectory: false)
        switch nextStep(for: object.filename) {
        case let .fail(kind):
            throw CameraLinkFailure(kind, detail: "bytes: scripted")
        case .deliver:
            try await write(object, from: 0, to: object.size, at: url, progress: progress)
        case let .deliverShort(count):
            try await write(object, from: 0, to: min(count, object.size), at: url, progress: progress)
        case let .holdAfter(count):
            let first = min(count, object.size)
            try await write(object, from: 0, to: first, at: url, progress: progress)
            try await hold(object.filename)
            try await write(object, from: first, to: object.size, at: url, progress: progress)
        }
        delivered.append(object.filename)
        return url
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        isOpen = false
        fanOut.finish()
        wakeEveryone(with: .removed)
    }

    // MARK: - Scripting the camera

    /// `list()` waits from now until `releaseCatalogue()`: ImageCaptureCore's catalogue still reading the card.
    public func holdCatalogue() { isCatalogueHeld = true }

    /// The catalogue has ended: waiting `list()` calls return.
    public func releaseCatalogue() {
        isCatalogueHeld = false
        wakeAll(.catalogue)
    }

    /// *Will suspend*: the app left the foreground; *did suspend* follows about 30 s later unless it returns.
    public func appLeavesForeground() { fanOut.send(.willSuspend) }

    /// *Did suspend*: from now every call but `info(of:)` waits, and every download stops at its next chunk, until
    /// `resumeOperations()`.
    public func suspend() {
        isSuspended = true
        fanOut.send(.didSuspend)
    }

    /// *Cancelled suspending*: the app came back within the 30 s.
    public func cancelSuspending() { fanOut.send(.cancelledSuspending) }

    /// *Resumed operations*: waiting calls and downloads go on. ImageCaptureCore also sends it with no suspension
    /// before it, and so may a test.
    public func resumeOperations() {
        isSuspended = false
        wakeAll(.suspension)
        fanOut.send(.resumedOperations)
    }

    /// Sends any event as it is, without changing the link's state.
    public func send(_ event: CameraLinkEvent) { fanOut.send(event) }

    /// The cable is pulled: `.removed`, then every pending call ends with `.disconnected` and the events finish.
    /// Later calls throw `.disconnected`; use `replugged()` for the camera coming back.
    public func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        isOpen = false
        fanOut.send(.removed)
        fanOut.finish()
        wakeEveryone(with: .removed)
    }

    /// The camera plugged in again: a new, unopened link over the card as it is now, with the same name, mode and
    /// descriptor and the next generation of item IDs. Failures and scripts don't carry over.
    public func replugged() -> SimulatedCameraLink {
        SimulatedCameraLink(card: card, mode: descriptor.mode, name: descriptor.name,
                            descriptorID: descriptor.id.rawValue, timeZone: timeZone, generation: generation + 1,
                            honoursCancellation: honoursCancellation, chunkSize: chunkSize)
    }

    /// The next `times` calls of `operation` throw `kind` (after waiting out a suspension, before doing anything).
    public func fail(_ operation: Operation, with kind: CameraLinkFailure.Kind, times: Int = 1) {
        injected[operation, default: []] += Array(repeating: kind, count: max(0, times))
    }

    /// The next `bytes` calls for `filename` take these steps, one per call; after them, `.deliver`.
    public func script(_ filename: String, _ steps: BytesStep...) {
        scripts[filename, default: []] += steps
    }

    /// Lets a call held by `.holdAfter` write the rest of its file. Returns whether one was held.
    @discardableResult
    public func release(_ filename: String) -> Bool {
        guard let token = held.filter({ $0.value.name == filename }).keys.min() else { return false }
        resolveHold(token, .released)
        return true
    }

    /// Returns once a call for `filename` (any file if nil) is held by `.holdAfter`.
    public func waitUntilHeld(_ filename: String? = nil) async {
        if held.values.contains(where: { filename == nil || $0.name == filename }) { return }
        await withCheckedContinuation { heldWaiters.append((filename, $0)) }
    }

    /// Returns once `list()` has been called `count` times (counting calls that are still waiting).
    public func waitForListCall(_ count: Int = 1) async {
        if listCount >= count { return }
        await withCheckedContinuation { listWaiters.append((count, $0)) }
    }

    /// The camera takes more frames (`ScriptedCard.shootMore`). Over USB no event says so: the next `list()` has
    /// them. Returns them as this link lists them.
    @discardableResult
    public func shoot(_ frames: [ScriptedCard.Frame], interval: Int = 2) -> [CameraItem] {
        card.shootMore(frames, interval: interval).map(item(for:))
    }

    /// Files deleted on the camera: later calls for them throw `.itemNotFound`.
    public func delete(_ filenames: Set<String>) {
        card.objects.removeAll { filenames.contains($0.filename) }
    }

    /// The listed item for a file on the card, by name.
    public func item(named filename: String) -> CameraItem? {
        card.objects.first { $0.filename == filename }.map(item(for:))
    }

    // MARK: - Private

    private var isUsable: Bool { !isRemoved && !closed }

    private func requireOpen(_ operation: Operation) throws(CameraLinkFailure) {
        if isRemoved { throw CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the camera has gone") }
        try requireNotClosed(operation)
        guard isOpen else {
            throw CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the link isn't open")
        }
    }

    private func requireNotClosed(_ operation: Operation) throws(CameraLinkFailure) {
        if closed { throw CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the link is closed") }
    }

    private func waitWhileSuspended(_ operation: Operation) async throws(CameraLinkFailure) {
        while isSuspended && isUsable {
            await park(.suspension)
            try throwIfCancelled(operation)
        }
        if operation != .open { try requireOpen(operation) }
        else if isRemoved { throw CameraLinkFailure(.disconnected, detail: "open: the camera has gone") }
    }

    private func throwIfCancelled(_ operation: Operation) throws(CameraLinkFailure) {
        if honoursCancellation && Task.isCancelled {
            throw CameraLinkFailure(.noAnswer, detail: "\(operation.rawValue): cancelled")
        }
    }

    private enum WaitList { case suspension, catalogue }

    /// Waits until the list is woken (`wakeAll`), or, when cancellation is honoured, until the task is cancelled.
    /// Callers re-check their condition afterwards, and `throwIfCancelled`.
    private func park(_ list: WaitList) async {
        let token = nextToken
        nextToken += 1
        let honours = honoursCancellation
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                switch list {
                case .suspension: suspensionWaiters[token] = continuation
                case .catalogue: catalogueWaiters[token] = continuation
                }
                if honours && Task.isCancelled { wake(list, token) }
            }
        } onCancel: {
            if honours { Task { await self.wake(list, token) } }
        }
    }

    private func wake(_ list: WaitList, _ token: Int) {
        switch list {
        case .suspension: suspensionWaiters.removeValue(forKey: token)?.resume()
        case .catalogue: catalogueWaiters.removeValue(forKey: token)?.resume()
        }
    }

    private func wakeAll(_ list: WaitList) {
        let tokens = switch list {
        case .suspension: suspensionWaiters.keys.sorted()
        case .catalogue: catalogueWaiters.keys.sorted()
        }
        for token in tokens { wake(list, token) }
    }

    private func takeInjected(_ operation: Operation) throws(CameraLinkFailure) {
        guard var queue = injected[operation], !queue.isEmpty else { return }
        let kind = queue.removeFirst()
        injected[operation] = queue.isEmpty ? nil : queue
        throw CameraLinkFailure(kind, detail: "\(operation.rawValue): injected")
    }

    private func nextStep(for filename: String) -> BytesStep {
        guard var steps = scripts[filename], !steps.isEmpty else { return .deliver }
        let step = steps.removeFirst()
        scripts[filename] = steps.isEmpty ? nil : steps
        return step
    }

    private func itemID(for handle: PTPObjectHandle) -> CameraItem.ID {
        CameraItem.ID(rawValue: "g\(generation)-\(String(handle.rawValue, radix: 16))")
    }

    private func item(for object: ScriptedCard.Object) -> CameraItem {
        CameraItem(id: itemID(for: object.handle), folder: object.folder, name: object.filename, size: object.size,
                   captureDate: PTPDateTime.parse(object.captureDateRaw, defaultTimeZone: timeZone))
    }

    private func object(for id: CameraItem.ID) -> ScriptedCard.Object? {
        card.objects.first { itemID(for: $0.handle) == id }
    }

    /// Writes `start..<end` of the object's bytes at `url` (a new file when `start` is 0), a chunk at a time,
    /// reporting progress and stopping for a suspension between chunks.
    private func write(
        _ object: ScriptedCard.Object, from start: UInt64, to end: UInt64, at url: URL,
        progress: @Sendable (UInt64) -> Void
    ) async throws(CameraLinkFailure) {
        let handle = try openFile(at: url, fresh: start == 0)
        defer { try? handle.close() }
        var offset = start
        while offset < end {
            let n = min(chunkSize, end - offset)
            try append(ScriptedCard.content(of: object.handle, in: offset ..< offset + n), to: handle)
            offset += n
            progress(offset)
            guard offset < end else { break }
            await Task.yield()
            try await waitWhileSuspended(.bytes)
            try throwIfCancelled(.bytes)
        }
    }

    private func openFile(at url: URL, fresh: Bool) throws(CameraLinkFailure) -> FileHandle {
        let fm = FileManager.default
        do {
            if fresh {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: url.path, contents: nil) else {
                    throw CameraLinkFailure(.unreadableItem, detail: "bytes: couldn't create the file")
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        } catch let failure as CameraLinkFailure {
            throw failure
        } catch {
            throw CameraLinkFailure(.unreadableItem, detail: "bytes: \(error)")
        }
    }

    private func append(_ data: Data, to handle: FileHandle) throws(CameraLinkFailure) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw CameraLinkFailure(.unreadableItem, detail: "bytes: \(error)")
        }
    }

    private func hold(_ filename: String) async throws(CameraLinkFailure) {
        let token = nextToken
        nextToken += 1
        let honours = honoursCancellation
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HoldOutcome, Never>) in
                guard isUsable else {
                    continuation.resume(returning: .removed)
                    return
                }
                held[token] = (filename, continuation)
                let due = heldWaiters.filter { $0.name == nil || $0.name == filename }
                heldWaiters.removeAll { $0.name == nil || $0.name == filename }
                for waiter in due { waiter.continuation.resume() }
                if honours && Task.isCancelled { resolveHold(token, .cancelled) }
            }
        } onCancel: {
            if honours { Task { await self.resolveHold(token, .cancelled) } }
        }
        switch outcome {
        case .released: try requireOpen(.bytes)
        case .removed: throw CameraLinkFailure(.disconnected, detail: "bytes: the camera went away mid-file")
        case .cancelled: throw CameraLinkFailure(.noAnswer, detail: "bytes: cancelled")
        }
    }

    private func resolveHold(_ token: Int, _ outcome: HoldOutcome) {
        held.removeValue(forKey: token)?.continuation.resume(returning: outcome)
    }

    /// Ends every wait: held downloads with `outcome`, the rest to find the link unusable.
    private func wakeEveryone(with outcome: HoldOutcome) {
        for token in held.keys.sorted() { resolveHold(token, outcome) }
        wakeAll(.catalogue)
        wakeAll(.suspension)
    }
}
