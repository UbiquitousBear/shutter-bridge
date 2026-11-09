#if canImport(ImageCaptureCore) && os(iOS)
import Foundation
import ImageCaptureCore

/// The `CameraLink` over ImageCaptureCore (backlog section 2): one camera on a USB-C cable, in Image Transfer (MSC)
/// or Image Transfer (MTP). Get one from `USBCameraBrowser.link(for:)`.
///
/// What it does, and what it never does:
/// - **One import path** (decision 7): `requestDownload` per file into the folder the engine names, never into
///   memory; an interrupted file is copied again from its start. No PTP command is sent at all: not in the import
///   path, not to list (listing over PTP is no faster in MTP and impossible in MSC), and never a whole-card
///   `GetObjectPropList` (no answer in 60 s, and the camera answered nothing more until it was replugged).
/// - **Branches on the transport type**, not on `acceptsPTPCommands` (decision 7; `USBModeClassifier`).
/// - **Lists from ImageCaptureCore's own items** (name, folder where it has one, size, capture date), newest first,
///   once its catalogue has completed: 7–12 s in MSC and 65–123 s in MTP on the bench.
/// - **Thumbnails two at a time**, newest first when more wait (`ThumbnailGate`).
/// - **No timeout on downloads**: a stalled download isn't a failure (decision 4). Opening waits 60 s at most and a
///   thumbnail 10 s, as `noAnswer`.
/// - **Every failure classified** (`USBFailureMapping`): a cable pull ends every pending call as `disconnected`
///   (retry on reconnect), including the file in flight, which the engine copies again after the replug. A failed
///   call waits a moment for a removal before it is classified, since ImageCaptureCore's error can come first.
///   After `close()` nothing more is sent: a thumbnail still waiting for a slot ends as `disconnected`.
///
/// The actor runs on the main actor's executor: the spike drove ImageCaptureCore only from the main thread, and its
/// delegates called back there, so the link keeps to what was proven on iOS 27. Its own work is small (bookkeeping
/// around ImageCaptureCore's requests), so the main thread isn't burdened; files are written by ImageCaptureCore.
public actor USBLink: CameraLink {
    public nonisolated var unownedExecutor: UnownedSerialExecutor { MainActor.sharedUnownedExecutor }

    /// As discovery saw it. For `ICTransportTypeUSB` its mode is MTP until the catalogue says otherwise: see `mode`.
    public nonisolated let descriptor: CameraDescriptor

    /// Live, as `CameraLink` requires: each read is a new stream that gets only the events after it (`EventFanOut`).
    /// Every stream finishes after `.removed` (the link can't be used again: the browser hands out a fresh one) and
    /// on `close()`; a read after either gets a finished stream.
    public nonisolated var events: AsyncStream<CameraLinkEvent> { eventFanOut.subscribe() }

    /// Two downloads at a time, no resume, IDs that last one session (`CameraLinkCapabilities.usb`).
    public nonisolated var capabilities: CameraLinkCapabilities { .usb }

    private enum State { case idle, opening, open, closed }

    private let device: ICCameraDevice
    private let deviceUUID: String?
    private let eventFanOut = EventFanOut<CameraLinkEvent>()
    private let delegate: USBDeviceDelegate
    private let signals: AsyncStream<USBDeviceSignal>
    private let signalSink: AsyncStream<USBDeviceSignal>.Continuation
    private var signalTask: Task<Void, Never>?
    private let thumbnails = ThumbnailGate(limit: 2)

    private var state = State.idle
    private var removed = false
    private var pending = PendingCalls<USBRequestOutcome>()
    private var timers: [UInt64: Task<Void, Never>] = [:]
    /// A download in flight: ImageCaptureCore's `Progress`, what has been reported from it, and where to.
    private struct Download {
        let progress: Progress
        var reports: USBProgressReports
        let report: @Sendable (UInt64) -> Void
    }
    private var downloads: [UInt64: Download] = [:]
    private var pollers: [UInt64: Task<Void, Never>] = [:]

    private var openedAt: ContinuousClock.Instant?
    private var catalogueWatch = USBCatalogueWatch()
    private var catalogueComplete = false
    private var timing = USBCatalogueTiming()

    /// The mode as far as the link can tell: the descriptor's until the catalogue completes, then refined
    /// (`USBModeClassifier.mode(after:provisional:)`, whose MTP-or-Remote-Shoot rule is `unverified`).
    public private(set) var mode: USBMode

    private var files: [CameraItem.ID: ICCameraFile] = [:]
    private var itemIDs: [ObjectIdentifier: CameraItem.ID] = [:]
    private var items: [CameraItem.ID: CameraItem] = [:]
    private var ranks: [CameraItem.ID: Int] = [:]
    private var nextItem: UInt64 = 0

    init(device: ICObject<ICCameraDevice>, descriptor: CameraDescriptor, deviceUUID: String?) {
        self.device = device.object
        self.descriptor = descriptor
        self.deviceUUID = deviceUUID
        if case let .usb(usbMode) = descriptor.mode { mode = usbMode } else { mode = .mtp }
        let (signals, signalSink) = AsyncStream<USBDeviceSignal>.makeStream()
        self.signals = signals
        self.signalSink = signalSink
        delegate = USBDeviceDelegate(signalSink)
    }

    /// How the catalogue went, for the bench checks.
    public var catalogueTiming: USBCatalogueTiming { timing }

    /// The camera key's raw material (an open point in MSC; see `USBCameraKeyMaterial`). Never log it.
    public func cameraKeyMaterial() -> USBCameraKeyMaterial? {
        USBCameraKeyMaterial.material(mode: mode, deviceUUID: deviceUUID)
    }

    /// False once the link is closed or its camera has gone: the browser then hands out a fresh link.
    var isUsable: Bool { state != .closed && !removed }

    /// The camera has gone or the link has closed: a call failing now is `disconnected`, whatever its code.
    private var isGone: Bool { removed || state == .closed }

    // MARK: - CameraLink

    public func open() async throws(CameraLinkFailure) {
        while state == .opening {   // a second open waits for the first
            do { try await Task.sleep(for: .milliseconds(50)) } catch { throw USBFailureMapping.cancelled(.open) }
        }
        switch state {
        case .open: return
        case .closed: throw CameraLinkFailure(.disconnected, detail: "open: the link is closed")
        case .idle, .opening: break
        }
        if removed { throw CameraLinkFailure(.disconnected, detail: "open: the camera has gone") }
        state = .opening
        attachDelegate()
        let start = ContinuousClock.now
        openedAt = start
        if !device.hasOpenSession {
            let device = self.device
            let outcome = await request(.open, timeout: USBFailureMapping.openTimeout) { _, done in
                device.requestOpenSession(options: nil) { @Sendable error in
                    done(error.map(USBRequestOutcome.error) ?? .done)
                }
            }
            do throws(CameraLinkFailure) {
                _ = try await resolve(outcome, .open)
            } catch {
                if state == .opening { state = .idle }
                throw error
            }
        }
        guard state == .opening, !removed else {
            throw CameraLinkFailure(.disconnected, detail: "open: the camera went away while opening")
        }
        state = .open
        // A catalogue ImageCaptureCore kept from an earlier session (an app relaunch with the camera plugged in
        // listed 391 files in 0.09 s) may already be complete, and its callback may not come again. With files, it
        // counts at once. Without (PC Remote on an adopted session read 100 % with 0 files after 0.03 s, and so would
        // an empty card), the reading starts the 10 s hold here, at the open, so the completion instant, and the
        // MTP-or-Remote-Shoot answer, don't depend on when `list` is called.
        if !catalogueComplete {
            let now = ContinuousClock.now
            _ = catalogueWatch.read(percent: device.contentCatalogPercentCompleted, at: now)
            if catalogueWatch.fullSince != nil && device.mediaFiles?.isEmpty == false {
                markCatalogueComplete(viaCallback: false, at: now)
            }
        }
    }

    public func list() async throws(CameraLinkFailure) -> [CameraItem] {
        try requireOpen(.list)
        try await awaitCatalogue()
        guard mode.listsFiles else {
            throw CameraLinkFailure(.modeListsNoFiles, detail: "list: the catalogue completed at once with no files")
        }
        let listing = USBListing.listing(from: catalogueEntries())
        items = Dictionary(uniqueKeysWithValues: listing.items.map { ($0.id, $0) })
        ranks = listing.ranks
        return listing.items
    }

    public func info(of item: CameraItem.ID) async throws(CameraLinkFailure) -> CameraItem {
        try requireOpen(.list)
        guard let file = files[item], let current = USBListing.item(from: entry(for: file, id: item)) else {
            throw CameraLinkFailure(.itemNotFound, detail: "info: not in this session's catalogue")
        }
        items[item] = current
        return current
    }

    public func thumbnail(of item: CameraItem.ID) async throws(CameraLinkFailure) -> Data {
        try requireOpen(.thumbnail)
        guard files[item] != nil else {
            throw CameraLinkFailure(.itemNotFound, detail: "thumbnail: not in this session's catalogue")
        }
        try await thumbnails.enter(rank: ranks[item] ?? .max)
        // The link may have closed, or the camera or the file gone, while this waited for a slot.
        let file: ICCameraFile
        do throws(CameraLinkFailure) {
            try requireOpen(.thumbnail)
            guard let current = files[item] else {
                throw CameraLinkFailure(.itemNotFound, detail: "thumbnail: not in this session's catalogue")
            }
            file = current
        } catch {
            await thumbnails.leave()
            throw error
        }
        let outcome = await request(.thumbnail, timeout: USBFailureMapping.thumbnailTimeout) { _, done in
            file.requestThumbnailData(options: nil) { @Sendable data, error in
                if let error { done(.error(error)) }
                else if let data { done(.data(data)) }
                else { done(.failed(CameraLinkFailure(.unreadableItem, detail: "thumbnail: no data and no error"))) }
            }
        }
        await thumbnails.leave()
        guard case let .data(data) = try await resolve(outcome, .thumbnail) else {
            throw CameraLinkFailure(.unreadableItem, detail: "thumbnail: unexpected reply")
        }
        return data
    }

    /// `resuming` is ignored and `checkpoint` never called: ImageCaptureCore copies whole files, so an interrupted
    /// file restarts from 0 and overwrites what is in `directory` (`capabilities.resumesPartialFiles` is false).
    public func bytes(
        of item: CameraItem.ID,
        into directory: URL,
        resuming: PartialDownload?,
        checkpoint: @escaping @Sendable (PartialDownload) -> Void,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL {
        try requireOpen(.download)
        guard let file = files[item], let known = items[item] else {
            throw CameraLinkFailure(.itemNotFound, detail: "download: not in this session's catalogue")
        }
        let size = known.size
        // Into the engine's folder, overwriting what an interrupted copy left (decision 7: start again from 0).
        let options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: directory, .overwrite: true]
        let outcome = await request(.download, timeout: nil) { id, done in
            let requestProgress = file.requestDownload(options: options) { @Sendable filename, error in
                if let error { done(.error(error)) } else { done(.downloaded(filename)) }
            }
            if let requestProgress {
                downloads[id] = Download(progress: requestProgress, reports: USBProgressReports(size: size),
                                         report: progress)
                pollers[id] = Self.pollProgress(of: self, request: id)
            }
        }
        guard case let .downloaded(name) = try await resolve(outcome, .download) else {
            throw CameraLinkFailure(.unreadableItem, detail: "download: unexpected reply")
        }
        let url = USBListing.downloadedURL(completionName: name, fileName: known.name, directory: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let written = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw CameraLinkFailure(.unreadableItem, detail: "download: finished but no file named \(url.lastPathComponent)")
        }
        progress(written)
        return url
    }

    public func close() async {
        guard state != .closed else { return }
        let hadSession = state == .open || state == .opening
        state = .closed
        pending.finishAll(with: .failed(CameraLinkFailure(.disconnected, detail: "the link was closed")))
        stopRequestTasks()
        if hadSession && !removed && device.hasOpenSession {
            // ImageCaptureCore keeps the catalogue while the camera stays plugged in (an app relaunch listed 391 files
            // in 0.09 s), so closing doesn't cost the next open its listing. The result doesn't matter.
            let device = self.device
            _ = await request(.close, timeout: .seconds(10)) { _, done in
                device.requestCloseSession(options: nil) { @Sendable error in
                    done(error.map(USBRequestOutcome.error) ?? .done)
                }
            }
        }
        // Only if it is still ours: after a lost session a fresh link may have installed its own on this device.
        if device.delegate === delegate { device.delegate = nil }
        signalSink.finish()
        signalTask?.cancel()
        signalTask = nil
        eventFanOut.finish()
        files.removeAll()
        items.removeAll()
        itemIDs.removeAll()
        ranks.removeAll()
    }

    // MARK: - Called by the browser

    /// The browser saw the camera go (its own `didRemove`), which may come before or instead of the device's.
    func browserReportedRemoval() { cameraWentAway(detail: "the camera was removed") }

    /// The browser's lifecycle callbacks, passed on to the engine (backlog section 2, *Lifecycle*).
    func forward(_ event: CameraLinkEvent) {
        guard state != .closed, !removed else { return }
        eventFanOut.send(event)
    }

    // MARK: - Device signals

    private func attachDelegate() {
        guard signalTask == nil else { return }
        device.delegate = delegate
        let signals = self.signals
        signalTask = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                await self.handle(signal)
            }
        }
    }

    private func handle(_ signal: USBDeviceSignal) {
        switch signal {
        case .removed:
            cameraWentAway(detail: "the camera was removed")
        case .sessionClosed:
            // Not the link's own close: the session ended under it, which the engine treats like a removal (the
            // camera event says "or the session lost"); the browser hands out a fresh link for the next open.
            if state == .open || state == .opening { cameraWentAway(detail: "the session closed under the link") }
        case .catalogueComplete:
            if !catalogueComplete && (state == .open || state == .opening) {
                markCatalogueComplete(viaCallback: true, at: ContinuousClock.now)
            }
        case let .itemsAdded(count):
            if !catalogueComplete { timing.itemsAnnouncedBeforeComplete += count }
        case let .itemsRemoved(identifiers):
            for identifier in identifiers {
                guard let id = itemIDs.removeValue(forKey: identifier) else { continue }
                files[id] = nil
                items[id] = nil
                ranks[id] = nil
            }
        }
    }

    private func cameraWentAway(detail: String) {
        guard !removed, state != .closed else { return }
        removed = true
        pending.finishAll(with: .failed(CameraLinkFailure(.disconnected, detail: detail)))
        stopRequestTasks()
        eventFanOut.send(.removed)
        eventFanOut.finish() // nothing more can happen on this link
    }

    // MARK: - Catalogue

    private func markCatalogueComplete(viaCallback: Bool, at instant: ContinuousClock.Instant) {
        catalogueComplete = true
        let fileCount = device.mediaFiles?.count ?? 0
        let seconds = openedAt.map { Self.seconds(instant - $0) } ?? 0
        timing.secondsToComplete = seconds
        timing.filesAtCompletion = fileCount
        timing.completedWithoutCallback = !viaCallback
        mode = USBModeClassifier.mode(
            after: .init(fileCount: fileCount, secondsToComplete: seconds), provisional: mode)
    }

    /// Waits for ImageCaptureCore's catalogue, with no time limit (825 files took 123 s in MTP): it ends when the
    /// catalogue completes, the camera goes, the link closes or the caller cancels. If the completion callback
    /// doesn't come, the percentage reading 100 for 10 s counts instead, as in the spike, completed at the first
    /// reading of 100 (`USBCatalogueWatch`; at the open, if it read 100 there).
    private func awaitCatalogue() async throws(CameraLinkFailure) {
        while !catalogueComplete {
            if removed || state != .open {
                throw CameraLinkFailure(.disconnected, detail: "list: the camera went away during the catalogue")
            }
            if let since = catalogueWatch.read(percent: device.contentCatalogPercentCompleted, at: ContinuousClock.now) {
                markCatalogueComplete(viaCallback: false, at: since)
            }
            if catalogueComplete { break }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { throw USBFailureMapping.cancelled(.list) }
        }
    }

    private func catalogueEntries() -> [USBCatalogueEntry] {
        var entries: [USBCatalogueEntry] = []
        for case let file as ICCameraFile in device.mediaFiles ?? [] {
            let identifier = ObjectIdentifier(file)
            let id: CameraItem.ID
            if let known = itemIDs[identifier] {
                id = known
            } else {
                nextItem += 1
                id = CameraItem.ID(rawValue: "usb-\(nextItem)")
                itemIDs[identifier] = id
            }
            files[id] = file
            entries.append(entry(for: file, id: id))
        }
        return entries
    }

    private func entry(for file: ICCameraFile, id: CameraItem.ID) -> USBCatalogueEntry {
        var ancestors: [String] = []
        var folder = file.parentFolder
        while let current = folder, ancestors.count < USBListing.maximumFolderDepth {
            ancestors.append(current.name ?? "")
            folder = current.parentFolder
        }
        return USBCatalogueEntry(id: id, ancestorsNearestFirst: ancestors, name: file.name,
                                 fileSize: Int64(file.fileSize), creationDate: file.creationDate)
    }

    // MARK: - Requests

    private func requireOpen(_ operation: USBFailureMapping.Operation) throws(CameraLinkFailure) {
        if removed { throw CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the camera has gone") }
        guard state == .open else {
            throw CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the link isn't open")
        }
    }

    /// Starts one ImageCaptureCore request and waits for whichever comes first: its completion, its time limit (nil:
    /// none), a cancel, the camera going away or the link closing. `start` runs on the actor with the call's id and
    /// a `done` that may be called from any queue; completions after the first are dropped (`PendingCalls`).
    private func request(
        _ operation: USBFailureMapping.Operation,
        timeout: Duration?,
        _ start: (_ id: UInt64, _ done: @escaping @Sendable (USBRequestOutcome) -> Void) -> Void
    ) async -> USBRequestOutcome {
        if let refusal = USBFailureMapping.refusal(operation, removed: removed, closed: state == .closed) {
            return .failed(refusal)
        }
        let id = pending.reserve()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<USBRequestOutcome, Never>) in
                pending.park(id, continuation)
                if Task.isCancelled {
                    finish(id, .failed(USBFailureMapping.cancelled(operation)))
                    return
                }
                if let timeout { timers[id] = Self.timer(for: self, request: id, operation: operation, after: timeout) }
                start(id) { outcome in
                    Task { await self.finish(id, outcome) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id, operation) }
        }
    }

    private func finish(_ id: UInt64, _ outcome: USBRequestOutcome) {
        timers.removeValue(forKey: id)?.cancel()
        pollers.removeValue(forKey: id)?.cancel()
        downloads[id] = nil   // any poll after this reports nothing (`reportProgress`)
        pending.finish(id, with: outcome)
    }

    private func cancel(_ id: UInt64, _ operation: USBFailureMapping.Operation) {
        guard pending.isWaiting(id) else { return }
        downloads[id]?.progress.cancel()   // whether ImageCaptureCore stops the transfer on this is `unverified`
        finish(id, .failed(USBFailureMapping.cancelled(operation)))
    }

    private func stopRequestTasks() {
        for task in timers.values { task.cancel() }
        for task in pollers.values { task.cancel() }
        timers.removeAll()
        pollers.removeAll()
        downloads.removeAll()
    }

    /// The outcome as a value, or the classified failure. A failed call (all but the close) waits a moment for a
    /// removal first (`USBFailureMapping.removalGrace(for:)`), since the spike's MSC pull failed the file in flight
    /// (-9934) before `didRemove` arrived, and in MTP `didRemove` came 30 ms after a failed read.
    private func resolve(
        _ outcome: USBRequestOutcome, _ operation: USBFailureMapping.Operation
    ) async throws(CameraLinkFailure) -> USBRequestOutcome {
        switch outcome {
        case let .failed(failure):
            throw failure
        case let .frameworkError(domain, code, outOfSpace):
            throw await USBFailureMapping.classify(
                domain: domain, code: code, outOfSpace: outOfSpace, operation: operation
            ) { [self] in await self.isGone }
        case .done, .data, .downloaded:
            return outcome
        }
    }

    /// One progress poll, on the actor: false once the download has finished (stop polling). The report is made
    /// here, before returning, so every report is ordered with `finish` and with `bytes`' final size on disk.
    private func reportProgress(_ id: UInt64) -> Bool {
        guard var download = downloads[id] else { return false }
        guard let bytes = download.reports.poll(fraction: download.progress.fractionCompleted) else { return true }
        downloads[id] = download
        download.report(bytes)
        return true
    }

    private nonisolated static func timer(
        for link: USBLink, request id: UInt64, operation: USBFailureMapping.Operation, after limit: Duration
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await link.finish(id, .failed(USBFailureMapping.timedOut(operation, after: limit)))
        }
    }

    /// Reports the bytes written from `requestDownload`'s `Progress` every 0.25 s while the download runs. Whether
    /// ImageCaptureCore moves it during the transfer is `unverified` (week 1); if it doesn't, progress moves once
    /// per file, when `bytes` reports the size on disk. The reporting itself happens on the actor
    /// (`reportProgress`), so no poll can land after that final report.
    private nonisolated static func pollProgress(of link: USBLink, request id: UInt64) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                guard await link.reportProgress(id) else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
